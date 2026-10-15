# Animal Poop Explosion Fix - recovery uninstall (self-contained)
# Removes ALL -agentlib:zbNative from ProjectZomboid64.json / .bat even if install_state is missing.
# Usage (Defender-friendlier than irm|iex):
#   powershell -ExecutionPolicy Bypass -Command "iwr https://github.com/Beibeisheep/AnimalPoopExplosionFix/releases/latest/download/Uninstall.ps1 -OutFile $env:TEMP\APEF-Uninstall.ps1; powershell -ExecutionPolicy Bypass -File $env:TEMP\APEF-Uninstall.ps1"

$ErrorActionPreference = 'Stop'
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
}

$StateDir = Join-Path $env:USERPROFILE '.animal_catchup_fix'
$StatePath = Join-Path $StateDir 'install_state.json'
$MarkerPath = Join-Path $env:USERPROFILE 'Zomboid\Lua\AnimalPoopExplosionFix-installed.txt'
$CacheDir = Join-Path $env:TEMP 'AnimalPoopExplosionFix-runtime'
$HelperFlag = Join-Path $env:USERPROFILE 'Zomboid\Lua\AnimalPoopExplosionFix-dont-show.txt'

function Write-Info([string]$msg) { Write-Host "[APEF] $msg" -ForegroundColor Cyan }
function Write-Ok([string]$msg) { Write-Host "[APEF] $msg" -ForegroundColor Green }
function Write-Warn([string]$msg) { Write-Host "[APEF] $msg" -ForegroundColor Yellow }
function Write-Err([string]$msg) { Write-Host "[APEF] $msg" -ForegroundColor Red }

function Add-UniquePath([System.Collections.Generic.List[string]]$list, [string]$path) {
    if (-not $path) { return }
    $norm = $path.TrimEnd('\', '/')
    if (-not $norm) { return }
    foreach ($existing in $list) {
        if ($existing.Equals($norm, [StringComparison]::OrdinalIgnoreCase)) { return }
    }
    [void]$list.Add($norm)
}

function Read-LibraryFoldersVdf([string]$vdf) {
    $found = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $vdf)) { return $found }
    $txt = Get-Content -LiteralPath $vdf -Raw -EA SilentlyContinue
    if (-not $txt) { return $found }
    [regex]::Matches($txt, '"path"\s+"([^"]+)"') | ForEach-Object {
        $lib = ($_.Groups[1].Value -replace '\\\\', '\').TrimEnd('\', '/')
        if ($lib) { Add-UniquePath $found $lib }
    }
    return $found
}

function Get-SteamInstallPaths {
    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($key in @(
        'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam',
        'HKLM:\SOFTWARE\Valve\Steam',
        'HKCU:\SOFTWARE\Valve\Steam'
    )) {
        try {
            $p = (Get-ItemProperty -Path $key -Name InstallPath -EA SilentlyContinue).InstallPath
            if ($p) { Add-UniquePath $paths $p }
        } catch {}
    }
    foreach ($f in @(
        (Join-Path ${env:ProgramFiles(x86)} 'Steam'),
        (Join-Path $env:ProgramFiles 'Steam'),
        'D:\software\Steam', 'D:\Steam', 'C:\Steam', 'E:\Steam', 'F:\Steam'
    )) {
        if ($f -and (Test-Path -LiteralPath $f)) { Add-UniquePath $paths $f }
    }
    return $paths
}

