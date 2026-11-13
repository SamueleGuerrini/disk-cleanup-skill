# Reporting layer: audit → JSON → HTML

`scripts/audit.ps1` scans a drive or folder **read-only** and writes a JSON report
plus a self-contained HTML dashboard. `scripts/report.ps1` re-renders an existing
JSON file. Neither script deletes, moves, or links anything.

Use the report to decide *what* to propose in Phase 3. It is evidence, not an
action.

---

## 1. What the report shows

| Section | Answers |
|---|---|
| KPI row | bytes scanned, volume used/free, average file size, unreadable entries |
| Risk donut | bytes per risk level (green / yellow / orange / red / unrated) |
| File-type donut | bytes per extension, top 9 + "other" |
| Year columns | bytes per last-write year (old ≠ unused, just worth reviewing) |
| Treemap | directory occupancy; click to drill down, breadcrumbs to go back |
| Large files | sortable/filterable table, each file tagged with a risk level |
| Duplicate candidates | groups of files with identical byte size |
| Known folders | measured junk/cache/hotspot locations with notes |

The dashboard has no CDN, fonts, or analytics. It works from `file://` and offline.

### Treemap behaviour

- Blocks are directories; the size is the recursive logical size.
- A block with a "(files in this folder)" tile means that directory holds direct
  files as well as subdirectories.
- Click a block to descend. The breadcrumb bar returns to any ancestor.
- Reparse points are never followed, so a junction's target is not double-counted.
- Directories smaller than `-MinDirMB` (default 1 MB) are folded into their parent.

### Large-file table

- Default threshold 100 MB, default cap 500 files.
- Filter by text, minimum size, "untouched ≥ 2 years", or "locked only".
- Select rows, then **Copy selected** (newline-separated paths) or **CSV**.
- Selection is manual. Nothing is pre-selected and nothing is acted on.

### Duplicate candidates

Groups are built from **exact byte size only**. The report labels them
"candidates" on purpose: same size is not same content. Hash before deleting
(`Get-FileHash -Algorithm SHA256`), or compare with
`scripts/verify.ps1`-style logic.

---

## 2. Commands

```powershell
# Full audit of C: with the HTML dashboard
.\scripts\audit.ps1 -Drive C:

# A single folder, no cache, locks checked on files ≥ 200 MB
.\scripts\audit.ps1 -Path 'D:\Projects' -NoCache -CheckLocks

# 1-second sample: estimate how long a full scan would take
.\scripts\audit.ps1 -Drive E: -SampleSeconds 1

# 30-second progressive partial result (good on a slow HDD)
.\scripts\audit.ps1 -Drive D: -Progressive

# Hard limits: stop after 5 minutes or 200k files
.\scripts\audit.ps1 -Drive D: -TimeLimitSeconds 300 -MaxFiles 200000

# JSON only, for scripting
.\scripts\audit.ps1 -Drive C: -NoHtml -Json

# Re-render an old report, or a checkpoint left by Ctrl+C
.\scripts\report.ps1 -InputJson "$env:LOCALAPPDATA\disk-cleanup\reports\audit-C-20260101-120000.json"
```

### Parameters that matter

