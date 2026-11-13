<div align="center">

# disk-cleanup

**Audit a Windows disk read-only. Reclaim space with approval-bound, crash-safe moves.**

[![MIT](https://img.shields.io/badge/license-MIT-3DA639?style=flat-square)](LICENSE)
[![PowerShell](https://img.shields.io/badge/powershell-5.1%20%7C%207%2B-5391FE?style=flat-square)](https://microsoft.com/powershell)
[![Windows](https://img.shields.io/badge/windows-10%20%7C%2011-0078D4?style=flat-square)](#requirements)

<sub>`audit` → `report` → `plan` → `execute` → `verify` → `record`</sub>

</div>

Not a "clean everything" button. It measures, explains, labels risk, and acts only
on what you approve. Dry run is the default; `-Execute` is required for any change.

> **Built for OpenCode on Windows.** Targets OpenCode V2 on Windows 10/11. Other
> agents that read `SKILL.md` and run PowerShell may work, but they are untested
> and unsupported.

## What it does

| Stage | Result |
|---|---|
| **Audit** | Read-only HTML dashboard and JSON: click-through treemap, risk donut, file types, modification years, sortable large files, duplicate size candidates, junk/cache hotspots. |
| **Plan** | Canonical paths, sizes, volume serials, and a SHA-256 per item. The executor rejects drift. |
| **Move** | Reparse-safe copy, verify, stage, link, verify, log. `-Recover` finishes or rolls back an interrupted run. |
| **Restore / purge** | Conflict-aware restore. Purge requires `-Execute` plus an exact confirmation, and refuses to destroy the last copy. |

Bounded memory, incremental cache, 1-second sample, 30-second progressive mode,
time/file/memory limits, Ctrl+C checkpoints. Renders offline from `file://`.

## Risk levels

| | Meaning | Default |
|---|---|---|
| 🟢 | Temporary or regenerable | Safe to delete |
| 🟡 | Archive material (media, ISOs, archives) | Archive or move; verify |
| 🟠 | User content or binaries | Explicit confirmation |
| 🔴 | Protected system paths | **Never move or delete** |
| ⚪ | No rule matched | Inspect; user-led |

`unrated` is not green. An unrecognised folder is never guessed at.

## Quick start

### 1. Install

From a checkout:

```powershell
git clone https://github.com/SamueleGuerrini/disk-cleanup-skill.git disk-cleanup
cd disk-cleanup
.\install.ps1
```

Or run the installer directly:

```powershell
irm https://raw.githubusercontent.com/SamueleGuerrini/disk-cleanup-skill/main/install.ps1 | iex
```

Installs `skills\disk-cleanup\` and `commands\clean-disk.md` under
`%USERPROFILE%\.config\opencode`, then verifies both. No admin needed.

### 2. Run `/clean-disk`

```text
/clean-disk
```

The agent checks that the session is in plan mode, then offers:

| Choice | Action |
|---|---|
| Audit | Read-only dashboard and JSON |
| Quick scan | Junctions, known folders, broken links |
| Plan a move | Source folder and destination drive |
| Verify | PASS/FAIL for a manifest or existing links |
| Explain | Risk levels, junk map, safe removals |

Pass a choice directly:

```text
/clean-disk audit C:
```

### 3. Execute (only when ready)

Plan mode cannot move anything. Switch to a build agent, then:

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

## Update

| Installed as | How to update |
|---|---|
| Checkout plus junction (default) | `git -C <checkout> pull`, then `.\install.ps1` to refresh the command copy |
| Clone from the one-liner | Re-run the one-liner. It pulls the existing clone. |
| `-Copy` install | `.\install.ps1 -Copy -Force` from an updated checkout |
| Pinned tag | `git -C <checkout> fetch --tags`, `git -C <checkout> checkout <tag>`, then `.\install.ps1` |

Check the installed commit:

```powershell
git -C "$env:USERPROFILE\.config\opencode\skills\disk-cleanup" log -1 --oneline
```

OpenCode reads the skill when a session starts, so start a new session after
updating. Version pins are git tags; a junction install follows the checkout, so
checking out a tag pins it.

## Requirements

**OpenCode V2 on Windows 10/11**, NTFS (ReFS has limited junction support).
PowerShell 7+ preferred; 5.1 works for most scripts. No admin for auditing or
per-user moves; admin for restore points, VSS, and some system cleanup.

The scripts run without an agent. The skill and `/clean-disk` are OpenCode-specific.

## Safety

A junction is not a backup. A restore point does not back up personal files. A
`Rename`-staged move frees no space until purge. Prefer a fixed internal NTFS
target; a junction to a removable or network drive breaks when it is absent or
re-lettered. Never remove a junction with `Remove-Item -Recurse` or `rmdir /s`.

Reparse-aware scanning and deletion, SHA-256 plan binding, an append-only event
log, explicit transaction states, and conflict-aware restore cover the usual
failure modes: a junction redirecting a recursive delete, a path mangled across
shells, a copy that skipped reparse points or cloud placeholders, and a
half-finished move with no record.

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
| `references/ROLLBACK.md` | Safety layers L1 to L4, recovery, remediation |
| `references/POST-OPERATION.md` | Verification checklist and remediation |
| `references/MANIFEST-TEMPLATE.md` | Markdown record + JSONL event schema |
| `references/PLAN.md` | Plan schema, approval hash, drift checks |
| `references/TRANSACTION.md` | States, crash recovery, restore, purge, ACL/ADS |
| `references/REPORTING.md` | Dashboard, JSON schema, cache, workers, limits |
| `references/TARGET-DRIVES.md` | SSD/HDD choice, HDD reliability, SMART, 3-2-1, CMR/SMR |
| `references/DOCKER.md` | Docker Desktop VHDX relocation and warnings |
| `references/TESTING.md` | Test suite and sandbox/VM options |
| `examples/JUNCTION-RECORD.md` | Synthetic C: to E: junction migration |
| `examples/plan.example.json` | A complete approved plan item |

</details>

## License

MIT. See [`LICENSE`](LICENSE). This software moves and deletes files: review every
proposal and keep a verified backup of anything you cannot afford to lose.
