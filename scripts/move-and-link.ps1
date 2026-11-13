<#
.SYNOPSIS
  Move a folder to another volume and replace the original path with a directory
  junction. Dry-run by default. Crash-safe: every step is recorded before the next
  destructive action, and -Recover can finish or roll back an interrupted run.

.DESCRIPTION
  Recipe: validate -> persist "prepared" -> copy -> verify (paths/sizes, metadata,
  optional SHA-256) -> stage the original -> junction -> verify -> "committed".

  Reparse points inside the source are never followed. If any are found outside
  excluded directories, the script aborts. Excluded names (default: node_modules)
  are not copied and must be regenerated.

  Two ways to run:
    Direct : -Source ... -Destination ...
    Plan   : -PlanPath ... -PlanItemId ...   (approval bound to audited reality)

  Nothing changes without -Execute. Permanent source deletion additionally
  requires -StageMode Delete -ConfirmDelete '<exact source path>'.

.PARAMETER Source
  Existing folder to move.

.PARAMETER Destination
  New location (must not already exist).

.PARAMETER PlanPath
  Plan JSON created by make-plan.ps1.

.PARAMETER PlanItemId
  Item id inside the plan. Required when the plan has more than one item.

.PARAMETER StageMode
  Rename (default): rename the original in place to <name>.__prelink_<ts>.
    Instant, reversible, but space is NOT freed until purged.
  Quarantine: copy the original to -QuarantinePath, verify, then remove it.
    Frees the source volume while keeping a restorable copy.
  Delete: permanently remove the source after verification. Requires
    -ConfirmDelete with the exact source path.

.PARAMETER QuarantinePath
  Required for -StageMode Quarantine.

.PARAMETER Exclude
  Directory names skipped when copying. Default: node_modules.

.PARAMETER IncludeNodeModules
  Copy node_modules too (not recommended for pnpm projects).

.PARAMETER Verification
  Basic (paths/sizes), Standard (+ timestamps, default), Strict (+ SHA-256).

.PARAMETER NoAcl
  Do not copy NTFS ACLs (robocopy /COPY:DAT instead of /COPY:DATS).

.PARAMETER AllowRemovable
  Permit a removable destination (explicit risk acceptance).

.PARAMETER AcceptWarnings
  Proceed despite destination warnings (tight space, BitLocker, removable).

.PARAMETER CreateRestorePoint
  Create and verify a Windows restore point before acting. Requires admin and
  Windows PowerShell 5.1 restore-point cmdlets; a 24h cooldown can block it.

.PARAMETER ManifestPath
  Append-only JSONL event log. Default: %USERPROFILE%\_AI_Rollback\manifest.jsonl

.PARAMETER ManifestMirrorPath
  Optional second copy of the event log. Defaults to the profile copy when the
  main manifest is on another drive.

.PARAMETER MaxDriftPercent
  Abort if the source changed more than this since the plan/validation (default 2).

.PARAMETER Recover
  Diagnose an interrupted operation. Requires -OperationId and -Execute to mutate.

.PARAMETER OperationId
  Operation id to recover.

.PARAMETER DiscardPartialTarget
  With -Recover: delete a partial destination when the source is still intact.

.PARAMETER Execute
  Actually perform the operation. Without it the script only prints the plan.

.EXAMPLE
  .\move-and-link.ps1 -Source 'C:\Work\App' -Destination 'D:\Work\App'

.EXAMPLE
  .\move-and-link.ps1 -PlanPath "$env:USERPROFILE\_AI_Rollback\plan.json" -PlanItemId 'App-20261113-120000' -Execute

.EXAMPLE
  .\move-and-link.ps1 -Recover -OperationId 20261113-120000-abc123 -Execute