| Parameter | Default | Effect |
|---|---|---|
| `-Drive` | system drive | Volume root to scan |
| `-Path` | — | Folder to scan; overrides `-Drive` |
| `-OutFile` | `%LOCALAPPDATA%\disk-cleanup\reports\audit-<label>-<stamp>.json` | JSON destination |
| `-HtmlFile` | same name, `.html` | Dashboard destination |
| `-NoHtml` | off | Skip rendering |
| `-LargeFileMinMB` | 100 | Large-file threshold |
| `-LargeFileCount` | 500 | Cap on tracked large files |
| `-DupMinMB` | 1 | Minimum size for duplicate groups |
| `-MinDirMB` | 1 | Minimum directory size in the treemap |
| `-PhysicalSize` | off | Allocated size (sparse/compressed aware); slower |
| `-Workers` | 0 = auto | 1 on HDD/removable/network/unknown; up to 4 on SSD |
| `-SampleSeconds` | 0 | Sample window, then extrapolate full-scan time |
| `-Progressive` | off | Time-box to 30 s and keep partial results |
| `-TimeLimitSeconds` | 600 on a volume root, 0 on a folder | Hard stop; a partial report is still written |
| `-MaxFiles` | 0 | Hard stop after N files |
| `-MemoryLimitMB` | 0 = 70% of free RAM | Hard stop on managed-memory use |
| `-CacheMaxAgeHours` | 24 | Reuse directory snapshots younger than this |
| `-RefreshCache` | off | Ignore the cache, then rewrite it |
| `-NoCache` | off | No cache read or write |
| `-CheckLocks` | off | Ask the Restart Manager which processes hold large files |
| `-CheckpointSeconds` | 60 | Write a partial JSON checkpoint at this interval |

`-Progressive` is not a different scanner: it simply sets a 30-second deadline.
Partial results are real results for the part that was scanned, never an
extrapolation.

---

## 3. How the scan works

### One bounded pass

The engine keeps aggregates, not a file list:

- per-directory direct bytes/files/allocated bytes (totals summed at report time)
- extension, year, and risk totals
- the largest N files (bounded; the list is pruned during the scan)
- same-size groups (bounded by `DupGroupLimit`)
- cache hits, links skipped, offline files, error samples

That keeps memory roughly proportional to the **number of directories**, not the
number of files, so a multi-million-file volume can be scanned.

### Reparse points and cloud files

- A reparse point is counted and skipped. Its target is never traversed.
- Cloud placeholders (OneDrive "online-only", `RecallOnDataAccess`) are counted as
  offline. Their logical size is reported; their allocated size is treated as 0
  unless `-PhysicalSize` is used.

### Concurrency

- Workers partition the scan by **top-level directory**, so no two workers share a
  subtree. This avoids double counting and lock contention.
- Worker state is serialized to JSON and merged. Hashtables and generic lists are
  rehydrated before merging (PowerShell's JSON round-trip turns them into
  `PSCustomObject`/arrays).
- Default workers = 1 on HDD, removable, network, or unknown media; up to 4 on SSD.
  Concurrent random reads on a spinning disk make it slower, not faster.

### Incremental cache

