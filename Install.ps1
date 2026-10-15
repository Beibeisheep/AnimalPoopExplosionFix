# Animal Poop Explosion Fix - runtime installer (PZOpt-style)
# Usage (TLS1.2 + GitHub mirrors; works better in CN):
#   powershell -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; $ok=$false; foreach($u in @('https://github.com/Beibeisheep/AnimalPoopExplosionFix/releases/latest/download/Install.ps1','https://ghfast.top/https://github.com/Beibeisheep/AnimalPoopExplosionFix/releases/latest/download/Install.ps1','https://ghproxy.net/https://github.com/Beibeisheep/AnimalPoopExplosionFix/releases/latest/download/Install.ps1')){ try { iex (irm $u); $ok=$true; break } catch { Write-Host ('[APEF] download failed: '+$u) } }; if(-not $ok){ throw 'Install.ps1 download failed' }"
# Or from Workshop folder / this file:
#   powershell -ExecutionPolicy Bypass -File .\Install.ps1
# Uninstall:
#   powershell -ExecutionPolicy Bypass -File .\Install.ps1 -Uninstall

param([switch]$Uninstall)

$ErrorActionPreference = 'Stop'

# GitHub requires TLS 1.2+; older Windows PowerShell defaults can fail with "underlying connection was closed"
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
}

# --- filled when publishing; override with $env:APEF_REPO = "user/AnimalPoopExplosionFix" ---
$Repo = if ($env:APEF_REPO -and $env:APEF_REPO.Trim()) { $env:APEF_REPO.Trim() } else { 'Beibeisheep/AnimalPoopExplosionFix' }
$ReleaseBase = "https://github.com/$Repo/releases/latest/download"
$ReleaseMirrors = @(
    'https://ghfast.top/https://github.com',
    'https://ghproxy.net/https://github.com',
    'https://mirror.ghproxy.com/https://github.com'
)

$AgentArg = '-agentlib:zbNative'
$StateDir = Join-Path $env:USERPROFILE '.animal_catchup_fix'
$StatePath = Join-Path $StateDir 'install_state.json'
$MarkerPath = Join-Path $env:USERPROFILE 'Zomboid\Lua\AnimalPoopExplosionFix-installed.txt'
$ZB_WORKSHOP_ID = '3619862853'
$CacheDir = Join-Path $env:TEMP 'AnimalPoopExplosionFix-runtime'

function Write-Info([string]$msg) { Write-Host "[APEF] $msg" -ForegroundColor Cyan }
function Write-Ok([string]$msg) { Write-Host "[APEF] $msg" -ForegroundColor Green }
function Write-Warn([string]$msg) { Write-Host "[APEF] $msg" -ForegroundColor Yellow }
function Write-Err([string]$msg) { Write-Host "[APEF] $msg" -ForegroundColor Red }

