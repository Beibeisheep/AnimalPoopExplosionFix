# Animal Poop Explosion Fix (B42)

Fixes Project Zomboid Build 42 livestock offline catch-up bugs (dung explosions / sudden deaths).

Steam Workshop cannot ship `.dll` / `.bat`. Install is **PZOpt-style**: one PowerShell line pulls runtime files from **this repo鈥檚 GitHub Releases**.

## Install (players)

1. Subscribe to the Workshop item and enable **Animal Poop Explosion Fix**.
2. Open PowerShell and run:

```powershell
irm https://github.com/Beibeisheep/AnimalPoopExplosionFix/releases/latest/download/Install.ps1 | iex
```

3. Quit the game when the script asks (it waits), then start again with the mod enabled.

Uninstall:

```powershell
irm https://github.com/Beibeisheep/AnimalPoopExplosionFix/releases/latest/download/Install.ps1 | iex
```

Then re-run with `-Uninstall` from a downloaded file, or:

```powershell
& ([scriptblock]::Create((irm https://github.com/Beibeisheep/AnimalPoopExplosionFix/releases/latest/download/Install.ps1))) -Uninstall
```

(Simpler: download `Install.ps1` and run `powershell -File Install.ps1 -Uninstall`.)

## Release assets (maintainers)

Tag a release and upload:

| Asset | Purpose |
|-------|---------|
| `Install.ps1` | Installer (same as repo root) |
| `zbNative.dll` | JVM agent native loader |
| `ZombieBuddy.jar` | Agent host (MIT 鈥?see LICENSE-ZombieBuddy.txt) |

## Credits

Bundled runtime uses [ZombieBuddy](https://github.com/zed-0xff/ZombieBuddy) (MIT) by Andrey "Zed" Zaikin.
