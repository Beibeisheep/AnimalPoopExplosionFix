# Animal Poop Explosion Fix 鈥?runtime installer (PZOpt-style)
# Usage (recommended, like PZ Optimization):
#   powershell -ExecutionPolicy Bypass -Command "irm https://github.com/Beibeisheep/AnimalPoopExplosionFix/releases/latest/download/Install.ps1 | iex"
# Or from Workshop folder / this file:
#   powershell -ExecutionPolicy Bypass -File .\Install.ps1
# Uninstall:
#   irm .../Install.ps1 | iex   then with:  & { param($u) }  OR
#   powershell -ExecutionPolicy Bypass -File .\Install.ps1 -Uninstall

param([switch]$Uninstall)

$ErrorActionPreference = 'Stop'

# --- filled when publishing; override with $env:APEF_REPO = "user/AnimalPoopExplosionFix" ---
$Repo = if ($env:APEF_REPO -and $env:APEF_REPO.Trim()) { $env:APEF_REPO.Trim() } else { 'Beibeisheep/AnimalPoopExplosionFix' }
$ReleaseBase = "https://github.com/$Repo/releases/latest/download"

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

function Get-SteamLibraryRoots {
    $roots = New-Object System.Collections.Generic.List[string]
    foreach ($vdf in @(
        (Join-Path ${env:ProgramFiles(x86)} 'Steam\steamapps\libraryfolders.vdf'),
        (Join-Path $env:ProgramFiles 'Steam\steamapps\libraryfolders.vdf')
    )) {
        if (-not (Test-Path $vdf)) { continue }
        $txt = Get-Content $vdf -Raw -EA SilentlyContinue
        if (-not $txt) { continue }
        [regex]::Matches($txt, '"path"\s+"([^"]+)"') | ForEach-Object {
            $lib = $_.Groups[1].Value -replace '\\\\', '\'
            if ($lib) { [void]$roots.Add($lib) }
        }
    }
    foreach ($f in @('D:\software\Steam', (Join-Path ${env:ProgramFiles(x86)} 'Steam'), (Join-Path $env:ProgramFiles 'Steam'))) {
        if ($f -and (Test-Path $f) -and -not ($roots -contains $f)) { [void]$roots.Add($f) }
    }
    return $roots
}

function Find-GameRoot {
    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($lib in Get-SteamLibraryRoots) {
        [void]$candidates.Add((Join-Path $lib 'steamapps\common\ProjectZomboid'))
    }
    foreach ($c in @(
        'D:\software\Steam\steamapps\common\ProjectZomboid',
        'C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid',
        'C:\Program Files\Steam\steamapps\common\ProjectZomboid'
    )) { [void]$candidates.Add($c) }
    foreach ($c in $candidates) {
        if ($c -and (Test-Path (Join-Path $c 'ProjectZomboid64.json'))) {
            return (Resolve-Path $c).Path
        }
    }
    return $null
}

function Download-ReleaseAsset([string]$name) {
    if ($Repo -like 'OWNER/*') {
        throw "GitHub repo not configured yet (Repo=$Repo). Set `$env:APEF_REPO or republish Install.ps1."
    }
    New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
    $out = Join-Path $CacheDir $name
    $url = "$ReleaseBase/$name"
    Write-Info "download $url"
    Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing
    if (-not (Test-Path $out) -or ((Get-Item $out).Length -lt 1)) {
        throw "Download failed: $url"
    }
    return $out
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
