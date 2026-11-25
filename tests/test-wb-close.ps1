param([Parameter(Mandatory=$true)][string]$TestDirectory)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$LogFile = Join-Path $TestDirectory 'close-test.log'
$source = Join-Path (Split-Path -Parent $PSScriptRoot) 'wb-daily-checkin.ps1'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Script parse failed' }
$functions = $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]}, $true)
foreach ($name in @('Write-Log', 'Get-ForegroundProcessId', 'Test-WorkbuddyBusy', 'Stop-IdleWorkBuddy')) {
    $function = $functions | Where-Object Name -EQ $name
    . ([scriptblock]::Create($function.Extent.Text))
}
$foreground = @(Get-ForegroundProcessId)
if ($foreground.Count -ne 1 -or $foreground[0] -isnot [int] -or -not ('Win32.WbApi' -as [type])) {
    throw 'FAIL native foreground API declaration'
}
Write-Output 'PASS native foreground API declaration'
$busy = @(Test-WorkbuddyBusy -DbPath (Join-Path $TestDirectory 'missing.db') -PyFile (Join-Path $TestDirectory 'helper.py'))
if ($busy.Count -ne 1 -or $busy[0] -isnot [bool] -or -not $busy[0]) {
    throw 'FAIL missing database must return one conservative boolean'
}
Write-Output 'PASS busy logs do not pollute boolean result'

# All process operations below are isolated mocks; no real application is closed.
function New-FakeProcess([int]$Id = 42, [bool]$Graceful = $false) {
    $process = [pscustomobject]@{ Id = $Id; Handle = [IntPtr]1; HasExited = $false; Graceful = $Graceful; CloseCalls = 0 }
    $process | Add-Member ScriptMethod CloseMainWindow { $this.CloseCalls++; if ($this.Graceful) { $this.HasExited = $true }; return $true }
    $process | Add-Member ScriptMethod WaitForExit { param($Milliseconds) return $this.HasExited }
    return $process
}
function Get-Process { [CmdletBinding()]param([string]$Name) return $script:mockProcesses }
function Get-ForegroundProcessId {
    $index = [Math]::Min($script:foregroundCalls, $script:foregroundValues.Count - 1)
    $script:foregroundCalls++
    return $script:foregroundValues[$index]
}
function Test-WorkbuddyBusy {
    $index = [Math]::Min($script:busyCalls, $script:busyValues.Count - 1)
    $script:busyCalls++
    return $script:busyValues[$index]
}
function Stop-Process {
    [CmdletBinding()]param($InputObject, [switch]$Force)
    $script:stopped += $InputObject.Id
    $InputObject.HasExited = $true
}
function Test-CloseCase($Label, $Processes, $Foregrounds, $BusyFlags, $Expected, [int]$ExpectedStops) {
    $script:mockProcesses = @($Processes)
    $script:foregroundValues = @($Foregrounds)
    $script:busyValues = @($BusyFlags)
    $script:foregroundCalls = 0; $script:busyCalls = 0; $script:stopped = @()
    $result = @(Stop-IdleWorkBuddy -GraceSeconds 0)
    if ($result.Count -ne 1 -or $result[0] -ne $Expected -or $script:stopped.Count -ne $ExpectedStops) {
        throw ('FAIL close case ' + $Label)
    }
    Write-Output ('PASS close ' + $Label)
}
Test-CloseCase 'not running' @() @(999) @($false) 'not-running' 0
Test-CloseCase 'foreground protected' @(New-FakeProcess) @(42) @($false) 'skipped-foreground' 0
Test-CloseCase 'unknown foreground protected' @(New-FakeProcess) @(-1) @($false) 'skipped-unknown' 0
Test-CloseCase 'busy task protected' @(New-FakeProcess) @(999) @($true) 'skipped-busy' 0
Test-CloseCase 'idle background processes released' @((New-FakeProcess 42), (New-FakeProcess 43)) @(999,999) @($false,$false) 'closed' 2
Test-CloseCase 'graceful exit' @(New-FakeProcess 42 $true) @(999) @($false) 'closed' 0
Test-CloseCase 'foreground changed before termination' @(New-FakeProcess) @(999,42) @($false) 'skipped-foreground' 0
Test-CloseCase 'task started before termination' @(New-FakeProcess) @(999,999) @($false,$true) 'skipped-busy' 0
Test-CloseCase 'foreground unavailable before termination' @(New-FakeProcess) @(999,-1) @($false) 'skipped-unknown' 0
