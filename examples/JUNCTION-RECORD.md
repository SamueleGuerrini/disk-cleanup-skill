# Junction Record — C: → E: migration (synthetic example)

> **This is a synthetic example.** Every path, project, folder, and application
> name below is invented to show the shape of a record. Nothing here describes a
> real machine, and the sizes are illustrative.

**Last updated:** 2026-11-13
**Status:** C: went from ~0.2 GB free to ~368 GB free.
**Safety layers used:** L1 (staged originals) + L3 (git snapshot on touched repos)

## Why

C: is a 930 GB NVMe SSD. E: is a 7.4 TB SATA HDD. Large, cold data and regenerable
caches live on E: and are exposed at their original C: paths via **directory
junctions**, so apps, scripts, editors, git and shell shortcuts keep working
unchanged. A junction is not a backup: E: is a single spindle, and the data on it is
covered by a separate external backup.

## What a junction is

A junction makes `C:\path\to\folder` point to `E:\real\location`. Windows and almost
all applications treat it as the real folder. No config changes are needed. Unlike a
symlink, a junction cannot point to a file, only to a directory on a local volume.

> **Golden rules**
> - Remove a junction with `[System.IO.Directory]::Delete($path, $false)` (or
>   `cmd /c rmdir "C:\path"`) — **never** `rmdir /s`, never `Remove-Item -Recurse`.
> - Never store a junction inside a folder that will be deleted recursively.
> - Copy → verify → stage → link → verify. Abort on mismatch.

---

## Junctions / redirects (original, 2026-06-19)

| # | Junction path (C:) | Target (E:) | Size |
|---|---|---|---|
| 1 | `%LOCALAPPDATA%\App-A\engine\disk` | `E:\Bulk\Apps\App-A\engine\disk` | 52.6 GB |
| 2 | `%USERPROFILE%\.app-b\models` | `E:\Bulk\Apps\App-B\models` | 18 GB |
| 3 | `%USERPROFILE%\Documents\Workspace` | `E:\Bulk\Workspace` | 49 GB |
| 4 | `%USERPROFILE%\Documents\Projects` | `E:\Bulk\Projects` | 40 GB |
| 5 | `%USERPROFILE%\Documents\Projects\Project-Web` | `E:\Bulk\Projects\Project-Web` | 27 GB |
| 6 | `%USERPROFILE%\Documents\Projects\Project-ERP` | `E:\Bulk\Projects\Project-ERP` | ~1 GB |
| 7 | `%USERPROFILE%\Videos` | `E:\Bulk\Videos` | 8.4 GB |
| 8 | `%USERPROFILE%\Pictures` | `E:\Bulk\Pictures` | 41 GB |
| 9 | `%USERPROFILE%\Downloads` | `E:\Bulk\Downloads` | 9.4 GB |

**Correction (2026-11-13):** `Pictures` is a **junction** to `E:\Bulk\Pictures`, not
only a shell-folder redirect. The registry value
`HKCU\...\User Shell Folders\My Pictures` also points to `E:\Bulk\Pictures`. Both
exist; the junction is what actually holds the data.

---

## Cache junctions → `E:\Bulk\Caches` (pre-existing)

These existed before this record was written and were undocumented.

| Junction path (C:) | Target (E:) |
|---|---|
| `%LOCALAPPDATA%\App-A\updates` | `E:\Bulk\Caches\App-A-Updates` |
| `%LOCALAPPDATA%\App-C\cache` | `E:\Bulk\Caches\App-C-Cache` |
| `%LOCALAPPDATA%\App-C\App-C\cache` | `E:\Bulk\Caches\App-C-Nested` |
| `%LOCALAPPDATA%\Editor\cache` | `E:\Bulk\Caches\Editor-Cache` |
| `%LOCALAPPDATA%\Editor\Caches` | `E:\Bulk\Caches\Editor-Local` |
| `%APPDATA%\Editor\Asset Store-5.x` | `E:\Bulk\Caches\Editor-Assets` |
| `%APPDATA%\Editor\cache` | `E:\Bulk\Caches\Editor-Roaming` |
| `%APPDATA%\Editor\Caches` | `E:\Bulk\Caches\Editor-Roaming-Caches` |
| `%APPDATA%\Editor\Packages` | `E:\Bulk\Caches\Editor-Packages` |

## Cache junctions → `E:\Bulk\Caches` (added 2026-11-13)

