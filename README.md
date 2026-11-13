# disk-cleanup

A read-only-first Windows disk audit, and a plan-bound, crash-safe way to reclaim
space by deleting junk or moving folders to another drive and replacing them with
directory junctions.

It is not a "clean everything" button. It measures, explains, labels risk, and acts
only on what you explicitly approve — one item at a time.

```
audit (read-only) → report (HTML) → plan (approval hash) → execute (transaction)
      → verify (PASS/FAIL) → document (append-only manifest) → purge (when proven)
```

## Why this exists

File cleanup is one of the easiest ways to lose data. The dangerous parts are rarely
obvious:

- a junction silently redirects a recursive delete into your user profile
- a path gets mangled across shells and a wildcard expands to something huge
- a copy "succeeds" but skipped reparse points or online-only cloud files
- a move is half-finished and nothing records where it stopped
- a restore overwrites newer work because nobody defined a conflict policy

This repository is built around those failure modes: reparse-aware scanning and
deletion, approval bound to a SHA-256 of the plan item, an append-only event log
with explicit transaction states, conflict-aware restore, and a purge that refuses
to destroy the last copy.

## Features

### Reporting layer (read-only)

`scripts/audit.ps1` scans a drive or folder and writes a self-contained HTML
dashboard plus JSON:

- directory **treemap** with click-to-drill-down and breadcrumbs
- **risk donut**: green / yellow / orange / red / unrated bytes
- **file-type** and **modification-year** charts
- **large-file table**, sortable and filterable, each file tagged with a risk level,
  with copy-paths and CSV export
- **duplicate candidates** grouped by exact size (labelled candidates — hash before
  deleting)
- **known junk/cache/hotspot** folders, measured not cleaned
- optional **lock awareness** via the Windows Restart Manager (never terminates
  anything)

Scanning is bounded-memory, reparse-safe, and cache-aware. It supports:

- 1-second **sample mode** to estimate a full scan
- 30-second **progressive** partial results
- hard **time / file / memory limits**
- progress every 2 seconds; Ctrl+C leaves a renderable checkpoint
- **concurrent workers** on SSD, single worker on HDD/removable/network
- incremental per-directory **cache**

No CDN, fonts, or analytics. The report works offline from `file://`.

### Transaction layer

- `make-plan.ps1` records canonical paths, volume serials, sizes, exclusions, and
  verification level; approval stores a SHA-256 of the item.
- `move-and-link.ps1` refuses an item that changed after approval or drifted more
  than 2%, copies reparse-safely, verifies, stages the original, creates the
  junction, verifies again, and appends events.
- `-Recover` finishes or rolls back an interrupted operation from the manifest.
- `restore-staged.ps1` restores with `Abort` / `KeepTarget` / `Merge` /
  `OverwriteTarget`.
- `purge-staged.ps1` requires `-Execute` and an exact `-ConfirmPurge` value, and
  refuses if the live target is missing or the link is wrong.

Dry run is the default everywhere. `-Execute` is required for any change.

## Requirements

- Windows 10/11 (NTFS; ReFS has limited junction support)
- PowerShell 7+ (`pwsh`) recommended; Windows PowerShell 5.1 works for most scripts
- No admin for auditing or per-user moves; admin for restore points, VSS, and some
  system cleanup

## Quick start

```powershell
git clone <this-repo> disk-cleanup
cd disk-cleanup

# 1. Audit (read-only). Writes JSON + HTML under %LOCALAPPDATA%\disk-cleanup\reports
.\scripts\audit.ps1 -Drive C:

# 2. Inspect the report, choose an item, then record and approve a move
.\scripts\make-plan.ps1 -Source 'C:\Work\App' -Destination 'D:\Work\App'
.\scripts\make-plan.ps1 -Source 'C:\Work\App' -Destination 'D:\Work\App' `
    -Approve -ApprovedBy 'Your Name'

# 3. Dry run, then execute
.\scripts\move-and-link.ps1 -PlanPath "$env:USERPROFILE\_AI_Rollback\plan.json" `
    -PlanItemId '<id>'
.\scripts\move-and-link.ps1 -PlanPath "$env:USERPROFILE\_AI_Rollback\plan.json" `
    -PlanItemId '<id>' -Execute

# 4. Verify
.\scripts\verify.ps1 -Drive C: -ManifestPath "$env:USERPROFILE\_AI_Rollback\manifest.jsonl"
```

If you only want a quick junction/known-folder audit without the dashboard:

```powershell
.\scripts\scan.ps1 -Drive C:
```

## Risk levels

| Level | Meaning | Default action |
|---|---|---|
| 🟢 green | Temporary or regenerable | Safe to delete |
| 🟡 yellow | Archive material (media, ISOs, archives) | Archive or move; verify first |
| 🟠 orange | User content or binaries | Explicit confirmation required |
| 🔴 red | Protected system paths and files | **Never move or delete** |
| ⚪ unrated | No rule matched | Inspect; no automatic suggestion |

`unrated` is deliberately not green. An unrecognised folder is user-led.

## Documentation

| File | Contents |
|---|---|
| `SKILL.md` | The full workflow (also usable as an OpenCode/agent skill) |
| `references/SAFETY.md` | Path, junction, shell, cloud, ACL/ADS, and incident lessons |
| `references/CLASSIFICATION.md` | Risk mapping, tiers, proposal format |
| `references/KNOWN-FOLDERS.md` | Junk/cache map, hotspots, leave-alone list |
| `references/ROLLBACK.md` | Safety layers L1–L4, recovery, remediation |
| `references/POST-OPERATION.md` | Verification checklist and remediation playbook |
| `references/MANIFEST-TEMPLATE.md` | Markdown record + JSONL event schema |
| `references/PLAN.md` | Plan schema, approval hash, drift checks |
| `references/TRANSACTION.md` | States, crash recovery, restore, purge, ACL/ADS caveats |
| `references/REPORTING.md` | Dashboard, JSON schema, cache, workers, limits, locks |
| `references/TARGET-DRIVES.md` | SSD/HDD choice, HDD reliability, SMART, 3-2-1, CMR/SMR |
| `references/DOCKER.md` | Docker Desktop VHDX relocation and warnings |
| `references/TESTING.md` | Test suite and sandbox/VM options |
| `examples/JUNCTION-RECORD.md` | A real-world migration record |
| `examples/plan.example.json` | A complete approved plan item |

## Testing

The suite creates real junctions and deletes real trees. Run it only in a disposable
Windows VM, Windows Sandbox, or Windows container:

```powershell
cd tests
pwsh -NoProfile -File .\run-tests.ps1
```

See `references/TESTING.md` and `tests/VM-TESTING.md`.

## Safety notes

- A junction is **not** a backup. If the target drive dies, the original path is a
  dead link.
- A Windows restore point does **not** back up personal files.
- A `Rename`-staged move frees **no** space until purge.
- Prefer a fixed internal NTFS target. A junction into a removable or network drive
  breaks when the drive is absent or re-lettered.
- Do not move data while the owning app, WSL, or Docker is running.
- Never remove a junction with `Remove-Item -Recurse` or `rmdir /s`; delete the link
  only.

## License

MIT — see `LICENSE`.

## Disclaimer

This software can move and delete files. You are responsible for reviewing every
proposal and for keeping a verified backup of anything you cannot afford to lose.
The authors are not liable for data loss or damage arising from its use.
