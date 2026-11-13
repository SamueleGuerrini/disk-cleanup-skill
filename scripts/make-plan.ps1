<#
.SYNOPSIS
  Create (or update) a machine-readable cleanup plan and optionally approve one
  item. The executor (move-and-link.ps1) consumes this plan so approval is bound
  to the exact audited paths, sizes, and volume identities.

.DESCRIPTION
  Read-only with respect to the filesystem being cleaned. It only writes the plan
  JSON. It records canonical/real paths, volume serials, file/byte counts,
  exclusions, verification level, risk, and rollback layer.

  An item is not approved until -Approve -ApprovedBy "<name>" is supplied. The
  approval stores a SHA-256 of the item's canonical fields; move-and-link.ps1
  refuses to run if the item changes afterwards.

.PARAMETER Source
  Folder to move.

.PARAMETER Destination
  New location (must not already exist).

.PARAMETER StageMode
  Rename (default), Quarantine, or Delete. Delete requires separate confirmation
  at execution time.

.PARAMETER Exclude
  Directory names excluded from the move. Default: node_modules.

.PARAMETER IncludeNodeModules
  Copy node_modules too (not recommended for pnpm projects).

.PARAMETER Verification
  Basic, Standard (default), or Strict (SHA-256).

.PARAMETER OutFile
  Plan JSON path. Default: %USERPROFILE%\_AI_Rollback\plan.json

.PARAMETER Approve
  Mark the item as approved. Requires -ApprovedBy.

.PARAMETER Force
  Replace an existing item with the same id.

.EXAMPLE
  .\make-plan.ps1 -Source 'C:\Work\App' -Destination 'D:\Work\App'