| Junction path (C:) | Target (E:) | Size |
|---|---|---|
| `%USERPROFILE%\.build-tool` | `E:\Bulk\Caches\build-tool` | 3.3 GB |
| `%USERPROFILE%\.package-store` | `E:\Bulk\Caches\package-store` | 1.3 GB |
| `%USERPROFILE%\.assistant-a` | `E:\Bulk\Caches\assistant-a` | 2.6 GB |
| `%USERPROFILE%\.assistant-b` | `E:\Bulk\Caches\assistant-b` | 0.5 GB |
| `%USERPROFILE%\.runtime-a` | `E:\Bulk\Caches\runtime-a` | 4.4 GB |
| `%USERPROFILE%\.cache\models` | `E:\Bulk\Caches\models` | 10.8 GB |
| `%LOCALAPPDATA%\python-tools` | `E:\Bulk\Caches\python-tools` | 11.2 GB |
| `%LOCALAPPDATA%\browser-drivers` | `E:\Bulk\Caches\browser-drivers` | 2.0 GB |
| `%LOCALAPPDATA%\desktop-runtime` | `E:\Bulk\Caches\desktop-runtime` | 1.2 GB |
| `%LOCALAPPDATA%\package-cache` | `E:\Bulk\Caches\package-cache` | 2.0 GB |
| `%APPDATA%\Design-App` | `E:\Bulk\Caches\Roaming-Design-App` | 3.6 GB |
| `%APPDATA%\Assistant-App` | `E:\Bulk\Caches\Roaming-Assistant-App` | 2.6 GB |

> `runtime-a`, `python-tools`, `package-cache` and `models` contained internal
> junctions or symlinks. They were **materialised** (real files) on E: to avoid
> broken links. This costs a little duplicate space but is functionally identical.

---

## Project folders → `E:\Bulk\Projects\Group-A` (2026-11-13)

Every original path on C: is now a junction. `node_modules` was **excluded** on
purpose (see the note below).

