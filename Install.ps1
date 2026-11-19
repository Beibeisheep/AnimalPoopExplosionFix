# Animal Poop Explosion Fix - runtime installer
# Short install:   irm .../Install.ps1 | iex
# Short uninstall: iwr .../Uninstall.ps1 -OutFile $env:TEMP\APEF-Uninstall.ps1; powershell -File $env:TEMP\APEF-Uninstall.ps1
# Mirror install:  irm https://ghfast.top/https://github.com/.../Install.ps1 | iex
# Internals: TLS1.2, game-path detection, one ghfast mirror for assets, root-only JSON agent (no BAT).
# CRITICAL: never rewrite ProjectZomboid64.json via ConvertTo-Json — pretty PS JSON breaks the PZ/PZOpt launcher.

param([switch]$Uninstall)

$ErrorActionPreference = 'Stop'

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
}

# --- filled when publishing; override with $env:APEF_REPO = "user/AnimalPoopExplosionFix" ---
$Repo = if ($env:APEF_REPO -and $env:APEF_REPO.Trim()) { $env:APEF_REPO.Trim() } else { 'Beibeisheep/AnimalPoopExplosionFix' }
$ReleaseBase = "https://github.com/$Repo/releases/latest/download"
# Single mirror only (less noisy / fewer AV false positives than a long mirror chain)
$ReleaseMirror = 'https://ghfast.top/https://github.com'

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

