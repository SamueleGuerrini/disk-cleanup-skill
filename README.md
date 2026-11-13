<div align="center">

# disk-cleanup

**Audit a Windows disk read-only. Reclaim space with approval-bound, crash-safe moves.**

[![MIT](https://img.shields.io/badge/license-MIT-3DA639?style=flat-square)](LICENSE)
[![PowerShell](https://img.shields.io/badge/powershell-5.1%20%7C%207%2B-5391FE?style=flat-square)](https://microsoft.com/powershell)
[![Windows](https://img.shields.io/badge/windows-10%20%7C%2011-0078D4?style=flat-square)](#requirements)

<sub>`audit` → `report` → `plan` → `execute` → `verify` → `record`</sub>

</div>

Not a "clean everything" button. It measures, explains, labels risk, and acts only
on what you explicitly approve — one item at a time. Dry run is the default;
`-Execute` is required for any change.

> **Built for OpenCode on Windows.** The skill and the `/clean-disk` command target
> OpenCode V2 on Windows 10/11. Other agents that read `SKILL.md` and run PowerShell
> may work, but they are untested and not supported.

## Why

Cleanup goes wrong in ways that are rarely obvious:

- a junction silently redirects a recursive delete into your profile
- a path gets mangled across shells and a wildcard expands to something huge
- a copy "succeeds" but skipped reparse points or online-only cloud files
- a move is half-finished and nothing records where it stopped

So: reparse-aware scanning and deletion, approval bound to a SHA-256 of the plan
item, an append-only event log with explicit transaction states, conflict-aware
restore, and a purge that refuses to destroy the last copy.

## What you get

**Look — read-only.** `scripts/audit.ps1` writes a self-contained HTML dashboard
plus JSON: a click-through directory **treemap**, a **risk donut** (green / yellow
/ orange / red / unrated), file-type and modification-year charts, a sortable
**large-file table** with per-file risk tags and CSV export, **duplicate
candidates** grouped by exact size, and known **junk/cache hotspots** — measured,
never cleaned. Optional lock awareness via the Windows Restart Manager; it never
terminates anything.

Bounded memory, reparse-safe, cache-aware. 1-second sample mode, 30-second
progressive results, hard time/file/memory limits, Ctrl+C checkpoints, SSD
workers, incremental cache. No CDN, fonts, or analytics — it renders offline from
`file://`.

**Act — plan-bound.** `make-plan.ps1` records canonical paths, volume serials,
sizes, exclusions and verification level; approval stores a SHA-256 of the item.
`move-and-link.ps1` refuses drift, copies reparse-safely, verifies, stages the
original, links, verifies again, and logs every event. `-Recover` finishes or
rolls back an interrupted run. `restore-staged.ps1` offers `Abort` /
`KeepTarget` / `Merge` / `OverwriteTarget`. `purge-staged.ps1` needs `-Execute`
and an exact `-ConfirmPurge`, and refuses if the live target is missing.

## Risk levels

| | Meaning | Default |
|---|---|---|
| 🟢 | Temporary or regenerable | Safe to delete |
| 🟡 | Archive material (media, ISOs, archives) | Archive or move; verify |
| 🟠 | User content or binaries | Explicit confirmation |
| 🔴 | Protected system paths | **Never move or delete** |
| ⚪ | No rule matched | Inspect; user-led |

`unrated` is deliberately not green. An unrecognised folder is never guessed at.

## Quick start

### 1. Install

```powershell
git clone https://github.com/SamueleGuerrini/disk-cleanup-skill.git disk-cleanup
cd disk-cleanup
.\install.ps1
```

No checkout? The same script downloads and installs itself:

```powershell
irm https://raw.githubusercontent.com/SamueleGuerrini/disk-cleanup-skill/main/install.ps1 | iex
```

It installs `skills\disk-cleanup\` and `commands\clean-disk.md` under
`%USERPROFILE%\.config\opencode`, then verifies both. No admin needed. From a
checkout it links the checkout, so updates are live; `-Copy` makes a standalone
copy, `-Force` replaces an existing install, `-Uninstall` removes it.

### 2. Run `/clean-disk`

```text
/clean-disk
```

The agent loads the skill, **checks that the session is in plan mode**, and stops
with a warning if it is not. It then asks which drive to look at and offers:

1. **Audit** — read-only HTML dashboard + JSON
2. **Quick scan** — junctions, known folders, broken links
3. **Plan a move** — a folder plus its destination drive
4. **Verify** — PASS/FAIL for a manifest or existing links
5. **Explain** — risk levels, the junk map, what is safe to remove

Pass a choice to skip the menu:

```text
/clean-disk audit C:
```

### 3. Approve and execute — only when ready

Plan mode cannot move anything. After the audit, switch to a build agent and run
the transaction from the installed skill:

```powershell
cd "$env:USERPROFILE\.config\opencode\skills\disk-cleanup"
```

```powershell
# record the move, then approve it (SHA-256 bound to the item)
.\scripts\make-plan.ps1 -Source 'C:\Work\App' -Destination 'D:\Work\App'
.\scripts\make-plan.ps1 -Source 'C:\Work\App' -Destination 'D:\Work\App' `
    -Approve -ApprovedBy 'Your Name'
```

```powershell
# dry run first; -Execute is required for any change
.\scripts\move-and-link.ps1 -PlanPath "$env:USERPROFILE\_AI_Rollback\plan.json" -PlanItemId '<id>'
.\scripts\move-and-link.ps1 -PlanPath "$env:USERPROFILE\_AI_Rollback\plan.json" -PlanItemId '<id>' -Execute
```

```powershell
# mandatory verification
.\scripts\verify.ps1 -Drive C: -ManifestPath "$env:USERPROFILE\_AI_Rollback\manifest.jsonl"
```

<details>
<summary><b>No agent? Use the CLI directly</b></summary>

```powershell
git clone https://github.com/SamueleGuerrini/disk-cleanup-skill.git disk-cleanup
cd disk-cleanup
.\scripts\audit.ps1 -Drive C:
.\scripts\scan.ps1 -Drive C:
```

</details>

## Requirements

**OpenCode V2 on Windows 10/11** on NTFS (ReFS has limited junction support) ·
PowerShell 7+ preferred, 5.1 works for most scripts · no admin for auditing or
per-user moves; admin for restore points, VSS, and some system cleanup.

The PowerShell scripts run on their own, without an agent. The skill and the
`/clean-disk` command are OpenCode-specific; other agents were not tested.

## Safety

A junction is **not** a backup. A restore point does **not** back up personal
files. A `Rename`-staged move frees **no** space until purge. Prefer a fixed
internal NTFS target — a junction into a removable or network drive breaks when
the drive is absent or re-lettered. Never remove a junction with
`Remove-Item -Recurse` or `rmdir /s`; delete the link only.

## Testing

The suite creates real junctions and deletes real trees. Run it only in a
disposable Windows VM, Windows Sandbox, or Windows container:

```powershell
cd tests
pwsh -NoProfile -File .\run-tests.ps1
```

<details>
<summary><b>Documentation</b></summary>

| File | Contents |
|---|---|
| `install.ps1` | Installs the skill and `/clean-disk` into OpenCode |
| `commands/clean-disk.md` | The `/clean-disk` slash command (plan-mode entry point) |
| `SKILL.md` | Full workflow (also usable as an OpenCode/agent skill) |
| `references/SAFETY.md` | Path, junction, shell, cloud, ACL/ADS, incident lessons |
| `references/CLASSIFICATION.md` | Risk mapping, tiers, proposal format |
| `references/KNOWN-FOLDERS.md` | Junk/cache map, hotspots, leave-alone list |
| `references/ROLLBACK.md` | Safety layers L1–L4, recovery, remediation |
| `references/POST-OPERATION.md` | Verification checklist and remediation |
| `references/MANIFEST-TEMPLATE.md` | Markdown record + JSONL event schema |
| `references/PLAN.md` | Plan schema, approval hash, drift checks |
| `references/TRANSACTION.md` | States, crash recovery, restore, purge, ACL/ADS |
| `references/REPORTING.md` | Dashboard, JSON schema, cache, workers, limits |
| `references/TARGET-DRIVES.md` | SSD/HDD choice, HDD reliability, SMART, 3-2-1, CMR/SMR |
| `references/DOCKER.md` | Docker Desktop VHDX relocation and warnings |
| `references/TESTING.md` | Test suite and sandbox/VM options |
| `examples/JUNCTION-RECORD.md` | Synthetic C: → E: junction migration |
| `examples/plan.example.json` | A complete approved plan item |

</details>

## License

MIT — see [`LICENSE`](LICENSE). This software moves and deletes files: you are
responsible for reviewing every proposal and keeping a verified backup of anything
you cannot afford to lose.
