function Get-WbAuthCandidates {
    foreach ($name in @('workbuddy-desktop.info', 'Tencent-Cloud.coding-copilot.info')) {
        foreach ($base in @($env:LOCALAPPDATA, $env:APPDATA)) {
            if ($base) { Join-Path $base ('CodeBuddyExtension\Data\Public\auth\' + $name) }
        }
    }
}

function Read-WbLoginFile([string]$Path) {
    try { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
    catch { throw '登录文件无法读取或格式已变化。' }
}
function Test-WbTextLogin($Info) {
    return ($Info.auth.refreshToken -is [string] -and
        -not [string]::IsNullOrWhiteSpace($Info.auth.refreshToken) -and
        -not [string]::IsNullOrWhiteSpace([string]$Info.account.uid))
}
# Internal result contains credentials. Only route and reason are public.
function Get-WbLoginSelection {
    param([string]$ExplicitPath)
    $paths = if ($ExplicitPath) { $ExplicitPath } else { Get-WbAuthCandidates }
    $present = @($paths | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
    if (-not $present.Count) { return @{Route='Unavailable'; Reason='LoginRequired'} }
    $primary = Read-WbLoginFile $present[0]
    if (Test-WbTextLogin $primary) {
        return @{Route='WindowsTask'; Reason='TextLogin'; Info=$primary; Path=$present[0]}
    }
    if ($primary.auth.refreshToken.'$wbEncrypted' -ne 1) { return @{Route='Unavailable'; Reason='UnknownFormat'} }
    $uid = [string]$primary.account.uid
    if (-not $ExplicitPath -and -not [string]::IsNullOrWhiteSpace($uid)) {
        foreach ($path in $present) {
            if ([IO.Path]::GetFileName($path) -ine 'Tencent-Cloud.coding-copilot.info' -or $path -eq $present[0]) { continue }
            try { $compat = Read-WbLoginFile $path } catch { continue }
            if ((Test-WbTextLogin $compat) -and [string]$compat.account.uid -ceq $uid) {
                return @{Route='WindowsTask'; Reason='SameAccountCompanion'; Info=$compat; Path=$path}
            }
        }
    }
    return @{Route='ClientTask'; Reason='EncryptedOnly'}
}