function Join-SafePath([string]$base, [string]$child) {
    if ([string]::IsNullOrWhiteSpace($base)) { return $null }
    if ($base -match '^[A-Za-z]:$') { $base = $base + '\' }
    if ([string]::IsNullOrWhiteSpace($child)) { return $base }
    try { return [IO.Path]::Combine($base, $child.TrimStart('\', '/')) } catch { return $null }
}

function Test-SafePath([string]$path) {
    if ([string]::IsNullOrWhiteSpace($path)) { return $false }
    try { return [bool](Test-Path -LiteralPath $path -ErrorAction SilentlyContinue) } catch { return $false }
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
    if (-not (Test-SafePath $vdf)) { return $found }
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
        foreach ($prop in @('InstallPath', 'SteamPath')) {
            try {
                $p = (Get-ItemProperty -Path $key -Name $prop -EA SilentlyContinue).$prop
                if ($p) {
                    $p = ($p -replace '/', '\')
                    if (Test-SafePath $p) { Add-UniquePath $paths $p }
                }
            } catch {}
        }
    }
    foreach ($f in @(
        (Join-SafePath ${env:ProgramFiles(x86)} 'Steam'),
        (Join-SafePath $env:ProgramFiles 'Steam'),
        'D:\software\Steam',
        'D:\Steam',
        'C:\Steam',
        'E:\Steam',
        'F:\Steam'
    )) {
        if (Test-SafePath $f) { Add-UniquePath $paths $f }
    }
    return $paths
}

function Get-SteamLibraryRoots {
    $roots = New-Object System.Collections.Generic.List[string]
    foreach ($steam in Get-SteamInstallPaths) {
        Add-UniquePath $roots $steam
        foreach ($lib in (Read-LibraryFoldersVdf (Join-SafePath $steam 'steamapps\libraryfolders.vdf'))) {
            if (Test-SafePath $lib) { Add-UniquePath $roots $lib }
        }
    }
    # Common secondary library folder names on every ready fixed drive (covers F:\SteamLibrary etc.)
    $drives = @()
    try {
        $drives = [IO.DriveInfo]::GetDrives() | Where-Object {
            try { $_.DriveType -eq 'Fixed' -and $_.IsReady } catch { $false }
        }
    } catch {}
    foreach ($drive in $drives) {
        $root = $drive.RootDirectory.FullName
        foreach ($name in @('SteamLibrary', 'Steam', 'SteamGames', 'Games\Steam', 'Program Files\Steam', 'Program Files (x86)\Steam')) {
            $candidate = Join-SafePath $root $name
            if (Test-SafePath (Join-SafePath $candidate 'steamapps')) {
                Add-UniquePath $roots $candidate
            }
        }
    }
    return $roots
}

function Test-GameRoot([string]$dir) {
    if (-not (Test-SafePath $dir)) { return $false }
    return (Test-SafePath (Join-SafePath $dir 'ProjectZomboid64.json')) -or
           (Test-SafePath (Join-SafePath $dir 'ProjectZomboid64.exe'))
}

function Resolve-GameRootPath([string]$dir) {
    if (-not (Test-GameRoot $dir)) { return $null }
    try {
        $resolved = (Resolve-Path -LiteralPath $dir -ErrorAction Stop).Path
    } catch {
        return $null
    }
    $json = Join-SafePath $resolved 'ProjectZomboid64.json'
    if (-not (Test-SafePath $json)) {
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
        Add-UniquePath $candidates (Join-SafePath $lib 'steamapps\common\ProjectZomboid')
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
    [void]$urls.Add("$ReleaseMirror$path")
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
        $ws = Join-SafePath $lib "steamapps\workshop\content\108600\$ZB_WORKSHOP_ID\mods\ZombieBuddy\libs"
        $jar = Join-SafePath $ws 'ZombieBuddy.jar'
        $dll = Join-SafePath $ws 'zbNative.dll'
        if ((Test-SafePath $jar) -and (Test-SafePath $dll)) {
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

function Write-Utf8NoBom([string]$path, [string]$text) {
    $enc = New-Object System.Text.UTF8Encoding $false
    [IO.File]::WriteAllText($path, $text, $enc)
}

function Test-PsPrettyJson([string]$raw) {
    # PowerShell ConvertTo-Json writes ":  " (colon + 2 spaces). PZ/PZOpt launcher rejects that layout.
    return [bool]($raw -match '"mainClass":\s{2}"')
}

function Find-CompactJsonText([string]$jsonPath) {
    $dir = (Get-Item -LiteralPath $jsonPath).DirectoryName
    $candidates = New-Object System.Collections.Generic.List[string]
    # Prefer newest game-folder backups first (keeps current AOTCache vs AOTCacheOutput).
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

function Get-RootVmArgsOpenBracketIndex([string]$raw) {
    # Brace-depth scan: root object keys sit at depth==1.
    # Works for vanilla (root vmArgs before windows), PZOpt (root after windows),
    # and other reorderings / odd whitespace / tabs.
    $depth = 0
    $inStr = $false
    $esc = $false
    $len = $raw.Length
    for ($i = 0; $i -lt $len; $i++) {
        $c = $raw[$i]
        if ($inStr) {
            if ($esc) { $esc = $false }
            elseif ($c -eq '\') { $esc = $true }
            elseif ($c -eq '"') { $inStr = $false }
            continue
        }
        if ($c -eq '"') {
            if ($depth -eq 1 -and ($i + 8) -le $len -and $raw.Substring($i, 8) -eq '"vmArgs"') {
                $j = $i + 8
                while ($j -lt $len -and [char]::IsWhiteSpace($raw[$j])) { $j++ }
                if ($j -lt $len -and $raw[$j] -eq ':') {
                    $j++
                    while ($j -lt $len -and [char]::IsWhiteSpace($raw[$j])) { $j++ }
                    if ($j -lt $len -and $raw[$j] -eq '[') { return $j }
                }
            }
            $inStr = $true
            continue
        }
        if ($c -eq '{') { $depth++ }
        elseif ($c -eq '}') { $depth-- }
    }
    return -1
}

function Get-RootObjectCloseBraceIndex([string]$raw) {
    $depth = 0
    $inStr = $false
    $esc = $false
    $len = $raw.Length
    $lastRootClose = -1
    for ($i = 0; $i -lt $len; $i++) {
        $c = $raw[$i]
        if ($inStr) {
            if ($esc) { $esc = $false }
            elseif ($c -eq '\') { $esc = $true }
            elseif ($c -eq '"') { $inStr = $false }
            continue
        }
        if ($c -eq '"') { $inStr = $true; continue }
        if ($c -eq '{') { $depth++ }
        elseif ($c -eq '}') {
            if ($depth -eq 1) { $lastRootClose = $i }
            $depth--
        }
    }
    return $lastRootClose
}

function Add-MissingRootVmArgsProperty([string]$raw) {
    $close = Get-RootObjectCloseBraceIndex $raw
    if ($close -lt 0) { return $raw }
    $before = $raw.Substring(0, $close).TrimEnd()
    if ($before.EndsWith(',')) {
        $insert = "`r`n`t`"vmArgs`": [`r`n`t`t`"-agentlib:zbNative`"`r`n`t]`r`n"
    } else {
        $insert = ",`r`n`t`"vmArgs`": [`r`n`t`t`"-agentlib:zbNative`"`r`n`t]`r`n"
    }
    return $before + $insert + $raw.Substring($close)
}

function Add-RootAgentlib([string]$raw) {
    try {
        $obj = $raw | ConvertFrom-Json
        $hasRoot = @($obj.vmArgs | ForEach-Object { [string]$_ } | Where-Object { $_ -like '-agentlib:zbNative*' })
        if ($hasRoot.Count -gt 0) { return $raw }
    } catch {}

    $bracket = Get-RootVmArgsOpenBracketIndex $raw
    if ($bracket -ge 0) {
        $tail = $raw.Substring($bracket + 1)
        $indent = '  '
        if ($tail -match '(?m)^[\t ]*\r?\n([\t ]+)"') { $indent = $Matches[1] }
        elseif ($raw.Contains("`t")) { $indent = "`t`t" }
        $nl = if ($raw.Contains("`r`n")) { "`r`n" } else { "`n" }
        $entry = $nl + $indent + '"-agentlib:zbNative",'
        return $raw.Insert($bracket + 1, $entry)
    }

    # No root vmArgs key at all (rare / heavily customized) — create one on the root object.
    Write-Warn 'ProjectZomboid64.json has no root vmArgs; creating root vmArgs with -agentlib:zbNative'
    return Add-MissingRootVmArgsProperty $raw
}

function Ensure-JsonAgent([string]$gameRoot, $state) {
    # NEVER use ConvertTo-Json to rewrite ProjectZomboid64.json — pretty PS JSON breaks the PZ launcher.
    # Text-patch only: restore compact layout if needed, strip nested agents, insert one root agent.
    $jsonPath = Join-Path $gameRoot 'ProjectZomboid64.json'
    if (-not (Test-Path $jsonPath)) { return $state }

    $raw = [IO.File]::ReadAllText($jsonPath)
    $changed = $false
    $backedUp = $false

    if (Test-PsPrettyJson $raw) {
        Write-Warn 'ProjectZomboid64.json has PowerShell ConvertTo-Json formatting (breaks launcher). Restoring compact JSON...'
        Backup-File $jsonPath
        $backedUp = $true
        $restored = Find-CompactJsonText $jsonPath
        if (-not $restored) {
            throw 'Cannot restore compact ProjectZomboid64.json. Steam → Verify integrity, then re-run install.'
        }
        $raw = $restored
        $changed = $true
    }

    $stripped = Remove-AgentlibEntries $raw
    if ($stripped -cne $raw) {
        $raw = $stripped
        $changed = $true
    }

    $withAgent = Add-RootAgentlib $raw
    if ($withAgent -cne $raw) {
        $raw = $withAgent
        $changed = $true
    }

    try {
        $obj = $raw | ConvertFrom-Json
        $rootCount = @($obj.vmArgs | ForEach-Object { [string]$_ } | Where-Object { $_ -like '-agentlib:zbNative*' }).Count
        $nestedCount = 0
        if ($obj.windows) {
            foreach ($p in $obj.windows.PSObject.Properties) {
                $nestedCount += @($p.Value.vmArgs | ForEach-Object { [string]$_ } | Where-Object { $_ -like '-agentlib:zbNative*' }).Count
            }
        }
        if ($rootCount -ne 1 -or $nestedCount -ne 0) {
            throw "root agentlib count=$rootCount (expected 1), nested=$nestedCount (expected 0)"
        }
    } catch {
        throw "ProjectZomboid64.json patch failed validation: $($_.Exception.Message)"
    }

    if (-not $changed) {
        Write-Ok "JSON already has single root $AgentArg (compact)"
        return $state
    }

    if (-not $backedUp) { Backup-File $jsonPath }
    Write-Utf8NoBom $jsonPath $raw
    $state.addedJsonAgent = $true
    Write-Ok 'patched ProjectZomboid64.json (text patch, root vmArgs only, no ConvertTo-Json)'
    return $state
}

function Ensure-BatAgent([string]$gameRoot, $state) {
    # Do NOT patch ProjectZomboid64.bat: Steam Normal Launch uses the JSON,
    # and _JAVA_OPTIONS can double-load the agent or break Alternate Launch + PZOpt.
    Write-Info 'skip BAT patch (JSON root vmArgs is enough for Normal Launch)'
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
    # Recovery uninstall: always strip zbNative from JSON/BAT even if install_state is missing/wrong.
    Write-Host ''
    Write-Host '=== Animal Poop Explosion Fix - Uninstall / Recovery ===' -ForegroundColor White
    $state = $null
    if (Test-Path $StatePath) {
        try { $state = Get-Content $StatePath -Raw | ConvertFrom-Json } catch {}
    }
    $gameRoot = $null
    if ($state -and $state.gameRoot -and (Test-SafePath $state.gameRoot)) {
        $gameRoot = $state.gameRoot
    } else {
        $gameRoot = Find-GameRoot
    }
    if (-not $gameRoot) {
        Write-Err 'Could not find Project Zomboid. cd into the game folder or set APEF_GAME_ROOT.'
        if ($Host.Name -eq 'ConsoleHost') { pause }
        exit 1
    }
    Write-Info "game root: $gameRoot"
    Wait-GameClosed $gameRoot

    $jsonPath = Join-Path $gameRoot 'ProjectZomboid64.json'
    if (Test-Path $jsonPath) {
        $raw = [IO.File]::ReadAllText($jsonPath)
        $changed = $false
        $backedUp = $false
        if (Test-PsPrettyJson $raw) {
            Write-Warn 'JSON has ConvertTo-Json formatting (breaks launcher). Restoring compact backup...'
            Backup-File $jsonPath
            $backedUp = $true
            $restored = Find-CompactJsonText $jsonPath
            if ($restored) { $raw = $restored; $changed = $true }
            else { Write-Err 'Could not find a compact JSON backup. Steam → Verify integrity.' }
        }
        if ($raw -match 'agentlib:zbNative') {
            $stripped = Remove-AgentlibEntries $raw
            if ($stripped -cne $raw) { $raw = $stripped; $changed = $true }
        }
        if ($changed) {
            if (-not $backedUp) { Backup-File $jsonPath }
            Write-Utf8NoBom $jsonPath $raw
            Write-Ok 'repaired ProjectZomboid64.json (stripped zbNative / restored compact; no ConvertTo-Json)'
        } elseif ($raw -notmatch 'agentlib:zbNative') {
            Write-Ok 'JSON has no zbNative agent'
        } else {
            Write-Ok 'JSON unchanged'
        }
    }

    $batPath = Join-Path $gameRoot 'ProjectZomboid64.bat'
    if (Test-Path $batPath) {
        $braw = Get-Content $batPath -Raw -Encoding UTF8
        if ($braw -match 'agentlib:zbNative') {
            Backup-File $batPath
            $out = foreach ($line in (Get-Content $batPath -Encoding UTF8)) {
                if ($line -match '^\s*SET\s+_JAVA_OPTIONS\s*=\s*(.*)$') {
                    $cur2 = ($Matches[1] -replace '-agentlib:zbNative\S*', '').Trim()
                    if ([string]::IsNullOrWhiteSpace($cur2)) { continue }
                    "SET _JAVA_OPTIONS=$cur2"
                } else { $line }
            }
            $out | Set-Content $batPath -Encoding UTF8
            Write-Ok 'removed zbNative from ProjectZomboid64.bat'
        } else {
            Write-Ok 'BAT has no zbNative agent'
        }
    }

    $removeDll = $false
    $removeJar = $false
    if ($state) {
        if ($state.copiedZbNative) { $removeDll = $true }
        if ($state.copiedZombieBuddyJar) { $removeJar = $true }
    } elseif (Test-SafePath $MarkerPath) {
        $removeDll = $true
        $removeJar = $true
    }
    if ($env:APEF_FORCE_REMOVE_RUNTIME -eq '1') {
        $removeDll = $true
        $removeJar = $true
    }
    if ($removeDll) {
        Remove-Item -LiteralPath (Join-SafePath $gameRoot 'zbNative.dll') -Force -EA SilentlyContinue
        Write-Ok 'removed zbNative.dll (if present)'
    }
    if ($removeJar) {
        Remove-Item -LiteralPath (Join-SafePath $gameRoot 'ZombieBuddy.jar') -Force -EA SilentlyContinue
        Write-Ok 'removed ZombieBuddy.jar (if present)'
    }

    Remove-Item $StatePath -Force -EA SilentlyContinue
    Remove-Marker
    Remove-Item (Join-Path $env:USERPROFILE 'Zomboid\Lua\AnimalPoopExplosionFix-hide-helper.txt') -Force -EA SilentlyContinue
    Remove-Item (Join-Path $env:USERPROFILE 'Zomboid\Lua\AnimalPoopExplosionFix-dont-show.txt') -Force -EA SilentlyContinue
    if (Test-Path $StateDir) { Remove-Item $StateDir -Recurse -Force -EA SilentlyContinue }
    if (Test-Path $CacheDir) { Remove-Item $CacheDir -Recurse -Force -EA SilentlyContinue }

    Write-Host ''
    Write-Ok 'Done. Try launching the game again.'
    Write-Warn 'If it still fails with missing mainfont_0.png, Steam → Verify integrity of game files.'
    Write-Host ''
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
