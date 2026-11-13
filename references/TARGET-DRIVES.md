# Choosing and trusting a target drive

The target drive is where the data will actually live. It is the most
under-considered part of a move: a junction is only as reliable as the volume
behind it.

---

## 1. Eligibility rules enforced by the scripts

`Test-DestinationDrive` (used by planning and execution) requires:

| Requirement | Detail |
|---|---|
| Local fixed volume | `DriveType` must be Fixed (3) |
| NTFS or ReFS | Directory junctions require NTFS; ReFS support is limited |
| Free space | Data size + 5% reserve (minimum 1 GB reserve) |
| Not BitLocker-locked | A locked volume breaks every junction into it |
| Not a network share | Junctions to `\\server\share` are not supported |
| Not a CD/DVD or RAM disk | Explicitly refused |

Warnings (require `-AcceptWarnings` at execution):

- free space below 1.5× the data size
- BitLocker-encrypted destination without confirmed auto-unlock
- removable destination (only with `-AllowRemovable`)

### Removable and network targets

- **Removable (USB HDD/SSD):** allowed only with `-AllowRemovable`. If the drive
  is not mounted at logon, **every junction into it is broken** — apps see an
  empty folder or fail. Drive-letter changes break it too. Prefer a fixed internal
  volume for anything that runs automatically.
- **Network share:** refused. A junction cannot target a UNC path, and a mapped
  drive that is offline behaves worse than a missing USB drive.
- **Cloud-synced folders (OneDrive/Dropbox):** a junction inside a synced tree can
  confuse the sync client and cause re-uploads or placeholder churn. Do not move a
  folder *into* a synced tree as a junction target.

---

## 2. SSD vs HDD

| | SSD (NVMe/SATA) | HDD (spinning) |
|---|---|---|
| Random reads | Fast | Slow (seek-bound) |
| Sequential reads | Fast | Fast-ish, ~100–250 MB/s |
| Concurrent scanning | Scales to a few workers | Gets **slower** with concurrency |
| Small-file trees (git, node_modules) | Fine | Painful |
| Failure mode | Sudden, often no warning | Gradual, often with SMART warnings |
| Best use | Active projects, OS, apps, caches in use | Cold archives, media, backups, large sequential data |

### Practical consequences

- **Scanning:** `audit.ps1` defaults to 1 worker on HDD/removable/network and up to
  4 on SSD. Do not override this on a spinning disk; parallel random reads cause
  seek thrash.
- **Running projects from an HDD:** git status, `pnpm install`, IDE indexing,
  Unity asset import, and build watchers all become noticeably slower. If the
  folder is actively edited, keep it on the SSD.
- **Media and archives on an HDD:** a good fit — large sequential files, rarely
  modified.
- **Caches on an HDD:** only for caches that are read sequentially or rarely. A
  package store on an HDD makes installs slower.
- **Junction overhead:** negligible. The cost is the target drive's latency, not
  the link.

### When the target is an HDD, prefer

- cold project archives, video/photo libraries, installers, ISOs, backups
- completed builds and exports
- large model/dataset files that are loaded sequentially

### When the target is an HDD, avoid

- `AppData` as a whole
- active repositories with many small files
- package caches used during installs
- anything a service reads at boot

---

## 3. HDD reliability

Spinning disks are mechanical. Plan for wear, not just capacity.

### Failure causes

| Cause | What happens | Mitigation |
|---|---|---|
| **Mechanical wear** | bearings, motor, actuator fatigue; head crashes | Replace on schedule; keep backups |
| **Bit rot** | silent corruption of stored bits over years | Checksums, periodic full read/refresh, backups |
| **Heat** | higher failure rate above ~40–45 °C | Airflow, spacing, monitor SMART temperature |
| **Humidity** | condensation, corrosion | Dry, stable environment |
| **Vibration** | adjacent drives, desk bumps; can cause write errors | Isolation mounts, avoid stacking under load |
| **Power events** | head parking/unexpected power loss | UPS, safe shutdown |
| **SMR writes** | very slow sustained writes, rebuild stalls | Prefer CMR for active data |

### Lifespan

A typical consumer HDD is designed for roughly **3–7 years** of service. That is a
planning number, not a guarantee. A drive can fail in months or last a decade.
Age alone is a reason to verify backups, not to panic.

### 3-2-1 backups

- **3** copies of the data
- **2** different media/types
- **1** off-site

A junction is **not** a backup. If the target drive dies, the original path is a
dead link and the data is gone. Moving data to a single HDD and calling it done is
a single point of failure.

### SMART monitoring

```powershell
Get-PhysicalDisk | Select-Object FriendlyName, MediaType, HealthStatus, OperationalStatus
Get-Disk | Select-Object Number, FriendlyName, HealthStatus, OperationalStatus
```

Useful attributes to watch (vendor tools or `smartmontools`):

- `Reallocated_Sector_Ct` (05) — rising is bad
- `Current_Pending_Sector` (C5) — sectors waiting for reallocation
- `Offline_Uncorrectable` (C6)
- `Raw_Read_Error_Rate` (01)
- `Temperature_Celsius` (C2)
- `Power_On_Hours` (09)

A single rising pending/reallocated count is a warning; a sustained rise is a
reason to replace the drive and restore from backup.

### Periodic refresh

For cold archives on HDDs, read the data periodically (for example quarterly) and
verify checksums. This surfaces bit rot before you need the file and gives the
drive a chance to reallocate weak sectors.

### CMR vs SMR

- **CMR** (conventional magnetic recording): consistent write performance. Prefer
  it for active data, RAID, and anything rewritten often.
- **SMR** (shingled): denser/cheaper, but sustained random writes and rebuilds can
  stall for long periods. Fine for write-once archives, bad for active projects or
  parity rebuilds.

Check the model's specification before buying; vendors do not always label it
clearly on the box.

### RPM, cache, workload

- **5400 RPM** — quiet, low power, slower random I/O. Archive/media.
- **7200 RPM** — faster, louder, hotter. Better for active sequential work.
- **Cache size** — helps bursty writes; not a substitute for CMR.
- **Workload rating** — desktop drives are not rated for 24/7 RAID use. Use
  NAS/enterprise drives where that matters.

### TLER / ERC

Desktop drives may spend a long time retrying a bad sector before reporting an
error. RAID/NAS drives implement **TLER/ERC** (time-limited error recovery) so the
controller is not left waiting. This matters for RAID, not for a single junction
target — but it is another reason not to build a RAID array from desktop drives.

---

## 4. A sane target layout

```text
D:\                     fixed internal HDD
  \_AI_Rollback\        staged originals + manifest (L1)
  \Work\App             moved project
  \Media\Videos         moved media
  \Caches\              relocated caches (prefer env/config over junctions)
```

Keep the staging folder on the same volume as the moved data when possible, so
staging is an instant rename rather than a cross-volume copy.

---

## 5. Before you commit to a target

1. Confirm the drive type, filesystem, free space, and BitLocker state.
2. Confirm the drive letter is stable (fixed internal, not a USB that may not
   mount).
3. Confirm you have a backup of anything irreplaceable — the junction is not one.
4. Confirm the workload matches the media (active small-file work → SSD).
5. Confirm SMART health and temperature if the drive is old.
6. Write the target and its serial into the manifest so a future reader can tell
   whether the drive changed.
