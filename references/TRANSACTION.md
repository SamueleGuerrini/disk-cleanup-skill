# Transactions, crash recovery, restore and purge

A move is not a single command. It is a transaction with named states. If the
process dies at any point, the manifest says exactly what happened and
`-Recover` can finish or roll back without guessing.

---

## 1. States

| # | Event | Meaning | Safe next step |
|---|---|---|---|
| 1 | `prepared` | Plan validated; operation id issued | Copy |
| 2 | `copy_started` | robocopy/copy running | Resume or discard partial target |
| 3 | `copy_verified` | Source and destination match | Stage the original |
| 4 | `original_staged` | Source renamed or moved to quarantine | Create the junction |
| 5 | `link_created` | Junction exists at the original path | Final verification |
| 6 | `verified` | Link + data + spot reads pass | Commit |
| 7 | `committed` | Transaction complete | Purge when comfortable |

Terminal/other events:

- `failed` — an error occurred. Includes `stage` and `message`; may include
  `rolled_back: true` and `partial_target_discarded: true`.
- `restore` — a staged item was restored. Carries `restored_from`, the operation
  id, the policy, and the file count.
- `purge` — staged data was permanently deleted. Carries `purged_op`.

The manifest is **append-only JSONL** (one JSON object per line). Every line also
gets `time`, `tool`, `host`, and `user`.

```jsonl
{"op":"20261113-120000-abc123","event":"prepared","source":"C:\\Work\\App","destination":"D:\\Work\\App","stage_mode":"Rename","expected_files":4321,"expected_bytes":12345678901,"verification":"Standard","risk":"Medium","rollback":"L1","time":"2026-11-13T12:00:00+01:00","tool":"disk-cleanup/2.0","host":"MACHINE","user":"Me"}
{"op":"20261113-120000-abc123","event":"copy_verified","files":4321,"bytes":12345678901,...}
{"op":"20261113-120000-abc123","event":"original_staged","stage_mode":"Rename","staged":"C:\\Work\\App.__prelink_20261113-120000",...}
{"op":"20261113-120000-abc123","event":"link_created","link_type":"Junction","target":"D:\\Work\\App",...}
{"op":"20261113-120000-abc123","event":"verified","verification":"Standard","files":4321,"bytes":12345678901,"spot_reads":5,...}
{"op":"20261113-120000-abc123","event":"committed","action":"move+junction",...}
```

### How state is derived

`Get-OperationStates` folds events per `op`:

- `LastState` = highest-ranked event seen
- `Open` = rank between `prepared` and `verified`, and not `failed`
- `Failed`, `Restored`, `Purged`, `Committed` = booleans

`verify.ps1` uses this to flag unfinished transactions and broken links. An
operation that never reached `committed` is never reported as successful.

---

## 2. Crash recovery

```powershell
# Diagnose first (read-only)
.\scripts\move-and-link.ps1 -Recover -OperationId 20261113-120000-abc123

# Apply the safe action
.\scripts\move-and-link.ps1 -Recover -OperationId 20261113-120000-abc123 -Execute
```

Recovery decisions, by last state:

| Situation | Action |
|---|---|
| Already `committed` | Nothing to do |
| `verified` but no link | Recreate the junction from the verified destination |
| Link exists, target missing | Remove the link (link only), restore the staged original |
| Interrupted before `link_created` | Move the staged original back to the source path |
| Partial destination, source intact | Offer `-DiscardPartialTarget` to delete the partial copy |
| Anything ambiguous | Refuse (exit 6): inspect, do not delete |

`-Recover` never deletes a source that could still be the only copy. When it
cannot prove which copy is authoritative, it stops.

---

## 3. Restore

```powershell
.\scripts\restore-staged.ps1 -ManifestPath 'D:\_AI_Rollback\manifest.jsonl' `
    -Id 20261113-120000-abc123 -Execute
```

Restore removes the junction (link only), then moves the staged folder back to the
original path.

### Conflict policies

| Policy | Behaviour | Use when |
|---|---|---|
| `Abort` (default) | Refuse if the original path or staged target conflicts | Safest; inspect first |
| `KeepTarget` | Keep the current target data, restore nothing over it, retain the staged copy | The junction target has newer work |
| `Merge` | Merge staged files into the destination without overwriting | You understand both sides |
| `OverwriteTarget` | Replace the destination with the staged copy | The staged copy is authoritative |

`KeepTarget` deliberately leaves the staged rollback copy on disk. Purge it only
after verification.

A restore is recorded as a `restore` event, not by editing old lines. History is
never rewritten.

---

## 4. Purge

Purging is irreversible. It requires **both** `-Execute` and an exact
`-ConfirmPurge` value:

```powershell
# One operation
.\scripts\purge-staged.ps1 -ManifestPath 'D:\_AI_Rollback\manifest.jsonl' `
    -Id 20261113-120000-abc123 -ConfirmPurge 20261113-120000-abc123 -Execute

# Everything (still requires the literal ALL)
.\scripts\purge-staged.ps1 -ManifestPath 'D:\_AI_Rollback\manifest.jsonl' `
    -All -ConfirmPurge ALL -Execute
```

Safety rules enforced by the script:

- Refuse if the **live target is missing** — that would destroy the last copy.
- Refuse if the original path is not the expected junction.
- Refuse if the junction points somewhere other than the recorded target.
- `-AllowMissingLink` overrides the link check **only** after you have confirmed
  the data exists elsewhere.

Purge deletes staged data with a reparse-safe delete: a junction is removed as a
link, never recursively followed.

---

## 5. Reparse-safe deletion

`Remove-TreeNoFollow` in `scripts/lib/common.ps1` is the only recursive delete used
by these scripts:

- It enumerates children and checks the reparse-point attribute **before**
  descending.
- A child that is a link is removed with
  `[System.IO.Directory]::Delete($path, $false)` — link only, target untouched.
- It never calls `Remove-Item -Recurse` on a path that could be a link.
- It is used by purge, recovery, and test cleanup.

This is the fix for the classic incident: a recursive delete that followed a
junction into the user profile. See `references/SAFETY.md`.

---

## 6. ACLs, ADS, hardlinks, sparse files, cloud placeholders

These are why "same size" is not "same data".

| Feature | Effect on a move | Handling |
|---|---|---|
| **ACLs** | `robocopy /COPY:DAT` copies data, attributes, timestamps but **not** security by default | `move-and-link.ps1` copies ACLs unless `-NoAcl`; verify inherited permissions on the target |
| **Alternate data streams (ADS)** | Zone.Identifier, mark-of-the-web, app metadata | robocopy `/COPY:DAT` does not copy ADS; use `/COPYALL` only if you understand the implications |
| **Hardlinks** | Two paths, one allocation unit | A copy duplicates the data (uses more space); a move within a volume preserves it |
| **Sparse files** | Logical size ≫ allocated size | Copying can materialize holes and consume much more space; the plan warns with `sparse_files` |
| **Compression/EFS** | Per-file compression or encryption | Copy may decompress/decrypt; check the destination policy |
| **Cloud placeholders** | File content lives remotely | Copying hydrates it (bandwidth + space); the plan warns with `offline_files` |
| **Reparse points inside the tree** | Copy tools may follow or skip them | Planning refuses a tree with reparse points; move/materialize them separately |

Verification levels reflect this:

- **Basic** — paths exist, file/byte counts match.
- **Standard** (default) — Basic + timestamps and a spot read.
- **Strict** — Standard + SHA-256 on a sample (or all files with `-Strict`).

No verification level proves application correctness. Always run a functional
smoke test afterwards (`references/POST-OPERATION.md`).
