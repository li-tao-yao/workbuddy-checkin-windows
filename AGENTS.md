# Deploying WorkBuddy check-in on Windows

适用于 WorkBuddy、Codex 等有本机操作能力的 agent。安装目标是接收者自己的 Windows 账号。所有下列命令都在该账号、同一固定源码目录中运行。例如将仓库克隆到 `%LOCALAPPDATA%\WorkBuddyCheckinSource`，将该目录设为工作目录。已有仓库时先核对 origin、当前版本和未提交修改；保留用户自己的改动。

## 诊断

使用非交互的 PowerShell 脚本入口。双击版的 `.cmd` 有 `pause`，适合人工使用。

```powershell
$engine = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
if (-not $engine) { $engine = (Get-Command powershell.exe -ErrorAction Stop).Source }
$output = & $engine -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\Diagnose.ps1 -Json
$result = $output | ConvertFrom-Json
$result | Select-Object route, reason
```

只向用户展示 `route` 和 `reason`。请勿打开或粘贴登录文件、缓存、令牌、账号标识。按照返回的路由执行：

| route | 含义及操作 |
| --- | --- |
| WindowsTask | 当前登录可用，或找到与桌面账号 UID 相同的兼容文件。继续预演、安装、核对。 |
| ClientTask | 仅有加密对象。转到下方客户端方案，说明运行条件。 |
| Unavailable | 按 reason 处理：LoginRequired 请用户登录国内版客户端；Unreadable 或 UnknownFormat 请反馈诊断原因和客户端版本。停止安装。 |

## WindowsTask

下面的命令保留用户打开的 WorkBuddy。若用户指定时间，替换两处时间。首次安装前检查现有 Windows 任务和 WorkBuddy 内同用途的定时任务，以免建立两个。若同名任务来源冲突，保留原任务并告知用户。

```powershell
& $engine -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\Install.ps1 -DailyTime '16:00' -NoClose -WhatIf
if ($LASTEXITCODE) { throw '安装预演失败，请查看上方错误。' }
& $engine -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\Install.ps1 -DailyTime '16:00' -NoClose
if ($LASTEXITCODE) { throw '安装失败，请查看上方错误。' }
$task = Get-ScheduledTask -TaskName WorkBuddyDailyCheckin -TaskPath '\' -ErrorAction Stop
$task.Actions | Select-Object Execute, Arguments, WorkingDirectory
$task | Get-ScheduledTaskInfo | Select-Object NextRunTime, LastRunTime, LastTaskResult
```

回读并核对任务指向当前固定目录、包含 `-NoClose`、下次触发时间符合用户要求，再报告安装完成。需要验证登录时，用 `wb-daily-checkin.ps1 -CheckOnly -NoClose`，这会刷新凭证但不会领取。只有在用户要求立即签到时才运行 `wb-daily-checkin.ps1 -NoClose`。领取成功、今日已领和已安装是三种不同结果，分别记录。卸载用 `Uninstall.ps1`。

## ClientTask

仅有加密对象时，公开版提供一个**客户端内定时任务模板**。这条路径要求 WorkBuddy 在任务执行时在线运行、本机桌面可交互、有桌面操作能力；模型执行可能消耗积分。若用户要求客户端退出后也要执行，请报告轻量模式不适用于这台机器。不要自动改变用户的运行条件。

用户选择此方式后，在 WorkBuddy 的“定时任务”中查找同用途本地任务，有则复用。确认 Windows 计划任务没有重复执行，再新建本地任务。默认名称“Buddy 加油站每日签到”，时间为每天本机 16:00。使用接收者当前账号和已有桌面权限。任务正文可用：

> 在正在运行的 WorkBuddy 桌面客户端，打开头像菜单里的「Buddy 加油站」，找到每日签到。只在明确可领取时点击一次。看到当日签到成功或新增积分后记录结果；已领取则记录“今日已领”。如果控件不明确、要求登录、桌面被锁或需要用户操作，记录原因并结束本次任务。保持客户端打开，不处理其他奖励。

保存后回读任务卡片的名称、时间、启用状态和下次执行时间。普通终端 agent 没有 WorkBuddy 桌面工具时，将任务模板交给用户或 WorkBuddy 执行，并标注尚未安装。真实领取请以客户端回执或积分明细验收。要停用这条路径，请在 WorkBuddy 自己的定时任务页暂停或删除对应卡片。

官方资料：[WorkBuddy 定时任务](https://www.workbuddy.cn/docs/workbuddy/From-Beginner-to-Expert-Guide/Function-Description/Automation-Guide) · [账号菜单和 Buddy 加油站](https://www.workbuddy.cn/docs/workbuddy/From-Beginner-to-Expert-Guide/Function-Description/Setting)
