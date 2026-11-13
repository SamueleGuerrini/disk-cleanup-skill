---
name: disk-cleanup
description: Audit Windows disk usage and help reclaim space by safely deleting junk/regenerable data or moving user-selected folders to another drive and replacing them with directory junctions. Use when asked to clean a drive, free disk space, find what is using space, move folders to another disk, offload caches/projects/AppData, or produce a disk-usage report. Always audit read-only first (visual HTML report plus a junction-aware scan), classify items with explicit green/yellow/orange/red risk levels, treat unknown or unrecognized folders as user-led (never guess), require explicit per-item approval bound to a machine-readable plan, and warn that agent-driven file moves and deletes are high risk. Execute as a transaction with crash recovery, verify + report the result afterwards, and document every action in an append-only manifest.
license: MIT
---

# Disk Cleanup (audit → propose → approve → act → verify → document)

A safe, auditable workflow for reclaiming space on Windows. It is **not** a one-shot
"clean everything" script: every machine is different, so it measures first, explains
what it finds, labels risk, and acts only on what the user explicitly approves.

Two layers work together:

- **Reporting layer** (`audit.ps1`, `report.ps1`): read-only, visual, fast. Produces
  the evidence you use to decide what to propose.
- **Transaction layer** (`make-plan.ps1`, `move-and-link.ps1`, `verify.ps1`,
  `restore-staged.ps1`, `purge-staged.ps1`): plan-bound, crash-safe, reversible
  until purge.

---

## ⚠️ Read this first: this is a high-risk operation

Letting an AI agent or an automated script move, rename, or delete files carries
real, sometimes irreversible risk:

- **Hidden dependencies.** Apps, services, IDEs, build tools and the OS itself keep
  state in places you cannot see from a folder listing.
- **Reparse points.** Junctions/symlinks can silently redirect a recursive delete
  into a different folder, including the user profile or system directories.
- **Path and shell bugs.** Escaping/quoting can be mangled across shells, trailing
  backslashes can truncate a path, POSIX-style paths (`/c/Users/...`) are not
  Windows paths, and 8.3 short names (`PROGRA~1`) are not temp folders.
- **Limited or no undo.** A moved file is usually recoverable; a deleted one is not.

Real-world incidents (widely reported) include agents wiping user profiles after
misreading Windows junctions, deleting the wrong root after path escaping was
corrupted across nested shells, and treating Unix-style Windows paths as disposable
temp folders. **Do not run this workflow in auto-approve / "YOLO" mode.** Prefer a
VM/container/sandbox or a verified backup for anything you cannot afford to lose.

**Non-negotiables:**

1. Audit is **read-only**.
2. No move/delete without explicit approval of that specific item, bound to a plan.
3. Prefer soft-delete (quarantine/Recycle Bin) over permanent deletion.
4. Never follow reparse points during cleanup or purge.
5. Verify after every operation, and report failures instead of declaring success.
6. Never move or delete a **red** (protected) item, even if it looks empty.

---

## Phase 0 — Choose mode and safety level

Ask the user, before proposing anything:

1. **Scope:** which drive(s) to audit (default `C:`), which target drive/path for
   moved data, and whether the target is SSD or HDD. See
   `references/TARGET-DRIVES.md` — media choice is a performance and reliability
   decision, not just capacity.
2. **Tiers to include** (see Phase 2): user-made folders, harmless profile folders,
   dev caches/stores, regenerable outputs, risky/system. Let them pick or name
   specific paths.
3. **Safety layers** (see `references/ROLLBACK.md`). Default = **L1 quarantine**.
   Layers are composable:
   - **L1** soft-delete/quarantine (recommended default)
   - **L2** L1 + Windows restore point before admin/system phases (needs admin,
     24h cooldown; must verify the point was created)
   - **L3** L2 + git snapshot (`git stash -u` or backup branch) for affected repos
   - **L4** L3 + Volume Shadow Copy (advanced; explain restore complexity, prefer a
     real backup)
4. **Isolation offer:** for system-level or bulk operations, recommend a VM,
   container, or a verified full backup first.

State plainly what each layer does and does not protect. A Windows restore point
does **not** back up personal files in `C:\Users\<User>`, and a junction is **not** a
backup.

---

## Phase 1 — Audit (read-only)

Run the reporting layer first:

```powershell
.\scripts\audit.ps1 -Drive C:            # full scan → JSON + HTML dashboard
.\scripts\audit.ps1 -Drive E: -SampleSeconds 1   # quick estimate of scan time
.\scripts\audit.ps1 -Drive D: -Progressive       # 30 s partial result
```

