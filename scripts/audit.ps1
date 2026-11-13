<#
.SYNOPSIS
  Read-only disk audit with a visual HTML report.

.DESCRIPTION
  Scans a drive or folder once and produces:

    * directory treemap (click to drill down)
    * file-type distribution (ring)
    * modification-year distribution (columns)
    * risk distribution (green/yellow/orange/red/unrated)
    * large-file list, each file tagged with a risk level
    * same-size duplicate candidates
    * known junk/cache/hotspot folders

  Nothing is deleted, moved or linked. The report is evidence for a decision,
  never an action.

  Reparse points are never followed. Cloud placeholders are counted as offline.
  Progress is reported every two seconds; Ctrl+C leaves the last checkpoint on
  disk (JSON only, render it later with report.ps1).

.PARAMETER Drive
  Drive letter to audit, e.g. C: or E:. Default: the system drive.

.PARAMETER Path
  Audit a folder instead of a whole drive. Overrides -Drive.

.PARAMETER OutFile
  JSON output path. Default: %LOCALAPPDATA%\disk-cleanup\reports\audit-<name>-<time>.json

.PARAMETER HtmlFile
  HTML output path. Default: same as -OutFile with .html

.PARAMETER NoHtml
  Only write JSON.

.PARAMETER LargeFileMinMB
  Minimum size for the large-file list. Default 100.

.PARAMETER LargeFileCount
  Maximum entries in the large-file list. Default 500.

.PARAMETER DupMinMB
  Minimum size for duplicate candidates. Default 1.

.PARAMETER MinDirMB
  Minimum directory size shown in the treemap. Default 1.

.PARAMETER PhysicalSize
  Use allocated size (sparse/compressed aware). Slower.

.PARAMETER Workers
  0 = auto (SSD: up to 4, HDD/removable/network: 1). 1 disables partitioning.

.PARAMETER SampleSeconds
  Quick estimate mode: scan for N seconds, then extrapolate time from the volume's
  used bytes. Default 0 (full scan).

.PARAMETER Progressive
  Time-box the scan to 30 seconds and keep partial results.

.PARAMETER TimeLimitSeconds
  Hard time limit. 0 = unlimited. Default: 600 on a volume root, 0 on a folder.
  Large or slow volumes may need more; a partial report is still written when the
  limit is reached.

.PARAMETER MaxFiles
  Stop after this many files. 0 = unlimited.

.PARAMETER MemoryLimitMB
  Stop when managed memory exceeds this. 0 = 70% of available RAM.

.PARAMETER CacheMaxAgeHours
  Reuse a directory cache younger than this. 0 = never expire. Default 24.

.PARAMETER RefreshCache
  Ignore and rewrite the cache.

.PARAMETER NoCache
  Do not read or write the incremental cache.

.PARAMETER CheckLocks
  Ask the Restart Manager which processes hold the largest files open. Never
  terminates anything.

.PARAMETER Quiet
  No progress output.

.PARAMETER Json
  Print the report JSON to stdout instead of a summary.

.EXAMPLE
  .\audit.ps1 -Drive C:

.EXAMPLE
  .\audit.ps1 -Drive E: -SampleSeconds 1

.EXAMPLE
  .\audit.ps1 -Path 'D:\Projects' -Workers 1 -CheckLocks