- Location: `%LOCALAPPDATA%\disk-cleanup\cache\`
- Key: scan root + volume serial (`<hash>.json.gz`).
- With `-Workers` > 1 the scan is partitioned by top-level directory, and each
  partition keeps its own snapshot (`<hash>-<part>.json.gz`). Partitions are stable
  between runs, so a second parallel scan hits the same files.
- Per-directory snapshot is reused when the directory's `LastWriteTimeUtc` is
  unchanged.
- The cache is only written after a **complete** scan; a partial or interrupted run
  never poisons it.
- `-RefreshCache` skips the read but still rewrites the cache.
- A cache failure never fails the audit.

### Limits and interruption

- Time, file-count, and memory limits set `partial: true` with a reason.
- Progress is written every two seconds.
- A checkpoint JSON is written every 60 seconds (`-CheckpointSeconds`).
- Ctrl+C leaves the last checkpoint on disk and exits `130`. Render it later:

```powershell
.\scripts\report.ps1 -InputJson '<checkpoint>.json'
```

- With `-Workers` greater than 1, an interrupt can leave a checkpoint that holds
  only root-level totals: worker partitions are merged as each one finishes, and
  Ctrl+C does not wait for them. Use `-Workers 1` when you need an interruptible
  checkpoint with full detail. A time limit is different — workers return their
  partial state, so the report is complete up to the limit.

The HTML always shows a `partial` badge with the reason when the result is
incomplete.

### Lock awareness

`-CheckLocks` uses the Windows Restart Manager (`RmStartSession` /
`RmRegisterResources` / `RmGetList`) on the largest files. It **never terminates a
process**. The report shows "locked by <app> (pid N)" in the Action column.
Restart Manager can miss files opened with unusual sharing modes; absence of a
lock is not proof that a file is idle.

---

## 4. Risk model in the report

| Level | Meaning | Default action |
|---|---|---|
| `green` | Temporary or regenerable | Safe to delete |
| `yellow` | Archive material (media, ISOs, archives) | Archive or move; verify first |
| `orange` | User content or binaries | Explicit confirmation required |
| `red` | Protected system paths and files | Never move or delete |
| `unrated` | No rule matched | Inspect; no automatic suggestion |

`unrated` is deliberately **not** green. An unrecognised folder must stay
user-led. See `references/CLASSIFICATION.md` for the mapping to the workflow's
Low/Medium/High/Unknown tiers.

---

## 5. JSON schema (version 1)

```jsonc
{
  "schema": 1,
  "root": "C:\\",
  "volume": { "Drive": "C:", "DriveType": "Fixed", "FileSystem": "NTFS",
              "Serial": "BA313953", "SizeBytes": 999188066304, "FreeBytes": 414316101632 },
  "meta": {
    "started": "2026-11-13T01:58:34Z", "finished": "2026-11-13T01:58:35Z",
    "elapsed_seconds": 0.1, "files": 6, "dirs": 5,
    "bytes": 7517, "allocated": 7517, "errors": 0,
    "links": 1, "offline": 0,
    "partial": false, "partial_reason": "", "sampled": false,
    "cache_hits": 0, "cache_dirs": 0,
    "dup_truncated": false, "tree_truncated": false,
    "media": "SSD", "workers": 1, "time_limit_seconds": 0
  },
  "tree":   [ { "path": "Users", "name": "Users", "bytes": 123, "files": 4, "parent": "" } ],
  "ext":    [ { "ext": ".mp4", "bytes": 3002, "files": 1 } ],
  "years":  [ { "year": "2024", "bytes": 1234, "files": 7 } ],
  "risk":   [ { "level": "green", "bytes": 10, "files": 2, "action": "Safe to delete (temporary or regenerable)" } ],
  "large":  [ { "path": "C:\\...", "bytes": 123, "last_write": "2024-01-01T00:00:00Z",
                "risk": "yellow", "action": "Archive or move; verify first",
                "locked": true, "lockers": ["Code (pid 1234)"] } ],
  "dups":   [ { "size": 1000, "count": 2, "wasted": 1000, "paths": ["C:\\a", "C:\\b"] } ],
  "known":  [ { "item": "Downloads", "path": "C:\\Users\\Me\\Downloads",
                "bytes": 123, "files": 4, "links": 0, "level": "unrated", "note": "clutter hotspot" } ],
  "estimate": { "sampled_bytes": 1, "sampled_seconds": 1, "used_bytes": 2,
                "projected_seconds": 3, "note": "Estimate only: ..." }
}
```

- `tree[].path` is relative to `root`; `""` is the root itself.
- `tree[].files` counts **direct** files in that directory.
- `tree[].bytes` is recursive.
- `large[].locked` / `lockers` appear only with `-CheckLocks`.
- `known` and `estimate` may be absent (`known` is empty for a folder scan).
- `partial: true` means the numbers describe only the scanned part.

The HTML embeds this JSON in a `<script type="application/json">` block, so a
report is self-describing: you can extract the data and re-render it without
re-scanning.

---

## 6. Reading a report responsibly

1. **Old does not mean unused.** A 2019 file can be an archive you still need.
2. **Same size is not duplicate.** Hash before deleting.
3. **Unrated is not safe.** It means "no rule matched".
4. **Red is a hard stop.** Never move or delete a red item, even if it looks empty.
5. **Partial results are partial.** Do not infer total usage from a time-boxed run.
6. **Space accounting differs.** Logical size, allocated size, sparse files,
   hardlinks, compression, and cloud placeholders can all disagree. Reconcile
   before promising a number.