The dashboard shows a directory treemap (drill-down), file-type and year
distributions, a risk donut, a large-file table tagged by risk, same-size
duplicate candidates, and known junk/cache/hotspot folders. See
`references/REPORTING.md` for the schema and every parameter.

For a quick junction/known-folder audit without the dashboard, use
`scripts/scan.ps1`. It is also read-only.

Report:

- Drive capacity, free/used, filesystem.
- **Top consumers**, size-ranked: root, user profiles, `Program Files`/`ProgramData`,
  project/work folders, package/tool caches, VMs/WSL/Docker, games, installers/media.
- **Largest files** (ISOs, VHDX, archives, installers, media, databases).
- **Reparse-point inventory:** existing junctions/symlinks/mounts, shell-folder
  redirects, and anomalies such as **self-referential loops**. Never double-count a
  junction target as local usage.
- **Clutter hotspots, always call out even if not the top consumer:**
  `Downloads`, `Desktop`, `Recycle Bin` (per drive), `%TEMP%`, and large
  `Videos`/`Pictures`/`Documents` media or exports.
- **Known junk/cache locations** (sizes only): see `references/KNOWN-FOLDERS.md`.

Report facts with confidence levels. If a path cannot be identified confidently,
say so and mark it **Unknown — user decision required**.

Useful read-only commands:

```powershell
Get-PSDrive -PSProvider FileSystem |
  Select-Object Name,@{n='FreeGB';e={[math]::Round($_.Free/1GB,1)}},
                @{n='UsedGB';e={[math]::Round($_.Used/1GB,1)}}

# junctions / symlinks under a root (depth-limited)
Get-ChildItem 'C:\Users' -Recurse -Force -Directory -Depth 4 -ErrorAction SilentlyContinue |
  Where-Object { $_.LinkType } |
  Select-Object FullName, LinkType, @{n='Target';e={$_.Target -join ','}}

# a file's canonical path (do this before deleting/moving)
[System.IO.Path]::GetFullPath('C:\Some\Path\..\Folder\')
```

---

## Phase 2 — Classify with explicit risk

Every finding gets: `path | observed size | class | confidence | risk | options | notes`.

### Report risk levels

| Level | Meaning | Default action |
|---|---|---|
| 🟢 **green** | Temporary or regenerable | Safe to delete |
| 🟡 **yellow** | Archive material (media, ISOs, archives) | Archive or move; verify first |
| 🟠 **orange** | User content or binaries | Explicit confirmation required |
| 🔴 **red** | Protected system paths and files | **Never move or delete** |
| ⚪ **unrated** | No rule matched | Inspect; no automatic suggestion |

`unrated` is deliberately **not** green. An unrecognised folder must stay user-led.

### Workflow tiers → risk levels

| Tier | How to recognize | Typical examples | Risk | Typical options |
|---|---|---|---|---|
| **User-made / custom** | Not a known system/cache location; lives in user-chosen areas | `MyFolder`, custom projects, archives | **Orange until confirmed** | Keep, move+junction, user-guided cleanup. If purpose unclear → **Unknown**. |
| **Profile — common/harmless** | Well-known shell folders | `Downloads`, `Pictures`, `Videos`, `Documents`, `Desktop`, `Music` | **Yellow** (if not in use/redirected) | Move+junction; review/clean installers or duplicates **only if user selects**. Check whether already redirected. |
| **Regenerable / build output** | Known patterns | Unity `Library/`, `bin/`, `obj/`, `dist/`, `build/` | **Green–Yellow** | Delete/regenerate; exclude from moves. Confirm it is truly regenerable. |
| **Dev caches & package stores** | Known paths/env vars | npm/pnpm/yarn/bun, pip/uv, NuGet, Cargo, Gradle, Maven, Go mod, HuggingFace/torch, Playwright, electron, IDE caches, Docker data | **Yellow** | Prune/clean; move+junction or relocate via config/env. Close tools first. Watch for internal links. |
| **Dependency/vendor dirs** | Known names | `node_modules`, virtualenvs, vendor trees | **Yellow** | Prefer reinstall/regenerate. Move only with care (pnpm farms, symlinks). |
| **Apps/runtimes/large installs** | Known locations | Games/Steam libraries, editors/SDKs, per-user `Programs` | **Orange–Red** | Use the app's own move/uninstall mechanism first. Junction only if supported. |
| **System / Windows-managed** | System paths | `C:\Windows` (`WinSxS`, `Installer`, `System32`), component store, drivers | **Red — do not touch** | Never delete/junction `WinSxS`/`Installer`. Limited: DISM component cleanup, safe temp/log locations only, admin + warnings. |
| **Virtual memory / hibernation** | Known files | `pagefile.sys`, `hiberfil.sys`, `swapfile.sys` | **Red / manual** | Not junctionable. `powercfg` / System settings, admin, reboot; explain tradeoffs. |
| **Virtual disks / containers** | Known types | WSL `ext4.vhdx`, Docker/VM disks | **Orange** | Compact/move via official tools (`wsl --manage --move/--set-sparse`, Docker/VM settings), only when stopped. See `references/DOCKER.md`. |
| **`AppData` (broad)** | Profile app data | `AppData\Local|Roaming|LocalLow`, especially `Microsoft`, `Packages`, browser profiles | **Red** | Targeted cache cleanup or per-app move with the app closed. **Avoid a wholesale AppData junction.** |
| **Unknown / unrecognized** | Anything not confidently matched | Odd names, unfamiliar blobs, system-like but unclear | **Unrated → user-led** | **No destructive suggestion.** Report facts and ask the user what it is and what they want. |

