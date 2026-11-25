$ErrorActionPreference='Stop'
Write-Output ('Runtime: '+(Get-Process -Id $PID).Path+' | '+$PSVersionTable.PSVersion)
$source=Join-Path (Split-Path -Parent $PSScriptRoot) 'wb-daily-checkin.ps1'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Parse failed'}
$functions=$ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)
foreach($name in @('Test-WorkBuddyTlsFailure','Invoke-JsonPost')) {
    . ([scriptblock]::Create(($functions | Where-Object Name -eq $name).Extent.Text))
}
$script:logs=@();$script:calls=@();$passed=0
function Write-Log([string]$Message){$script:logs+=$Message}
function Assert($Condition,$Label){if(-not $Condition){throw ('FAIL '+$Label)};$script:passed++;Write-Output ('PASS '+$Label)}
function Mock-Request($Arguments){
    $script:calls+=@{}+$Arguments
    if($script:mode -eq 'timeout'){throw [TimeoutException]::new('fixture timeout')}
    if($script:mode -eq 'always-tls' -or ($script:mode -eq 'tls' -and $script:calls.Count -eq 1)) {
        throw [Security.Authentication.AuthenticationException]::new('fixture TLS failure')
    }
    if($script:mode -eq 'already'){return [pscustomobject]@{StatusCode=400;Content='{"code":10001,"msg":"already"}'}}
    return [pscustomobject]@{StatusCode=200;Content='{"code":0,"data":{"ok":true}}'}
}
foreach($legacy in @($false,$true)) {
    if($legacy) {
        function Invoke-WebRequest { [CmdletBinding()]param($Uri,$Method,$Headers,$Body,$ContentType,$TimeoutSec,$MaximumRedirection,[switch]$UseBasicParsing,[switch]$SkipHttpErrorCheck,$WebSession,[switch]$SkipCertificateCheck) Mock-Request $PSBoundParameters }
    } else {
        function Invoke-WebRequest { [CmdletBinding()]param($Uri,$Method,$Headers,$Body,$ContentType,$TimeoutSec,$MaximumRedirection,[switch]$UseBasicParsing,[switch]$SkipHttpErrorCheck,[switch]$NoProxy,$WebSession,[switch]$SkipCertificateCheck) Mock-Request $PSBoundParameters }
    }
    $script:mode='tls';$script:calls=@();$script:logs=@()
    $r=Invoke-JsonPost 'https://www.workbuddy.cn/test' @{Authorization='fixture-secret'}
    Assert ($r.code -eq 0 -and $script:calls.Count -eq 2) "TLS failure recovers once (legacy=$legacy)"
    $second=$script:calls[1]
    if($legacy){Assert ($second.WebSession.Proxy.IsBypassed([uri]'https://www.workbuddy.cn')) '5.1 uses per-request direct session'}
    else{Assert ([bool]$second.NoProxy) '7 uses NoProxy'}
    Assert (-not $second.SkipCertificateCheck -and $second.MaximumRedirection -eq 0 -and $second.Headers.Authorization -ceq 'fixture-secret') 'certificate validation and redirect refusal preserved'
    Assert (($script:logs -join '') -notmatch 'fixture-secret') 'fallback log contains no credentials'
    $script:mode='always-tls';$script:calls=@();$thrown=$false
    try{$null=Invoke-JsonPost 'https://www.workbuddy.cn/test'}catch{$thrown=$true}
    Assert ($thrown -and $script:calls.Count -eq 2) 'second TLS failure stops without looping'
    $script:mode='timeout';$script:calls=@();$thrown=$false
    try{$null=Invoke-JsonPost 'https://www.workbuddy.cn/test'}catch{$thrown=$true}
    Assert ($thrown -and $script:calls.Count -eq 1) 'ambiguous timeout is not resubmitted'
    $script:mode='already';$script:calls=@()
    $r=Invoke-JsonPost 'https://www.workbuddy.cn/test'
    Assert ($r.code -eq 10001 -and $script:calls.Count -eq 1) 'business response is not retried'
    $script:mode='tls';$script:calls=@();$thrown=$false
    try{$null=Invoke-JsonPost 'https://unrelated.example/test'}catch{$thrown=$true}
    Assert ($thrown -and $script:calls.Count -eq 1) 'fallback restricted to official domains'
}
Write-Output ('Passed network checks: '+$passed)
