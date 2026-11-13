# Known Windows folders: junk, caches, hotspots, and leave-alone list

All paths are **typical**. Verify on the actual machine before touching anything.
Delete **contents**, not the root folder, and skip files in use. Third-party
optimizers (e.g. Bitdefender OneClick Optimizer) automate a subset of this; this
skill stays transparent and asks for approval per action.

## 1. Clutter hotspots — always report

Report size/count and top offenders even when they are not the biggest consumer:

| Hotspot | Path | Notes | Risk |
|---|---|---|---|
| Downloads | `%USERPROFILE%\Downloads` (or redirected target) | installers, ISOs, archives, duplicates | Low to review; Medium to bulk-delete — user selects |
| Desktop | `%USERPROFILE%\Desktop` | large files/folders parked "temporarily" | Low to review; Medium to bulk-delete |
| Recycle Bin | `$Recycle.Bin` per drive | still consumes space; purging is irreversible | Low **if user confirms** |
| Videos / Pictures / Documents | `%USERPROFILE%\...` | media, exports, large project assets | Low to review; Medium to delete/move |
| User temp | `%TEMP%` | grows continuously | Low to clear contents |

Never bulk-delete Downloads/Desktop without item-by-item or explicit user selection.

## 2. Temp/cache/junk map (Bitdefender-like targets)

| Location | Contains | Action | Risk / notes |
|---|---|---|---|
| `%TEMP%` (`C:\Users\<User>\AppData\Local\Temp`) | installer leftovers, app caches, crash remnants | clear contents, skip in use | Low; close apps/installers first |
| `C:\Windows\Temp` | system temp | clear contents, skip in use | Low–Medium; not during updates/installs; may need admin |
| Browser caches (Chrome, Edge, Firefox, Brave, Opera) | cache, temp internet files | clear cache via browser/approved method | Low for cache; **Medium/privacy** for cookies/history/logins — explicit choice only |
| `C:\Windows\Minidump`, `C:\Windows\LiveKernelReports` | BSOD/kernel dumps | delete old dumps | Low unless debugging a crash |
| WER: `C:\ProgramData\Microsoft\Windows\WER\ReportArchive`, `...\ReportQueue` | crash reports | empty | Low |
| Known `*.log` / diagnostic logs | logs | delete/rotate old logs | Low–Medium; keep if needed for support |
| `$Recycle.Bin` | deleted items | empty on confirmation | Low but irreversible |
| `C:\Windows\SoftwareDistribution\Download` | past update packages | empty when updates are finished | Low–Medium; skip if updates pending/active |
| Delivery Optimization cache (`C:\Windows\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache`) | P2P update files | prefer Settings → Storage / Disk Cleanup | Low–Medium; tool-managed preferred |
| `C:\Users\<User>\AppData\Local\Microsoft\Windows\Explorer` (`thumbcache_*.db`, `iconcache_*.db`) | thumbnail/icon cache | delete cache files (Explorer closed) | Low; Windows rebuilds (brief UI slowdown) |
| `C:\Users\<User>\AppData\Local\D3DSCache` | DirectX shader cache | delete | Low; games recompile (brief stutter) |
| `C:\Windows.old` | previous Windows install | remove via Disk Cleanup → "Previous Windows installation(s)" only if no rollback needed | **Medium**; 10–30+ GB; do not delete by hand |

## 3. Leave alone (explicitly)

| Path | Why | Agent behavior |
|---|---|---|
| `C:\Windows\Prefetch` | `.pf` files help app launch; clearing gives no real benefit and slows startup while rebuilt | Do not recommend cleaning; explain only |
| `C:\Windows\Installer` | `.msi`/`.msp` needed for repair/uninstall/update | Never delete/junction; High risk |
| `C:\Windows\WinSxS` | component store with hardlinks; critical for servicing | Never delete/junction; DISM only, admin, warn |
| `C:\Windows\System32` and core system dirs | OS-critical | Never touch |
| `pagefile.sys`, `hiberfil.sys`, `swapfile.sys` | kernel-managed | System settings / `powercfg` only |
| `C:\Program Files*`, `C:\ProgramData` | system/app integration | Per-app official mechanisms only; High risk |
| `C:\Recovery`, `C:\Boot`, `System Volume Information`, `$Recycle.Bin` | boot/recovery/volume metadata | Never move or junction; Recycle Bin purge only with confirmation |

