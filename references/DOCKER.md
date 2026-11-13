# Docker Desktop: relocating the WSL disk (reference recipe)

Docker Desktop on Windows runs its engine inside a WSL2 distribution and stores the
whole engine in a single virtual disk (VHDX). That file grows and does not shrink by
itself. On a small system SSD it can become a top consumer.

> **This is a reference recipe, not an instruction to run it now.** Do not move
> Docker while containers, WSL, or Docker Desktop are running, and do not move it
> onto a slow HDD if you use Docker interactively.

---

## 1. Preferred method: Docker Desktop settings

If your version supports it, use the built-in move first. It is the least likely to
leave the engine in a broken state.

1. Quit Docker Desktop completely (tray icon → Quit Docker Desktop).
2. Open Docker Desktop → **Settings → Resources → Advanced**.
3. Change **Disk image location** to the new folder on the target drive.
4. Apply and restart. Docker moves the disk itself.
5. Verify: `docker info` and `docker run --rm hello-world`.

If the setting is missing in your version, use the manual recipe below.

---

## 2. Manual recipe (junction)

### 2.1 Find the real disk

Current Docker Desktop versions store the engine disk under the user profile:

```text
C:\Users\<User>\AppData\Local\Docker\wsl\main\ext4.vhdx
```

Older versions used a different layout and file name:

```text
C:\Users\<User>\AppData\Local\Docker\wsl\data\ext4.vhdx
C:\Users\<User>\AppData\Local\Docker\wsl\docker_data.vhdx
C:\ProgramData\DockerDesktop\...
```

Do not trust a guide that names one path. **Find the actual file** and confirm its
size:

```powershell
Get-ChildItem "$env:LOCALAPPDATA\Docker" -Recurse -Filter *.vhdx -ErrorAction SilentlyContinue |
  Select-Object FullName, @{n='GB';e={[math]::Round($_.Length/1GB,2)}}, LastWriteTime
```

Also list WSL distributions, because Docker's disk is a WSL disk:

```powershell
wsl -l -v
```

### 2.2 Stop everything

```powershell
# 1. Quit Docker Desktop from the tray (or:)
Get-Process 'Docker Desktop' -ErrorAction SilentlyContinue | Stop-Process

# 2. Stop all WSL distributions
wsl --shutdown

# 3. Confirm nothing holds the file
Get-Process | Where-Object { $_.Name -match 'docker|wsl|vmmem' }
```

Do not continue while `vmmem`/`wsl`/Docker processes are alive.

### 2.3 Move the disk

Pick a destination folder on the target drive, e.g. `D:\Docker\wsl\main`.

```powershell
$src = "$env:LOCALAPPDATA\Docker\wsl\main\ext4.vhdx"   # use the path you found
$dstDir = 'D:\Docker\wsl\main'
New-Item -ItemType Directory -Force -Path $dstDir | Out-Null

# Copy (not move) first, then verify, then remove the source
robocopy (Split-Path $src) $dstDir (Split-Path $src -Leaf) /COPY:DAT /R:2 /W:2

# Verify size matches before deleting anything
(Get-Item $src).Length
(Get-Item (Join-Path $dstDir (Split-Path $src -Leaf))).Length
```

Only after the sizes match:

```powershell
Remove-Item -LiteralPath $src -Force
```

### 2.4 Replace the old folder with a junction

```powershell
# The original folder must be gone or empty before the junction is created.
# Remove the now-empty original directory (it contains no data at this point):
Remove-Item -LiteralPath (Split-Path $src) -Force -Recurse:$false

# Create the junction at the original location
New-Item -ItemType Junction -Path (Split-Path $src) -Target $dstDir

# Verify
$i = Get-Item (Split-Path $src) -Force
$i.LinkType   # Junction
$i.Target     # D:\Docker\wsl\main
```

If Docker expects the exact old path (it does), the junction must be at
`...\Docker\wsl\main`, not at `...\Docker\wsl`.

### 2.5 Restart and verify

1. Start Docker Desktop.
2. `docker info` — the engine should come up.
3. `docker images` and `docker ps -a` — your images/containers should be listed.
4. `docker run --rm hello-world`.
5. Confirm the VHDX is now on the target drive and the old path is a junction.

If Docker recreates a new disk instead of using the junction, the path is wrong.
Stop, remove the new disk, and fix the junction target.

---

## 3. Performance warning: SSD → HDD

Docker's engine disk is random-I/O heavy: image layers, container filesystems,
build caches, and databases all do small random reads/writes.

- **On an SSD:** normal Docker responsiveness.
- **On an HDD:** `docker build`, `docker pull` (unpacking), and container startup
  can become several times slower. Databases in containers may time out. This is
  expected, not a bug.
- **On a USB HDD:** worse still, and the drive may not be mounted at boot.

If Docker is part of your daily workflow, keep the disk on an SSD. Move it to an
HDD only if Docker is occasional and the space pressure is real.

---

## 4. Compacting instead of moving

A VHDX grows but does not shrink when images are deleted. If the goal is space,
compacting may be enough and is lower risk than moving.

```powershell
wsl --shutdown
# Find the disk, then (Docker Desktop has its own "Clean / Purge data" too):
Optimize-VHD -Path 'C:\Users\<User>\AppData\Local\Docker\wsl\main\ext4.vhdx' -Mode Full
```

`Optimize-VHD` requires the Hyper-V PowerShell module and an elevated shell, and the
disk must not be attached. Docker Desktop also offers **Troubleshoot → Clean /
Purge data** and `docker system prune -a` for reclaiming image/build space.

Order of operations: prune unused images/build cache first, then compact, then
consider moving only if it is still too large.

---

## 5. Rollback

1. Quit Docker Desktop; `wsl --shutdown`.
2. Remove the junction **link only**:
   `[System.IO.Directory]::Delete('C:\Users\<User>\AppData\Local\Docker\wsl\main', $false)`
3. Move the disk back with robocopy `/MOVE`, or copy + verify + remove.
4. Start Docker Desktop and verify.

Keep the original disk until `docker info`, `docker images`, and a test container
all work.

---

## 6. Checklist

- [ ] Docker Desktop quit; `wsl --shutdown`; no `vmmem`/`wsl`/docker processes
- [ ] Actual VHDX path and size confirmed (do not assume the file name)
- [ ] Target has space and is a fixed local NTFS volume
- [ ] Copy verified before the source was removed
- [ ] Junction created at the **exact** original path and verified
- [ ] Docker starts; images/containers present; `hello-world` runs
- [ ] Performance acceptable on the chosen media
- [ ] Manifest updated with source, target, size, date