function Get-SteamLibraryRoots {
    $roots = New-Object System.Collections.Generic.List[string]
    foreach ($steam in Get-SteamInstallPaths) {
        Add-UniquePath $roots $steam
        foreach ($lib in (Read-LibraryFoldersVdf (Join-Path $steam 'steamapps\libraryfolders.vdf'))) {
            Add-UniquePath $roots $lib
        }
    }
    foreach ($drive in ([IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady })) {
        $root = $drive.RootDirectory.FullName.TrimEnd('\')
        foreach ($name in @('SteamLibrary', 'Steam', 'SteamGames', 'Games\Steam', 'Program Files\Steam', 'Program Files (x86)\Steam')) {
            $candidate = Join-Path $root $name
            if (Test-Path -LiteralPath (Join-Path $candidate 'steamapps')) { Add-UniquePath $roots $candidate }
        }
    }
    return $roots
}

function Test-GameRoot([string]$dir) {
    if (-not $dir) { return $false }
    return (Test-Path -LiteralPath (Join-Path $dir 'ProjectZomboid64.json')) -or
           (Test-Path -LiteralPath (Join-Path $dir 'ProjectZomboid64.exe'))
}

function Resolve-GameRootPath([string]$dir) {
    if (-not (Test-GameRoot $dir)) { return $null }
    $resolved = (Resolve-Path -LiteralPath $dir).Path
    if (-not (Test-Path -LiteralPath (Join-Path $resolved 'ProjectZomboid64.json'))) { return $null }
    return $resolved
}

function Find-GameRoot {
    if ($env:APEF_GAME_ROOT -and $env:APEF_GAME_ROOT.Trim()) {
        $hit = Resolve-GameRootPath $env:APEF_GAME_ROOT.Trim()
        if ($hit) { return $hit }
    }
    foreach ($start in @((Get-Location).Path, $PWD.Path)) {
        if (-not $start) { continue }
        $cur = $start
        for ($i = 0; $i -lt 6 -and $cur; $i++) {
            $hit = Resolve-GameRootPath $cur
            if ($hit) { return $hit }
            $parent = Split-Path $cur -Parent
            if (-not $parent -or $parent -eq $cur) { break }
            $cur = $parent
        }
    }
    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($lib in Get-SteamLibraryRoots) {
        Add-UniquePath $candidates (Join-Path $lib 'steamapps\common\ProjectZomboid')
    }
    foreach ($c in @(
        'D:\software\Steam\steamapps\common\ProjectZomboid',
        'C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid',
        'C:\Program Files\Steam\steamapps\common\ProjectZomboid',
        'D:\SteamLibrary\steamapps\common\ProjectZomboid',
        'E:\SteamLibrary\steamapps\common\ProjectZomboid',
        'F:\SteamLibrary\steamapps\common\ProjectZomboid',
        'G:\SteamLibrary\steamapps\common\ProjectZomboid'
    )) { Add-UniquePath $candidates $c }
    foreach ($c in $candidates) {
        $hit = Resolve-GameRootPath $c
        if ($hit) { return $hit }
    }
    if ($Host.Name -eq 'ConsoleHost') {
        Write-Warn 'Paste your Project Zomboid folder path (contains ProjectZomboid64.exe):'
        $manual = Read-Host 'Game folder'
        if ($manual) { return (Resolve-GameRootPath $manual.Trim().Trim('"')) }
    }
    return $null
}

function Backup-File([string]$path) {
    if (-not (Test-Path $path)) { return }
    Copy-Item -Force $path "$path.acfbackup_$(Get-Date -Format yyyyMMdd_HHmmss)"
}

function Wait-GameClosed([string]$gameRoot) {
    $norm = $gameRoot.TrimEnd('\', '/')
    while ($true) {
        $running = Get-Process ProjectZomboid64 -EA SilentlyContinue | Where-Object {
            $_.Path -and ((Split-Path $_.Path -Parent).TrimEnd('\', '/') -eq $norm)
        }
        if (-not $running) { return }
        Write-Info 'Waiting for Project Zomboid to quit...'
        Start-Sleep -Seconds 2
    }
}

function Write-Utf8NoBom([string]$path, [string]$text) {
    $enc = New-Object System.Text.UTF8Encoding $false
    [IO.File]::WriteAllText($path, $text, $enc)
}

function Test-PsPrettyJson([string]$raw) {
    return [bool]($raw -match '"mainClass":\s{2}"')
}

function Find-CompactJsonText([string]$jsonPath) {
    $dir = (Get-Item -LiteralPath $jsonPath).DirectoryName
    $candidates = New-Object System.Collections.Generic.List[string]
    Get-ChildItem -LiteralPath $dir -Filter 'ProjectZomboid64.json.acfbackup_*' -File -EA SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        ForEach-Object { [void]$candidates.Add($_.FullName) }
    $baseline = Join-Path $env:USERPROFILE '.animal_catchup_fix\baseline_ProjectZomboid64.json'
    if (Test-Path -LiteralPath $baseline) { [void]$candidates.Add($baseline) }
    $fallback = $null
    foreach ($c in $candidates) {
        try {
            $t = [IO.File]::ReadAllText($c)
            if (Test-PsPrettyJson $t) { continue }
            if ($t -notmatch '"mainClass"\s*:') { continue }
            if ($t -match 'pzopt|AOTCache') { return $t }
            if (-not $fallback) { $fallback = $t }
        } catch {}
    }
    return $fallback
}

function Remove-AgentlibEntries([string]$raw) {
    $s = $raw
    $s = [regex]::Replace($s, ',\s*\r?\n\s*"-agentlib:zbNative[^"]*"', '')
    $s = [regex]::Replace($s, '"-agentlib:zbNative[^"]*"\s*,\s*\r?\n\s*', '')
    $s = [regex]::Replace($s, '"-agentlib:zbNative[^"]*"\s*,?', '')
    return $s
}

function Strip-JsonAgent([string]$gameRoot) {
    # NEVER ConvertTo-Json — pretty PS JSON breaks the PZ/PZOpt launcher.
    $jsonPath = Join-Path $gameRoot 'ProjectZomboid64.json'
    if (-not (Test-Path $jsonPath)) {
        Write-Warn "missing $jsonPath"
        return $false
    }
    $raw = [IO.File]::ReadAllText($jsonPath)
    $changed = $false
    if (Test-PsPrettyJson $raw) {
        Write-Warn 'JSON has ConvertTo-Json formatting (breaks launcher). Restoring compact backup...'
        Backup-File $jsonPath
        $restored = Find-CompactJsonText $jsonPath
        if ($restored) { $raw = $restored; $changed = $true }
        else { Write-Err 'Could not find compact JSON backup. Steam → Verify integrity.' }
    }
    if ($raw -match 'agentlib:zbNative') {
        $stripped = Remove-AgentlibEntries $raw
        if ($stripped -cne $raw) { $raw = $stripped; $changed = $true }
    }
    if ($changed) {
        Backup-File $jsonPath
        Write-Utf8NoBom $jsonPath $raw
        Write-Ok 'repaired ProjectZomboid64.json (stripped zbNative / restored compact; no ConvertTo-Json)'
    } elseif ($raw -notmatch 'agentlib:zbNative') {
        Write-Ok 'JSON has no zbNative agent'
    }
    return $changed
}

function Strip-BatAgent([string]$gameRoot) {
    $batPath = Join-Path $gameRoot 'ProjectZomboid64.bat'
    if (-not (Test-Path $batPath)) { return $false }
    $text = Get-Content $batPath -Raw -Encoding UTF8
    if ($text -notmatch 'agentlib:zbNative') {
        Write-Ok 'BAT has no zbNative agent'
        return $false
    }
    Backup-File $batPath
    $lines = Get-Content $batPath -Encoding UTF8
    $out = foreach ($line in $lines) {
        if ($line -match '^\s*SET\s+_JAVA_OPTIONS\s*=\s*(.*)$') {
            $cur = ($Matches[1] -replace '-agentlib:zbNative\S*', '').Trim()
            if ([string]::IsNullOrWhiteSpace($cur)) {
                # drop empty _JAVA_OPTIONS line entirely
                continue
            }
            "SET _JAVA_OPTIONS=$cur"
        } else { $line }
    }
    $out | Set-Content $batPath -Encoding UTF8
    Write-Ok 'removed zbNative from ProjectZomboid64.bat'
    return $true
}

function Remove-RuntimeIfOurs([string]$gameRoot, $state) {
    $removeDll = $false
    $removeJar = $false
    if ($state) {
        if ($state.copiedZbNative) { $removeDll = $true }
        if ($state.copiedZombieBuddyJar) { $removeJar = $true }
    }
    # Marker without state: still remove files we likely installed
    if ((Test-Path $MarkerPath) -and -not $state) {
        $removeDll = $true
        $removeJar = $true
    }
    # Force full cleanup of runtime we commonly drop (safe for boot; other ZB mods can reinstall)
    if ($env:APEF_FORCE_REMOVE_RUNTIME -eq '1') {
        $removeDll = $true
        $removeJar = $true
    }
    if ($removeDll) {
        $p = Join-Path $gameRoot 'zbNative.dll'
        if (Test-Path $p) { Remove-Item $p -Force -EA SilentlyContinue; Write-Ok 'removed zbNative.dll' }
    }
    if ($removeJar) {
        $p = Join-Path $gameRoot 'ZombieBuddy.jar'
        if (Test-Path $p) { Remove-Item $p -Force -EA SilentlyContinue; Write-Ok 'removed ZombieBuddy.jar' }
    }
}

Write-Host ''
Write-Host '=== Animal Poop Explosion Fix - Uninstall / Recovery ===' -ForegroundColor White
Write-Host ''

$state = $null
if (Test-Path $StatePath) {
    try { $state = Get-Content $StatePath -Raw | ConvertFrom-Json } catch {}
}

$gameRoot = $null
if ($state -and $state.gameRoot -and (Test-Path $state.gameRoot)) {
    $gameRoot = $state.gameRoot
    Write-Info "game root (from install record): $gameRoot"
} else {
    $gameRoot = Find-GameRoot
    if ($gameRoot) { Write-Info "game root (auto-detect): $gameRoot" }
}

if (-not $gameRoot) {
    Write-Err 'Could not find Project Zomboid.'
    Write-Err 'cd into the game folder, or: set APEF_GAME_ROOT=你的游戏目录'
    if ($Host.Name -eq 'ConsoleHost') { pause }
    exit 1
}

Wait-GameClosed $gameRoot

# Always strip agents — this is what restores launch after a bad install
[void](Strip-JsonAgent $gameRoot)
[void](Strip-BatAgent $gameRoot)
Remove-RuntimeIfOurs $gameRoot $state

# Clear APEF records / temp
Remove-Item $StatePath -Force -EA SilentlyContinue
Remove-Item $MarkerPath -Force -EA SilentlyContinue
Remove-Item $HelperFlag -Force -EA SilentlyContinue
if (Test-Path $StateDir) { Remove-Item $StateDir -Recurse -Force -EA SilentlyContinue }
if (Test-Path $CacheDir) { Remove-Item $CacheDir -Recurse -Force -EA SilentlyContinue }
Write-Ok 'cleared install markers / state / temp cache'

Write-Host ''
Write-Ok 'Done. Try launching Project Zomboid again.'
Write-Warn 'If it still fails with missing mainfont_0.png, use Steam → Verify integrity of game files.'
Write-Host ''
if ($Host.Name -eq 'ConsoleHost') { pause }