Rule: **low confidence ⇒ Unknown ⇒ user-led.** Never invent a purpose for a folder.

---

## Phase 3 — Propose and record a plan (no changes yet)

Present a plan only for the tiers/items the user selected. For each item:

- proposed action: `keep` / `delete-safe` / `clean-cache` / `move+junction` /
  `relocate-config` / `inspect`
- target path and estimated space freed
- prerequisites (close app, admin/UAC, reboot, reinstall dependencies)
- risk label + one-line reason
- SSD/HDD performance note
- rollback layer that will cover it

Ask the user to choose per item or per group. Never batch-approve unknowns.

Then record the approved move as a machine-readable plan:

```powershell
.\scripts\make-plan.ps1 -Source 'C:\Work\App' -Destination 'D:\Work\App'
# review the printed item, then:
.\scripts\make-plan.ps1 -Source 'C:\Work\App' -Destination 'D:\Work\App' `
    -Approve -ApprovedBy '<your name>'
```

Approval stores a SHA-256 of the item's canonical fields. The executor rejects the
item if anything changes afterwards. See `references/PLAN.md`.

---

## Phase 4 — Preflight and execute

### 4.1 Preflight (per approved item)

- Resolve the **absolute canonical path**; show it; refuse drive roots and protected
  system paths.
- Confirm it is not in use/locked; skip and report if it is.
- If it is already a link, check whether it points where expected — do not "fix" it
  silently.
- Inspect for nested reparse points; planning refuses a tree that contains them.
- Confirm target has space, is a fixed local NTFS/ReFS volume, is not BitLocker-locked,
  and the destination does not already exist.
- Restate risk and get final confirmation for Orange/Red-adjacent items.

### 4.2 Execute the transaction

```powershell
# Dry run (default): prints checks, changes nothing
.\scripts\move-and-link.ps1 -PlanPath 'C:\Users\Me\_AI_Rollback\plan.json' `
    -PlanItemId 'App-20261113-021000'

# Apply
.\scripts\move-and-link.ps1 -PlanPath '...' -PlanItemId '...' -Execute
```

The executor:

1. re-checks approval hash, volume serials, size/file drift (default 2%), and target
   eligibility;
2. copies (reparse-safe, `node_modules` excluded by default);
3. verifies the copy (Basic / Standard / Strict);
4. stages the original (`Rename` default, `Quarantine`, or `Delete` with exact-path
   confirmation);
5. creates the junction;
6. verifies again and commits.

Every step appends an event to `manifest.jsonl`. If the process dies, the manifest
records the last completed state and `-Recover -OperationId <id>` can finish or roll
back. See `references/TRANSACTION.md`.

Manual equivalent (only if you cannot use the script):

```powershell
# 1. copy (no link traversal; node_modules excluded by default for pnpm projects)
robocopy "C:\Source" "D:\Target\Source" /E /COPY:DAT /DCOPY:T /R:2 /W:2 /XJ /XD node_modules

# 2. verify counts/bytes yourself (robocopy summary text is localized)
#    source files == destination files, source bytes == destination bytes, else STOP

# 3. stage the original instead of hard-deleting (see references/ROLLBACK.md)
Rename-Item -LiteralPath "C:\Source" -NewName "Source.__prelink_2026-11-13_0130"

# 4. create the junction at the original path
New-Item -ItemType Junction -Path "C:\Source" -Target "D:\Target\Source"

# 5. verify
$i = Get-Item "C:\Source" -Force
$i.LinkType   # Junction
$i.Target     # D:\Target\Source
```

Rules:

- **Never** remove a junction with `Remove-Item -Recurse` or `rmdir /s`. Delete the
  link only: `[System.IO.Directory]::Delete($path, $false)` (or
  `cmd /c rmdir "<path>"`). In scripts prefer the .NET call — no nested shells.
- Never copy a folder into itself or into its own descendant.
- Never use wildcards or unquoted variables in destructive commands.
- Do not chain `cd` and a delete with `;`; use `&&` and verify `Get-Location`.
- Avoid nesting `cmd` inside PowerShell inside Bash; match syntax to the active shell.
- Use `-LiteralPath` for paths that may contain `[`, `]`, `*`, or `?`.

### 4.3 Junk / cache cleanup

Follow `references/KNOWN-FOLDERS.md`. Key rules:

- Delete **contents**, not the root folder.
- Skip files in use; close the owning app when practical.
- Empty the Recycle Bin only with explicit confirmation (irreversible).
- Use built-in tools (Settings → Storage, Disk Cleanup) for Delivery Optimization
  and `C:\Windows.old`.
- **Never** delete or junction `C:\Windows\WinSxS` or `C:\Windows\Installer`.
- Leave `C:\Windows\Prefetch` alone (no real benefit).
- `pagefile.sys`/`hiberfil.sys` are not junctionable — use system settings and
  `powercfg /h off` (admin), explaining tradeoffs.

### 4.4 Special cases

- **pnpm/npm `node_modules`:** exclude and reinstall (`pnpm install --prefer-offline`);
  the store usually already lives on the target drive. Junctioning `node_modules`
  saves little and breaks some watchers/`realpath` flows.
- **Caches with internal symlinks** (HuggingFace, pnpm, uv): materialize links or
  recreate them; robocopy `/XJ` skips them, and recreating symlinks may need admin.
- **WSL:** `wsl --shutdown`, then `wsl --manage <distro> --move <path>`, optionally
  `--set-sparse true`. Never while the distro or tools are running.
- **Docker Desktop:** prefer Settings → Resources → Advanced → Disk image location;
  manual VHDX + junction recipe and HDD performance warnings are in
  `references/DOCKER.md`. Do not move it while Docker/WSL are running.
- **Unity editors:** move the install folder, then confirm Unity Hub still lists it
  (Hub stores install paths); reinstall into the new location if not.
- **AppData:** default to targeted cleanup or per-app moves with the app closed.
  A whole-AppData junction is an advanced, offline, high-risk move — advise against
  it when the target is an HDD.
- **OneDrive/cloud placeholders:** copying hydrates online-only files (bandwidth +
  space). Exclude or hydrate deliberately; do not junction into a synced tree.
- **Windows.old:** remove only via Disk Cleanup ("Previous Windows installation(s)")
  and only if the user does not need rollback.

---

## Phase 5 — Verify and report (mandatory, never skipped)

Run `scripts/verify.ps1` and a functional smoke test appropriate to what changed:

```powershell
.\scripts\verify.ps1 -Drive C: -ManifestPath 'D:\_AI_Rollback\manifest.jsonl'
```

Report `check | expected | observed | PASS/FAIL/WARN | evidence | suggested fix`.

Minimum checks:

1. **Space:** free/used before vs after; reconcile with estimates (logical vs
   allocated, sparse, hardlinks, cloud placeholders).
2. **Links:** every created junction has `LinkType=Junction` and the intended target;
   no broken or self-referential links; no unexpected reparse points.
3. **Data:** file/byte counts match the verified copy; spot-read sample files;
   `git status` on touched repos shows no mass deletions.
4. **Transactions:** no operation is left between `prepared` and `verified`; anything
   unfinished is flagged, never reported as success.
5. **Function:** launch/verify affected apps or tools (IDE, Unity Hub, package
   manager, browser, WSL, Docker); open a moved folder via its original C: path;
   confirm shell folders still resolve.
6. **Scope:** nothing outside the approved list changed; unknowns were left alone;
   staged/quarantined items are present and restorable.
7. **System:** if system cleanup ran, confirm services/updates are healthy and that
   `WinSxS`/`Installer` were untouched.

If anything **FAILs: stop, do not declare success.** Diagnose read-only, explain the
blast radius, and propose the least destructive fix from `references/POST-OPERATION.md`
(quarantine restore, re-link, restore point, git stash/branch, VSS). Apply a fix only
after explicit approval, then re-verify and update the manifest.

### Restore and purge

```powershell
# Restore a staged item (Abort is the default conflict policy)
.\scripts\restore-staged.ps1 -ManifestPath 'D:\_AI_Rollback\manifest.jsonl' `
    -Id <op-id> -Execute

