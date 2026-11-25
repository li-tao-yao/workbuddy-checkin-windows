[CmdletBinding()]
param(
    [string]$AuthInfoFile,
    [string]$StateFile = (Join-Path $env:LOCALAPPDATA 'WorkBuddyDailyCheckin\state.json'),
    [string]$LogFile = (Join-Path $env:LOCALAPPDATA 'WorkBuddyDailyCheckin\checkin.log'),
    [switch]$NoClose,
    [switch]$CheckOnly,
    [int]$TimeoutSec = 30
)

$BaseUrl = 'https://www.workbuddy.cn'
$BackupBaseUrl = 'https://www.codebuddy.cn'
. (Join-Path $PSScriptRoot 'wb-auth-path.ps1')
. (Join-Path $PSScriptRoot 'wb-cache.ps1')
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
# 5.1 默认按 ANSI 代码页解码 curl 等原生命令输出，UTF-8 中文会被搞乱导致 JSON 解析失败
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

# ---------------- 基础函数 ----------------

function Write-Log {
    param([Parameter(Mandatory=$true)][string]$Message)
    $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $Message
    try {
        $dir = Split-Path -Parent $LogFile
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [IO.File]::AppendAllText($LogFile, $line + "`r`n", (New-Object Text.UTF8Encoding($false)))
    } catch {}
    # 日志不进入函数的返回值管道，避免把「日志 + $false」误判成 $true。
    Write-Host $line
}

function Test-WorkBuddyTlsFailure {
    param($ErrorRecord, [string]$Uri)
    $target = $null
    if (-not [uri]::TryCreate($Uri, [UriKind]::Absolute, [ref]$target)) { return $false }
    if ($target.Scheme -ne 'https' -or $target.DnsSafeHost -notin @('www.workbuddy.cn','www.codebuddy.cn')) { return $false }
    $errorObject = $ErrorRecord.Exception
    while ($null -ne $errorObject) {
        if ($errorObject -is [Security.Authentication.AuthenticationException]) { return $true }
        if ($errorObject.PSObject.Properties.Name -contains 'HttpRequestError') {
            if ([string]$errorObject.HttpRequestError -eq 'SecureConnectionError') { return $true }
        }
        if ($errorObject -is [Net.WebException] -and $errorObject.Status -in @([Net.WebExceptionStatus]::SecureChannelFailure,[Net.WebExceptionStatus]::TrustFailure)) { return $true }
        $errorObject = $errorObject.InnerException
    }
    return $false
}

