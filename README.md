# Animal Poop Explosion Fix (B42)

Fixes Project Zomboid Build 42 livestock offline catch-up bugs (dung explosions / sudden deaths).

Steam Workshop cannot ship `.dll` / `.bat`. Install is **PZOpt-style**: one command pulls runtime files from **this repo's GitHub Releases**.

## Install (players)

1. Subscribe to the Workshop item and enable **Animal Poop Explosion Fix**.
2. Open **cmd** or **PowerShell** and run:

```bat
powershell -ExecutionPolicy Bypass -Command "irm https://github.com/Beibeisheep/AnimalPoopExplosionFix/releases/latest/download/Install.ps1 | iex"
```

(If you are already inside PowerShell, you can also use: `irm .../Install.ps1 | iex`)

3. Quit the game when the script asks (it waits), then start again with the mod enabled.

## Uninstall

```bat
powershell -ExecutionPolicy Bypass -Command "irm https://github.com/Beibeisheep/AnimalPoopExplosionFix/releases/latest/download/Uninstall.ps1 | iex"
```

## Release assets (maintainers)

| Asset | Purpose |
|-------|---------|
| `Install.ps1` | Installer |
| `Uninstall.ps1` | Uninstaller wrapper |
| `zbNative.dll` | JVM agent native loader |
| `ZombieBuddy.jar` | Agent host (MIT — see LICENSE-ZombieBuddy.txt) |

## Credits

Bundled runtime uses [ZombieBuddy](https://github.com/zed-0xff/ZombieBuddy) (MIT) by Andrey "Zed" Zaikin.
