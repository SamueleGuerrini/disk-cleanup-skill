<#
.SYNOPSIS
  Permanently purge a staged/quarantined rollback copy from the manifest.

.DESCRIPTION
  This is the only script that performs irreversible deletion, and it is
  deliberately hard to run by accident:

    - requires -Execute and -ConfirmPurge <operation-id> (or ALL),
    - refuses unless the original path is still a junction pointing at the
      recorded target and that target exists,
    - deletes without ever following reparse points (nested junctions/symlinks
      are unlinked, not traversed),
    - records a purge event in the manifest.

  Purging is never automatic and never based on a timer. Keep the rollback copy
  until you have verified the application and data for as long as you need.

.PARAMETER ManifestPath
  JSONL manifest written by move-and-link.ps1.

.PARAMETER Id
  Operation id to purge. Required unless -All is used.

.PARAMETER All
  Purge every eligible staged copy.

.PARAMETER ConfirmPurge
  Must equal the operation id, or ALL when -All is used.

.PARAMETER AllowMissingLink
  Allow purging when the original junction is missing or wrong. This destroys the
  last local rollback copy; use only when the live data is verified elsewhere.

.PARAMETER Execute
  Actually delete. Without it, prints the plan.

.EXAMPLE
  .\purge-staged.ps1 -ManifestPath D:\_AI_Rollback\manifest.jsonl -Id 20261113-013000-abc123

.EXAMPLE
  .\purge-staged.ps1 -ManifestPath D:\_AI_Rollback\manifest.jsonl -Id 20261113-013000-abc123 -ConfirmPurge 20261113-013000-abc123 -Execute
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$ManifestPath,
  [string]$Id,
  [switch]$All,
  [string]$ConfirmPurge,
  [switch]$AllowMissingLink,
  [switch]$Execute
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\common.ps1')

function Fail { param([string]$Message, [int]$Code = 1) Write-Host "ABORT: $Message" -ForegroundColor Red; exit $Code }

if (-not (Test-Path -LiteralPath $ManifestPath)) { Fail "Manifest not found: $ManifestPath" }
if (-not $Id -and -not $All) { Fail "Specify -Id <operation id> or -All." }
if (-not $ConfirmPurge) { Fail "Purging is irreversible. Add -ConfirmPurge <operation-id> (or ALL)." }
if ($All -and $ConfirmPurge -ne 'ALL') { Fail "-All requires -ConfirmPurge ALL." }
if ($Id -and $ConfirmPurge -ne $Id) { Fail "-ConfirmPurge must exactly match the operation id." }

$events = Read-ManifestEvents -Path $ManifestPath
$states = Get-OperationStates -Events $events

$candidates = New-Object System.Collections.Generic.List[object]
foreach ($op in $states.Keys) {
  $st = $states[$op]
  if (-not $st.Committed -or $st.Restored -or $st.Purged) { continue }
  if ($Id -and $op -ne $Id) { continue }
  $committed = @($st.Events | Where-Object { $_.event -eq 'committed' }) | Select-Object -Last 1
  if (-not $committed -or -not $committed.staged) { continue }
  $candidates.Add($committed)
}

if ($candidates.Count -eq 0) { Fail "No purgable staged copies found for the selection." }

Write-Host ''
Write-Host '=== Purge plan (IRREVERSIBLE) ===' -ForegroundColor Red
foreach ($c in $candidates) {
  $staged = Get-FullPath $c.staged
  $size = if ($staged -and (Test-Path -LiteralPath $staged)) { Get-TreeStats -Path $staged } else { $null }
  Write-Host ("op      : {0}" -f $c.op)
  Write-Host ("source  : {0}" -f $c.source)
  Write-Host ("target  : {0}" -f $c.target)
  Write-Host ("staged  : {0}" -f $staged)
  if ($size) { Write-Host ("size    : {0} files / {1:N2} GB" -f $size.Files, $size.GB) }
  Write-Host ''
}

if (-not $Execute) {
  Write-Host 'DRY RUN - nothing deleted. Add -Execute and -ConfirmPurge to purge.' -ForegroundColor Yellow
  exit 0
}

$failures = 0
foreach ($c in $candidates) {
  $staged = Get-FullPath $c.staged
  $src = Get-FullPath $c.source
  $dst = Get-FullPath $c.target

  Write-Host "--- Purging $($c.op) ---" -ForegroundColor Cyan

  if (-not $staged -or -not (Test-Path -LiteralPath $staged)) {
    Write-Host "SKIP: staged path is missing: $staged" -ForegroundColor Red
    $failures++
    continue
  }
  if (-not $dst -or -not (Test-Path -LiteralPath $dst)) {
    Write-Host "SKIP: live target is missing: $dst. Refusing to purge the last copy." -ForegroundColor Red
    $failures++
    continue
  }

  $linkOk = $false
  if ($src -and (Test-Path -LiteralPath $src)) {
    $item = Get-Item -LiteralPath $src -Force
    if ($item.LinkType) {
      $actual = Get-LinkTarget $src
      $actualFirst = Get-FullPath (($actual -split ',')[0])
      if ($actualFirst -eq $dst) { $linkOk = $true }
    }
  }

  if (-not $linkOk -and -not $AllowMissingLink) {
    Write-Host "SKIP: original path is not a junction to $dst. Refusing to purge the rollback copy." -ForegroundColor Red
    Write-Host '      Use -AllowMissingLink only after confirming the live data elsewhere.' -ForegroundColor Red
    $failures++
    continue
  }
  if (-not $linkOk) {
    Write-Host 'WARN: junction missing/wrong; purging because -AllowMissingLink was supplied.' -ForegroundColor Yellow
  }

  $before = Get-TreeStats -Path $staged
  Write-Host ("Deleting {0} files / {1:N2} GB (no reparse traversal)..." -f $before.Files, $before.GB) -ForegroundColor Yellow
  $result = Remove-TreeNoFollow -Path $staged

  if (Test-Path -LiteralPath $staged) {
    Write-Host ("PURGE INCOMPLETE: {0} error(s); path still exists." -f $result.Errors.Count) -ForegroundColor Red
    foreach ($e in ($result.Errors | Select-Object -First 5)) { Write-Host "  $e" -ForegroundColor Red }
    Write-ManifestEvent -Path $ManifestPath -Event @{
      op         = "$(Get-NewOperationId)"
      event      = 'failed'
      stage      = 'purge'
      purged_op  = $c.op
      staged     = $staged
      message    = "Purge incomplete; $($result.Errors.Count) error(s)"
      rolled_back = $false
    }
    $failures++
    continue
  }

  Write-ManifestEvent -Path $ManifestPath -Event @{
    op        = "$(Get-NewOperationId)"
    event     = 'purge'
    purged_op = $c.op
    source    = $src
    target    = $dst
    staged    = $staged
    files     = $before.Files
    bytes     = $before.Bytes
    links_unlinked = $result.Links
    verified  = $true
  }

  Write-Host ("PURGED: {0} ({1} files / {2:N2} GB freed)" -f $staged, $before.Files, $before.GB) -ForegroundColor Green
}

Write-Host ''
if ($failures -gt 0) {
  Write-Host "RESULT: FAIL - $failures purge(s) did not complete." -ForegroundColor Red
  exit 1
}
Write-Host 'RESULT: PASS - purge complete. Run verify.ps1 afterwards.' -ForegroundColor Green
exit 0
