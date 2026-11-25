[CmdletBinding(SupportsShouldProcess=$true)]
param([string]$TaskName = 'WorkBuddyDailyCheckin')
$ErrorActionPreference = 'Stop'
$task = Get-ScheduledTask -TaskName $TaskName -TaskPath '\' -ErrorAction SilentlyContinue
if (-not $task) { Write-Host '未找到签到任务，无需卸载。'; return }
if (-not ([string]$task.Description).Contains('[WorkBuddyCheckinShare]')) {
    throw '该任务不是由本分享包安装的，未作更改。请在任务计划程序中核对任务来源。'
}
if ($PSCmdlet.ShouldProcess($TaskName, '删除本分享包的签到计划任务')) {
    Unregister-ScheduledTask -TaskName $TaskName -TaskPath '\' -Confirm:$false
    Write-Host '已删除签到计划任务。当前正在运行的任务会自行完成。'
    Write-Host '脚本文件及本机运行数据保留；不再需要时可自行清理。'
}
