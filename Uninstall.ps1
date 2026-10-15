# Downloads latest Install.ps1 (TLS1.2 + mirrors) and runs -Uninstall
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$urls = @(
    'https://github.com/Beibeisheep/AnimalPoopExplosionFix/releases/latest/download/Install.ps1',
    'https://ghfast.top/https://github.com/Beibeisheep/AnimalPoopExplosionFix/releases/latest/download/Install.ps1',
    'https://ghproxy.net/https://github.com/Beibeisheep/AnimalPoopExplosionFix/releases/latest/download/Install.ps1',
    'https://mirror.ghproxy.com/https://github.com/Beibeisheep/AnimalPoopExplosionFix/releases/latest/download/Install.ps1'
)
$tmp = Join-Path $env:TEMP 'APEF-Install.ps1'
$ok = $false
foreach ($u in $urls) {
    try {
        Write-Host "[APEF] download $u"
        Invoke-WebRequest -Uri $u -OutFile $tmp -UseBasicParsing -TimeoutSec 60
        if ((Test-Path $tmp) -and ((Get-Item $tmp).Length -gt 0)) {
            $ok = $true
            break
        }
    } catch {
        Write-Host "[APEF] failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}
if (-not $ok) {
    throw 'Could not download Install.ps1 from GitHub or mirrors. Check network / VPN.'
}
& $tmp -Uninstall