function Invoke-JsonPost {
    param(
        [Parameter(Mandatory=$true)][string]$Uri,
        [hashtable]$Headers = @{},
        [string]$Body = '{}',
        [int]$TimeoutSec = 30
    )
    # 使用 PowerShell 的 HTTP 客户端；系统 curl 的 Schannel 在本机因
    # CRYPT_E_REVOCATION_OFFLINE 失败，不能据此判定 WorkBuddy 服务不可用。
    # 不记录请求头/响应正文，也不允许跳转，避免认证头被转发到其他地址。
    # 服务端用 HTTP 400 表示「今天已签到」；必须保留 JSON 业务码。
    $request = @{
        Uri = $Uri
        Method = 'Post'
        Headers = $Headers
        Body = $Body
        ContentType = 'application/json'
        TimeoutSec = $TimeoutSec
        MaximumRedirection = 0
        UseBasicParsing = $true
        ErrorAction = 'Stop'
    }
    $canSkip = (Get-Command Invoke-WebRequest).Parameters.ContainsKey('SkipHttpErrorCheck')
    if ($canSkip) { $request.SkipHttpErrorCheck = $true }
    $status = 0
    $text = $null
    try {
        try { $response = Invoke-WebRequest @request }
        catch {
            # A failed TLS handshake happens before the authenticated HTTP request.
            # Try a different route once in this invocation; never relax certificate
            # checks or retry an HTTP response / ambiguous post-send timeout.
            if (-not (Test-WorkBuddyTlsFailure -ErrorRecord $_ -Uri $Uri)) { throw }
            Write-Log 'WARN  官方接口 TLS 握手失败；本次运行切换直连尝试一次，继续校验证书。'
            if ((Get-Command Invoke-WebRequest).Parameters.ContainsKey('NoProxy')) {
                $request.NoProxy = $true
            } else {
                $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
                $session.Proxy = New-Object Net.WebProxy
                $request.WebSession = $session
            }
            $response = Invoke-WebRequest @request
        }
        $status = [int]$response.StatusCode
        if ($response.Content -is [byte[]]) {
            $text = [Text.Encoding]::UTF8.GetString($response.Content)
        } else {
            $text = [string]$response.Content
        }
    } catch {
        # Windows PowerShell 5.1 在 HTTP 4xx/5xx 时抛异常。
        $response = $_.Exception.Response
        if (-not $response) { throw }
        $status = [int]$response.StatusCode
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            $text = $_.ErrorDetails.Message
        } else {
            $stream = $response.GetResponseStream()
            $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8)
            try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
        }
    }
    if ($status -ge 300 -and $status -lt 400) {
        throw ('HTTP ' + $status + ': redirect refused')
    }
    if ([string]::IsNullOrWhiteSpace($text)) {
        throw ('HTTP ' + $status + ': empty JSON response')
    }
    try { $parsed = $text | ConvertFrom-Json -ErrorAction Stop } catch {
        throw ('HTTP ' + $status + ': invalid JSON response')
    }
    if ($null -eq $parsed -or -not ($parsed.PSObject.Properties.Name -contains 'code')) {
        throw ('HTTP ' + $status + ': missing API business code')
    }
    # 5xx 不能因为正文含 code=0 就被当成签到成功。
    if ($status -ge 500) { throw ('HTTP ' + $status + ': server error') }
    return $parsed
}

function Get-JwtSubject {
    param([string]$Token)
    try {
        $parts = $Token.Split('.')
        if ($parts.Length -lt 2) { return $null }
        $payload = $parts[1].Replace('-', '+').Replace('_', '/')
        switch ($payload.Length % 4) {
            2 { $payload += '==' }
            3 { $payload += '=' }
        }
        $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload))
        $obj = $json | ConvertFrom-Json
        return [string]$obj.sub
    } catch { return $null }
}

function Get-ForegroundProcessId {
    # 用于「关闭 WorkBuddy 前」的安全检查：用户正在前台使用时不关闭。
    try {
        if (-not ('Win32.WbApi' -as [type])) {
            $members = '[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();' +
                '[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);'
            Add-Type -Namespace 'Win32' -Name 'WbApi' -MemberDefinition $members
        }
        $hwnd = [Win32.WbApi]::GetForegroundWindow()
        if ($hwnd -eq [IntPtr]::Zero) { return -1 }
        $procId = 0
        [void][Win32.WbApi]::GetWindowThreadProcessId($hwnd, [ref]$procId)
        return [int]$procId
    } catch { return -1 }
}