#>
[CmdletBinding()]
param(
  [string]$Source,
  [string]$Destination,
  [string]$PlanPath,
  [string]$PlanItemId,
  [ValidateSet('Rename', 'Quarantine', 'Delete')][string]$StageMode = 'Rename',
  [string]$QuarantinePath,
  [string[]]$Exclude = @('node_modules'),
  [switch]$IncludeNodeModules,
  [ValidateSet('Basic', 'Standard', 'Strict')][string]$Verification = 'Standard',
  [switch]$NoAcl,
  [switch]$AllowRemovable,
  [switch]$AcceptWarnings,
  [switch]$CreateRestorePoint,
  [string]$ManifestPath = (Join-Path $env:USERPROFILE '_AI_Rollback\manifest.jsonl'),
  [string]$ManifestMirrorPath,
  [double]$MaxDriftPercent = 2,
  [switch]$Recover,
  [string]$OperationId,
  [switch]$DiscardPartialTarget,
  [string]$ConfirmDelete,
  [switch]$Execute
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\common.ps1')

function Write-Step { param([string]$Message, [string]$Color = 'Gray') Write-Host $Message -ForegroundColor $Color }
function Fail { param([string]$Message, [int]$Code = 1) Write-Host "ABORT: $Message" -ForegroundColor Red; exit $Code }

if ($ManifestMirrorPath) {
  $ManifestMirrorPath = Get-FullPath $ManifestMirrorPath
} else {
  $candidate = Get-FullPath (Join-Path $env:USERPROFILE '_AI_Rollback\manifest.jsonl')
  if ($candidate -ne (Get-FullPath $ManifestPath)) { $ManifestMirrorPath = $candidate }
}
$ManifestPath = Get-FullPath $ManifestPath

function Restore-StagedTree {
  param([string]$Staged, [string]$Target)
  if (-not $Staged -or -not (Test-Path -LiteralPath $Staged)) { return $false }
  if (Test-Path -LiteralPath $Target) { return $false }
  $sameVolume = ([System.IO.Path]::GetPathRoot($Staged) -eq [System.IO.Path]::GetPathRoot($Target))
  try {
    if ($sameVolume) {
      Move-Item -LiteralPath $Staged -Destination $Target -ErrorAction Stop
    } else {
      New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Target) | Out-Null
      $rcArgs = @($Staged, $Target, '/E', '/COPY:DATS', '/DCOPY:T', '/XJ', '/R:2', '/W:2', '/NFL', '/NDL', '/NP', '/NJH')
      & robocopy @rcArgs | Out-Null
      if ($LASTEXITCODE -ge 8) { return $false }
      $cmp = Compare-Trees -Source $Staged -Destination $Target -Level 'Basic'
      if (-not $cmp.Ok) { return $false }
      Remove-TreeNoFollow -Path $Staged | Out-Null
    }
  } catch { return $false }
  return (Test-Path -LiteralPath $Target)
}

function Get-LastEvent {
  param($Events, [string]$Name)
  return (@($Events | Where-Object { $_.event -eq $Name }) | Select-Object -Last 1)
}

