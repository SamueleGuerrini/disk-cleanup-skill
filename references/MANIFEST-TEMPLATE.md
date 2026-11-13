# Manifest template

Keep one manifest per machine/run. There are two views of the same record:

- **Markdown** — human-readable summary, for the user and for future readers.
- **`manifest.jsonl`** — append-only, machine-restorable, written by the scripts.

Suggested location: the target drive, e.g. `D:\_AI_Rollback\JUNCTIONS.md`, with
`manifest.jsonl` next to the staged data.

Never rewrite or "clean up" JSONL history. Append a new event instead (including
`restore` and `purge`). That is what makes crash recovery and audits possible.

---

## 1. JSONL event schema

One JSON object per line. Common fields added automatically:

| Field | Meaning |
|---|---|
| `time` | ISO-8601 timestamp |
| `tool` | `disk-cleanup/2.0` |
| `host` | Computer name |
| `user` | User name |
| `op` | Operation id (stable for the whole transaction) |
| `event` | State name (see below) |

### Events

| `event` | Extra fields |
|---|---|
| `prepared` | `source`, `destination`, `stage_mode`, `expected_files`, `expected_bytes`, `verification`, `risk`, `rollback` |
| `copy_started` | `source`, `destination` |
| `copy_verified` | `files`, `bytes`, `verification` |
| `original_staged` | `stage_mode`, `staged` |
| `link_created` | `link_type`, `target` |
| `verified` | `verification`, `files`, `bytes`, `spot_reads` |
| `committed` | `action` |
| `failed` | `stage`, `message`, optional `rolled_back`, `partial_target_discarded` |
| `restore` | `restored_from`, `policy`, `files`, `bytes` |
| `purge` | `purged_op`, `staged`, `bytes` |

### Example transaction

```jsonl
{"op":"20261113-120000-abc123","event":"prepared","source":"C:\\Work\\App","destination":"D:\\Work\\App","stage_mode":"Rename","expected_files":4321,"expected_bytes":12345678901,"verification":"Standard","risk":"Medium","rollback":"L1","time":"2026-11-13T12:00:00+01:00","tool":"disk-cleanup/2.0","host":"MACHINE","user":"Me"}
{"op":"20261113-120000-abc123","event":"copy_started","source":"C:\\Work\\App","destination":"D:\\Work\\App","time":"2026-11-13T12:00:01+01:00"}
{"op":"20261113-120000-abc123","event":"copy_verified","files":4321,"bytes":12345678901,"verification":"Standard","time":"2026-11-13T12:08:00+01:00"}
{"op":"20261113-120000-abc123","event":"original_staged","stage_mode":"Rename","staged":"C:\\Work\\App.__prelink_20261113-120000","time":"2026-11-13T12:08:01+01:00"}
{"op":"20261113-120000-abc123","event":"link_created","link_type":"Junction","target":"D:\\Work\\App","time":"2026-11-13T12:08:02+01:00"}
{"op":"20261113-120000-abc123","event":"verified","verification":"Standard","files":4321,"bytes":12345678901,"spot_reads":5,"time":"2026-11-13T12:08:10+01:00"}
{"op":"20261113-120000-abc123","event":"committed","action":"move+junction","time":"2026-11-13T12:08:10+01:00"}
{"op":"20261113-120000-abc123","event":"purge","purged_op":"20261113-120000-abc123","staged":"C:\\Work\\App.__prelink_20261113-120000","bytes":12345678901,"time":"2026-11-20T09:00:00+01:00"}
```

### Reading state

Group by `op`; the highest-ranked event is the current state
(`prepared` < `copy_started` < `copy_verified` < `original_staged` <
`link_created` < `verified` < `committed`). An operation without `committed` is
unfinished. `restore`/`purge` are terminal side-events keyed by `restored_from` /
`purged_op`.

---

## 2. Markdown record

---

# Junction / Migration Record — <machine or user> — <date>

**Last updated:** YYYY-MM-DD
**Status:** <drive> went from <X> GB free to <Y> GB free.
**Safety layers used:** L1 / L2 / L3 / L4

## Why

<One paragraph: source drive, target drive, SSD/HDD, what kind of data is moved and
why. Note that original paths keep working via junctions.>

## Golden rules

- Remove a junction with `[System.IO.Directory]::Delete($path, $false)` or
  `cmd /c rmdir "<path>"` — never `rmdir /s`, never `Remove-Item -Recurse`.
- Never store a junction inside a folder that will be deleted recursively.
- Copy → verify → stage → link → verify. Abort on mismatch.

## Junctions (pre-existing)

| # | Junction path | Target | Size | Notes |
|---|---|---|---|---|

## Junctions (added this run)

| # | Junction path | Target | Size | Risk | Rollback |
|---|---|---|---|---|---|

## Moved items

| Source | Target | Size | Files | Method | Exclusions | Verified |
|---|---|---|---|---|---|---|

## Cleaned (contents only)

| Path | What was removed | Freed | Tool/command | In-use skipped |
|---|---|---|---|---|

## Deleted / purged (irreversible)

| Path | Freed | Approval | Backup/rollback available? |
|---|---|---|---|

## Not moved (deliberately)

| Item | Size | Reason | Next step |
|---|---|---|---|

## Verification

| Check | Result | Evidence |
|---|---|---|
| Free space | PASS/FAIL | before → after |
| Junctions | PASS/FAIL | LinkType/Target spot checks |
| Data counts | PASS/FAIL | source vs target files/bytes |
| Transactions | PASS/FAIL | committed / unfinished op ids |
| Git status | PASS/FAIL | summary |
| Apps/tools | PASS/FAIL | what was launched |
| Scope | PASS/FAIL | diff vs approved plan |

## Remediation log

| Time | Issue | Fix | Layer | Result |
|---|---|---|---|---|

## Config changes (no junctions)

| Tool | Setting | New location |
|---|---|---|

## How to verify

```powershell
(Get-Item "C:\path\to\junction").Target
Get-PSDrive C | Select-Object Free
Get-ChildItem C:\Users -Recurse -Force -Directory -Depth 4 |
  Where-Object { $_.LinkType } | Select-Object FullName, LinkType, Target
```

## How to undo

1. Close apps using the folder.
2. Remove the link only:
   `[System.IO.Directory]::Delete('C:\path\to\junction', $false)`
3. Move data back:
   `robocopy "D:\real\location" "C:\original\path" /E /COPY:DAT /DCOPY:T /MOVE`
4. Recreate if needed:
   `New-Item -ItemType Junction -Path "C:\path" -Target "D:\real\location"`

Or use the scripts: `restore-staged.ps1` (with a conflict policy), then
`purge-staged.ps1` only after verification.

## How to move a junction to another drive

```powershell
[System.IO.Directory]::Delete('C:\Users\Me\Videos', $false)
robocopy 'D:\Videos' 'E:\Videos' /E /COPY:DAT /DCOPY:T /MOVE
New-Item -ItemType Junction -Path 'C:\Users\Me\Videos' -Target 'E:\Videos'
```
