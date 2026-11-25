param([Parameter(Mandatory=$true)][string]$TestBaseUrl)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
Write-Output ('Runtime: ' + (Get-Process -Id $PID).Path + ' | ' + $PSVersionTable.PSVersion)

# 仅导入纯函数；不执行脚本主体，不读取登录文件或状态文件。
$source = Join-Path (Split-Path -Parent $PSScriptRoot) 'wb-daily-checkin.ps1'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Script parse failed' }
$functions = $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)
foreach ($name in @('Test-WorkBuddyTlsFailure', 'Invoke-JsonPost', 'Format-CheckinResult', 'Select-RefreshCredential')) {
    $function = $functions | Where-Object Name -EQ $name
    if (@($function).Count -ne 1) { throw ('Missing function: ' + $name) }
    . ([scriptblock]::Create($function.Extent.Text))
}
$TimeoutSec = 4
$passed = 0
function Assert-Equal($Actual, $Expected, [string]$Label) {
    if ($Actual -ne $Expected) { throw ('FAIL ' + $Label) }
    Write-Output ('PASS ' + $Label)
    $script:passed++
}

$headers = @{ 'X-Test-Header' = 'local-test' }
$result = Invoke-JsonPost -Uri ($TestBaseUrl + '/success') -Headers $headers -TimeoutSec 4
Assert-Equal $result.data.credit 100 'HTTP 200 credit'
Assert-Equal (Format-CheckinResult $result).Result 'success' 'success classification'
$result = Invoke-JsonPost -Uri ($TestBaseUrl + '/already') -Headers $headers -TimeoutSec 4
Assert-Equal $result.code 10001 'HTTP 400 business code preserved'
Assert-Equal $result.msg ([string][char]0x4eca + [char]0x5929 + [char]0x5df2 + [char]0x7b7e + [char]0x5230) 'UTF-8 response preserved'
Assert-Equal (Format-CheckinResult $result).Result 'already' 'already classification'
foreach ($path in @('ineligible', 'unauthorized')) {
    $result = Invoke-JsonPost -Uri ($TestBaseUrl + '/' + $path) -Headers $headers -TimeoutSec 4
    Assert-Equal (Format-CheckinResult $result).Result 'error' ($path + ' not success')
}
$result = Invoke-JsonPost -Uri ($TestBaseUrl + '/inactive') -Headers $headers -TimeoutSec 4
Assert-Equal (Format-CheckinResult $result).Result 'inactive' 'activity ended only from claim response'
foreach ($path in @('empty', 'html', 'invalid-json', 'missing-code', 'null', 'server-error', 'redirect')) {
    $thrown = $false
    try { $null = Invoke-JsonPost -Uri ($TestBaseUrl + '/' + $path) -Headers $headers -TimeoutSec 4 } catch { $thrown = $true }
    Assert-Equal $thrown $true ($path + ' fails visibly')
}
$thrown = $false
try { $null = Invoke-JsonPost -Uri 'http://127.0.0.1:1/unreachable' -TimeoutSec 2 } catch { $thrown = $true }
Assert-Equal $thrown $true 'network failure not swallowed'
foreach ($credit in @($null, 0, -1, 'invalid')) {
    $claim = [pscustomobject]@{ code = 0; data = [pscustomobject]@{ credit = $credit } }
    Assert-Equal (Format-CheckinResult $claim).Result 'error' 'no valid awarded credit is not success'
}
$cache = [pscustomobject]@{refreshToken='fixture-new';uid='fixture-user';lastRun='2026-10-17 20:00:00'}
$credential = Select-RefreshCredential 'fixture-old' 'fixture-user' $cache ([datetime]'2026-10-17 19:00:00')
Assert-Equal $credential.Source 'cache' 'rotated cache preferred over stale client'
$credential = Select-RefreshCredential 'fixture-client-new' 'fixture-user' $cache ([datetime]'2026-10-17 21:00:00')
Assert-Equal $credential.Source 'client' 'new client credential preferred'
$credential = Select-RefreshCredential 'fixture-other' 'other-user' $cache ([datetime]'2026-10-17 19:00:00')
Assert-Equal $credential.UserId 'other-user' 'account switch never uses old account cache'
$credential = Select-RefreshCredential '' 'fixture-user' $cache
Assert-Equal $credential.Source 'cache' 'cache works without running client'
$credential = Select-RefreshCredential 'fixture-client' 'fixture-user' $null
Assert-Equal $credential.Source 'client' 'first run works without cache'
Write-Output ('Passed: ' + $passed)