The scripts enforce this with the **red** risk level and a protected-path check in
`make-plan.ps1` / `move-and-link.ps1`. A red item is refused, not warned about.

## 4. Common dev caches and stores

| Tool | Typical location | Notes |
|---|---|---|
| npm | `%LOCALAPPDATA%\npm-cache`, `%APPDATA%\npm-cache` | relocate via `npm config set cache` |
| pnpm | store (config), `%LOCALAPPDATA%\pnpm`, `pnpm-cache` | `pnpm store path`, `pnpm store prune`; watch junction farms |
| yarn | `%LOCALAPPDATA%\Yarn\Cache` | `yarn cache dir` |
| bun | `%USERPROFILE%\.bun\install\cache` | internal links possible |
| pip | `%LOCALAPPDATA%\pip\Cache` | `pip cache dir`, `pip cache purge` |
| uv | `%LOCALAPPDATA%\uv\cache` | `UV_CACHE_DIR`, `uv cache prune` |
| NuGet | `%USERPROFILE%\.nuget\packages` | `NUGET_PACKAGES` |
| Cargo | `%USERPROFILE%\.cargo\registry`, `\git` | `CARGO_HOME`; don't move while cargo/rust-analyzer runs |
| Gradle | `%USERPROFILE%\.gradle` | `GRADLE_USER_HOME` |
| Maven | `%USERPROFILE%\.m2\repository` | |
| Go | `%USERPROFILE%\go\pkg\mod` | `GOMODCACHE` |
| HuggingFace | `%USERPROFILE%\.cache\huggingface` | often contains symlinks — materialize or recreate |
| PyTorch | `%USERPROFILE%\.cache\torch` | `TORCH_HOME` |
| Playwright | `%LOCALAPPDATA%\ms-playwright` | `PLAYWRIGHT_BROWSERS_PATH`; keep one browser version |
| electron | `%LOCALAPPDATA%\electron`, `%LOCALAPPDATA%\electron-builder` | `ELECTRON_CACHE` |
| Unity | `%LOCALAPPDATA%\Unity\cache`, `%APPDATA%\Unity\...` | editor/asset caches; projects' `Library/` is regenerable |
| Unreal | `%LOCALAPPDATA%\UnrealEngine\Common` | DerivedDataCache, regenerable |
| Docker | `%LOCALAPPDATA%\Docker\wsl\main\ext4.vhdx` (path varies by version) | prefer Settings → Disk image location; `docker system prune`; see `references/DOCKER.md` |
| WSL | `%LOCALAPPDATA%\wsl\<distro>\ext4.vhdx` | `wsl --manage --move/--set-sparse`, stopped only |

## 4b. Cloud placeholders (OneDrive and friends)

| Location | What it is | Action |
|---|---|---|
| `%USERPROFILE%\OneDrive` (or your sync root) | Files On-Demand: some files are online-only placeholders | Do **not** bulk-copy or junction blindly. Copying hydrates every file (bandwidth + space). Exclude, or hydrate deliberately. |
| Any folder with the `Offline` / `RecallOnDataAccess` attribute | Placeholder, content not local | Report as offline; do not count its logical size as reclaimable. |
| Synced folder as a junction target | Sync client may re-upload or fight the link | Avoid. Move data outside the sync root. |

`audit.ps1` counts placeholders as `offline` and reports their logical size; the
plan warns with `offline_files`. See `references/TRANSACTION.md`.

## 5. Prevention (environment/config → target drive)

```text
UV_CACHE_DIR, PIP_CACHE_DIR, HF_HOME, TORCH_HOME, PNPM_HOME / store-dir,
npm_config_cache, PLAYWRIGHT_BROWSERS_PATH, ELECTRON_CACHE,
GRADLE_USER_HOME, NUGET_PACKAGES, GOMODCACHE, CARGO_HOME
```

Plus: Storage Sense on, `wsl --manage <distro> --set-sparse true`, and a monthly
prune (`uv cache prune`, `pnpm store prune`, `npm cache clean --force`,
`pip cache purge`, `docker system prune`, DISM component cleanup).
