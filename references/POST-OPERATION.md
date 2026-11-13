# Post-operation verification and remediation

Verification is **mandatory** after every run and is never skipped. Report
`check | expected | observed | PASS/FAIL/WARN | evidence | suggested fix`.

Run the read-only verifier first:

```powershell
.\scripts\verify.ps1 -Drive C: -ManifestPath 'D:\_AI_Rollback\manifest.jsonl'
```

`verify.ps1` checks drive space, junctions/reparse points, the manifest's
transaction states, broken links, and optional git repositories. It never changes
anything.

## 1. Space and outcome

- Drive free/used before vs after (per affected drive).
- Total reclaimed; reconcile against estimates; explain discrepancies
  (already-redirected paths, hardlinks, sparse files, compression, locked items,
  cloud placeholders).
- Confirm target paths exist with expected size/file counts; original paths resolve.

A move staged with `Rename` frees **no** space until purge. Do not report the staged
size as reclaimed.

## 2. Link integrity

For every created link:

```powershell
$i = Get-Item 'C:\original\path' -Force
$i.LinkType   # must be Junction
$i.Target     # must be the intended target
```

- Path is reachable; a sample file opens/reads.
- No broken links (target missing), no self-referential links, no unexpected
  reparse points introduced in moved trees.
- Windows ships **legacy compatibility junctions** (`Application Data`,
  `Dati applicazioni`, and other localized equivalents) that point at their own
  parent on purpose. `verify.ps1` reports these as expected, not as failures.
  Do not delete them to "fix" a loop.
- Spot-check that nothing was deleted *through* a link.
- A junction into a removable drive is only valid while that drive is mounted with
  the expected letter.

## 3. Data integrity

- Moves: file/byte counts match the verified copy; spot-read representative files.
- Strict verification: SHA-256 sample (or all files) matches.
- Repos: `git status` shows no mass deletions; expected tracked files present.
- Deletions/quarantine: staged items exist and manifest paths are valid/restorable.
- Exclusions handled as planned (`node_modules` reinstalled, links materialized, etc.).
- ACLs: check that the moved tree still grants the expected users access (a copy
  without security descriptors can change effective permissions).
- ADS/sparse/cloud: confirm whether streams were preserved, holes materialized, or
  placeholders hydrated.

## 4. Transaction completeness

`verify.ps1` groups the JSONL manifest by `op` and flags:

- operations that stopped between `prepared` and `verified` (unfinished)
- operations marked `failed`
- `link_created` without a matching `verified`/`committed`
- junctions whose target is missing

An unfinished operation is **never** reported as success. Diagnose it with
`move-and-link.ps1 -Recover -OperationId <id>` (read-only), then apply the safe
recovery action.

## 5. Functional smoke tests (appropriate to what changed)

- Editors/IDEs, Unity Hub/editor (sees moved editors), package managers
  (`npm/pnpm/pip/uv` config/store), browsers, WSL (`wsl -l -v`), Docker.
- Dev servers/builds: `pnpm install`, a build/lint/test subset for touched repos.
- Open a moved folder via its original C: path; verify shell folders resolve.
- System cleanup: update service healthy, no pending servicing issues, `WinSxS` and
  `Installer` untouched, hibernation/pagefile state as intended.
- Confirm skipped/in-use items remain intact.

## 6. Scope regression guard

- Compare against the approved plan/manifest: nothing outside scope changed.
- Plan item hash still matches what was approved.
- Unknown/user-led items were left alone.
- No drive was re-lettered, mounted, or repartitioned as part of the cleanup.

## 7. Report template

```text
Summary: <what was done> | <space freed> | safety layers <L1-L4>
Verification:
  [PASS] <check> — <evidence>
  [FAIL] <check> — <observed vs expected>
Transactions: <committed / unfinished / failed op ids>
Issues: <symptom, likely cause, blast radius>
Fixes proposed/applied: <least destructive fix + rollback layer>
Deferred/skipped: <item, reason, next step>
Prevention: <env/config relocations, prune routine>
```

If any check FAILs: **stop, do not declare success.** Diagnose read-only, explain,
propose a fix, get approval, apply, re-verify, update the manifest.

## 8. Remediation playbook

| Symptom | Likely cause | First safe response | Layer |
|---|---|---|---|
| App/tool can't find folder; original path empty | link missing/wrong target | inspect `LinkType/Target`; recreate link to verified target | L1 |
| Project missing files; `git status` mass deletions | copy skipped items/reparse points; partial copy | re-copy missing set; reinstall deps; re-check counts | L1 |
| Broken internal symlinks/junctions | links not recreated/materialized | recreate (may need admin) or materialize; verify each | manifest |
| Data deleted unexpectedly | wrong target/wildcard/link traversal | **stop**; restore quarantine/Recycle Bin/VSS; escalate to backups | L1 → L4 |
| System/app misbehaves after cleanup | over-aggressive temp/log/servicing change | restore point rollback; re-enable services; DISM checks | L2 |
| Repo working tree altered/lost | in-place edit/move | restore stash/branch; re-apply; verify | L3 |
| Unfinished transaction | crash/interrupt | `-Recover -OperationId <id>`, then `-Execute` | manifest |
| Purge refused | live target missing / wrong link | do **not** force; locate the data first | L1 |
| Space not reclaimed | staged with `Rename`, hardlinks, sparse, locks, cloud | purge only after verification; re-audit junction-aware | — |
| Junction broken after reboot | target on removable/network/locked volume | remount/unlock; consider a fixed internal target | — |

Rules: diagnose first; least destructive fix; explicit approval; re-verify; update
the manifest. Never broaden scope to "fix" something.
