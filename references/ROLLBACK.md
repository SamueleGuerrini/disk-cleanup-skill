# Rollback and safety layers

Choose layers **before** executing. Default = **L1 quarantine**. State clearly what
each layer protects and what it does not. No single layer is a full backup, and the
layers are **composable** — use as many as the operation warrants.

| Layer | Protects | Does NOT protect | Prereqs / limits |
|---|---|---|---|
| L1 — Soft delete / quarantine | User & project files targeted for deletion/removal, for a retention window | OS/registry state; moves done outside the agent; items too large for the Recycle Bin | Writable staging path with space; retention + purge decision |
| L2 — Windows restore point | System files, registry, installed programs/drivers | **Personal files** in `C:\Users\<User>`, caches/temp, other drives | **Admin**; 24h cooldown; must verify creation |
| L3 — Git snapshot | Working tree of the affected repo (tracked + untracked with `-u`) | Anything outside that repo; non-git folders | Git repo; user accepts stash/branch artifacts |
| L4 — Volume Shadow Copy | Block-level point-in-time view of a volume (can include user files) | Simple selective restore; long-term backup guarantees | **Admin**; space/retention managed by Windows; restore is non-trivial |

> A restore point is **not** a backup of your documents/projects. For irreplaceable
> data, use an independent, verified backup (external/cloud/image) first.

## L1 — Quarantine / soft delete (recommended default)

Never permanently delete on the first pass.

**Staging layout:**

```text
<staging root>\_AI_Rollback\<YYYY-MM-DD_HHmm>\
    manifest.jsonl
    <relative paths of staged items>
```

**Manifest entry (one JSON object per line):**

```json
{"op":"20261113-013000-abc123","event":"original_staged","stage_mode":"Quarantine","source":"C:\\Data\\Projects","destination":"D:\\Migrated\\Projects","staged":"D:\\_AI_Rollback\\2026-11-13_0130\\C\\Data\\Projects","time":"2026-11-13T01:30:00+01:00","tool":"disk-cleanup/2.0","host":"MACHINE","user":"Me"}
```

**Stage modes for moves:** after the verified copy + junction:

- `Rename` (default, instant, same volume): rename to `Name.__prelink_<ts>`.
  Reversible immediately; **space is not freed until purge**.
- `Quarantine`: move the original into the staging root (copy+delete if
  cross-volume). Frees the source volume while retaining the data. Slower and needs
  staging space.
- `Delete`: permanent after verification; requires `-ConfirmDelete '<exact source
  path>'` at execution time.

**For deletes:** move items to quarantine or send to Recycle Bin instead of
`Remove-Item`/`del`. The Recycle Bin has size/drive limits; if the item exceeds
them, the delete falls through to permanent. Check before relying on it.

**Restore:** remove the junction (link only), then move the staged folder back to
its original path. `scripts/restore-staged.ps1` does this from the manifest with an
explicit conflict policy:

| Policy | Behaviour | Use when |
|---|---|---|
| `Abort` (default) | Refuse if the original path or staged target conflicts | Safest; inspect first |
| `KeepTarget` | Keep current target data, restore nothing over it, retain the staged copy | The target has newer work |
| `Merge` | Merge staged files into the destination without overwriting | You understand both sides |
| `OverwriteTarget` | Replace the destination with the staged copy | The staged copy is authoritative |

**Purge:** after the user confirms apps/data are fine, delete the staging folder (or
let a scheduled task purge entries older than N days). Record the purge. Purge
requires `-Execute` **and** `-ConfirmPurge <op-id>` (or `ALL`), and refuses if:

- the live target is missing (that would destroy the last copy)
- the original path is not the expected junction
- the junction points somewhere other than the recorded target

`-AllowMissingLink` overrides the link check only after you have confirmed the data
exists elsewhere.

**Recycle Bin (PowerShell):**

```powershell
Add-Type -AssemblyName Microsoft.VisualBasic
[Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory(
  'C:\Path\To\Target','OnlyErrorDialogs','SendToRecycleBin')
[Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(
  'C:\Path\To\File','OnlyErrorDialogs','SendToRecycleBin')
```

## L2 — Windows restore point (admin)

Create before admin/system-level phases:

```powershell
Checkpoint-Computer -Description 'AI_Agent_PreCleanup_2026-11-13' -RestorePointType 'MODIFY_SETTINGS'
```

Verify it was actually created (the 24h frequency limit can silently skip it):

```powershell
Get-ComputerRestorePoint | Sort-Object CreationTime -Descending |
  Select-Object -First 5 CreationTime, Description, SequenceNumber
```

If it cannot be created or verified: **report and ask** before continuing. Do not
silently bypass the frequency policy.

Limits: system restore is usually disabled on non-system volumes, does not include
user documents, and is not a substitute for a backup.

## L3 — Git snapshot (repos)

Before modifying/moving/cleaning inside a repo:

```powershell
git status --short
git stash push -u -m "pre-agent-backup 2026-11-13"
# or: git branch agent-backup-2026-11-13 && git add -A && git commit -m "pre-agent-backup"
```

Record which stash/branch was created. Restore with `git stash list` →
`git stash apply <ref>` (or check out the backup branch) and re-verify.

Limits: one repository at a time; large untracked folders (models, build output) may
make the snapshot huge or slow. Do not create a branch inside a repo you do not own.

## L4 — Volume Shadow Copy (advanced, admin)

Block-level snapshot of a volume; can include user files. It is **not** a one-click
undo: restoring individual files requires mounting/exposing the shadow copy.

```powershell
# example concept only — verify on your Windows edition
vssadmin create shadow /for=C:
vssadmin list shadows
```

Limits: shadow storage is finite and self-managing; old snapshots can be deleted by
Windows; restoring is not a simple copy. Prefer a real backup/image for critical
data. Use L4 only when the user explicitly asks and understands the restore
workflow.

## Transaction recovery (v2)

A move is a state machine, not a single command. If a run dies, the JSONL manifest
records the last completed state, and `move-and-link.ps1 -Recover -OperationId <id>`
finishes or rolls back:

| Last state | Recovery |
|---|---|
| `committed` | Nothing to do |
| `verified`, no link | Recreate the junction from the verified destination |
| link exists, target missing | Remove the link, restore the staged original |
| interrupted before `link_created` | Move the staged original back |
| partial destination, source intact | Offer `-DiscardPartialTarget` |
| ambiguous | Refuse; inspect manually |

See `references/TRANSACTION.md` for the full event schema.

## Remediation mapping

| Symptom | First safe response | Layer |
|---|---|---|
| Junction missing/wrong target | inspect and recreate link to the verified target | L1 manifest |
| Mass deletions in git status | re-copy missing files / reinstall deps, then re-check | L1 staged source |
| Broken internal links | recreate links (may need admin) or materialize | pre-op manifest |
| Unexpected data loss | **stop**, restore from quarantine/Recycle Bin/VSS; escalate to backups | L1 → L4 |
| System misbehaves after cleanup | restore point rollback, re-enable services, DISM checks | L2 |
| Repo altered/lost | restore stash/branch | L3 |
| Unfinished transaction | `-Recover -OperationId <id>` (diagnose, then `-Execute`) | manifest |
| Space not reclaimed | already redirected, hardlinks, sparse, locks, cloud placeholders | — |

Always diagnose read-only first, propose the least destructive fix, get approval,
then re-verify.
