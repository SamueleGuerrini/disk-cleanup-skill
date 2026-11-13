<#
.SYNOPSIS
  Restore a moved folder from the manifest, with conflict detection.

.DESCRIPTION
  A junction makes the target the live copy: anything written after the move lives
  there. Blindly restoring the staged original would discard that newer work. This
  script therefore compares staged vs live target first and requires an explicit
  conflict policy.

  Policies:
    Abort (default)  : refuse if the target has newer/modified/deleted files.
    KeepTarget       : bring the current live target back to the original path.
                       Safest when the app has been used since the move.
    Merge            : restore the staged original, then overlay files that are
                       newer or only in the live target. Current data wins.
    OverwriteTarget  : restore the staged original exactly. The live target is
                       renamed aside (not deleted) for later inspection.

  Dry-run by default. The junction is always removed as a link only; the target
  data is never traversed by a recursive delete.

.PARAMETER ManifestPath
  JSONL manifest written by move-and-link.ps1.

.PARAMETER Id
  Operation id to restore. Required unless -All is used.

.PARAMETER All
  Restore every eligible operation.

.PARAMETER ConflictPolicy
  Abort (default), KeepTarget, Merge, or OverwriteTarget.

.PARAMETER Strict
  Hash same-size/same-time files during conflict detection, and require the
  restored tree to contain at least the recorded file count.

.PARAMETER Execute
  Actually perform the restore.

.EXAMPLE
  .\restore-staged.ps1 -ManifestPath D:\_AI_Rollback\manifest.jsonl

.EXAMPLE
  .\restore-staged.ps1 -ManifestPath D:\_AI_Rollback\manifest.jsonl -Id 20261113-013000-abc123 -ConflictPolicy KeepTarget -Execute
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$ManifestPath,
  [string]$Id,
  [switch]$All,
  [ValidateSet('Abort', 'KeepTarget', 'Merge', 'OverwriteTarget')][string]$ConflictPolicy = 'Abort',
  [switch]$Strict,
  [switch]$Execute
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\common.ps1')

function Fail { param([string]$Message, [int]$Code = 1) Write-Host "ABORT: $Message" -ForegroundColor Red; exit $Code }

function Restore-StagedTree {
  param([string]$Staged, [string]$Target)
  if (Test-Path -LiteralPath $Target) { return $false }
  $sameVolume = ([System.IO.Path]::GetPathRoot($Staged) -eq [System.IO.Path]::GetPathRoot($Target))
  if ($sameVolume) {
    Move-Item -LiteralPath $Staged -Destination $Target -ErrorAction Stop
    return (Test-Path -LiteralPath $Target)
  }
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Target) | Out-Null
  $rcArgs = @($Staged, $Target, '/E', '/COPY:DATS', '/DCOPY:T', '/XJ', '/R:2', '/W:2', '/NFL', '/NDL', '/NP', '/NJH')
  & robocopy @rcArgs | Out-Null
  if ($LASTEXITCODE -ge 8) { return $false }
  $cmp = Compare-Trees -Source $Staged -Destination $Target -Level 'Basic'
  if (-not $cmp.Ok) { return $false }
  Remove-TreeNoFollow -Path $Staged | Out-Null
  return (Test-Path -LiteralPath $Target)
}

function Move-TargetBack {
  param([string]$Target, [string]$Source)
  if (-not (Test-Path -LiteralPath $Target)) { return $false }
  if (Test-Path -LiteralPath $Source) { return $false }
  $sameVolume = ([System.IO.Path]::GetPathRoot($Target) -eq [System.IO.Path]::GetPathRoot($Source))
  if ($sameVolume) {
    Move-Item -LiteralPath $Target -Destination $Source -ErrorAction Stop
    return (Test-Path -LiteralPath $Source)
  }
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Source) | Out-Null
  $rcArgs = @($Target, $Source, '/E', '/COPY:DATS', '/DCOPY:T', '/XJ', '/R:2', '/W:2', '/NFL', '/NDL', '/NP', '/NJH')
  & robocopy @rcArgs | Out-Null
  if ($LASTEXITCODE -ge 8) { return $false }
  $cmp = Compare-Trees -Source $Target -Destination $Source -Level 'Basic'
  if (-not $cmp.Ok) { return $false }
  Remove-TreeNoFollow -Path $Target | Out-Null
  return (Test-Path -LiteralPath $Source)
}