#>
[CmdletBinding()]
param(
  [string]$Drive = $env:SystemDrive,
  [string]$Path,
  [string]$OutFile,
  [string]$HtmlFile,
  [switch]$NoHtml,
  [int]$LargeFileMinMB = 100,
  [int]$LargeFileCount = 500,
  [int]$DupMinMB = 1,
  [int]$MinDirMB = 1,
  [switch]$PhysicalSize,
  [int]$Workers = 0,
  [int]$SampleSeconds = 0,
  [switch]$Progressive,
  [int]$TimeLimitSeconds = -1,
  [int]$MaxFiles = 0,
  [int]$MemoryLimitMB = 0,
  [int]$CacheMaxAgeHours = 24,
  [switch]$RefreshCache,
  [switch]$NoCache,
  [switch]$CheckLocks,
  [int]$LockCheckMinMB = 200,
  [int]$LockCheckMax = 100,
  [int]$CheckpointSeconds = 60,
  [switch]$Json,
  [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
if ($Json) { $Quiet = $true }
. (Join-Path $PSScriptRoot 'lib\common.ps1')
. (Join-Path $PSScriptRoot 'lib\risk.ps1')
. (Join-Path $PSScriptRoot 'lib\inventory.ps1')
. (Join-Path $PSScriptRoot 'lib\known.ps1')

function Write-Status {
  param([string]$Text)
  if (-not $Quiet) { Write-Host $Text -ForegroundColor Cyan }
}

function Get-AvailableMemoryMB {
  try {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    return [int64]($os.FreePhysicalMemory / 1KB)
  } catch {
    return [int64]0
  }
}

function Get-MediaType {
  param([string]$Letter)
  try {
    $part = Get-Partition -DriveLetter $Letter.TrimEnd(':') -ErrorAction Stop
    $disk = $part | Get-Disk -ErrorAction Stop
    $pd = $disk | Get-PhysicalDisk -ErrorAction Stop
    return [string]$pd.MediaType
  } catch {
    return 'Unknown'
  }
}

# --- resolve the root ------------------------------------------------------
if ($Path) {
  $root = Get-FullPath $Path
  if (-not $root -or -not (Test-Path -LiteralPath $root)) { throw "Path not found: $Path" }
} else {
  $letter = $Drive.TrimEnd(':', '\')
  $root = $letter + ':\'
  if (-not (Test-Path -LiteralPath $root)) { throw "Drive not found: $Drive" }
  $letter = $root.Substring(0, 2)
}

$vol = Get-VolumeInfo $root
if (-not $vol) { throw "Cannot read volume information for $root" }

$isVolumeRoot = ($root.TrimEnd('\').Length -eq 2)
if ($TimeLimitSeconds -lt 0) {
  if ($Progressive) { $TimeLimitSeconds = 30 }
  elseif ($isVolumeRoot) { $TimeLimitSeconds = 600 }
  else { $TimeLimitSeconds = 0 }
}
if ($Progressive -and $TimeLimitSeconds -eq 0) { $TimeLimitSeconds = 30 }

$media = 'Unknown'
if ($isVolumeRoot) { $media = Get-MediaType -Letter $root.Substring(0, 2) }
if ($Workers -le 0) {
  if ($media -eq 'SSD') { $Workers = [Math]::Min(4, [Math]::Max(1, [Environment]::ProcessorCount)) }
  else { $Workers = 1 }
}

$label = if ($isVolumeRoot) { $root.Substring(0, 1) } else { Split-Path -Leaf $root }
$safeLabel = ($label -replace '[^A-Za-z0-9._-]', '_')
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$reportDir = Join-Path $env:LOCALAPPDATA 'disk-cleanup\reports'
if (-not $OutFile) { $OutFile = Join-Path $reportDir ("audit-$safeLabel-$stamp.json") }
if (-not $HtmlFile) { $HtmlFile = [System.IO.Path]::ChangeExtension($OutFile, '.html') }

if ($MemoryLimitMB -le 0) {
  $freeMB = Get-AvailableMemoryMB
  if ($freeMB -gt 0) { $MemoryLimitMB = [int]($freeMB * 0.7) }
}

$cachePath = $null
if (-not $NoCache -and -not $SampleSeconds) {
  $cachePath = Get-InventoryCachePath -Root $root -VolumeSerial $vol.Serial
}

$deadline = $null
if ($TimeLimitSeconds -gt 0) { $deadline = (Get-Date).ToUniversalTime().AddSeconds($TimeLimitSeconds) }

$options = @{
  PhysicalSize          = [bool]$PhysicalSize
  Workers               = $Workers
  SampleSeconds         = $SampleSeconds
  MaxFiles              = $MaxFiles
  DeadlineUtc           = $deadline
  MaxSeconds            = $TimeLimitSeconds
  MemoryLimitMB         = $MemoryLimitMB
  LargeFileMinBytes     = [int64]$LargeFileMinMB * 1MB
  LargeFileCount        = $LargeFileCount
  DupMinBytes           = [int64]$DupMinMB * 1MB
  DupGroupLimit         = 20000
  UseCache              = [bool]$cachePath
  RefreshCache          = [bool]$RefreshCache
  CachePath             = $cachePath
  CacheMaxAgeHours      = $CacheMaxAgeHours
  VolumeSerial          = $vol.Serial
  ProgressIntervalSeconds = 2
  OnProgress            = $null
}

$lastCheckpoint = [datetime]::UtcNow
$lastProgress = [datetime]::UtcNow
$state = $null

function Save-Checkpoint {
  param($ScanState, [switch]$Final)
  if (-not $OutFile -or -not $ScanState) { return }
  try {
    $partial = ConvertTo-InventoryReport -State $ScanState -Volume $vol -MinDirBytes ([int64]$MinDirMB * 1MB) `
      -MaxLarge $LargeFileCount
    if (-not $Final) {
      $partial.meta.partial = $true
      $partial.meta.partial_reason = 'checkpoint while scanning'
    }
    Write-JsonAtomic -Path $OutFile -Object $partial
  } catch {
    if (-not $Quiet) { Write-Host "WARN: checkpoint failed: $($_.Exception.Message)" -ForegroundColor Yellow }
  }
}

$options.OnProgress = {
  param($s)
  $now = [datetime]::UtcNow
  if (-not $Quiet) {
    $secs = [math]::Round(($now - $s.StartedUtc).TotalSeconds, 0)
    $line = "{0:N1} GB | {1:N0} files | {2:N0} dirs | {3}s | {4}" -f ($s.Bytes / 1GB), $s.Files, $s.Dirs, $secs, $s.Root
    Write-Progress -Activity 'Disk audit (read-only)' -Status $line -PercentComplete -1
    if (($now - $lastProgress).TotalSeconds -ge 10) {
      Write-Host $line -ForegroundColor DarkGray
      $script:lastProgress = $now
    }
  }
  if ($OutFile -and ($now - $lastCheckpoint).TotalSeconds -ge $CheckpointSeconds) {
    $script:lastCheckpoint = $now
    Save-Checkpoint -ScanState $s
  }
}

Write-Status ''
Write-Status "Audit: $root  [$($vol.FileSystem), $($vol.DriveType), serial $($vol.Serial)]"
Write-Status ("Volume: {0:N1} GB total, {1:N1} GB used, {2:N1} GB free" -f ($vol.SizeBytes / 1GB), (($vol.SizeBytes - $vol.FreeBytes) / 1GB), ($vol.FreeBytes / 1GB))
Write-Status "Media: $media | workers: $Workers | time limit: $(if ($TimeLimitSeconds -gt 0) { "$($TimeLimitSeconds)s" } else { 'none' }) | cache: $(if ($cachePath -and -not $RefreshCache) { 'on' } else { 'off' })"
if ($SampleSeconds -gt 0) { Write-Status "Sample mode: scanning for $SampleSeconds second(s), results are an estimate." }

$interrupted = $false
try {
  $state = Invoke-InventoryScan -Root $root -Options $options
} catch [System.Management.Automation.PipelineStoppedException] {
  $interrupted = $true
  if ($state) { $state.Partial = $true; $state.PartialReason = 'interrupted by user' }
} finally {
  if (-not $Quiet) { Write-Progress -Activity 'Disk audit (read-only)' -Completed }
}

if (-not $state) {
  if ($interrupted -and $OutFile -and (Test-Path -LiteralPath $OutFile)) {
    Write-Host "Interrupted. A partial checkpoint is available: $OutFile" -ForegroundColor Yellow
    Write-Host "Render it with: .\report.ps1 -InputJson '$OutFile'" -ForegroundColor Yellow
    exit 130
  }
  throw 'Scan produced no state. Nothing was written.'
}
if ($interrupted) {
  $state.Partial = $true
  if (-not $state.PartialReason) { $state.PartialReason = 'interrupted by user' }
}

# --- lock awareness --------------------------------------------------------
if ($CheckLocks -and $state.Large.Count -gt 0) {
  . (Join-Path $PSScriptRoot 'lib\locks.ps1')
  $candidates = @($state.Large | Sort-Object bytes -Descending |
      Where-Object { $_.bytes -ge ([int64]$LockCheckMinMB * 1MB) } |
      Select-Object -First $LockCheckMax)
  Write-Status "Checking locks on $($candidates.Count) large file(s)..."
  foreach ($f in $candidates) {
    $lock = Get-FileLockers -Path $f.path
    $f | Add-Member -NotePropertyName locked -NotePropertyValue ([bool]$lock.Locked) -Force
    $f | Add-Member -NotePropertyName lockers -NotePropertyValue (@($lock.Processes | ForEach-Object { "$($_.Name) (pid $($_.Pid))" })) -Force
  }
}

# --- report ----------------------------------------------------------------
$report = ConvertTo-InventoryReport -State $state -Volume $vol -MinDirBytes ([int64]$MinDirMB * 1MB) -MaxLarge $LargeFileCount
$report.meta | Add-Member -NotePropertyName media -NotePropertyValue $media -Force
$report.meta | Add-Member -NotePropertyName workers -NotePropertyValue $Workers -Force
$report.meta | Add-Member -NotePropertyName time_limit_seconds -NotePropertyValue $TimeLimitSeconds -Force

$known = @()
if ($isVolumeRoot -and $root -eq $vol.Root) {
  $known = Get-KnownLocations -DriveRoot ($vol.Root) -UserProfile $env:USERPROFILE -PhysicalSize:$PhysicalSize
}
$report | Add-Member -NotePropertyName known -NotePropertyValue $known -Force

$estimate = $null
if ($SampleSeconds -gt 0 -and $state.Bytes -gt 0 -and $vol.SizeBytes -gt 0) {
  $used = [int64]($vol.SizeBytes - $vol.FreeBytes)
  $elapsed = [math]::Max(0.001, ($state.FinishedUtc - $state.StartedUtc).TotalSeconds)
  $sampled = [double]$state.Bytes
  if ($sampled -le 0) { $sampled = 1 }
  $estimate = [pscustomobject]@{
    sampled_bytes   = $state.Bytes
    sampled_seconds = [math]::Round($elapsed, 2)
    used_bytes      = $used
    projected_seconds = [math]::Round($elapsed * ([double]$used / $sampled), 0)
    note            = 'Estimate only: linear projection from the sample window to the volume used bytes.'
  }
}
$report | Add-Member -NotePropertyName estimate -NotePropertyValue $estimate -Force

Write-JsonAtomic -Path $OutFile -Object $report
Write-Status "JSON written: $OutFile"

$htmlOk = $false
if (-not $NoHtml) {
  try {
    . (Join-Path $PSScriptRoot 'report.ps1')
    Write-HtmlReport -Report $report -Path $HtmlFile
    Write-Status "HTML written: $HtmlFile"
    $htmlOk = $true
  } catch {
    Write-Host "WARN: HTML report failed: $($_.Exception.Message)" -ForegroundColor Yellow
  }
}

if ($Json) {
  $report | ConvertTo-Json -Depth 12
  exit 0
}

Write-Host ''
Write-Host '=== Result ===' -ForegroundColor Cyan
Write-Host ("Scanned {0:N0} files in {1:N0} directories, {2:N1} GB in {3:N1}s{4}" -f `
    $report.meta.files, $report.meta.dirs, ($report.meta.bytes / 1GB), $report.meta.elapsed_seconds,
    $(if ($report.meta.partial) { "  [PARTIAL: $($report.meta.partial_reason)]" } else { '' }))
if ($report.meta.cache_hits -gt 0) {
  Write-Host ("Cache: {0:N0} of {1:N0} directories reused" -f $report.meta.cache_hits, $report.meta.dirs) -ForegroundColor DarkGray
}
if ($report.meta.errors -gt 0) {
  Write-Host ("Unreadable entries skipped: {0:N0}" -f $report.meta.errors) -ForegroundColor Yellow
}
if ($estimate) {
  Write-Host ("Estimate: full scan of {0:N1} GB used would take about {1:N0}s" -f ($estimate.used_bytes / 1GB), $estimate.projected_seconds) -ForegroundColor Yellow
}

Write-Host ''
Write-Host '=== Risk distribution (bytes) ===' -ForegroundColor Cyan
$report.risk | ForEach-Object {
  $pct = if ($report.meta.bytes -gt 0) { 100.0 * $_.bytes / $report.meta.bytes } else { 0 }
  '{0,-8} {1,8:N1} GB  {2,6:N1}%  {3,9:N0} files  {4}' -f $_.level, ($_.bytes / 1GB), $pct, $_.files, $_.action
}

Write-Host ''
Write-Host '=== Top directories ===' -ForegroundColor Cyan
$report.tree | Where-Object { $_.path -and -not $_.parent } | Sort-Object bytes -Descending | Select-Object -First 15 | ForEach-Object {
  '{0,8:N1} GB  {1,9:N0} files  {2}' -f ($_.bytes / 1GB), $_.files, $_.name
}

Write-Host ''
Write-Host '=== Largest files ===' -ForegroundColor Cyan
$report.large | Select-Object -First 10 | ForEach-Object {
  '{0,8:N1} GB  {1,-7} {2}' -f ($_.bytes / 1GB), $_.risk, $_.path
}

if ($report.dups.Count -gt 0) {
  Write-Host ''
  Write-Host ("=== Duplicate candidates (same size, no hash): {0:N0} groups ===" -f $report.dups.Count) -ForegroundColor Cyan
  $report.dups | Select-Object -First 10 | ForEach-Object {
    '{0,8:N1} MB  x{1}  {2}' -f ($_.size / 1MB), $_.count, $_.paths[0]
  }
}

Write-Host ''
Write-Host 'Read-only audit: nothing was changed.' -ForegroundColor Green
if ($htmlOk) { Write-Host "Open the report: $HtmlFile" -ForegroundColor Green }
exit 0