function Test-WorkbuddyBusy {
    <#
    通过本地数据库判断是否有会话正在执行任务（status='working' 且近期有活动）。
    返回 $true 表示"有任务在跑"，此时不关闭 WorkBuddy。
    查询失败时保守返回 $true（宁可漏关一天，不可误杀正在跑的任务）。
    注意: 不用 python -c 内联代码——PS 5.1 会破坏含引号的内联参数，必须调用独立 .py 文件。
    #>
    param([int]$FreshMinutes = 60,
        [string]$DbPath = (Join-Path $env:USERPROFILE '.workbuddy\workbuddy.db'),
        [string]$PyFile = (Join-Path $PSScriptRoot 'wb-busy-check.py'))
    if (-not (Test-Path $dbPath)) {
        Write-Log 'WARN  忙闲检测: 数据库不存在，本次不关闭'
        return $true
    }
    if (-not (Test-Path $pyFile)) {
        Write-Log 'WARN  忙闲检测: wb-busy-check.py 缺失，本次不关闭'
        return $true
    }
    $py = $null
    try { $py = (Get-Command python -ErrorAction SilentlyContinue).Source } catch {}
    if (-not $py) {
        $cand = Get-ChildItem (Join-Path $env:USERPROFILE '.workbuddy\binaries\python\versions') -Filter python.exe -Recurse -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending | Select-Object -First 1
        if ($cand) { $py = $cand.FullName }
    }
    if (-not $py) {
        Write-Log 'WARN  忙闲检测: 找不到 python，本次不关闭'
        return $true
    }
    $cutoff = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - ($FreshMinutes * 60 * 1000)
    $count = $null
    for ($i = 0; $i -lt 2; $i++) {
        try {
            $out = & $py $pyFile $dbPath $cutoff 2>$null
            if ($LASTEXITCODE -eq 0 -and $out) { $count = [int]($out | Select-Object -Last 1); break }
        } catch {}
        if ($i -eq 0) { Start-Sleep -Seconds 3 }
    }
    if ($null -eq $count) {
        Write-Log 'WARN  忙闲检测: 查询失败，按"有任务在跑"处理，本次不关闭'
        return $true
    }
    return ($count -gt 0)
}

function Stop-IdleWorkBuddy {
    param([int]$GraceSeconds = 5)
    $processes = @(Get-Process -Name 'WorkBuddy' -ErrorAction SilentlyContinue)
    if ($processes.Count -eq 0) {
        Write-Log 'INFO  WorkBuddy 未在运行，无需启动或关闭'
        return 'not-running'
    }
    $foreground = Get-ForegroundProcessId
    if ($foreground -lt 1) {
        Write-Log 'WARN  无法确认前台窗口，本次跳过关闭'
        return 'skipped-unknown'
    }
    if ($processes.Id -contains $foreground) {
        Write-Log 'INFO  WorkBuddy 正在前台使用，本次跳过关闭'
        return 'skipped-foreground'
    }
    if (Test-WorkbuddyBusy) {
        Write-Log 'INFO  检测到近期有任务执行或状态未知，本次跳过关闭'
        return 'skipped-busy'
    }
    # 先取得进程句柄，随后只处理这一批进程，避免误关用户新开的实例。
    try { foreach ($process in $processes) { $null = $process.Handle } } catch {
        Write-Log 'WARN  无法安全定位 WorkBuddy 进程，本次跳过关闭'
        return 'skipped-unknown'
    }
    Write-Log ('INFO  正在退出空闲后台 WorkBuddy（' + $processes.Count + ' 个进程）')
    foreach ($process in $processes) {
        try { $null = $process.CloseMainWindow() } catch {}
    }
    $deadline = (Get-Date).AddSeconds($GraceSeconds)
    do {
        $remaining = @($processes | Where-Object { -not $_.HasExited })
        if ($remaining.Count -eq 0 -or (Get-Date) -ge $deadline) { break }
        Start-Sleep -Seconds 1
    } while ($true)
    if ($remaining.Count -gt 0) {
        # 关闭窗口可能仅隐藏到托盘；结束残留前再次检查用户是否开始使用。
        $foreground = Get-ForegroundProcessId
        if ($foreground -lt 1) { return 'skipped-unknown' }
        if ($processes.Id -contains $foreground) { return 'skipped-foreground' }
        if (Test-WorkbuddyBusy) { return 'skipped-busy' }
        try {
            foreach ($process in $remaining) {
                if (-not $process.HasExited) { Stop-Process -InputObject $process -Force -ErrorAction Stop }
            }
        } catch {
            Write-Log 'WARN  部分 WorkBuddy 后台进程未能退出'
            return 'close-failed'
        }
        foreach ($process in $remaining) {
            try { $null = $process.WaitForExit(2000) } catch {}
        }
        if (@($processes | Where-Object { -not $_.HasExited }).Count -gt 0) { return 'close-failed' }
    }
    Write-Log 'INFO  WorkBuddy 已退出，后台进程已释放'
    return 'closed'
}

