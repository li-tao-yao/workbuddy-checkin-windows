<#
.SYNOPSIS
安装当前用户的 WorkBuddy 每日签到任务，默认每天 16:00。
.EXAMPLE
.\Install.ps1 -WhatIf
.EXAMPLE
.\Install.ps1 -DailyTime '16:00' -NoClose
#>
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [ValidatePattern('^([01][0-9]|2[0-3]):[0-5][0-9]$')]
    [string]$DailyTime = '16:00',
    [string]$TaskName = 'WorkBuddyDailyCheckin',
    [switch]$NoClose
)
$ErrorActionPreference = 'Stop'
$marker = '[WorkBuddyCheckinShare]'
$scriptPath = Join-Path $PSScriptRoot 'wb-daily-checkin.ps1'
foreach ($file in @($scriptPath, (Join-Path $PSScriptRoot 'wb-busy-check.py'), (Join-Path $PSScriptRoot 'wb-cache.ps1'), (Join-Path $PSScriptRoot 'wb-auth-path.ps1'))) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw ('缺少文件，请完整解压分享包：' + (Split-Path -Leaf $file)) }
}
. (Join-Path $PSScriptRoot 'wb-auth-path.ps1')
$selection = Get-WbLoginSelection
if ($selection.Route -eq 'ClientTask') { throw 'EncryptedOnly：请按 AGENTS.md 的 ClientTask 路径在 WorkBuddy 内配置本地定时任务。' }
if ($selection.Route -ne 'WindowsTask') { throw ('请运行 Diagnose.cmd 检查登录。原因 ' + $selection.Reason) }
$programFilesRoot = $env:ProgramW6432
if (-not $programFilesRoot) { $programFilesRoot = $env:ProgramFiles }
$engine = Join-Path $programFilesRoot 'PowerShell\7\pwsh.exe'
if (-not (Test-Path -LiteralPath $engine)) {
    $engine = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
}
if (-not (Test-Path -LiteralPath $engine)) { throw '未找到 PowerShell 7 或 Windows PowerShell 5.1。' }
$existing = Get-ScheduledTask -TaskName $TaskName -TaskPath '\' -ErrorAction SilentlyContinue
if ($existing -and -not ([string]$existing.Description).Contains($marker)) {
    throw '存在其他来源的同名任务，本安装器不会覆盖。请先在任务计划程序中检查旧任务，或用 -TaskName 指定其他名称。'
}
if ($existing -and $existing.State -eq 'Running') { throw '签到任务正在运行，请等待结束后再安装。' }

$arguments = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $scriptPath + '"'
if ($NoClose) { $arguments += ' -NoClose' }
$action = New-ScheduledTaskAction -Execute $engine -Argument $arguments -WorkingDirectory $PSScriptRoot
$time = [datetime]::ParseExact($DailyTime, 'HH:mm', [Globalization.CultureInfo]::InvariantCulture)
$trigger = New-ScheduledTaskTrigger -Daily -At ([datetime]::Today.AddHours($time.Hour).AddMinutes($time.Minute))
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -WakeToRun -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries -RestartCount 1 -RestartInterval (New-TimeSpan -Minutes 15) `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 3) -MultipleInstances IgnoreNew
$userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$principal = New-ScheduledTaskPrincipal -UserId $userSid -LogonType Interactive -RunLevel Limited
$definition = New-ScheduledTask -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
    -Description ($marker + ' 每日领取 WorkBuddy 签到积分；无常驻进程；仅使用当前用户本机登录态。')

if ($PSCmdlet.ShouldProcess($TaskName, ('安装或更新每日 ' + $DailyTime + ' 签到任务'))) {
    Register-ScheduledTask -TaskName $TaskName -TaskPath '\' -InputObject $definition -Force | Out-Null
    Write-Host ('安装完成：每天 ' + $DailyTime + ' 自动签到；失败 15 分钟后补试一次。')
    Write-Host '不需要一直打开 PowerShell 或 WorkBuddy；请保持脚本文件夹位置不变。'
    Write-Host '首次可双击 Checkin.cmd 手动验证。'
} else {
    [pscustomobject]@{
        TaskName = $TaskName; DailyTime = $DailyTime; Engine = $engine; ScriptPath = $scriptPath
        CloseIdleClient = (-not $NoClose); RestartCount = 1; StartWhenAvailable = $true
        WakeToRun = $true; AllowOnBattery = $true; ResidentProcess = $false
    } | ConvertTo-Json
}
