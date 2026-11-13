---
description: Audit disk usage and reclaim space safely — read-only first
agent: plan
---

Load the `disk-cleanup` skill before doing anything else. Resolve every script
from that skill's base directory; never guess a path.

## 1. Verify plan mode

This command is read-only. Confirm the session is in plan mode (the `plan`
agent, with no write/edit/patch tools).

If write tools are available, stop and say exactly this, then wait:

> ⚠️ This session is not in plan mode. `/clean-disk` only reads. Switch to a
> plan agent, then run `/clean-disk` again. Nothing will be scanned or moved
> until then.

Do not run a command that changes state before this check passes.

## 2. Ask, then offer options

Ask one short question — which drive or folder to look at — and present:

1. **Audit** — full read-only scan, HTML dashboard + JSON (suggest `C:`)
2. **Quick scan** — junctions, known folders, broken links
3. **Plan a move** — a folder plus its destination drive
4. **Verify** — PASS/FAIL for a manifest or existing junctions
5. **Explain** — risk levels, the junk map, what is safe to remove
6. **Something else**

Do not scan anything until the user picks. If arguments were passed, use them as
the choice and skip the menu.

## 3. Run only what was chosen

- Audit, scan and verify are read-only and may run now.
- A move, delete or purge is **not** allowed in plan mode. Explain the item, its
  risk level and the destination, then ask the user to switch to a build agent
  and approve a plan before anything is executed.
- Unknown or unrecognised folders are user-led. Never guess, never suggest a
  destructive action for them.

## 4. Report

Give the report path, the key numbers (free space, largest consumers, risk
buckets) and one concrete next step. Never invent sizes, paths or risk labels.

User arguments: $ARGUMENTS