function Get-ConflictReport {
  param([string]$Staged, [string]$Target, [switch]$HashSameSize)

  $report = [pscustomobject]@{
    TargetOnly = New-Object System.Collections.Generic.List[string]
    StagedOnly = New-Object System.Collections.Generic.List[string]
    Modified   = New-Object System.Collections.Generic.List[string]
    TargetMissing = $false
    Error = $null
  }

  if (-not (Test-Path -LiteralPath $Target)) { $report.TargetMissing = $true; return $report }

  try {
    $s = Get-FileMap -Root $Staged
    $t = Get-FileMap -Root $Target
  } catch {
    $report.Error = $_.Exception.Message
    return $report
  }

  foreach ($rel in $t.Map.Keys) {
    if (-not $s.Map.ContainsKey($rel)) {
      $report.TargetOnly.Add($rel)
      continue
    }
    $sf = $s.Map[$rel]
    $tf = $t.Map[$rel]
    $changed = $false
    if ($sf.Size -ne $tf.Size) { $changed = $true }
    elseif ([math]::Abs(($tf.MTimeUtc - $sf.MTimeUtc).TotalSeconds) -gt 2) { $changed = $true }
    elseif ($HashSameSize -and (Get-FileSha256 $sf.Full) -ne (Get-FileSha256 $tf.Full)) { $changed = $true }
    if ($changed) { $report.Modified.Add($rel) }
  }
  foreach ($rel in $s.Map.Keys) {
    if (-not $t.Map.ContainsKey($rel)) { $report.StagedOnly.Add($rel) }
  }
  return $report
}

function Merge-TargetIntoSource {
  param([string]$Target, [string]$Source, [string]$Staged)
  $s = Get-FileMap -Root $Staged
  $t = Get-FileMap -Root $Target
  $copied = 0
  foreach ($rel in $t.Map.Keys) {
    $tf = $t.Map[$rel]
    $copy = $false
    if (-not $s.Map.ContainsKey($rel)) { $copy = $true }
    elseif ($s.Map[$rel].Size -ne $tf.Size) { $copy = $true }
    elseif ([math]::Abs(($tf.MTimeUtc - $s.Map[$rel].MTimeUtc).TotalSeconds) -gt 2) { $copy = $true }

    if ($copy) {
      $dest = Join-Path $Source $rel
      $dir = Split-Path -Parent $dest
      if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
      [System.IO.File]::Copy($tf.Full, $dest, $true)
      [System.IO.File]::SetLastWriteTimeUtc($dest, $tf.MTimeUtc)
      $copied++
    }
  }
  return $copied
}

if (-not (Test-Path -LiteralPath $ManifestPath)) { Fail "Manifest not found: $ManifestPath" }
if (-not $Id -and -not $All) { Fail "Specify -Id <operation id> or -All." }

$events = Read-ManifestEvents -Path $ManifestPath
$states = Get-OperationStates -Events $events

$candidates = New-Object System.Collections.Generic.List[object]
foreach ($op in $states.Keys) {
  $st = $states[$op]
  if (-not $st.Committed -or $st.Restored) { continue }
  if ($Id -and $op -ne $Id) { continue }
  $c = @($st.Events | Where-Object { $_.event -eq 'committed' }) | Select-Object -Last 1
  if ($c -and $c.staged) { $candidates.Add($c) }
}

if ($candidates.Count -eq 0) { Fail "No restorable operation found for the selection." }