function Get-ScriptModRoot {
    if ($PSScriptRoot) {
        $parent = Split-Path $PSScriptRoot -Parent
        # Workshop layout: .../AnimalPoopExplosionFix/42/Install.ps1
        if ((Split-Path $PSScriptRoot -Leaf) -eq '42') { return $parent }
        return $PSScriptRoot
    }
    return $null
}

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
        'D:\software\Steam',
        'D:\Steam',
        'C:\Steam',
        'E:\Steam',
        'F:\Steam'
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
    # Common secondary library folder names on every fixed drive (covers F:\SteamLibrary etc.)
    foreach ($drive in ([IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady })) {
        $root = $drive.RootDirectory.FullName.TrimEnd('\')
        foreach ($name in @('SteamLibrary', 'Steam', 'SteamGames', 'Games\Steam', 'Program Files\Steam', 'Program Files (x86)\Steam')) {
            $candidate = Join-Path $root $name
            if (Test-Path -LiteralPath (Join-Path $candidate 'steamapps')) {
                Add-UniquePath $roots $candidate
            }
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
    $json = Join-Path $resolved 'ProjectZomboid64.json'
    if (-not (Test-Path -LiteralPath $json)) {
        Write-Warn "Found game folder but ProjectZomboid64.json is missing: $resolved"
        Write-Warn 'Run Steam → Project Zomboid → Properties → Installed Files → Verify integrity of game files.'
        return $null
    }
    return $resolved
}

function Find-GameRootFromPwd {
    # irm|iex inherits the caller's cwd — many players already cd into the game folder.
    $probe = @(
        (Get-Location).Path,
        $PWD.Path,
        $env:CD
    ) | Where-Object { $_ } | Select-Object -Unique
    foreach ($start in $probe) {
        $cur = $start
        for ($i = 0; $i -lt 6 -and $cur; $i++) {
            $hit = Resolve-GameRootPath $cur
            if ($hit) { return $hit }
            $leaf = Split-Path $cur -Leaf
            # If cwd is ...\ProjectZomboid\something, still walk up
            $parent = Split-Path $cur -Parent
            if (-not $parent -or $parent -eq $cur) { break }
            $cur = $parent
            if ($leaf -eq 'ProjectZomboid') { break }
        }
    }
    return $null
}

function Find-GameRoot {
    # 1) Explicit override
    if ($env:APEF_GAME_ROOT -and $env:APEF_GAME_ROOT.Trim()) {
        $hit = Resolve-GameRootPath $env:APEF_GAME_ROOT.Trim()
        if ($hit) { return $hit }
        Write-Warn "APEF_GAME_ROOT is set but invalid: $($env:APEF_GAME_ROOT)"
    }

    # 2) Current directory (fixes players who opened cmd inside the game folder)
    $fromPwd = Find-GameRootFromPwd
    if ($fromPwd) { return $fromPwd }

    # 3) Steam libraries (registry + libraryfolders.vdf + per-drive SteamLibrary scan)
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

    # 4) Interactive fallback
    if ($Host.Name -eq 'ConsoleHost') {
        Write-Warn 'Auto-detect failed. Paste your Project Zomboid folder path and press Enter.'
        Write-Warn 'Example: F:\SteamLibrary\steamapps\common\ProjectZomboid'
        $manual = Read-Host 'Game folder'
        if ($manual) {
            $hit = Resolve-GameRootPath $manual.Trim().Trim('"')
            if ($hit) { return $hit }
        }
    }
    return $null
}

function Get-ReleaseAssetUrls([string]$name) {
    $path = "/$Repo/releases/latest/download/$name"
    $urls = New-Object System.Collections.Generic.List[string]
    [void]$urls.Add("$ReleaseBase/$name")
    foreach ($m in $ReleaseMirrors) {
        [void]$urls.Add("$m$path")
    }
    if ($env:APEF_MIRROR -and $env:APEF_MIRROR.Trim()) {
        $pref = $env:APEF_MIRROR.Trim().TrimEnd('/')
        $urls.Insert(0, "$pref/https://github.com$path")
    }
    return $urls
}

function Download-ReleaseAsset([string]$name) {
    if ($Repo -like 'OWNER/*') {
        throw "GitHub repo not configured yet (Repo=$Repo). Set `$env:APEF_REPO or republish Install.ps1."
    }
    New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
    $out = Join-Path $CacheDir $name
    $errors = New-Object System.Collections.Generic.List[string]
    foreach ($url in (Get-ReleaseAssetUrls $name)) {
        try {
            Write-Info "download $url"
            Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing -TimeoutSec 60
            if ((Test-Path $out) -and ((Get-Item $out).Length -gt 0)) {
                return $out
            }
            [void]$errors.Add("$url (empty file)")
        } catch {
            [void]$errors.Add("$url ($($_.Exception.Message))")
            Write-Warn "download failed, trying next mirror..."
        }
    }
    throw ("Download failed for $name : " + ($errors -join ' | '))
}

function Find-WorkshopZombieBuddyLibs {
    foreach ($lib in Get-SteamLibraryRoots) {
        $ws = Join-Path $lib "steamapps\workshop\content\108600\$ZB_WORKSHOP_ID\mods\ZombieBuddy\libs"
        $jar = Join-Path $ws 'ZombieBuddy.jar'
        $dll = Join-Path $ws 'zbNative.dll'
        if ((Test-Path $jar) -and (Test-Path $dll)) {
            return @{ Jar = $jar; Dll = $dll; Source = 'workshop-ZombieBuddy' }
        }
    }
    return $null
}

function Resolve-Runtime([string]$modRoot) {
    # 1) GitHub Release (preferred, PZOpt-style)
    try {
        $dll = Download-ReleaseAsset 'zbNative.dll'
        $jar = Download-ReleaseAsset 'ZombieBuddy.jar'
        return @{ Jar = $jar; Dll = $dll; Source = "github:$Repo" }
    } catch {
        Write-Warn "GitHub release download failed: $($_.Exception.Message)"
    }

    # 2) Workshop ZombieBuddy cache
    $ws = Find-WorkshopZombieBuddyLibs
    if ($ws) { return $ws }

    # 3) Bundled next to workshop mod (jar only usually)
    if ($modRoot) {
        $bJar = Join-Path $modRoot 'libs\ZombieBuddy.jar'
        $bDll = Join-Path $modRoot 'libs\zbNative.dll'
        if ((Test-Path $bJar) -and (Test-Path $bDll)) {
            return @{ Jar = $bJar; Dll = $bDll; Source = 'bundled-libs' }
        }
    }
    return $null
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

function Read-State {
    if (-not (Test-Path $StatePath)) {
        return [ordered]@{
            gameRoot = $null; copiedZbNative = $false; copiedZombieBuddyJar = $false
            addedJsonAgent = $false; addedBatAgent = $false; reusedExistingRuntime = $false; installedAt = $null
        }
    }
    return (Get-Content $StatePath -Raw | ConvertFrom-Json)
}

function Save-State($state) {
    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
    ($state | ConvertTo-Json -Depth 5) | Set-Content $StatePath -Encoding UTF8
}

function Write-Marker {
    New-Item -ItemType Directory -Force -Path (Split-Path $MarkerPath) | Out-Null
    Set-Content $MarkerPath ("installed=" + (Get-Date).ToString('o')) -Encoding UTF8
}

function Remove-Marker { Remove-Item $MarkerPath -Force -EA SilentlyContinue }

function Backup-File([string]$path) {
    if (-not (Test-Path $path)) { return }
    Copy-Item -Force $path "$path.acfbackup_$(Get-Date -Format yyyyMMdd_HHmmss)"
}

function Ensure-JsonAgent([string]$gameRoot, $state) {
    $jsonPath = Join-Path $gameRoot 'ProjectZomboid64.json'
    if (-not (Test-Path $jsonPath)) { return $state }
    $raw = Get-Content $jsonPath -Raw -Encoding UTF8
    if ($raw -match 'agentlib:zbNative') { Write-Ok "JSON already has $AgentArg"; return $state }
    if ($raw -notmatch '"vmArgs"\s*:\s*\[') { return $state }
    Backup-File $jsonPath
    $insert = "`"$AgentArg`",`r`n`t`t"
    $newRaw = [regex]::Replace($raw, '("vmArgs"\s*:\s*\[)\s*', ('$1' + "`r`n`t`t" + $insert), 1)
    Set-Content $jsonPath $newRaw -Encoding UTF8
    $state.addedJsonAgent = $true
    Write-Ok 'patched ProjectZomboid64.json'
    return $state
}

function Ensure-BatAgent([string]$gameRoot, $state) {
    $batPath = Join-Path $gameRoot 'ProjectZomboid64.bat'
    if (-not (Test-Path $batPath)) { return $state }
    $lines = @(Get-Content $batPath -Encoding UTF8)
    if (($lines -join "`n") -match 'agentlib:zbNative') { Write-Ok 'BAT already patched'; return $state }
    Backup-File $batPath
    $changed = $false
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($line in $lines) {
        if ($line -match '^\s*SET\s+_JAVA_OPTIONS\s*=\s*(.*)$') {
            $cur = $Matches[1].Trim()
            if ([string]::IsNullOrWhiteSpace($cur)) { $out.Add("SET _JAVA_OPTIONS=$AgentArg") }
            elseif ($cur -notmatch 'agentlib:zbNative') { $out.Add("SET _JAVA_OPTIONS=$AgentArg $cur") }
            else { $out.Add($line) }
            $changed = $true
        } else { $out.Add($line) }
    }
    if (-not $changed) {
        $out2 = New-Object System.Collections.Generic.List[string]
        $ins = $false
        foreach ($line in $out) {
            $out2.Add($line)
            if (-not $ins -and $line -match '^\s*@?echo\s+off') { $out2.Add("SET _JAVA_OPTIONS=$AgentArg"); $ins = $true }
        }
        if (-not $ins) { $out2.Insert(0, "SET _JAVA_OPTIONS=$AgentArg") }
        $out = $out2
    }
    $out | Set-Content $batPath -Encoding UTF8
    $state.addedBatAgent = $true
    Write-Ok 'patched ProjectZomboid64.bat'
    return $state
}

function Ensure-RuntimeFiles([string]$gameRoot, $runtime, $state) {
    $dstDll = Join-Path $gameRoot 'zbNative.dll'
    $dstJar = Join-Path $gameRoot 'ZombieBuddy.jar'
    if ((Test-Path $dstDll) -and (Test-Path $dstJar)) {
        $state.reusedExistingRuntime = $true
        Write-Ok 'runtime already present'
        return $state
    }
    if (-not (Test-Path $dstDll)) {
        Copy-Item -Force $runtime.Dll $dstDll
        $state.copiedZbNative = $true
        Write-Ok 'copied zbNative.dll'
    }
    if (-not (Test-Path $dstJar)) {
        Copy-Item -Force $runtime.Jar $dstJar
        $state.copiedZombieBuddyJar = $true
        Write-Ok 'copied runtime jar'
    }
    return $state
}

function Invoke-Uninstall {
    Write-Host ''
    Write-Host '=== Animal Poop Explosion Fix - Uninstall ===' -ForegroundColor White
    if (-not (Test-Path $StatePath)) {
        Write-Warn 'Nothing to uninstall.'
        Remove-Marker
        if ($Host.Name -eq 'ConsoleHost') { pause }
        exit 0
    }
    $state = Get-Content $StatePath -Raw | ConvertFrom-Json
    $gameRoot = $state.gameRoot
    if (-not $gameRoot -or -not (Test-Path $gameRoot)) {
        Write-Err "Recorded game root missing: $gameRoot"
        if ($Host.Name -eq 'ConsoleHost') { pause }
        exit 1
    }
    Wait-GameClosed $gameRoot
    if ($state.addedJsonAgent) {
        $jsonPath = Join-Path $gameRoot 'ProjectZomboid64.json'
        if (Test-Path $jsonPath) {
            $obj = Get-Content $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $args = @($obj.vmArgs | ForEach-Object { [string]$_ } | Where-Object { $_ -notlike '-agentlib:zbNative*' })
            $map = [ordered]@{}
            foreach ($p in $obj.PSObject.Properties) {
                if ($p.Name -eq 'vmArgs') { $map[$p.Name] = $args } else { $map[$p.Name] = $p.Value }
            }
            Backup-File $jsonPath
            ($map | ConvertTo-Json -Depth 8) | Set-Content $jsonPath -Encoding UTF8
            Write-Ok 'reverted JSON'
        }
    }
    if ($state.addedBatAgent) {
        $batPath = Join-Path $gameRoot 'ProjectZomboid64.bat'
        if (Test-Path $batPath) {
            $lines = Get-Content $batPath -Encoding UTF8
            $out = foreach ($line in $lines) {
                if ($line -match '^\s*SET\s+_JAVA_OPTIONS\s*=\s*(.*)$') {
                    $cur2 = ($Matches[1] -replace '-agentlib:zbNative\S*', '').Trim()
                    if ([string]::IsNullOrWhiteSpace($cur2)) { continue }
                    "SET _JAVA_OPTIONS=$cur2"
                } else { $line }
            }
            Backup-File $batPath
            $out | Set-Content $batPath -Encoding UTF8
            Write-Ok 'reverted BAT'
        }
    }
    if ($state.copiedZbNative) {
        Remove-Item (Join-Path $gameRoot 'zbNative.dll') -Force -EA SilentlyContinue
        Write-Ok 'removed zbNative.dll'
    }
    if ($state.copiedZombieBuddyJar) {
        Remove-Item (Join-Path $gameRoot 'ZombieBuddy.jar') -Force -EA SilentlyContinue
        Write-Ok 'removed runtime jar'
    }
    Remove-Item $StatePath -Force -EA SilentlyContinue
    Remove-Marker
    Write-Ok 'Done.'
    if ($Host.Name -eq 'ConsoleHost') { pause }
    exit 0
}

# ---- main ----
if ($Uninstall) { Invoke-Uninstall }

Write-Host ''
Write-Host '=== Animal Poop Explosion Fix - Install ===' -ForegroundColor White
Write-Host "Repo: $Repo"
Write-Host ''

$modRoot = Get-ScriptModRoot
$gameRoot = Find-GameRoot
if (-not $gameRoot) {
    Write-Err 'Could not find Project Zomboid (ProjectZomboid64.json).'
    Write-Err 'Fix: open cmd in the game folder (the one with ProjectZomboid64.exe), then re-run the install command,'
    Write-Err 'or set:  set APEF_GAME_ROOT=F:\SteamLibrary\steamapps\common\ProjectZomboid'
    Write-Err 'Steam → right-click Project Zomboid → Manage → Browse local files  shows the correct folder.'
    if ($Host.Name -eq 'ConsoleHost') { pause }
    exit 1
}
Write-Info "game root: $gameRoot"
Wait-GameClosed $gameRoot

$dstDll = Join-Path $gameRoot 'zbNative.dll'
$dstJar = Join-Path $gameRoot 'ZombieBuddy.jar'
$runtime = $null
if (-not ((Test-Path $dstDll) -and (Test-Path $dstJar))) {
    $runtime = Resolve-Runtime $modRoot
    if (-not $runtime) {
        Write-Err 'Could not get zbNative.dll / ZombieBuddy.jar.'
        Write-Err "1) Publish a GitHub Release on $Repo with those assets, or"
        Write-Err "2) Subscribe to ZombieBuddy Workshop ($ZB_WORKSHOP_ID)."
        if ($Host.Name -eq 'ConsoleHost') { pause }
        exit 1
    }
    Write-Info "runtime from: $($runtime.Source)"
} else {
    Write-Ok 'game-root runtime already present'
}

$state = Read-State
$state.gameRoot = $gameRoot
$state.installedAt = (Get-Date).ToString('o')
if ($runtime) { $state = Ensure-RuntimeFiles $gameRoot $runtime $state }
$state = Ensure-JsonAgent $gameRoot $state
$state = Ensure-BatAgent $gameRoot $state
Save-State $state
Write-Marker

Write-Host ''
Write-Ok 'Done. Enable Animal Poop Explosion Fix and start the game.'
Write-Host ''
if ($Host.Name -eq 'ConsoleHost') { pause }
