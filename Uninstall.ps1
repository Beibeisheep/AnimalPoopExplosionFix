# Downloads Install.ps1 (GitHub, then one mirror) and runs -Uninstall.
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
}

$urls = @(
    'https://github.com/Beibeisheep/AnimalPoopExplosionFix/releases/latest/download/Install.ps1',
    'https://ghfast.top/https://github.com/Beibeisheep/AnimalPoopExplosionFix/releases/latest/download/Install.ps1'
)
$tmp = Join-Path $env:TEMP 'APEF-Install.ps1'
$ok = $false
foreach ($u in $urls) {
    try {
        Write-Host "[APEF] download $u"
        Invoke-WebRequest -Uri $u -OutFile $tmp -UseBasicParsing -TimeoutSec 60
        if ((Test-Path $tmp) -and ((Get-Item $tmp).Length -gt 0)) { $ok = $true; break }
    } catch {
        Write-Host "[APEF] failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}
if (-not $ok) {
    throw 'Could not download Install.ps1. Allow PowerShell in Windows Security, or try the mirror uninstall command.'
}
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tmp -Uninstall
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