# ===========================================================================
# Recovery mode
# ===========================================================================
if ($Recover) {
  if (-not $OperationId) { Fail "-Recover requires -OperationId." }
  if (-not (Test-Path -LiteralPath $ManifestPath)) { Fail "Manifest not found: $ManifestPath" }

  $events = Read-ManifestEvents -Path $ManifestPath
  $states = Get-OperationStates -Events $events
  if (-not $states.ContainsKey($OperationId)) { Fail "Operation not found: $OperationId" }
  $st = $states[$OperationId]

  $prepared = Get-LastEvent -Events $st.Events -Name 'prepared'
  $committed = Get-LastEvent -Events $st.Events -Name 'committed'
  if (-not $prepared) { Fail "Operation $OperationId has no prepared event; cannot recover safely." }

  if ($committed -and -not $st.Restored) {
    Write-Host "Operation $OperationId is already committed. Nothing to recover." -ForegroundColor Green
    exit 0
  }

  $src = Get-FullPath $prepared.source
  $dst = Get-FullPath $prepared.target
  $staged = Get-FullPath $prepared.staged
  if (-not $staged) {
    $stagedEvent = Get-LastEvent -Events $st.Events -Name 'original_staged'
    if ($stagedEvent) { $staged = Get-FullPath $stagedEvent.staged }
  }

  $linkOk = $false
  if ($src -and (Test-Path -LiteralPath $src)) {
    $i = Get-Item -LiteralPath $src -Force
    if ($i.LinkType) {
      $actual = Get-LinkTarget $src
      $linkOk = ((Get-FullPath (($actual -split ',')[0])) -eq $dst)
    }
  }
  $sourceReal = ($src -and (Test-Path -LiteralPath $src) -and -not $linkOk)
  $targetExists = ($dst -and (Test-Path -LiteralPath $dst))
  $stagedExists = ($staged -and (Test-Path -LiteralPath $staged))

  Write-Host ''
  Write-Host "=== Recovery diagnosis: $OperationId ===" -ForegroundColor Cyan
  Write-Host ("source       : {0}  (exists={1}, junction_ok={2})" -f $src, (Test-Path -LiteralPath $src), $linkOk)
  Write-Host ("target       : {0}  (exists={1})" -f $dst, $targetExists)
  Write-Host ("staged       : {0}  (exists={1})" -f $staged, $stagedExists)
  Write-Host ("last state   : {0}" -f $st.LastState)
  Write-Host ''

  if (-not $Execute) {
    Write-Host 'DRY RUN - no changes. Add -Execute to apply the recovery action.' -ForegroundColor Yellow
    exit 0
  }

  if ($linkOk -and $targetExists) {
    # Verify counts through the junction and spot-read files. Do not enumerate the
    # junction for a full path map: some providers return target-based paths.
    $srcStats = Get-TreeStats -Path $src
    $dstStats = Get-TreeStats -Path $dst
    if ($srcStats.Files -ne $dstStats.Files -or $srcStats.Bytes -ne $dstStats.Bytes) {
      Fail "Junction exists but counts differ. Not committing. Inspect both paths." 2
    }
    $map = Get-FileMap -Root $dst
    foreach ($rel in (@($map.Map.Keys | Select-Object -First 3))) {
      $p = Join-Path $src $rel
      $fs = [System.IO.File]::Open($p, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
      try { $buf = New-Object byte[] 4096; [void]$fs.Read($buf, 0, $buf.Length) } finally { $fs.Dispose() }
    }
    Write-ManifestEvent -Path $ManifestPath -MirrorPath $ManifestMirrorPath -Event @{
      op = $OperationId; event = 'committed'; action = 'move+junction'
      source = $src; target = $dst; staged = $staged; stage_mode = $prepared.stage_mode
      files = $dstStats.Files; bytes = $dstStats.Bytes; excluded = ($prepared.exclude -join ',')
      verification = 'Basic'; verified = $true; purged = $false
      recovered = $true; rollback = 'L1'
    }
    Write-Step "RECOVERED: operation completed and committed." Green
    exit 0
  }

  if ($linkOk -and -not $targetExists) {
    try { [System.IO.Directory]::Delete($src, $false) } catch { }
    if ($stagedExists) {
      if (Restore-StagedTree -Staged $staged -Target $src) {
        Write-ManifestEvent -Path $ManifestPath -MirrorPath $ManifestMirrorPath -Event @{
          op = $OperationId; event = 'failed'; stage = 'recover'; message = 'Target was missing; link removed and staged original restored.'; rolled_back = $true
        }
        Write-Step "RECOVERED: broken link removed, staged original restored." Green
        exit 0
      }
    }
    Fail "Target missing and staged copy could not be restored. Data may be lost; stop and restore from backup." 3
  }

  if (-not (Test-Path -LiteralPath $src) -and $stagedExists) {
    if (Restore-StagedTree -Staged $staged -Target $src) {
      Write-ManifestEvent -Path $ManifestPath -MirrorPath $ManifestMirrorPath -Event @{
        op = $OperationId; event = 'failed'; stage = 'recover'; message = 'Interrupted before link creation; staged original restored.'; rolled_back = $true
      }
      Write-Step "RECOVERED: staged original moved back to $src." Green
      exit 0
    }
    Fail "Could not restore staged original to $src. Inspect $staged manually." 3
  }

  if ($sourceReal) {
    if ($targetExists -and $DiscardPartialTarget) {
      Write-Step "Discarding partial destination: $dst" Yellow
      $r = Remove-TreeNoFollow -Path $dst
      if (Test-Path -LiteralPath $dst) { Fail "Could not fully remove partial destination: $dst" 4 }
      Write-ManifestEvent -Path $ManifestPath -MirrorPath $ManifestMirrorPath -Event @{
        op = $OperationId; event = 'failed'; stage = 'recover'; message = 'Partial destination discarded; source intact.'; rolled_back = $true; partial_target_discarded = $true
      }
      Write-Step "RECOVERED: partial destination removed; source is intact." Green
      exit 0
    }
    Write-Host 'Source is intact (real directory). The destination may be a partial copy.' -ForegroundColor Yellow
    if ($targetExists) {
      Write-Host "To discard the partial copy and retry: -Recover -OperationId $OperationId -DiscardPartialTarget -Execute" -ForegroundColor Yellow
    }
    exit 0
  }

  if (-not $sourceReal -and -not $stagedExists -and $targetExists) {
    # Crash after the original was removed but before the junction existed.
    $stats = Get-TreeStats -Path $dst
    $expectedFiles = [int64]$prepared.expected_files
    $expectedBytes = [int64]$prepared.expected_bytes
    if ($expectedFiles -gt 0 -and ($stats.Files -ne $expectedFiles -or $stats.Bytes -ne $expectedBytes)) {
      Fail ("Destination does not match the prepared snapshot ({0} files/{1} bytes vs {2}/{3}). Refusing to link." -f $stats.Files, $stats.Bytes, $expectedFiles, $expectedBytes) 5
    }
    New-Item -ItemType Junction -Path $src -Target $dst -ErrorAction Stop | Out-Null
    $i = Get-Item -LiteralPath $src -Force
    if ($i.LinkType -ne 'Junction') { Fail "Junction verification failed after recovery." 5 }
    Write-ManifestEvent -Path $ManifestPath -MirrorPath $ManifestMirrorPath -Event @{
      op = $OperationId; event = 'committed'; action = 'move+junction'
      source = $src; target = $dst; staged = $null; stage_mode = $prepared.stage_mode
      files = $stats.Files; bytes = $stats.Bytes; excluded = ($prepared.exclude -join ',')
      verification = 'Basic'; verified = $true; purged = $true; recovered = $true; rollback = 'L1'
    }
    Write-Step "RECOVERED: junction recreated from the verified destination." Green
    exit 0
  }

  Fail "No safe automatic recovery is possible. Inspect the paths above; do not delete anything." 6
}

# ===========================================================================
# Normal mode: load and validate
# ===========================================================================
$planItem = $null
$planHash = $null
if ($PlanPath) {
  $planItem = Get-PlanItem -PlanPath $PlanPath -ItemId $PlanItemId
  $approval = Test-PlanApproval $planItem
  if (-not $approval.Ok) {
    if ($Execute) { Fail "$($approval.Reason) Run make-plan.ps1 -Approve -ApprovedBy '<name>' first." }
    Write-Host "WARN: $($approval.Reason) (dry run only)" -ForegroundColor Yellow
  } else {
    Write-Step "Plan approval: $($approval.Reason)" Green
  }
  $Source = $planItem.source
  $Destination = $planItem.destination
  $StageMode = $planItem.stage_mode
  $Verification = $planItem.verification
  if ($null -ne $planItem.exclude) { $Exclude = @($planItem.exclude) }
  $planHash = (Get-FileHash -LiteralPath $PlanPath -Algorithm SHA256).Hash
}

if (-not $Source -or -not $Destination) { Fail "Provide -Source/-Destination or -PlanPath." }

$src = Get-FullPath $Source
$dst = Get-FullPath $Destination
if (-not $src -or -not (Test-Path -LiteralPath $src)) { Fail "Source not found: $Source" }
if (-not $dst) { Fail "Invalid destination: $Destination" }

$srcItem = Get-Item -LiteralPath $src -Force
if (-not $srcItem.PSIsContainer) { Fail "Source is not a directory: $src" }
if (Test-ReparsePoint $srcItem) { Fail "Source is a reparse point ($(Get-LinkKind $src)). Refusing." }
if (Test-CloudPlaceholder $srcItem) { Fail "Source is a cloud placeholder; hydrate or exclude it first." }

$srcReal = Get-RealPath $src
if ($srcReal.LoopDetected) { Fail "Reparse loop while resolving: $src" }
$protected = Get-ProtectedPaths
if (Test-ProtectedPath -Path $src -Protected $protected) { Fail "Source is a protected path: $src" }
if (Test-ProtectedPath -Path $srcReal.Path -Protected $protected) { Fail "Source resolves to a protected path: $($srcReal.Path)" }

if ($dst.Length -le 3) { Fail "Destination cannot be a drive root: $dst" }
if (Test-Path -LiteralPath $dst) { Fail "Destination already exists: $dst" }
if ($dst.StartsWith($src + '\', [StringComparison]::OrdinalIgnoreCase)) { Fail "Destination is inside the source." }
if ($src.StartsWith($dst + '\', [StringComparison]::OrdinalIgnoreCase)) { Fail "Source is inside the destination." }

$dstReal = Get-RealPath $dst
if ($dstReal.LoopDetected) { Fail "Reparse loop while resolving destination: $dst" }
if ($dstReal.Path.StartsWith($srcReal.Path + '\', [StringComparison]::OrdinalIgnoreCase)) { Fail "Destination resolves inside the source." }

$excludes = @()
if (-not $IncludeNodeModules) { $excludes = @($Exclude) }

$stats = Get-TreeStats -Path $src -ExcludeNames $excludes -PhysicalSize
$required = [math]::Max($stats.Bytes, $stats.PhysicalBytes)

$inv = @(Get-ReparseInventory -Root $src -ExcludeNames $excludes)
if ($inv.Count -gt 0) {
  Write-Host "Reparse points inside the source (outside excluded directories):" -ForegroundColor Yellow
  $inv | ForEach-Object { Write-Host ("  {0} [{1}] -> {2}" -f $_.Path, $_.Kind, $_.Target) -ForegroundColor Yellow }
  Fail "Refusing to copy a tree with reparse points. Move/materialize them separately first."
}

$elig = Test-DestinationDrive -Destination $dst -RequiredBytes $required -AllowRemovable:$AllowRemovable
if (-not $elig.Ok) {
  foreach ($e in $elig.Errors) { Write-Host "  - $e" -ForegroundColor Red }
  Fail "Destination is not eligible."
}

$srcVol = Get-VolumeInfo $src
$dstVol = $elig.Volume
if ($srcVol.Drive -eq $dstVol.Drive) {
  Write-Host 'NOTE: source and destination are on the same volume; a junction saves no space here.' -ForegroundColor Yellow
}

# Plan drift / identity checks.
if ($planItem) {
  if ($planItem.source_volume_serial -and $srcVol.Serial -ne $planItem.source_volume_serial) {
    Fail "Source volume serial changed since the plan ($($planItem.source_volume_serial) -> $($srcVol.Serial)). Re-plan."
  }
  if ($planItem.target_volume_serial -and $dstVol.Serial -ne $planItem.target_volume_serial) {
    Fail "Target volume serial changed since the plan ($($planItem.target_volume_serial) -> $($dstVol.Serial)). Re-plan."
  }
  if ($planItem.source_creation_utc) {
    $planned = [datetime]::Parse($planItem.source_creation_utc).ToUniversalTime()
    if ([math]::Abs(($srcItem.CreationTimeUtc - $planned).TotalSeconds) -gt 2) {
      Fail "Source creation time changed since the plan; the path may have been replaced. Re-plan."
    }
  }
  if ($planItem.expected_bytes -gt 0) {
    $drift = [math]::Abs($stats.Bytes - [int64]$planItem.expected_bytes) / [double]$planItem.expected_bytes * 100
    if ($drift -gt $MaxDriftPercent) {
      Fail ("Source size drifted {0:N1}% since the plan (limit {1}%). Re-run make-plan.ps1." -f $drift, $MaxDriftPercent)
    }
  }
  if ($planItem.expected_files -gt 0) {
    $fileDrift = [math]::Abs($stats.Files - [int64]$planItem.expected_files) / [double]$planItem.expected_files * 100
    if ($fileDrift -gt $MaxDriftPercent) {
      Fail ("Source file count drifted {0:N1}% since the plan (limit {1}%). Re-run make-plan.ps1." -f $fileDrift, $MaxDriftPercent)
    }
  }
}

# Refuse to start while another transaction for this source is open.
$events = Read-ManifestEvents -Path $ManifestPath
$states = Get-OperationStates -Events $events
foreach ($op in $states.Keys) {
  $ost = $states[$op]
  if (-not $ost.Open) { continue }
  $p = Get-LastEvent -Events $ost.Events -Name 'prepared'
  if ($p -and (Get-FullPath $p.source) -eq $src) {
    Fail "An unfinished operation already exists for $src (id $op). Use -Recover -OperationId $op -Execute, or finish it manually."
  }
}

# Quarantine path validation.
$qRoot = $null
if ($StageMode -eq 'Quarantine') {
  if (-not $QuarantinePath) { Fail "-StageMode Quarantine requires -QuarantinePath." }
  $qRoot = Get-FullPath $QuarantinePath
  if (-not $qRoot) { Fail "Invalid quarantine path." }
  if ($qRoot.StartsWith($src + '\', [StringComparison]::OrdinalIgnoreCase)) { Fail "Quarantine path is inside the source." }
  if ($dst.StartsWith($qRoot + '\', [StringComparison]::OrdinalIgnoreCase) -or $qRoot.StartsWith($dst + '\', [StringComparison]::OrdinalIgnoreCase)) {
    Fail "Quarantine path and destination overlap."
  }
  $qElig = Test-DestinationDrive -Destination $qRoot -RequiredBytes $required -AllowRemovable:$AllowRemovable
  if (-not $qElig.Ok) {
    foreach ($e in $qElig.Errors) { Write-Host "  - $e" -ForegroundColor Red }
    Fail "Quarantine destination is not eligible."
  }
  $qVol = $qElig.Volume
  if ($qVol.Drive -eq $srcVol.Drive) {
    Write-Host 'NOTE: quarantine is on the source volume; no space is freed until it is purged.' -ForegroundColor Yellow
  }
}

if ($StageMode -eq 'Delete') {
  if (-not $ConfirmDelete -or $ConfirmDelete -cne $src) {
    Fail "Permanent deletion requires -ConfirmDelete '$src' (exact path)."
  }
}

# ===========================================================================
# Plan output / dry run
# ===========================================================================
$op = Get-NewOperationId
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'

Write-Host ''
Write-Host '=== Plan ===' -ForegroundColor Cyan
Write-Host ("operation   : {0}" -f $op)
Write-Host ("source      : {0}" -f $src)
Write-Host ("  real path : {0}" -f $srcReal.Path)
Write-Host ("destination : {0}" -f $dst)
Write-Host ("  real path : {0}" -f $dstReal.Path)
Write-Host ("stage mode  : {0}" -f $StageMode)
Write-Host ("verification: {0}" -f $Verification)
Write-Host ("size        : {0} files / {1:N2} GB logical / {2:N2} GB allocated" -f $stats.Files, ($stats.Bytes / 1GB), ($stats.PhysicalBytes / 1GB))
if ($excludes.Count -gt 0) { Write-Host ("excluded    : {0}" -f ($excludes -join ', ')) }
if ($qRoot) { Write-Host ("quarantine  : {0}" -f $qRoot) }
Write-Host ("source vol  : {0} {1} (serial {2})" -f $srcVol.Drive, $srcVol.FileSystem, $srcVol.Serial)
Write-Host ("target vol  : {0} {1} {2} (serial {3})" -f $dstVol.Drive, $dstVol.DriveType, $dstVol.FileSystem, $dstVol.Serial)
Write-Host ("manifest    : {0}" -f $ManifestPath)
if ($ManifestMirrorPath) { Write-Host ("mirror      : {0}" -f $ManifestMirrorPath) }
Write-Host ''

foreach ($w in $elig.Warnings) { Write-Host "WARN: $w" -ForegroundColor Yellow }
if ($srcReal.Links.Count -gt 0) {
  Write-Host 'Ancestor reparse points on the source path:' -ForegroundColor Yellow
  foreach ($l in $srcReal.Links) { Write-Host ("  {0} [{1}] -> {2}" -f $l.Path, $l.Kind, $l.Target) -ForegroundColor Yellow }
}

if (-not $Execute) {
  Write-Host 'DRY RUN - nothing changed. Add -Execute to perform the move.' -ForegroundColor Green
  exit 0
}

if ($elig.Warnings.Count -gt 0 -and -not $AcceptWarnings) {
  Fail "Destination has warnings. Review them, then add -AcceptWarnings to proceed."
}

# ===========================================================================
# Execute
# ===========================================================================
if ($CreateRestorePoint) {
  if (-not (Test-IsAdmin)) { Fail "-CreateRestorePoint requires an elevated shell." }
  if (-not (Get-Command Checkpoint-Computer -ErrorAction SilentlyContinue) -or
      -not (Get-Command Get-ComputerRestorePoint -ErrorAction SilentlyContinue)) {
    Fail "Restore-point cmdlets are unavailable. Use Windows PowerShell 5.1 as admin, or skip this layer."
  }
  $started = Get-Date
  try {
    Checkpoint-Computer -Description "disk-cleanup_$timestamp" -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
  } catch {
    Fail "Could not create a restore point: $($_.Exception.Message). Create one manually or continue without it."
  }
  $rp = Get-ComputerRestorePoint -ErrorAction SilentlyContinue | Sort-Object CreationTime -Descending | Select-Object -First 1
  if (-not $rp -or $rp.CreationTime -lt $started.AddMinutes(-2)) {
    Fail "Restore point was not verified (System Protection off or 24h cooldown). Create one manually."
  }
  Write-Step "Restore point verified: $($rp.Description)" Green
}

$prepared = @{
  op = $op
  event = 'prepared'
  source = $src
  source_real = $srcReal.Path
  target = $dst
  target_real = $dstReal.Path
  stage_mode = $StageMode
  exclude = @($excludes)
  verification = $Verification
  expected_files = [int64]$stats.Files
  expected_bytes = [int64]$stats.Bytes
  expected_physical_bytes = [int64]$stats.PhysicalBytes
  source_volume = $srcVol.Drive
  source_volume_serial = $srcVol.Serial
  target_volume = $dstVol.Drive
  target_volume_serial = $dstVol.Serial
  target_drive_type = $dstVol.DriveType
  target_filesystem = $dstVol.FileSystem
  quarantine = $qRoot
  plan_path = $PlanPath
  plan_sha256 = $planHash
  plan_item_id = $(if ($planItem) { $planItem.id } else { $null })
  risk = $(if ($planItem) { $planItem.risk } else { 'Medium' })
  rollback = 'L1'
}
Write-ManifestEvent -Path $ManifestPath -MirrorPath $ManifestMirrorPath -Event $prepared

$stage = 'copying'
$staged = $null
$copyStats = $null

try {
  # ---- copy -------------------------------------------------------------
  Write-Step 'Copying (robocopy)...' Cyan
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null

  $rcArgs = @($src, $dst, '/E', '/DCOPY:T', '/R:2', '/W:2', '/XJ', '/NFL', '/NDL', '/NP', '/NJH')
  if ($NoAcl) { $rcArgs += '/COPY:DAT' } else { $rcArgs += '/COPY:DATS' }
  foreach ($e in $excludes) { $rcArgs += @('/XD', $e) }

  & robocopy @rcArgs | Out-Null
  $rc = $LASTEXITCODE
  if ($rc -ge 8) { throw "robocopy failed with exit code $rc" }
  if ($rc -ge 4) { Write-Host "WARN: robocopy exit code $rc (some files/dirs mismatched); verification will decide." -ForegroundColor Yellow }

  # ---- verify copy ------------------------------------------------------
  $stage = 'copy_verified'
  Write-Step "Verifying copy ($Verification)..." Cyan
  $cmp = Compare-Trees -Source $src -Destination $dst -ExcludeNames $excludes -Level $Verification
  if (-not $cmp.Ok) {
    Write-Host ("  files: source {0} / destination {1}" -f $cmp.Files, (Get-TreeStats -Path $dst).Files) -ForegroundColor Red
    foreach ($m in $cmp.Mismatches) { Write-Host ("  mismatch: {0} {1}" -f $m.Kind, ($m.Path)) -ForegroundColor Red }
    foreach ($m in $cmp.Missing) { Write-Host ("  missing : {0}" -f $m) -ForegroundColor Red }
    foreach ($m in $cmp.Extra) { Write-Host ("  extra   : {0}" -f $m) -ForegroundColor Red }
    throw "Copy verification failed ($($cmp.MismatchCount) mismatches, $($cmp.MissingCount) missing, $($cmp.ExtraCount) extra)"
  }
  $copyStats = $cmp
  Write-Step ("Verified: {0} files / {1:N2} GB" -f $cmp.Files, ($cmp.Bytes / 1GB)) Green
  Write-ManifestEvent -Path $ManifestPath -MirrorPath $ManifestMirrorPath -Event @{
    op = $op; event = 'copy_verified'; files = $cmp.Files; bytes = $cmp.Bytes
    verification = $Verification; mismatches = 0
  }

  # ---- revalidate source immediately before staging ---------------------
  $stage = 'staging'
  $nowItem = Get-Item -LiteralPath $src -Force
  if (-not $nowItem.PSIsContainer -or (Test-ReparsePoint $nowItem)) { throw "Source changed type or became a link during the copy." }
  $nowVol = Get-VolumeInfo $src
  if ($nowVol.Serial -ne $srcVol.Serial) { throw "Source volume serial changed during the copy." }
  $nowStats = Get-TreeStats -Path $src -ExcludeNames $excludes -PhysicalSize
  $drift = 0
  if ($stats.Bytes -gt 0) { $drift = [math]::Abs($nowStats.Bytes - $stats.Bytes) / [double]$stats.Bytes * 100 }
  if ($drift -gt $MaxDriftPercent -or $nowStats.Files -ne $stats.Files) {
    throw ("Source changed during the copy ({0} -> {1} files, drift {2:N1}%). Re-plan and retry." -f $stats.Files, $nowStats.Files, $drift)
  }

  # ---- stage the original ----------------------------------------------
  switch ($StageMode) {
    'Rename' {
      $staged = Join-Path (Split-Path -Parent $src) ("{0}.__prelink_{1}" -f (Split-Path -Leaf $src), $timestamp)
      if (Test-Path -LiteralPath $staged) { throw "Staging path already exists: $staged" }
      Rename-Item -LiteralPath $src -NewName (Split-Path -Leaf $staged) -ErrorAction Stop
      if (Test-Path -LiteralPath $src) { throw "Source still exists after rename." }
      Write-Step "Original renamed to: $staged" Yellow
    }
    'Quarantine' {
      New-Item -ItemType Directory -Force -Path $qRoot | Out-Null
      $staged = Join-Path $qRoot ("{0}__{1}" -f (Split-Path -Leaf $src), $timestamp)
      if (Test-Path -LiteralPath $staged) { throw "Staging path already exists: $staged" }
      $qArgs = @($src, $staged, '/E', '/DCOPY:T', '/R:2', '/W:2', '/XJ', '/NFL', '/NDL', '/NP', '/NJH')
      if ($NoAcl) { $qArgs += '/COPY:DAT' } else { $qArgs += '/COPY:DATS' }
      foreach ($e in $excludes) { $qArgs += @('/XD', $e) }
      & robocopy @qArgs | Out-Null
      if ($LASTEXITCODE -ge 8) { throw "Quarantine copy failed with exit code $LASTEXITCODE" }
      $qcmp = Compare-Trees -Source $src -Destination $staged -ExcludeNames $excludes -Level 'Basic'
      if (-not $qcmp.Ok) { throw "Quarantine copy verification failed." }
      $removed = Remove-TreeNoFollow -Path $src
      if (Test-Path -LiteralPath $src) { throw "Could not fully remove source (locked files?); staged copy is at $staged." }
      Write-Step "Original quarantined to: $staged" Yellow
    }
    'Delete' {
      $removed = Remove-TreeNoFollow -Path $src
      if (Test-Path -LiteralPath $src) { throw "Could not fully remove source (locked files?). Junction not created." }
      Write-Step 'Original deleted (confirmed StageMode=Delete).' Yellow
    }
  }

  Write-ManifestEvent -Path $ManifestPath -MirrorPath $ManifestMirrorPath -Event @{
    op = $op; event = 'original_staged'; stage_mode = $StageMode; staged = $staged
    files = $stats.Files; bytes = $stats.Bytes
  }

  # ---- create junction --------------------------------------------------
  $stage = 'link'
  if (Test-Path -LiteralPath $src) { throw "Source path exists before junction creation: $src" }
  New-Item -ItemType Junction -Path $src -Target $dst -ErrorAction Stop | Out-Null
  $linkItem = Get-Item -LiteralPath $src -Force
  if ($linkItem.LinkType -ne 'Junction') { throw "Junction verification failed (LinkType=$($linkItem.LinkType))." }
  $actualTarget = Get-FullPath ((Get-LinkTarget $src) -split ',')[0]
  if ($actualTarget -ne $dst) { throw "Junction target mismatch: $actualTarget (expected $dst)." }
  Write-ManifestEvent -Path $ManifestPath -MirrorPath $ManifestMirrorPath -Event @{
    op = $op; event = 'link_created'; link_type = 'Junction'; target = $dst
  }

  # ---- post-link verification ------------------------------------------
  $stage = 'verifying'
  $final = Compare-Trees -Source $src -Destination $dst -Level $Verification
  if (-not $final.Ok) { throw "Post-link verification failed." }

  # Spot-read a few files through the junction.
  $map = Get-FileMap -Root $dst
  $spot = @($map.Map.Keys | Select-Object -First 3)
  foreach ($rel in $spot) {
    $p = Join-Path $src $rel
    $fs = [System.IO.File]::Open($p, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
      $buf = New-Object byte[] 4096
      [void]$fs.Read($buf, 0, $buf.Length)
    } finally { $fs.Dispose() }
  }

  Write-ManifestEvent -Path $ManifestPath -MirrorPath $ManifestMirrorPath -Event @{
    op = $op; event = 'verified'; verification = $Verification; files = $final.Files; bytes = $final.Bytes; spot_reads = $spot.Count
  }

  # ---- commit -----------------------------------------------------------
  Write-ManifestEvent -Path $ManifestPath -MirrorPath $ManifestMirrorPath -Event @{
    op = $op; event = 'committed'; action = 'move+junction'
    source = $src; target = $dst; staged = $staged; stage_mode = $StageMode
    files = $final.Files; bytes = $final.Bytes; excluded = ($excludes -join ',')
    verification = $Verification; link_type = 'Junction'
    source_volume = $srcVol.Drive; source_volume_serial = $srcVol.Serial
    target_volume = $dstVol.Drive; target_volume_serial = $dstVol.Serial
    target_drive_type = $dstVol.DriveType; target_filesystem = $dstVol.FileSystem
    plan_path = $PlanPath; plan_sha256 = $planHash; plan_item_id = $(if ($planItem) { $planItem.id } else { $null })
    rollback = 'L1'; verified = $true; purged = $false
  }

  Write-Host ''
  Write-Host "DONE: $src -> $dst" -ForegroundColor Green
  Write-Host ("Junction verified. {0} files / {1:N2} GB." -f $final.Files, ($final.Bytes / 1GB)) -ForegroundColor Green
  if ($StageMode -eq 'Rename') {
    Write-Host "Rollback copy: $staged" -ForegroundColor Yellow
    Write-Host "  Space is NOT freed until you purge it:" -ForegroundColor Yellow
    Write-Host "  .\purge-staged.ps1 -ManifestPath '$ManifestPath' -Id $op -ConfirmPurge $op -Execute" -ForegroundColor Yellow
  } elseif ($StageMode -eq 'Quarantine') {
    Write-Host "Rollback copy: $staged (purge after verification)." -ForegroundColor Yellow
  } else {
    Write-Host 'Source permanently deleted (StageMode=Delete).' -ForegroundColor Yellow
  }
  if ($excludes.Count -gt 0) {
    Write-Host ("Excluded: {0} - regenerate them (e.g. pnpm install --prefer-offline)." -f ($excludes -join ', ')) -ForegroundColor Yellow
  }
  exit 0
} catch {
  $message = $_.Exception.Message
  Write-Host ''
  Write-Host "FAILED at stage '$stage': $message" -ForegroundColor Red

  # Roll back without ever traversing a link.
  $actions = New-Object System.Collections.Generic.List[string]
  $rolledBack = $false
  $needsManual = $false

  if ($src -and (Test-Path -LiteralPath $src)) {
    $cur = Get-Item -LiteralPath $src -Force
    if ($cur.LinkType) {
      try {
        [System.IO.Directory]::Delete($src, $false)
        $actions.Add('removed junction (link only)')
      } catch { $actions.Add("could not remove junction: $($_.Exception.Message)") }
    }
  }

  $srcExists = ($src -and (Test-Path -LiteralPath $src))
  if (-not $srcExists -and $staged -and (Test-Path -LiteralPath $staged)) {
    if (Restore-StagedTree -Staged $staged -Target $src) {
      $actions.Add('restored staged original')
      $rolledBack = $true
    } else {
      $actions.Add('could not restore staged original')
      $needsManual = $true
    }
  } elseif ($srcExists) {
    $cur = Get-Item -LiteralPath $src -Force
    if (-not $cur.LinkType) {
      if ($staged -and (Test-Path -LiteralPath $staged)) {
        # Source survived (e.g. locked files during Delete/Quarantine).
        $actions.Add('source still present; staged copy retained')
        $needsManual = $true
      } else {
        $actions.Add('source intact')
        $rolledBack = $true
      }
    }
  }

  Write-ManifestEvent -Path $ManifestPath -MirrorPath $ManifestMirrorPath -Event @{
    op = $op; event = 'failed'; stage = $stage; message = $message
    source = $src; target = $dst; staged = $staged; stage_mode = $StageMode
    rolled_back = $rolledBack; needs_manual = $needsManual
    actions = ($actions -join '; '); partial_target = (Test-Path -LiteralPath $dst)
  }

  foreach ($a in $actions) { Write-Host "  $a" -ForegroundColor Yellow }
  if ($needsManual) {
    Write-Host 'Manual attention required. Do not delete anything; inspect the paths above.' -ForegroundColor Red
    Write-Host "Staged copy: $staged" -ForegroundColor Red
    Write-Host "Destination: $dst" -ForegroundColor Red
    Write-Host "Recovery: .\move-and-link.ps1 -Recover -OperationId $op" -ForegroundColor Red
  } elseif ($rolledBack) {
    Write-Host 'Rolled back; the original path is usable again.' -ForegroundColor Yellow
  }
  exit 3
}