| Project (C: path under `Documents\Projects\Group-A\`) | Size |
|---|---|
| Project-01 | 32.4 GB |
| Project-02 | 28.9 GB |
| Project-03 | 10.2 GB |
| Project-04 | 9.0 GB |
| Project-05 | 7.8 GB |
| Project-06 | 4.2 GB |
| Project-07 | 4.1 GB |
| Project-08 | 3.0 GB |
| Project-09 | 1.5 GB |
| Project-10 | 1.5 GB |
| Project-11 | 0.9 GB |
| Project-12 | 0.9 GB |
| Project-13 | 0.2 GB |
| Project-14 | 0.2 GB |
| Project-15 | 0.2 GB |
| Project-16 | 0.2 GB |
| Project-17 | 0.1 GB |
| Project-18 | 0.2 GB |
| Project-19 | 0.1 GB |
| Project-20 | 0.1 GB |
| Project-21 | <0.1 GB |
| Project-22 | <0.1 GB |
| Project-23 | <0.1 GB |
| Project-24 | <0.1 GB |
| Project-25 | <0.1 GB |
| Project-26 | <0.1 GB |
| Project-27 | <0.1 GB |
| Project-28 | <0.1 GB |
| `Project-Side` → `E:\Bulk\Projects\Project-Side` | 2.0 GB |

**pnpm / node_modules:** nine of these use pnpm junction farms in `node_modules`
(for example Project-04, Project-16 and Project-20). Those folders were not moved.
Before working on one, run:

```powershell
cd "C:\Users\<user>\Documents\Projects\Group-A\<project>"
pnpm install --prefer-offline
```

The pnpm store is already local on E: (`E:\Bulk\Caches\pnpm-store`), so this is
mostly linking, not downloading.

---

## Root programs → `E:\Bulk\Apps` (2026-11-13)

| Junction path (C:) | Target (E:) | Size |
|---|---|---|
| `C:\tool-a` | `E:\Bulk\Apps\tool-a` | <0.1 GB |
| `C:\tool-b` | `E:\Bulk\Apps\tool-b` | 0.3 GB |
| `C:\runtime-1` | `E:\Bulk\Apps\runtime-1` | 0.1 GB |
| `C:\runtime-2` | `E:\Bulk\Apps\runtime-2` | 0.1 GB |
| `C:\stack-x` | `E:\Bulk\Apps\stack-x` | 0.8 GB |

`C:\node-version-manager` and `C:\Python-runtime` were **not** moved: live processes
(including the agent CLI) run from them. Junctioning them later is fine, but only
with those processes stopped.

---

## Unused engine versions → `E:\Bulk\Engines` (2026-11-13)

`Version-A` stays on C: (it is the version in active use). The rest moved and are
junctioned back, so the engine hub still sees them at their original paths.

| Junction path (C:) | Target (E:) | Size |
|---|---|---|
| `...\Hub\Editor\Version-B` | `E:\Bulk\Engines\Version-B` | 18.0 GB |
| `...\Hub\Editor\Version-C` | `E:\Bulk\Engines\Version-C` | 8.8 GB |
| `...\Hub\Editor\Version-D` | `E:\Bulk\Engines\Version-D` | 0.1 GB |
| `...\Hub\Editor\Version-E` | `E:\Bulk\Engines\Version-E` | ~0 GB |

---

## Deleted / cleaned (2026-11-13)

| Item | Freed |
|---|---|
| `C:\hiberfil.sys` (hibernation disabled with `powercfg /h off`) | 12.7 GB |
| `C:\Windows\Panther` (upgrade logs) | 3.5 GB |
| `C:\Windows\Logs` | 0.9 GB |
| `C:\Windows\SoftwareDistribution\Download` | 0.2 GB |
| `%LOCALAPPDATA%\Engine-A\DerivedDataCache` | 3.2 GB |
| `%LOCALAPPDATA%\Game-A\ShaderCache` | 2.3 GB |

> Hibernation is now **off** → Fast Startup is also off. Re-enable anytime with
> `powercfg /h on` (admin).

---

## Not moved (deliberately still on C:)

| Item | Size | Reason |
|---|---|---|
| `Documents\Projects\Group-A\Project-Large` | 82 GB | actively edited |
| `Documents\Projects\Group-A\Project-Engine` | 30.2 GB | kept on SSD by request |
| `Documents\Projects\Group-A\Project-Framework` | 6.3 GB | open in the editor |
| `%USERPROFILE%\.compiler-cache` | 0.9 GB | compiler/analyzer running |
| `%USERPROFILE%\.cache` (rest) | ~8 GB | runtime caches in use |
| `%USERPROFILE%\.agent-data` | 3.0 GB | agent active |
| `%USERPROFILE%\.editor` | 4.0 GB | editor running |
| `%APPDATA%\Editor` | 4.0 GB | editor running |
| `%USERPROFILE%\.local` | 4.1 GB | holds an in-use database |
| WSL `ext4.vhdx` | 17 GB | workload running inside WSL |
| `Program Files` apps | — | system-integrated; junctionable only per-app |

Follow-up: close the relevant app, then move with the same recipe.

---

## Config changes (no junctions)

| Tool | Config | New location |
|---|---|---|
| **npm** | `npm config set cache` | `E:\Bulk\Caches\npm` |
| **pnpm** | `pnpm config set store-dir --global` | `E:\Bulk\Caches\pnpm-store` |
| **pip** | `PIP_CACHE_DIR` (User env) | `E:\Bulk\Caches\pip` |

Recommended additions (not yet applied):

```text
UV_CACHE_DIR             = E:\Bulk\Caches\python-tools
HF_HOME                  = E:\Bulk\Caches\models
PLAYWRIGHT_BROWSERS_PATH = E:\Bulk\Caches\browser-drivers
ELECTRON_CACHE           = E:\Bulk\Caches\desktop-runtime
GRADLE_USER_HOME         = E:\Bulk\Caches\build-tool
NUGET_PACKAGES           = E:\Bulk\Caches\package-store
```

---

## Known oddity

`C:\Users\<user>\node_modules` is a **junction pointing to `C:\Users\<user>`** (a
self-referencing loop). It consumes no real space but breaks disk-usage tools and
`npm` run from the home directory. Remove it with:

```powershell
[System.IO.Directory]::Delete('C:\Users\<user>\node_modules', $false)
```

---

## How to verify

```powershell
(Get-Item "C:\Users\<user>\Downloads").Target                 # E:\Bulk\Downloads
(Get-Item "C:\Users\<user>\Documents\Projects\Group-A\Project-06").Target
Get-PSDrive C | Select-Object Free
```

List every junction under a path:

```powershell
Get-ChildItem C:\Users\<user> -Recurse -Force -Directory -Depth 4 |
  Where-Object { $_.LinkType -eq 'Junction' } |
  Select-Object FullName, Target
```

## How to undo (move back to C:)

1. Close apps using the folder.
2. Remove the link only: `[System.IO.Directory]::Delete('C:\path\to\junction', $false)`.
3. `robocopy "E:\real\location" "C:\original\path" /E /COPY:DAT /DCOPY:T /MOVE`
4. Recreate if needed: `New-Item -ItemType Junction -Path "C:\path" -Target "E:\real\location"`.

## How to move a junction to another drive

```powershell
[System.IO.Directory]::Delete('C:\Users\<user>\Videos', $false)
robocopy "E:\Bulk\Videos" "F:\Bulk\Videos" /E /COPY:DAT /DCOPY:T /MOVE
New-Item -ItemType Junction -Path 'C:\Users\<user>\Videos' -Target 'F:\Bulk\Videos'
```