# Purge staged data only when the move is proven good (irreversible)
.\scripts\purge-staged.ps1 -ManifestPath 'D:\_AI_Rollback\manifest.jsonl' `
    -Id <op-id> -ConfirmPurge <op-id> -Execute
```

Purge refuses if the live target is missing or the original path is not the expected
junction. See `references/TRANSACTION.md`.

---

## Phase 6 — Document and prevent

Append every action to a manifest (see `references/MANIFEST-TEMPLATE.md` and
`examples/JUNCTION-RECORD.md`): date, source, target, size, action, risk, rollback
layer, exclusions, verification result, purge status, undo steps. The JSONL manifest
is append-only; never rewrite history.

Then report:

- space freed and where
- links created (original path → target)
- deleted/quarantined items and how to restore them
- deferred/skipped items and why (locked, in use, unknown, user kept)
- prevention: relocate caches via env/config and schedule pruning, e.g.

```text
UV_CACHE_DIR, PIP_CACHE_DIR, HF_HOME, TORCH_HOME, PNPM_HOME / store-dir,
npm_config_cache, PLAYWRIGHT_BROWSERS_PATH, ELECTRON_CACHE,
GRADLE_USER_HOME, NUGET_PACKAGES, GOMODCACHE, CARGO_HOME
```

Suggested prune routine: `uv cache prune`, `pnpm store prune`, `npm cache clean
--force`, `pip cache purge`, Docker `system prune`, `DISM /Online /Cleanup-Image
/StartComponentCleanup` (admin; `/ResetBase` is irreversible for update rollback).

---

## Stop conditions (do not act)

- Path is unknown/unrecognized, ambiguous, a drive root, or a protected system path.
- Path contains `~` (8.3 short name) or looks alias-like — resolve first.
- Target is in use/locked, or is (or contains) a reparse point you did not plan for.
- Verification mismatches, or a link target is missing/incorrect.
- The plan item is unapproved, changed since approval, or the source drifted.
- The target drive is removable/network without explicit acceptance.
- The user has not approved the specific item, or the requested action is high risk
  without an explicit, informed confirmation.

When in doubt: report, ask, wait.

---

## Bundled files

**Agent entry point**

- `commands/clean-disk.md` — `/clean-disk`: loads this skill in plan mode, checks
  the mode, warns if it is not read-only, then offers audit / scan / plan / verify.

**Workflow and safety**

- `references/SAFETY.md` — path/junction/shell safety checklist and incident lessons.
- `references/CLASSIFICATION.md` — tiers, green/yellow/orange/red risk mapping, proposal format.
- `references/KNOWN-FOLDERS.md` — Windows junk/cache map, clutter hotspots, leave-alone list.
- `references/ROLLBACK.md` — safety layers L1–L4, commands, limitations, restore steps.
- `references/POST-OPERATION.md` — verification checklist and remediation playbook.
- `references/MANIFEST-TEMPLATE.md` — human-readable record and JSONL event schema.

**Planning and execution**

- `references/PLAN.md` — plan schema, approval hash, drift checks.
- `references/TRANSACTION.md` — states, crash recovery, restore conflicts, safe purge,
  ACL/ADS/hardlink/sparse/cloud caveats.

**Reporting**

- `references/REPORTING.md` — dashboard, JSON schema, cache, workers, limits, locks.

**Media and targets**

- `references/TARGET-DRIVES.md` — SSD/HDD choice, HDD reliability, SMART, 3-2-1, CMR/SMR.
- `references/DOCKER.md` — Docker Desktop VHDX relocation and performance warnings.

**Testing**

- `references/TESTING.md` — what the suite covers and how to run it in a sandbox/VM.

**Examples**

- `examples/JUNCTION-RECORD.md` — anonymised real-world migration record.
- `examples/plan.example.json` — a complete approved plan item (placeholder hash).

**Scripts**

- `scripts/audit.ps1` — read-only visual audit → JSON + HTML dashboard.
- `scripts/report.ps1` — re-render an audit JSON as HTML.
- `scripts/scan.ps1` — quick read-only junction/known-folder audit.
- `scripts/make-plan.ps1` — create/approve a machine-readable move plan.
- `scripts/move-and-link.ps1` — guarded copy → verify → stage → junction; dry-run by default; `-Recover`.
- `scripts/verify.ps1` — read-only post-operation verification.
- `scripts/restore-staged.ps1` — restore a staged/quarantined folder with conflict policies.
- `scripts/purge-staged.ps1` — permanently delete staged data after confirmation.
- `scripts/lib/*` — shared helpers (paths, risk, inventory, locks, known folders, report).
- `tests/run-tests.ps1` — transaction test suite (run only in a disposable VM/sandbox).
