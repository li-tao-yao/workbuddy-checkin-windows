# WorkBuddy 每日自动签到 · Windows

**基于 Windows 任务计划程序的 WorkBuddy 国内版每日自动签到工具，支持手动双击安装与 AI Agent 自动部署。**

> A lightweight Windows Task Scheduler automation for WorkBuddy (mainland China edition) daily check-in, supporting both one-click manual setup and AI-agent deployment.

[中文](#中文) · [English](#english)

---

## 中文

### 适用范围与重要说明（先看这里）

本工具通过读取本机 WorkBuddy 登录文件（`refreshToken`）直接请求官方签到接口，无需打开或常驻客户端界面。

| 本机登录格式 | 支持方式 | 说明 |
| --- | --- | --- |
| **明文登录文件**（`refreshToken` 为文本字符串） | **WindowsTask**（推荐） | 注册每日定时任务，无需打开 WorkBuddy，不消耗 AI 积分 |
| **加密登录 + 同 UID 明文伴随文件** | **WindowsTask**（推荐） | 桌面登录文件为加密对象时，自动回退到同一账号 UID 的兼容明文登录文件 |
| **仅存在加密登录对象**（`$wbEncrypted: 1`） | **仅限 ClientTask 模板** | **安全边界说明**：新版 WorkBuddy 将本地登录态改为客户端加密存储。为避免公开发布可独立剥离的第三方凭证提取代码，**本公开仓库故意不包含任何本地解密模块**。此时可通过 [AGENTS.md](AGENTS.md#clienttask) 在客户端内建立定时任务模板（需保持客户端运行、桌面未锁屏且可能消耗 AI 积分） |
| **仅有旧版 `state.vscdb` / 国际版 / macOS / Linux** | **暂不支持** | 请使用国内版最新客户端并登录后用 `Diagnose.cmd` 重新检查 |

> **如何判断自己的电脑走哪条路径？**
> 完整解压仓库后，先双击 **`Diagnose.cmd`**。脚本只检查本地登录文件路径与字段格式，**不读取令牌内容、不联网、不修改任何系统设置**，直接告诉你当前机器属于 `WindowsTask`、`ClientTask` 还是 `Unavailable`。

---

### 核心功能

1. **轻量无界面签到**：直接调用官方刷新令牌接口（`/v2/plugin/auth/token/refresh`）与幂等签到接口（`/billing/meter/daily-checkin`），区分“本次新增积分”与“今日已领（返回码 `10001`）”。
2. **安全网络兜底**：使用 PowerShell 原生 HTTPS 客户端（兼容 PowerShell 7 与系统自带 Windows PowerShell 5.1）。遇到官方域名 TLS 握手异常时在本次调用内切换直连尝试一次，**保持证书校验并禁止 HTTP 重定向**；普通超时或已收到的业务响应不盲目重发。
3. **本机凭证安全保护**：刷新轮换后的 `refreshToken` 使用 Windows DPAPI（`CurrentUser` 作用域）加密缓存在 `%LOCALAPPDATA%\WorkBuddyDailyCheckin\state.json`，日志不打印任何令牌或账号标识。
4. **空闲后台自动释放（可选）**：默认签到成功或确认今日已领后，仅在 **WorkBuddy 不在前台** 且 **本地数据库无活跃 `working` 会话** 时退出空闲后台进程；使用 `-NoClose` 可始终保留客户端。
5. **计划任务防冲突**：仅更新由本项目创建的同名任务（含 `[WorkBuddyCheckinShare]` 标记），发现其他来源的同名任务会停止并提示。

---

### 目录结构

```text
workbuddy-checkin-windows/
├── Diagnose.cmd / Diagnose.ps1   # 只读诊断本机登录路径与可用部署方式（支持 -Json）
├── Install.cmd / Install.ps1     # 注册每日定时任务（默认每天 16:00，支持 -WhatIf 预演）
├── Checkin.cmd                   # 手动触发一次立即签到
├── Uninstall.cmd / Uninstall.ps1 # 卸载本项目注册的计划任务（保留脚本与用户数据）
├── wb-daily-checkin.ps1          # 核心签到主脚本（支持 -NoClose / -CheckOnly）
├── wb-auth-path.ps1              # 登录文件发现、格式判定与同 UID 伴随文件回退
├── wb-cache.ps1                  # Windows DPAPI 当前用户加密/解密缓存封装
├── wb-busy-check.py              # 只读查询本地 SQLite 会话状态（防止误关活跃任务）
├── AGENTS.md                     # 给 AI Agent（WorkBuddy / Codex 等）的非交互部署指南
└── tests/                        # 本地模拟 HTTP / 路由 / 关闭保护 / 忙闲检测测试套件
```

---

### 快速开始（手动安装）

1. 在 Windows 10/11 上安装并登录 **WorkBuddy 国内版**。
2. 下载本仓库（Clone 或 Download ZIP）并**完整解压到一个固定文件夹**（例如 `D:\Tools\workbuddy-checkin-windows`）。**安装后请勿移动或删除该文件夹**，计划任务会直接从此目录运行。
3. 双击 **`Diagnose.cmd`**：
   - 若输出提示“可以安装 Windows 每日任务”，继续下一步。
   - 若提示“检测到加密登录对象”，说明本机只有新版加密登录文件；可参考 [AGENTS.md](AGENTS.md#clienttask) 的客户端内任务模板，无法使用本仓库的轻量计划任务模式。
4. 双击 **`Install.cmd`** 注册当前用户的每日定时任务（默认每天 `16:00`，通常无需管理员权限；错过时间支持补跑，失败后 15 分钟自动重试一次）。
5. 双击 **`Checkin.cmd`** 手动验证一次。如需只验证登录与网络连通性而不提交签到请求，可在仓库目录下运行 PowerShell：

```powershell
.\wb-daily-checkin.ps1 -CheckOnly -NoClose
```

#### 常用自定义参数

```powershell
# 更改每日运行时间（例如每天 09:00），并始终保留已打开的 WorkBuddy 客户端
.\Install.ps1 -DailyTime '09:00' -NoClose

# 仅预演安装参数，不实际写入计划任务
.\Install.ps1 -DailyTime '16:00' -NoClose -WhatIf
```

#### 查看日志与卸载

- **日志与状态位置**：
  - `%LOCALAPPDATA%\WorkBuddyDailyCheckin\checkin.log`
  - `%LOCALAPPDATA%\WorkBuddyDailyCheckin\state.json`（含 DPAPI 加密后的本机缓存令牌，**切勿分享或上传**）
- **卸载**：双击 **`Uninstall.cmd`** 移除计划任务；如需彻底清理，再手动删除解压目录及 `%LOCALAPPDATA%\WorkBuddyDailyCheckin`。

---

### 交给 AI Agent 自动部署

将下方指令发送给具备本机终端操作能力的 AI Agent（如 WorkBuddy、Codex、Antigravity 等）：

> 请从 https://github.com/li-tao-yao/workbuddy-checkin-windows 部署到当前 Windows 用户。按仓库 AGENTS.md 先运行诊断（`Diagnose.ps1 -Json`），若支持 `WindowsTask` 则先用 `-WhatIf` 预演并安装每日 16:00 任务（保留我打开的客户端 `-NoClose`），并回读任务信息验证；不要擅自立即领取。如果诊断为 `ClientTask`，请先向我说明运行条件与积分消耗后再决定是否启用。

---

### 安全与隐私边界

- **官方域名限定**：仅向 `https://www.workbuddy.cn` 与 `https://www.codebuddy.cn` 发送刷新与签到请求。
- **不发送个人数据**：仓库内仅含源码与本地合成测试；请勿将自己的 `*.info`、`state.json`、日志或备份提交到公开仓库。
- **不削弱系统安全**：不禁用证书校验，不跟随 HTTP 重定向，仅对目标进程在确认空闲后执行温和退出。

---

### 开发与回归测试

所有测试均使用本地临时配置与本地模拟 HTTP 服务，**不读取你的真实账号凭证，也不请求线上官方服务器**。需 Python 3.9+：

```powershell
python tests/run-wb-http-tests.py
python tests/test-wb-busy.py
python tests/test-login-routes.py
.\tests\test-wb-network.ps1
```

---

## English

### Overview & Compatibility

This repository provides a Windows Task Scheduler automation script for daily check-in on the mainland China edition of **WorkBuddy**, supporting both manual double-click installation and automated AI-agent setup.

| Local Login Format | Supported Route | Notes |
| --- | --- | --- |
| **Plaintext `refreshToken`** | **WindowsTask** (Recommended) | Runs silently via Windows Task Scheduler; no open client or AI credits required. |
| **Encrypted desktop login + plaintext companion with matching UID** | **WindowsTask** (Recommended) | Automatically falls back to the compatible plaintext `.info` file for the same account UID. |
| **Encrypted-only (`$wbEncrypted: 1`)** | **ClientTask template only** | **Security boundary**: Newer WorkBuddy builds encrypt `refreshToken` locally. To avoid publishing a standalone third-party credential extractor, **this public repository intentionally omits any local decryption module**. See [AGENTS.md](AGENTS.md#clienttask) for an optional in-client UI automation prompt template (requires running client, unlocked desktop, and may consume AI credits). |
| **Legacy `state.vscdb` / International edition / macOS / Linux** | **Unsupported** | — |

### Quick Start (Manual)

1. Install and sign in to the mainland China edition of **WorkBuddy** on Windows 10/11.
2. Clone or extract this repository into a **permanent folder** (do not move or delete it after installation).
3. Double-click **`Diagnose.cmd`** to check your local login format without reading credential contents or making network requests.
4. If eligible for `WindowsTask`, double-click **`Install.cmd`** to register the daily task (default `16:00` local time, runs under current user without admin rights, retries once after 15 minutes on failure).
5. Double-click **`Checkin.cmd`** to test a live check-in, or run read-only connectivity verification in PowerShell:

```powershell
.\wb-daily-checkin.ps1 -CheckOnly -NoClose
```

To customize the schedule or always keep an open WorkBuddy window running:

```powershell
.\Install.ps1 -DailyTime '09:00' -NoClose
```

Double-click **`Uninstall.cmd`** to remove the scheduled task. Logs and DPAPI-encrypted state are stored under `%LOCALAPPDATA%\WorkBuddyDailyCheckin\`.

### AI-Agent Deployment & Tests

AI agents should run `Diagnose.ps1 -Json` and follow [AGENTS.md](AGENTS.md).

Offline regression tests (using synthetic credentials and a local mock HTTP server) run under both Windows PowerShell 5.1 and PowerShell 7+:

```powershell
python tests/run-wb-http-tests.py
python tests/test-wb-busy.py
python tests/test-login-routes.py
.\tests\test-wb-network.ps1
```

## License

[MIT](LICENSE)