function Select-RefreshCredential {
    param([string]$LocalToken, [string]$LocalUserId, $CachedState,
        [datetime]$LocalLastWriteTime = [datetime]::MinValue)
    $cachedToken = $null; $cachedUid = $null
    $cachedTime = [datetime]::MinValue
    if ($null -ne $CachedState) {
        $cachedToken = [string]$CachedState.refreshToken
        $cachedUid = [string]$CachedState.uid
        if ($CachedState.lastRun) {
            [void][datetime]::TryParseExact([string]$CachedState.lastRun, 'yyyy-MM-dd HH:mm:ss',
                [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$cachedTime)
        }
    }
    # 刷新接口会轮换凭证；客户端不运行时，其文件不会同步更新。
    # 只在账号一致时选择更新的脚本缓存，防止切换账号后领到旧账号。
    $canUseCache = $cachedToken -and (-not $LocalUserId -or $LocalUserId -eq $cachedUid)
    if ($canUseCache -and (-not $LocalToken -or $cachedTime -gt $LocalLastWriteTime)) {
        return [pscustomobject]@{ RefreshToken = $cachedToken; UserId = $cachedUid; Source = 'cache' }
    }
    return [pscustomobject]@{ RefreshToken = $LocalToken; UserId = $LocalUserId; Source = 'client' }
}

# ---------------- 1. 读取登录态（refreshToken / uid） ----------------

$refreshToken = $null
$uid = $null
$authLastWriteTime = [datetime]::MinValue

try {
    $selection = Get-WbLoginSelection -ExplicitPath $AuthInfoFile
    if ($selection.Route -eq 'WindowsTask') {
        $AuthInfoFile = $selection.Path
        $info = $selection.Info
        $refreshToken = $info.auth.refreshToken
        $uid = [string]$info.account.uid
        $authLastWriteTime = (Get-Item -LiteralPath $AuthInfoFile).LastWriteTime
    } elseif (-not $AuthInfoFile -and $selection.Route -eq 'Unavailable' -and $selection.Reason -eq 'LoginRequired' -and (Test-Path -LiteralPath $StateFile)) {
        Write-Log 'WARN  未找到客户端登录文件，尝试使用脚本缓存凭证'
    } else {
        throw ('请运行 Diagnose.cmd，部署路径见 AGENTS.md。原因 ' + $selection.Reason)
    }
} catch { Write-Log ('ERROR ' + $_.Exception.Message); exit 1 }

$state = $null
if (Test-Path -LiteralPath $StateFile) {
    try {
        $state = Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $uid -or $state.uid -eq $uid) { $state.refreshToken = Unprotect-WbCacheToken -Token $state.refreshToken }
        else { $state = $null }
    } catch { $state = $null }
}

$credential = Select-RefreshCredential -LocalToken $refreshToken -LocalUserId $uid -CachedState $state -LocalLastWriteTime $authLastWriteTime
$refreshToken = $credential.RefreshToken
$uid = $credential.UserId
if ($credential.Source -eq 'cache') { Write-Log 'INFO  已使用脚本缓存的较新登录凭证' }

if (-not $refreshToken) {
    Write-Log 'ERROR 未找到可用凭证。请先打开并登录 WorkBuddy 客户端，再重新运行本脚本。'
    exit 1
}

# ---------------- 2. 刷新 accessToken ----------------