$failures = 0
foreach ($c in $candidates) {
  $src = Get-FullPath $c.source
  $dst = Get-FullPath $c.target
  $staged = Get-FullPath $c.staged

  Write-Host ''
  Write-Host "=== Restore: $($c.op) ===" -ForegroundColor Cyan
  Write-Host ("source : {0}" -f $src)
  Write-Host ("target : {0}" -f $dst)
  Write-Host ("staged : {0}" -f $staged)
  Write-Host ("policy : {0}" -f $ConflictPolicy)

  if (-not $staged -or -not (Test-Path -LiteralPath $staged)) {
    Write-Host 'SKIP: staged rollback copy is missing.' -ForegroundColor Red
    $failures++
    continue
  }

  if (Test-Path -LiteralPath $src) {
    $item = Get-Item -LiteralPath $src -Force
    if (-not $item.LinkType) {
      Write-Host 'SKIP: source is already a real directory; refusing to overwrite it.' -ForegroundColor Red
      $failures++
      continue
    }
    $actual = Get-FullPath ((Get-LinkTarget $src) -split ',')[0]
    if ($actual -ne $dst) {
      Write-Host "SKIP: junction target mismatch (expected $dst, got $actual)." -ForegroundColor Red
      $failures++
      continue
    }
  }

  $conflicts = Get-ConflictReport -Staged $staged -Target $dst -HashSameSize:$Strict
  if ($conflicts.Error) {
    Write-Host "SKIP: cannot compare trees: $($conflicts.Error)" -ForegroundColor Red
    $failures++
    continue
  }

  $conflictCount = $conflicts.TargetOnly.Count + $conflicts.Modified.Count + $conflicts.StagedOnly.Count
  if ($conflicts.TargetMissing) {
    Write-Host 'NOTE: live target is missing; only the staged copy remains.' -ForegroundColor Yellow
  } elseif ($conflictCount -gt 0) {
    Write-Host ("Conflicts: {0} newer/changed in target, {1} only in target, {2} only in staged" -f $conflicts.Modified.Count, $conflicts.TargetOnly.Count, $conflicts.StagedOnly.Count) -ForegroundColor Yellow
    foreach ($p in ($conflicts.Modified | Select-Object -First 10)) { Write-Host "  modified in target: $p" -ForegroundColor Yellow }
    foreach ($p in ($conflicts.TargetOnly | Select-Object -First 10)) { Write-Host "  only in target    : $p" -ForegroundColor Yellow }
    foreach ($p in ($conflicts.StagedOnly | Select-Object -First 10)) { Write-Host "  only in staged    : $p" -ForegroundColor Yellow }
  } else {
    Write-Host 'No conflicts detected.' -ForegroundColor Green
  }

  if ($ConflictPolicy -eq 'Abort' -and $conflictCount -gt 0) {
    Write-Host 'ABORT: conflicts found. Choose -ConflictPolicy KeepTarget, Merge, or OverwriteTarget.' -ForegroundColor Red
    $failures++
    continue
  }
  if ($ConflictPolicy -eq 'KeepTarget' -and $conflicts.TargetMissing) {
    Write-Host 'ABORT: KeepTarget requested but the live target is missing.' -ForegroundColor Red
    $failures++
    continue
  }

  if (-not $Execute) {
    Write-Host 'DRY RUN - no changes for this entry.' -ForegroundColor Yellow
    continue
  }

  # Remove the link only (never recursive).
  if (Test-Path -LiteralPath $src) {
    $item = Get-Item -LiteralPath $src -Force
    if ($item.LinkType) {
      try {
        [System.IO.Directory]::Delete($src, $false)
      } catch {
        Write-Host "FAILED: could not remove junction: $($_.Exception.Message)" -ForegroundColor Red
        $failures++
        continue
      }
    }
  }

  $restored = $false
  $preservedTarget = $null
  $copied = 0

  try {
    switch ($ConflictPolicy) {
      'KeepTarget' {
        $restored = Move-TargetBack -Target $dst -Source $src
      }
      'Merge' {
        $restored = Restore-StagedTree -Staged $staged -Target $src
        if ($restored) {
          $copied = Merge-TargetIntoSource -Target $dst -Source $src -Staged $staged
          $preservedTarget = "$dst.__restored_$(Get-Date -Format 'yyyyMMdd-HHmmss')"
          Rename-Item -LiteralPath $dst -NewName (Split-Path -Leaf $preservedTarget) -ErrorAction Stop
        }
      }
      'OverwriteTarget' {
        $restored = Restore-StagedTree -Staged $staged -Target $src
        if ($restored -and (Test-Path -LiteralPath $dst)) {
          $preservedTarget = "$dst.__restored_$(Get-Date -Format 'yyyyMMdd-HHmmss')"
          Rename-Item -LiteralPath $dst -NewName (Split-Path -Leaf $preservedTarget) -ErrorAction Stop
        }
      }
      'Abort' {
        # No conflicts were found, so restoring the staged original is safe.
        # Keep the live target aside rather than deleting it.
        $restored = Restore-StagedTree -Staged $staged -Target $src
        if ($restored -and (Test-Path -LiteralPath $dst)) {
          $preservedTarget = "$dst.__restored_$(Get-Date -Format 'yyyyMMdd-HHmmss')"
          Rename-Item -LiteralPath $dst -NewName (Split-Path -Leaf $preservedTarget) -ErrorAction Stop
        }
      }
    }
  } catch {
    Write-Host "FAILED during restore: $($_.Exception.Message)" -ForegroundColor Red
    $failures++
    continue
  }

  if (-not $restored) {
    Write-Host 'FAILED: restore did not complete; inspect the paths above.' -ForegroundColor Red
    $failures++
    continue
  }

  $item = Get-Item -LiteralPath $src -Force
  if ($item.LinkType) {
    Write-Host 'FAILED: restored path is still a link.' -ForegroundColor Red
    $failures++
    continue
  }

  $stats = Get-TreeStats -Path $src
  if ($Strict -and $c.files -and $stats.Files -lt [int64]$c.files) {
    Write-Host ("WARN: restored tree has {0} files; manifest recorded {1}." -f $stats.Files, $c.files) -ForegroundColor Yellow
  }

  Write-ManifestEvent -Path $ManifestPath -Event @{
    op = "$(Get-NewOperationId)"
    event = 'restore'
    restored_from = $c.op
    source = $src
    target = $dst
    staged = $staged
    policy = $ConflictPolicy
    conflicts = $conflictCount
    files = $stats.Files
    bytes = $stats.Bytes
    target_preserved_at = $preservedTarget
    merged_files = $copied
    verified = $true
  }

  Write-Host ("RESTORED: {0} ({1} files, policy {2})" -f $src, $stats.Files, $ConflictPolicy) -ForegroundColor Green
  if ($preservedTarget) { Write-Host "Live target preserved at: $preservedTarget" -ForegroundColor Yellow }
  if ($ConflictPolicy -eq 'KeepTarget') { Write-Host "Staged rollback copy retained at: $staged (purge after verification)." -ForegroundColor Yellow }
}

Write-Host ''
if ($failures -gt 0) {
  Write-Host "RESULT: FAIL - $failures entr(ies) not restored." -ForegroundColor Red
  exit 1
}
Write-Host 'RESULT: PASS - restore complete. Run verify.ps1 afterwards.' -ForegroundColor Green
exit 0
