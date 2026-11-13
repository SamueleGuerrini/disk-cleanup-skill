# Plans and approval binding

A plan is a JSON file that records **what** will be moved, **where**, **how** it will
be verified, and **who approved it**. The executor refuses to act on anything that
does not match the approved plan.

```text
make-plan.ps1  →  plan.json  →  (human review)  →  move-and-link.ps1 -Execute
```

`make-plan.ps1` is read-only with respect to the filesystem being cleaned. It only
writes the plan JSON.

---

## 1. Create an item

```powershell
.\scripts\make-plan.ps1 -Source 'C:\Work\App' -Destination 'D:\Work\App'
```

The script refuses to plan when:

- the source does not exist, is not a directory, or is a reparse point
- the source is a cloud placeholder (hydrate or exclude it first)
- the source (or its resolved real path) is a protected path
- the destination is a drive root, already exists, or is inside the source
  (or vice versa, including via resolved real paths)
- the tree contains a reparse point outside the excluded directories
- the destination drive is ineligible (see `references/TARGET-DRIVES.md`)

It records:

| Field | Why it matters |
|---|---|
| `id` | Stable handle used by execute/restore/purge |
| `source`, `source_real` | The path and its fully resolved path |
| `destination`, `destination_real` | Same for the target |
| `stage_mode` | `Rename` (default), `Quarantine`, or `Delete` |
| `exclude` | Directory names not copied (`node_modules` by default) |
| `verification` | `Basic`, `Standard`, `Strict` |
| `risk`, `rollback` | Labels carried into the manifest |
| `expected_files`, `expected_dirs`, `expected_bytes`, `expected_physical_bytes` | Drift baseline |
| `sparse_files`, `offline_files` | Space/accounting warnings |
| `source_volume`, `source_volume_serial` | Detect a re-mounted or different source volume |
| `target_volume`, `target_volume_serial`, `target_drive_type`, `target_filesystem` | Detect a different destination |
| `source_creation_utc` | Extra identity check |

Default plan path: `%USERPROFILE%\_AI_Rollback\plan.json`. Several items can live in
one plan; each has its own `id`.

---

## 2. Approve an item

An item is **not approved** until it is written with `-Approve -ApprovedBy`:

```powershell
.\scripts\make-plan.ps1 -Source 'C:\Work\App' -Destination 'D:\Work\App' `
    -Approve -ApprovedBy 'Your Name'
```

Approval adds:

```json
"approval": {
  "approved_by": "Your Name",
  "approved_at": "2026-11-13T02:10:00+01:00",
  "item_sha256": "…"
}
```

`item_sha256` is the SHA-256 of the item's **canonical JSON** (sorted keys, stable
formatting). The executor recomputes it and compares.

> Approval is per item and per exact field set. Changing the destination, the
> exclusions, the stage mode, or anything else invalidates the hash. Re-approve
> after any change.

---

## 3. Execute

```powershell
.\scripts\move-and-link.ps1 -PlanPath 'C:\Users\Me\_AI_Rollback\plan.json' `
    -PlanItemId 'App-20261113-021000' -Execute
```

Dry run is the default. Without `-Execute` the executor prints the plan and the
checks it would run, and changes nothing.

Before touching the disk, the executor verifies:

| Check | On failure |
|---|---|
| Approval block present | Refuse: "not approved" |
| Canonical hash matches | Refuse: "changed after approval; re-approve" |
| Source volume serial matches the plan | Refuse: "source volume changed; re-plan" |
| Source still exists and is not a link | Refuse |
| Size drift ≤ `-MaxDriftPercent` (default 2%) | Refuse: re-run `make-plan.ps1` |
| File-count drift ≤ limit | Refuse: re-plan |
| Destination still absent | Refuse |
| Destination drive eligible and has space | Refuse (or require `-AcceptWarnings`) |
| No unfinished operation for this source | Refuse: recover or finish it first |
| `Delete` mode has `-ConfirmDelete '<exact source path>'` | Refuse |

Then it copies, verifies, stages the original, creates the junction, and verifies
again. See `references/TRANSACTION.md`.

---

## 4. Example plan

`examples/plan.example.json` is a complete, approved item you can read alongside
this document. The shape is:

```jsonc
{
  "version": 1,
  "created_at": "2026-11-13T02:00:00+01:00",
  "items": [
    {
      "id": "App-20261113-021000",
      "source": "C:\\Work\\App",
      "source_real": "C:\\Work\\App",
      "destination": "D:\\Work\\App",
      "destination_real": "D:\\Work\\App",
      "stage_mode": "Rename",
      "exclude": ["node_modules"],
      "verification": "Standard",
      "risk": "Medium",
      "rollback": "L1",
      "expected_files": 4321,
      "expected_dirs": 512,
      "expected_bytes": 12345678901,
      "expected_physical_bytes": 12345678901,
      "sparse_files": 0,
      "offline_files": 0,
      "source_volume": "C:",
      "source_volume_serial": "BA313953",
      "source_creation_utc": "2024-05-01T10:00:00.0000000Z",
      "target_volume": "D:",
      "target_volume_serial": "1A2B3C4D",
      "target_drive_type": "Fixed",
      "target_filesystem": "NTFS",
      "created_at": "2026-11-13T02:00:00+01:00",
      "created_by": "Me@MACHINE",
      "approval": {
        "approved_by": "Your Name",
        "approved_at": "2026-11-13T02:10:00+01:00",
        "item_sha256": "0000000000000000000000000000000000000000000000000000000000000000"
      }
    }
  ]
}
```

The example hash is a placeholder. A real plan is only produced by
`make-plan.ps1`; do not hand-write an approval hash, because the executor will
reject it (correctly).

---

## 5. Why bind approval to a hash

Approval drift is a real failure mode:

1. The user approves moving 40 GB of a project.
2. A build runs and adds 20 GB of output.
3. The executor copies 60 GB to a target sized for 40 GB, or silently changes what
   the user approved.

The hash and the drift checks make that a refusal, not a surprise. If the plan is
stale, the fix is always to re-audit and re-approve — never to bypass the check.