function Get-FreshAccessToken {
    param([string]$Rt, [string]$Url)
    $headers = @{
        'X-Refresh-Token' = $Rt
        'X-Auth-Refresh-Source' = 'plugin'
        'Accept' = 'application/json'
    }
    return Invoke-JsonPost -Uri ($Url + '/v2/plugin/auth/token/refresh') -Headers $headers -TimeoutSec $TimeoutSec
}

$tokenResp = $null
try {
    $tokenResp = Get-FreshAccessToken -Rt $refreshToken -Url $BaseUrl
} catch {
    Write-Log ('WARN  主域名刷新失败，切换备用域名: ' + $_.Exception.Message)
}

if ($tokenResp -eq $null -or $tokenResp.code -ne 0) {
    try {
        $tokenResp = Get-FreshAccessToken -Rt $refreshToken -Url $BackupBaseUrl
    } catch {
        Write-Log ('ERROR token 刷新失败: ' + $_.Exception.Message)
        exit 1
    }
}

if ($tokenResp.code -ne 0 -or -not $tokenResp.data.accessToken) {
    Write-Log ('ERROR token 刷新返回异常: code=' + $tokenResp.code + ' msg=' + $tokenResp.msg)
    exit 1
}

$accessToken = [string]$tokenResp.data.accessToken
if ($tokenResp.data.refreshToken) { $refreshToken = [string]$tokenResp.data.refreshToken }
if (-not $uid) {
    $uid = Get-JwtSubject -Token $accessToken
    if (-not $uid) {
        Write-Log 'ERROR 无法确定账号 uid'
        exit 1
    }
    Write-Log 'INFO  已从令牌确定账号标识'
}

# ---------------- 3. 执行每日签到 ----------------

function Invoke-DailyCheckin {
    param([string]$Token, [string]$UserId)
    $headers = @{
        'Authorization' = 'Bearer ' + $Token
        'X-User-Id' = $UserId
        'Accept' = 'application/json'
        'Content-Type' = 'application/json'
    }
    return Invoke-JsonPost -Uri ($BaseUrl + '/billing/meter/daily-checkin') -Headers $headers -TimeoutSec $TimeoutSec
}

function Format-CheckinResult {
    param($Claim)
    if ($Claim -eq $null) { return @{ Result = 'error'; Credit = 0; Streak = 0; Msg = 'empty response' } }
    if ($Claim.code -eq 0) {
        $credit = 0; $streak = 0
        if (-not [int]::TryParse([string]$Claim.data.credit, [ref]$credit) -or $credit -le 0) {
            return @{ Result = 'error'; Credit = 0; Streak = 0; Msg = '领取响应未包含有效的新增积分' }
        }
        if ($Claim.data.streak_days) { $streak = [int]$Claim.data.streak_days }
        return @{ Result = 'success'; Credit = $credit; Streak = $streak; Msg = [string]$Claim.msg }
    }
    if ($Claim.code -eq 10001) { return @{ Result = 'already'; Credit = 0; Streak = 0; Msg = [string]$Claim.msg } }
    if ($Claim.code -eq 10003) { return @{ Result = 'inactive'; Credit = 0; Streak = 0; Msg = [string]$Claim.msg } }
    return @{ Result = 'error'; Credit = 0; Streak = 0; Msg = ('code=' + $Claim.code + ' ' + $Claim.msg) }
}

