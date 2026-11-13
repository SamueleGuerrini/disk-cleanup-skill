<#
.SYNOPSIS
  Read-only post-operation verification for a disk-cleanup run.

.DESCRIPTION
  Checks drive space, transaction state, every junction/symlink under the audited
  roots, broken or self-referential links, staged rollback copies, the manifest
  (and its mirror), and optionally `git status` of touched repositories.

  This script NEVER modifies anything. Exit code 1 means at least one FAIL.

.PARAMETER Drive
  Drives to include in the reparse scan (e.g. C:, D:). Default: all fixed drives.

.PARAMETER UserProfile
  Profile to scan. Default: current user.

.PARAMETER ManifestPath
  JSONL event log written by move-and-link.ps1.

.PARAMETER ManifestMirrorPath
  Optional second copy of the manifest; checks that it exists.

.PARAMETER GitRepo
  Repositories to check for mass deletions.

.PARAMETER Depth
  Max directory depth for the profile link scan (default 6).

.PARAMETER SkipDriveScan
  Do not scan whole drive roots for reparse points. Use this to verify a single
  transaction quickly, or in tests with a sandboxed -UserProfile.

.PARAMETER Json
  Emit the full result as JSON.

.EXAMPLE
  .\verify.ps1 -ManifestPath D:\_AI_Rollback\manifest.jsonl

.EXAMPLE
  .\verify.ps1 -Drive C: -GitRepo C:\Work\App -Json
#>
[CmdletBinding()]
param(
  [string[]]$Drive = @(),
  [string]$UserProfile = $env:USERPROFILE,
  [string]$ManifestPath,
  [string]$ManifestMirrorPath,
  [string[]]$GitRepo = @(),
  [int]$Depth = 6,
  [switch]$SkipDriveScan,
  [switch]$Json
)

$ErrorActionPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'lib\common.ps1')

$script:checks = New-Object System.Collections.Generic.List[object]

function Add-Check {
  param(
    [string]$Name,
    [ValidateSet('PASS', 'FAIL', 'WARN', 'INFO')][string]$Status,
    [string]$Detail = '',
    [string]$Evidence = ''
  )
  $script:checks.Add([pscustomobject]@{
      Check    = $Name
      Status   = $Status
      Detail   = $Detail
      Evidence = $Evidence
    })
}

function Resolve-LinkTarget {
  param([string]$LinkPath, [string]$Target)
  if (-not $Target) { return $null }
  $first = ($Target -split ',')[0]
  if ([System.IO.Path]::IsPathRooted($first)) { return (Get-FullPath $first) }
  return (Get-FullPath (Join-Path (Split-Path -Parent $LinkPath) $first))
}