.EXAMPLE
  .\make-plan.ps1 -Source 'C:\Work\App' -Destination 'D:\Work\App' `
      -Approve -ApprovedBy 'Samuele'
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Source,
  [Parameter(Mandatory = $true)][string]$Destination,
  [ValidateSet('Rename', 'Quarantine', 'Delete')][string]$StageMode = 'Rename',
  [string[]]$Exclude = @('node_modules'),
  [switch]$IncludeNodeModules,
  [ValidateSet('Basic', 'Standard', 'Strict')][string]$Verification = 'Standard',
  [string]$Risk = 'Medium',
  [string]$Rollback = 'L1',
  [string]$OutFile = (Join-Path $env:USERPROFILE '_AI_Rollback\plan.json'),
  [string]$PlanItemId,
  [string]$ApprovedBy,
  [switch]$Approve,
  [switch]$Force,
  [switch]$Json
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\common.ps1')

function Fail { param([string]$Message, [int]$Code = 1) Write-Host "ERROR: $Message" -ForegroundColor Red; exit $Code }

$src = Get-FullPath $Source
$dst = Get-FullPath $Destination
if (-not $src -or -not (Test-Path -LiteralPath $src)) { Fail "Source not found: $Source" }
if (-not $dst) { Fail "Invalid destination: $Destination" }

$srcItem = Get-Item -LiteralPath $src -Force
if (-not $srcItem.PSIsContainer) { Fail "Source is not a directory: $src" }
if (Test-ReparsePoint $srcItem) { Fail "Source is a reparse point ($(Get-LinkKind $src)). Refusing to plan a link as a move source." }
if (Test-CloudPlaceholder $srcItem) { Fail "Source is a cloud placeholder. Hydrate it or exclude it before planning." }

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
$inv = @(Get-ReparseInventory -Root $src -ExcludeNames $excludes)
if ($inv.Count -gt 0) {
  Write-Host "Reparse points inside the source (outside excluded directories):" -ForegroundColor Yellow
  $inv | ForEach-Object { Write-Host ("  {0} [{1}] -> {2}" -f $_.Path, $_.Kind, $_.Target) -ForegroundColor Yellow }
  Fail "Refusing to plan a tree with reparse points. Move/materialize them separately first."
}

$elig = Test-DestinationDrive -Destination $dst -RequiredBytes $stats.Bytes
if (-not $elig.Ok) {
  foreach ($e in $elig.Errors) { Write-Host "  - $e" -ForegroundColor Red }
  Fail "Destination is not eligible."
}

$srcVol = Get-VolumeInfo $src
$dstVol = $elig.Volume

$id = $PlanItemId
if (-not $id) {
  $slug = (Split-Path -Leaf $src) -replace '[^A-Za-z0-9._-]', '-'
  if ($slug.Length -gt 40) { $slug = $slug.Substring(0, 40) }
  $id = "$slug-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
}

$item = [pscustomobject][ordered]@{
  id                       = $id
  source                   = $src
  source_real              = $srcReal.Path
  destination              = $dst
  destination_real         = $dstReal.Path
  stage_mode               = $StageMode
  exclude                  = @($excludes)
  verification             = $Verification
  risk                     = $Risk
  rollback                 = $Rollback
  expected_files           = [int64]$stats.Files
  expected_dirs            = [int64]$stats.Dirs
  expected_bytes           = [int64]$stats.Bytes
  expected_physical_bytes  = [int64]$stats.PhysicalBytes
  sparse_files             = [int64]$stats.SparseFiles
  offline_files            = [int64]$stats.OfflineFiles
  source_volume            = $srcVol.Drive
  source_volume_serial     = $srcVol.Serial
  source_creation_utc      = $srcItem.CreationTimeUtc.ToString('o')
  target_volume            = $dstVol.Drive
  target_volume_serial     = $dstVol.Serial
  target_drive_type        = $dstVol.DriveType
  target_filesystem        = $dstVol.FileSystem
  created_at               = (Get-Date).ToString('o')
  created_by               = "$env:USERNAME@$env:COMPUTERNAME"
}

if ($Approve) {
  if (-not $ApprovedBy) { Fail "-Approve requires -ApprovedBy '<name>'." }
  $item | Add-Member -NotePropertyName approval -NotePropertyValue ([pscustomobject]@{
      approved_by = $ApprovedBy
      approved_at = (Get-Date).ToString('o')
      item_sha256 = (Get-ItemHash $item)
    }) -Force
}

$plan = $null
if (Test-Path -LiteralPath $OutFile) {
  try { $plan = ConvertFrom-JsonSafe (Get-Content -LiteralPath $OutFile -Raw) } catch { Fail "Existing plan is not valid JSON: $OutFile" }
} else {
  $plan = [pscustomobject][ordered]@{
    version    = 1
    created_at = (Get-Date).ToString('o')
    items      = @()
  }
}

$items = @($plan.items)
$existing = @($items | Where-Object { $_.id -eq $id })
if ($existing.Count -gt 0 -and -not $Force) {
  Fail "Plan already has an item with id '$id'. Use -Force to replace it."
}
$items = @($items | Where-Object { $_.id -ne $id })
$items += $item
$plan.items = $items

Write-JsonAtomic -Path $OutFile -Object $plan

if ($Json) {
  $item | ConvertTo-Json -Depth 12
  exit 0
}

Write-Host ''
Write-Host '=== Plan item ===' -ForegroundColor Cyan
Write-Host ("id           : {0}" -f $item.id)
Write-Host ("source       : {0}" -f $item.source)
Write-Host ("  real path  : {0}" -f $item.source_real)
Write-Host ("destination  : {0}" -f $item.destination)
Write-Host ("  real path  : {0}" -f $item.destination_real)
Write-Host ("size         : {0} files / {1:N2} GB logical / {2:N2} GB allocated" -f $item.expected_files, ($item.expected_bytes / 1GB), ($item.expected_physical_bytes / 1GB))
Write-Host ("excluded     : {0}" -f $(if ($item.exclude.Count) { $item.exclude -join ', ' } else { '(none)' }))
Write-Host ("verification : {0}" -f $item.verification)
Write-Host ("risk         : {0} / rollback {1}" -f $item.risk, $item.rollback)
Write-Host ("source volume: {0} (serial {1})" -f $item.source_volume, $item.source_volume_serial)
Write-Host ("target volume: {0} {1} {2} (serial {3})" -f $item.target_volume, $item.target_drive_type, $item.target_filesystem, $item.target_volume_serial)

foreach ($w in $elig.Warnings) { Write-Host "WARN: $w" -ForegroundColor Yellow }
if ($srcVol.Drive -eq $dstVol.Drive) {
  Write-Host 'NOTE: source and destination are on the same volume; a junction saves no space here.' -ForegroundColor Yellow
}
if ($item.sparse_files -gt 0) {
  Write-Host ("WARN: {0} sparse file(s) detected; the copy may use more physical space than the source." -f $item.sparse_files) -ForegroundColor Yellow
}
if ($item.offline_files -gt 0) {
  Write-Host ("WARN: {0} cloud/offline file(s) detected; copying may hydrate them and consume bandwidth/space." -f $item.offline_files) -ForegroundColor Yellow
}

Write-Host ''
Write-Host ("Plan written: {0}" -f $OutFile) -ForegroundColor Green
if ($Approve) {
  Write-Host ("APPROVED by {0}. The executor will reject this item if it changes." -f $ApprovedBy) -ForegroundColor Green
} else {
  Write-Host 'NOT APPROVED. Review the item, then re-run with:' -ForegroundColor Yellow
  Write-Host ("  .\make-plan.ps1 -Source '{0}' -Destination '{1}' -Approve -ApprovedBy '<your name>'" -f $src, $dst) -ForegroundColor Yellow
}
exit 0
