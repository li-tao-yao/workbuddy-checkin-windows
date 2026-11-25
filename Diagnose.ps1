param([switch]$Json)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'wb-auth-path.ps1')
try { $selection = Get-WbLoginSelection } catch { $selection = @{Route='Unavailable'; Reason='Unreadable'} }
$route = $selection.Route
if ($Json) {
    [ordered]@{route=$route; reason=$selection.Reason} | ConvertTo-Json -Compress
} elseif ($route -eq 'WindowsTask') {
    Write-Host '可以安装 Windows 每日任务。运行 Install.cmd 或按 AGENTS.md 自动部署。'
} elseif ($route -eq 'ClientTask') {
    Write-Host '检测到加密登录对象。请按 AGENTS.md 的 ClientTask 路径，用已登录的 WorkBuddy 部署。'
} else { Write-Host ('请登录国内版 WorkBuddy 后再检查。诊断结果 ' + $selection.Reason) }
if ($route -eq 'Unavailable') { exit 1 }