# --- 1. drives -----------------------------------------------------------
$drives = @()
if ($Drive.Count -gt 0) {
  $drives = $Drive | ForEach-Object { $_.TrimEnd('\') }
} elseif (-not $SkipDriveScan) {
  $drives = Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object { $_.DeviceID }
}

$driveRows = New-Object System.Collections.Generic.List[object]
foreach ($d in $drives) {
  $vol = Get-VolumeInfo $d
  if (-not $vol) {
    Add-Check -Name "Drive $d" -Status 'FAIL' -Detail 'Drive not found'
    continue
  }
  $row = [pscustomobject]@{
    Drive   = $vol.Drive
    TotalGB = [math]::Round($vol.SizeBytes / 1GB, 2)
    UsedGB  = [math]::Round(($vol.SizeBytes - $vol.FreeBytes) / 1GB, 2)
    FreeGB  = [math]::Round($vol.FreeBytes / 1GB, 2)
  }
  $driveRows.Add($row)
  Add-Check -Name "Drive $($vol.Drive) space" -Status 'INFO' -Detail ("Free {0:N1} GB / Total {1:N1} GB" -f $row.FreeGB, $row.TotalGB)
}

# --- 2. transaction state ------------------------------------------------
$events = New-Object System.Collections.Generic.List[object]
$states = @{}
if ($ManifestPath) {
  if (-not (Test-Path -LiteralPath $ManifestPath)) {
    Add-Check -Name 'Manifest' -Status 'WARN' -Detail "Manifest not found: $ManifestPath"
  } else {
    $events = Read-ManifestEvents -Path $ManifestPath
    if ($events.Count -eq 0) {
      Add-Check -Name 'Manifest' -Status 'WARN' -Detail 'Manifest is empty'
    } else {
      Add-Check -Name 'Manifest' -Status 'PASS' -Detail "$($events.Count) events parsed" -Evidence $ManifestPath
    }
    $states = Get-OperationStates -Events $events
  }
}

foreach ($op in $states.Keys) {
  $st = $states[$op]
  if ($st.Open) {
    $prepared = @($st.Events | Where-Object { $_.event -eq 'prepared' }) | Select-Object -Last 1
    Add-Check -Name "Transaction $op" -Status 'FAIL' -Detail "Unfinished at state '$($st.LastState)'. Use move-and-link.ps1 -Recover." -Evidence $(if ($prepared) { $prepared.source } else { '' })
  } elseif ($st.Failed -and -not $st.Restored -and -not $st.Purged) {
    $failed = @($st.Events | Where-Object { $_.event -eq 'failed' }) | Select-Object -Last 1
    Add-Check -Name "Transaction $op" -Status 'WARN' -Detail "Last attempt failed: $($failed.message)" -Evidence $(if ($failed) { "stage=$($failed.stage)" } else { '' })
  }
}

foreach ($op in $states.Keys) {
  $st = $states[$op]
  if (-not $st.Committed) { continue }
  $c = @($st.Events | Where-Object { $_.event -eq 'committed' }) | Select-Object -Last 1
  if (-not $c) { continue }

  $src = Get-FullPath $c.source
  $dst = Get-FullPath $c.target

  if ($st.Restored) {
    Add-Check -Name "Operation $op" -Status 'INFO' -Detail 'Restored; junction no longer expected'
    continue
  }

  if (-not $src -or -not (Test-Path -LiteralPath $src)) {
    Add-Check -Name "Operation $op source" -Status 'FAIL' -Detail "Source path missing: $src"
  } else {
    $item = Get-Item -LiteralPath $src -Force
    if (-not $item.LinkType) {
      Add-Check -Name "Operation $op source" -Status 'FAIL' -Detail "Source is not a link: $src"
    } else {
      $actual = Resolve-LinkTarget -LinkPath $src -Target (Get-LinkTarget $src)
      if ($actual -ne $dst) {
        Add-Check -Name "Operation $op target" -Status 'FAIL' -Detail 'Link target mismatch' -Evidence "expected $dst, got $actual"
      } else {
        Add-Check -Name "Operation $op target" -Status 'PASS' -Detail "$($item.LinkType) -> $dst"
      }
    }
  }

  if (-not $dst -or -not (Test-Path -LiteralPath $dst)) {
    Add-Check -Name "Operation $op data" -Status 'FAIL' -Detail "Destination data missing: $dst"
  } else {
    $vol = Get-VolumeInfo $dst
    if (-not $vol) {
      Add-Check -Name "Operation $op volume" -Status 'FAIL' -Detail "Destination volume not mounted for $dst"
    } else {
      Add-Check -Name "Operation $op volume" -Status 'PASS' -Detail "Mounted at $($vol.Drive) ($($vol.DriveType))"
      $reserve = [int64]([math]::Max(1GB, $vol.SizeBytes * 0.05))
      if ($vol.FreeBytes -lt $reserve) {
        Add-Check -Name "Operation $op free space" -Status 'WARN' -Detail ("Only {0:N1} GB free on {1}; reserve is {2:N1} GB" -f ($vol.FreeBytes / 1GB), $vol.Drive, ($reserve / 1GB))
      }
    }
  }

  $staged = Get-FullPath $c.staged
  if ($staged) {
    if ($st.Purged) {
      Add-Check -Name "Operation $op rollback copy" -Status 'PASS' -Detail 'Purged as recorded'
    } elseif (Test-Path -LiteralPath $staged) {
      Add-Check -Name "Operation $op rollback copy" -Status 'WARN' -Detail 'Staged original still present; space not reclaimed until purged' -Evidence $staged
    } else {
      Add-Check -Name "Operation $op rollback copy" -Status 'WARN' -Detail 'Staged path missing but not marked purged' -Evidence $staged
    }
  }
}

if ($ManifestMirrorPath) {
  if (Test-Path -LiteralPath $ManifestMirrorPath) {
    $m = Read-ManifestEvents -Path $ManifestMirrorPath
    Add-Check -Name 'Manifest mirror' -Status 'PASS' -Detail "$($m.Count) events" -Evidence $ManifestMirrorPath
  } else {
    Add-Check -Name 'Manifest mirror' -Status 'WARN' -Detail "Mirror not found: $ManifestMirrorPath"
  }
}

# --- 3. reparse points ---------------------------------------------------
$roots = @()
foreach ($d in $drives) { $roots += ($d + '\') }
if ($UserProfile -and (Test-Path -LiteralPath $UserProfile)) { $roots += $UserProfile }
$roots = $roots | Select-Object -Unique

$allLinks = New-Object System.Collections.Generic.List[object]
$seen = @{}
foreach ($r in $roots) {
  $maxD = if ($r -eq $UserProfile) { $Depth } else { 2 }
  foreach ($l in (Get-ReparseInventory -Root $r -MaxDepth $maxD)) {
    $key = (Get-FullPath $l.Path).ToLowerInvariant()
    if ($seen.ContainsKey($key)) { continue }
    $seen[$key] = $true
    $resolved = Resolve-LinkTarget -LinkPath $l.Path -Target $l.Target
    $canon = Get-FullPath $l.Path
    $selfRef = $false
    if ($resolved -and $canon) {
      if ($canon -eq $resolved) { $selfRef = $true }
      elseif ($canon.StartsWith($resolved + '\', [StringComparison]::OrdinalIgnoreCase)) { $selfRef = $true }
      elseif ($resolved.StartsWith($canon + '\', [StringComparison]::OrdinalIgnoreCase)) { $selfRef = $true }
    }
    $exists = $false
    if ($resolved) { $exists = Test-Path -LiteralPath $resolved }
    $allLinks.Add([pscustomobject]@{
        Path     = $canon
        Kind     = $l.Kind
        Target   = $resolved
        Exists   = $exists
        SelfRef  = $selfRef
      })
  }
}

$legacyCompatNames = @(
  'Application Data', 'Dati applicazioni', 'Anwendungsdaten', 'Données d''applications',
  'Datos de programa', 'Dados de aplicativos', 'Toepassingsgegevens',
  'Local Settings', 'Impostazioni locali', 'Lokale Einstellungen', 'Paramètres locaux',
  'Configuración local', 'Configurações locais'
)

foreach ($l in $allLinks) {
  if ($l.SelfRef) {
    # Windows ships compatibility junctions (English and localized) that point at
    # their own parent on purpose. They are not loops a user should "fix".
    $leaf = Split-Path -Leaf $l.Path
    $parent = Split-Path -Parent $l.Path
    if (($legacyCompatNames -contains $leaf) -and $parent -and ($l.Target -eq $parent)) {
      Add-Check -Name "Link $($l.Path)" -Status 'PASS' -Detail 'Windows legacy compatibility junction (expected)' -Evidence ("-> " + $l.Target)
      continue
    }
    Add-Check -Name "Link $($l.Path)" -Status 'FAIL' -Detail 'Self-referential or points to its own ancestor' -Evidence ("-> " + $l.Target)
    continue
  }
  if ($l.Kind -eq 'UnknownReparse') {
    Add-Check -Name "Link $($l.Path)" -Status 'WARN' -Detail 'Unknown reparse tag; inspect before relying on it' -Evidence ("-> " + $l.Target)
    continue
  }
  if ($l.Kind -eq 'CloudPlaceholder') {
    Add-Check -Name "Link $($l.Path)" -Status 'WARN' -Detail 'Cloud placeholder; accessing it may hydrate data and consume space' -Evidence ("-> " + $l.Target)
    continue
  }
  if (-not $l.Exists) {
    Add-Check -Name "Link $($l.Path)" -Status 'FAIL' -Detail 'Target missing (broken link)' -Evidence ("-> " + $l.Target)
    continue
  }
  Add-Check -Name "Link $($l.Path)" -Status 'PASS' -Detail "$($l.Kind) target reachable" -Evidence ("-> " + $l.Target)
}

# --- 4. staged leftovers not in the manifest -----------------------------
if ($UserProfile -and (Test-Path -LiteralPath $UserProfile)) {
  $orphans = New-Object System.Collections.Generic.List[string]
  $stack = New-Object System.Collections.Generic.Stack[object]
  $stack.Push([pscustomobject]@{ Path = $UserProfile; Level = 0 })
  while ($stack.Count -gt 0) {
    $cur = $stack.Pop()
    try {
      $di = New-Object System.IO.DirectoryInfo $cur.Path
      foreach ($d in $di.EnumerateDirectories()) {
        if ($d.Name -like '*.__prelink_*') {
          $orphans.Add($d.FullName)
        } elseif (-not (Test-ReparsePoint $d) -and $cur.Level -lt $Depth) {
          $stack.Push([pscustomobject]@{ Path = $d.FullName; Level = ($cur.Level + 1) })
        }
      }
    } catch { }
  }
  if ($orphans.Count -gt 0) {
    foreach ($o in $orphans) {
      Add-Check -Name "Staged folder $o" -Status 'WARN' -Detail 'Looks like a renamed original; verify then purge to reclaim space'
    }
  } else {
    Add-Check -Name 'Staged folders' -Status 'PASS' -Detail 'No __prelink_ folders found under the profile'
  }
}

# --- 5. git repos --------------------------------------------------------
foreach ($repo in $GitRepo) {
  $r = Get-FullPath $repo
  if (-not $r -or -not (Test-Path -LiteralPath $r)) {
    Add-Check -Name "Git $repo" -Status 'FAIL' -Detail 'Repository path not found'
    continue
  }
  $isRepo = & git -C $r rev-parse --is-inside-work-tree 2>$null
  if ($LASTEXITCODE -ne 0 -or "$isRepo".Trim() -ne 'true') {
    Add-Check -Name "Git $r" -Status 'WARN' -Detail 'Not a git repository (skipped)'
    continue
  }
  $status = @(& git -C $r status --porcelain 2>$null)
  $deleted = @($status | Where-Object { $_.Length -ge 2 -and ($_.Substring(0, 1) -eq 'D' -or $_.Substring(1, 1) -eq 'D') })
  if ($deleted.Count -gt 20) {
    Add-Check -Name "Git $r" -Status 'FAIL' -Detail "$($deleted.Count) deleted paths (possible mass deletion)" -Evidence (($deleted | Select-Object -First 5) -join '; ')
  } elseif ($status.Count -gt 0) {
    Add-Check -Name "Git $r" -Status 'WARN' -Detail "$($status.Count) changed paths; $($deleted.Count) deletions" -Evidence (($status | Select-Object -First 5) -join '; ')
  } else {
    Add-Check -Name "Git $r" -Status 'PASS' -Detail 'Working tree clean'
  }
}

# --- report --------------------------------------------------------------
$fails = @($script:checks | Where-Object { $_.Status -eq 'FAIL' })
$warns = @($script:checks | Where-Object { $_.Status -eq 'WARN' })
$exitCode = if ($fails.Count -gt 0) { 1 } else { 0 }

if ($Json) {
  [pscustomobject]@{
    GeneratedAt = (Get-Date).ToString('o')
    Drives      = $driveRows
    Links       = $allLinks
    Checks      = $script:checks
    Fails       = $fails.Count
    Warns       = $warns.Count
    ExitCode    = $exitCode
  } | ConvertTo-Json -Depth 8
  exit $exitCode
}

Write-Host ''
Write-Host '=== Drives ===' -ForegroundColor Cyan
$driveRows | Format-Table Drive, TotalGB, UsedGB, FreeGB -AutoSize | Out-String -Width 4096 | Write-Host

Write-Host "=== Reparse points ($($allLinks.Count) found) ===" -ForegroundColor Cyan
if ($allLinks.Count -eq 0) {
  Write-Host 'none found'
} else {
  $allLinks | Format-Table Path, Kind, Target, Exists, SelfRef -AutoSize | Out-String -Width 4096 | Write-Host
}

Write-Host '=== Checks ===' -ForegroundColor Cyan
foreach ($c in $script:checks) {
  $color = switch ($c.Status) {
    'PASS' { 'Green' }
    'FAIL' { 'Red' }
    'WARN' { 'Yellow' }
    default { 'Gray' }
  }
  $line = "[{0}] {1}" -f $c.Status, $c.Check
  if ($c.Detail) { $line += " - $($c.Detail)" }
  if ($c.Evidence) { $line += " | $($c.Evidence)" }
  Write-Host $line -ForegroundColor $color
}

Write-Host ''
if ($fails.Count -gt 0) {
  Write-Host ("RESULT: FAIL - {0} failure(s), {1} warning(s). Do not declare success; see references/POST-OPERATION.md." -f $fails.Count, $warns.Count) -ForegroundColor Red
} elseif ($warns.Count -gt 0) {
  Write-Host ("RESULT: PASS with {0} warning(s)." -f $warns.Count) -ForegroundColor Yellow
} else {
  Write-Host 'RESULT: PASS - all checks passed.' -ForegroundColor Green
}

exit $exitCode