$outcome = @{ Result = 'error'; Credit = 0; Streak = 0; Msg = 'check-in not attempted' }
try {
    # 活动状态接口在实际已手动领取的账号上仍返回 inactive，不作为领取门槛。
    # daily-checkin 自身幂等：已领取会返回 10001，不会重复发放。
    if ($CheckOnly) {
        $statusHeaders = @{Authorization=('Bearer ' + $accessToken);'X-User-Id'=$uid;Accept='application/json'}
        $statusResponse = Invoke-JsonPost -Uri ($BaseUrl + '/billing/meter/checkin-status') -Headers $statusHeaders -TimeoutSec $TimeoutSec
        if ($statusResponse.code -ne 0 -or $null -eq $statusResponse.data) { throw 'WB_STATUS_QUERY_FAILED' }
        if ($statusResponse.data.today_checked_in -isnot [bool]) { throw 'WB_STATUS_FORMAT_UNKNOWN' }
        $outcome = @{Result='checked';Credit=0;Streak=0;Msg=('登录刷新和状态查询成功；接口返回今日已签到=' + [string]$statusResponse.data.today_checked_in + '（该状态接口可能滞后，不作为领取依据）；未提交领取请求。')}
    } else {
        $claim = Invoke-DailyCheckin -Token $accessToken -UserId $uid
        $outcome = Format-CheckinResult -Claim $claim
    }
} catch {
    Write-Log ('ERROR 签到请求失败: ' + $_.Exception.Message)
    $outcome = @{ Result = 'error'; Credit = 0; Streak = 0; Msg = $_.Exception.Message }
}

switch ($outcome.Result) {
    'success' { Write-Log ('OK    签到成功，获得 ' + $outcome.Credit + ' 积分，连续签到 ' + $outcome.Streak + ' 天') }
    'already' { Write-Log ('INFO  今天已签到，无需重复领取（' + $outcome.Msg + '）') }
    'inactive' { Write-Log ('INFO  ' + $outcome.Msg) }
    'checked' { Write-Log ('INFO  ' + $outcome.Msg) }
    default   { Write-Log ('ERROR 签到失败: ' + $outcome.Msg) }
}

# ---------------- 4. 保存状态 ----------------

$prevSuccess = 0; $prevAlready = 0; $prevError = 0
if ($state -ne $null) {
    if ($state.PSObject.Properties.Name -contains 'successCount') { $prevSuccess = [int]$state.successCount }
    if ($state.PSObject.Properties.Name -contains 'alreadyCount') { $prevAlready = [int]$state.alreadyCount }
    if ($state.PSObject.Properties.Name -contains 'errorCount') { $prevError = [int]$state.errorCount }
}

$newState = [ordered]@{
    refreshToken  = $null
    uid           = $uid
    lastRun       = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    lastResult    = $outcome.Result
    lastMessage   = $outcome.Msg
    lastCredit    = $outcome.Credit
    lastStreak    = $outcome.Streak
    successCount  = $prevSuccess
    alreadyCount  = $prevAlready
    errorCount    = $prevError
}

switch ($outcome.Result) {
    'success' { $newState.successCount = $prevSuccess + 1 }
    'already' { $newState.alreadyCount = $prevAlready + 1 }
    'inactive' { } # 活动未开放不是脚本故障，不触发计划任务失败重试。
    'checked' { } # 查询不计为自动领取成功。
    default   { $newState.errorCount = $prevError + 1 }
}

try {
    $newState.refreshToken = Protect-WbCacheToken -Token $refreshToken
    $newState | ConvertTo-Json | Set-Content -Path $StateFile -Encoding UTF8
} catch {
    Write-Log ('WARN  状态保存失败: ' + $_.Exception.Message)
}

# ---------------- 5. 按需关闭 WorkBuddy ----------------
# 三道保护，任一命中即跳过关闭：
#   1. 前台窗口属于 WorkBuddy（用户正在用）
#   2. 数据库存在 working 状态且 60 分钟内有活动的会话（有任务正在执行）
#   3. -NoClose 开关
# 另：签到失败（success/already 之外）一律不关。

$shouldClose = (-not $NoClose) -and ($outcome.Result -eq 'success' -or $outcome.Result -eq 'already')

if ($shouldClose) {
    $closeResult = Stop-IdleWorkBuddy
    Write-Log ('INFO  客户端退出结果: ' + $closeResult)
} elseif ($outcome.Result -eq 'error') {
    Write-Log 'INFO  签到失败，保留 WorkBuddy 运行状态以便排查'
}

if ($outcome.Result -eq 'error') { exit 1 }
exit 0
