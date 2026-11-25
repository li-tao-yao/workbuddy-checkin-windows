# WorkBuddy 每日签到 · Windows

> **版本说明 / Version status**
> 本仓库当前提供候选实现。已在其他电脑验证过的 Windows v2 分享包支持客户端的加密登录对象，候选实现采用不同的登录处理方式。v2 原包尚未在此仓库发布。
> This repository contains a preview with different sign-in handling. The Windows v2 package tested on other PCs has not been published here.

**Windows 自动签到，支持手动安装和 AI agent 部署。** Daily WorkBuddy check-in for Windows, with manual and AI-agent setup. [English quick start](#english-quick-start)

### 交给 WorkBuddy 或其他 AI agent 安装

把这段话发给能操作你 Windows 电脑的 agent：

> 请从 https://github.com/li-tao-yao/workbuddy-checkin-windows 部署到当前 Windows 用户。按仓库 AGENTS.md 先诊断，优先使用轻量模式，每天 16:00，保留我打开的客户端。先验证任务设置，只在我要求时立即领取。如果只能使用客户端内定时任务，请告诉我它的运行条件再启用。

部署分为两条路径。下文的 `Install.cmd` 等命令用于 **WindowsTask**。若诊断选择 **ClientTask**，使用 [客户端内任务模板](AGENTS.md#clienttask)。

用 Windows 任务计划程序为当前用户每天运行一次 WorkBuddy 国内版签到。默认时间为本机 **16:00**。实际领取的积分以服务端响应为准。此项目是个人维护的非官方脚本。

## 先判断你的电脑能否使用

| 条件 | 支持范围 |
| --- | --- |
| 系统 | 面向 Windows 10/11。需要 Windows 任务计划程序以及 PowerShell 7 或系统自带的 Windows PowerShell 5.1。 |
| 账号 | 在运行任务的 Windows 用户下登录自己的国内版 WorkBuddy，且账号有签到资格。 |
| 文本型登录文件 | 可安装 WindowsTask，无需保持 WorkBuddy 打开。 |
| 桌面登录文件为加密对象 | 如果另有同一 UID 的兼容登录文件，仍可安装 WindowsTask。仅有加密对象时可使用 ClientTask 模板，需要本地 WorkBuddy 运行并具备桌面操作能力。 |
| 暂不支持的脚本环境 | 仅有旧版数据库、未知登录格式、国际版、macOS 和 Linux。 |

把仓库 ZIP 完整解压到固定文件夹，先双击 **Diagnose.cmd**。它在本机检查登录文件的路径、字段类型和账号是否匹配，只显示部署方式。排查时可以反馈诊断文字及客户端版本，请保留登录文件在自己的电脑上。

## 安装和使用

1. 诊断通过后，双击 **Install.cmd**，注册当前用户的每日任务。**解压目录需要保留**，任务直接从这个目录运行。
2. 双击 **Checkin.cmd** 可立即领取一次。要只验证登录和连接，在该文件夹的 PowerShell 中运行下面的命令。只检查也会刷新和缓存凭证，状态接口的结果可能滞后，以领取响应和客户端积分记录为准。

   ```powershell
   .\wb-daily-checkin.ps1 -CheckOnly -NoClose
   ```

3. 结果在 `%LOCALAPPDATA%\WorkBuddyDailyCheckin\checkin.log`。脚本区分新增积分和当日已领。自动运行需要 Windows 用户已登录及网络可用。错过时间由计划任务补跑，允许系统唤醒，失败 15 分钟后最多再试一次。

默认领取成功或当日已领后，脚本会尝试退出当前空闲的后台 WorkBuddy。检测到前台使用、有活跃任务或无法确认忙闲时会跳过关闭。忙闲检查用到 Python，签到本身无需安装 Python。若希望始终保留客户端，可用下面的安装方式，并按需修改时间。

```powershell
.\Install.ps1 -DailyTime '16:00' -NoClose
```

双击 **Uninstall.cmd** 可移除本项目安装的计划任务。需要完全清理时，再自行删除解压目录及上述运行数据目录。安装器会核对任务来源，已有其他来源的同名任务时会停止。

## 本机数据

脚本向 `www.workbuddy.cn` 和 `www.codebuddy.cn` 的 HTTPS 接口请求刷新或签到。握手失败时会尝试直连，保持证书校验并禁止 HTTP 重定向。刷新后的凭证使用 Windows DPAPI 按当前用户加密，缓存和日志保存在用户数据目录。公开仓库只放源码和合成测试，用自己的账号在自己的电脑上运行。请勿上传 `*.info`、`state.json`、日志、用户目录或备份。

## 验证

开发测试使用 Python 3.9+，本地模拟服务覆盖首次领取、已领取、登录轮换、仅查询、HTTP 异常和空闲退出保护。在本机分别用 PowerShell 5.1 和 7 验证过。不同电脑上的客户端登录格式仍需通过 Diagnose.cmd 检查。

```powershell
python tests/run-wb-http-tests.py
python tests/test-wb-busy.py
.\tests\test-wb-network.ps1
python tests/test-login-routes.py
```

## English quick start

Sign in to the mainland China edition of WorkBuddy on Windows 10 or 11. Extract the repository into a permanent folder and run **Diagnose.cmd** there. AI agents can run **Diagnose.ps1 -Json** and follow [AGENTS.md](AGENTS.md).

**WindowsTask** uses Windows Task Scheduler at 16:00 local time. Run **Install.cmd** to install or **Uninstall.cmd** to remove the task. To keep an open WorkBuddy client running, use `Install.ps1 -NoClose`. A desktop profile with encrypted credentials can use this route if the script finds a compatible login file with the same account ID.

**ClientTask** is a setup template for WorkBuddy's built-in local scheduler. It uses the signed-in desktop UI, requires a running client and desktop interaction permissions, and may consume agent credits. Availability of the check-in control and rewards depends on the account. The Windows route has offline regression tests. The client template still needs a first successful run on the recipient's device.
