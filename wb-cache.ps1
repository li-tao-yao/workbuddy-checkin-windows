function Protect-WbCacheToken {
    param([string]$Token)
    Add-Type -AssemblyName System.Security
    $bytes = [Text.Encoding]::UTF8.GetBytes($Token)
    try {
        $protected = [Security.Cryptography.ProtectedData]::Protect($bytes, $null,
            [Security.Cryptography.DataProtectionScope]::CurrentUser)
        return 'dpapi:' + [Convert]::ToBase64String($protected)
    } finally { [Array]::Clear($bytes, 0, $bytes.Length) }
}

function Unprotect-WbCacheToken {
    param([string]$Token)
    if (-not $Token.StartsWith('dpapi:')) { return $Token }
    Add-Type -AssemblyName System.Security
    $bytes = [Security.Cryptography.ProtectedData]::Unprotect(
        [Convert]::FromBase64String($Token.Substring(6)), $null,
        [Security.Cryptography.DataProtectionScope]::CurrentUser)
    try { return [Text.Encoding]::UTF8.GetString($bytes) }
    finally { [Array]::Clear($bytes, 0, $bytes.Length) }
}
