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

function Test-WbTextLogin($Info, [switch]$RequireUid) {
    $hasToken = ($Info.auth.refreshToken -is [string] -and
        -not [string]::IsNullOrWhiteSpace($Info.auth.refreshToken))
    if (-not $hasToken) { return $false }
    if ($RequireUid) {
        return (-not [string]::IsNullOrWhiteSpace([string]$Info.account.uid))
    }
    return $true
}

# Internal result contains credentials. Only route and reason are public.
function Get-WbLoginSelection {
    param([string]$ExplicitPath)
    if ($ExplicitPath) {
        if (-not (Test-Path -LiteralPath $ExplicitPath -PathType Leaf)) {
            return @{Route='Unavailable'; Reason='LoginRequired'}
        }
        try { $doc = Read-WbLoginFile $ExplicitPath } catch {
            return @{Route='Unavailable'; Reason='Unreadable'}
        }
        if (Test-WbTextLogin $doc) {
            return @{Route='WindowsTask'; Reason='TextLogin'; Info=$doc; Path=$ExplicitPath}
        }
        if ($doc.auth.refreshToken.'$wbEncrypted' -eq 1) {
            return @{Route='ClientTask'; Reason='EncryptedOnly'}
        }
        return @{Route='Unavailable'; Reason='UnknownFormat'}
    }

    $present = @(Get-WbAuthCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
    if (-not $present.Count) { return @{Route='Unavailable'; Reason='LoginRequired'} }

    $hadUnreadable = $false
    $firstEncrypted = $null
    $firstUnknown = $false

    for ($i = 0; $i -lt $present.Count; $i++) {
        $path = $present[$i]
        try { $doc = Read-WbLoginFile $path } catch {
            $hadUnreadable = $true
            continue
        }
        if (Test-WbTextLogin $doc) {
            return @{Route='WindowsTask'; Reason='TextLogin'; Info=$doc; Path=$path}
        }
        if ($doc.auth.refreshToken.'$wbEncrypted' -eq 1) {
            $uid = [string]$doc.account.uid
            if (-not [string]::IsNullOrWhiteSpace($uid)) {
                for ($j = 0; $j -lt $present.Count; $j++) {
                    if ($j -eq $i) { continue }
                    $otherPath = $present[$j]
                    try { $compat = Read-WbLoginFile $otherPath } catch { continue }
                    if ((Test-WbTextLogin $compat -RequireUid) -and [string]$compat.account.uid -ceq $uid) {
                        return @{Route='WindowsTask'; Reason='SameAccountCompanion'; Info=$compat; Path=$otherPath}
                    }
                }
            }
            return @{Route='ClientTask'; Reason='EncryptedOnly'}
        }
        return @{Route='Unavailable'; Reason='UnknownFormat'}
    }

    if ($hadUnreadable) { return @{Route='Unavailable'; Reason='Unreadable'} }
    return @{Route='Unavailable'; Reason='LoginRequired'}
}
