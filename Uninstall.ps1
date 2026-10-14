# Downloads latest Install.ps1 and runs -Uninstall
$u = "https://github.com/Beibeisheep/AnimalPoopExplosionFix/releases/latest/download/Install.ps1"
$tmp = Join-Path $env:TEMP "APEF-Install.ps1"
Invoke-WebRequest -Uri $u -OutFile $tmp -UseBasicParsing
& $tmp -Uninstall
