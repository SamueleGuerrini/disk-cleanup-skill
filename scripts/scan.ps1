<#
.SYNOPSIS
  Read-only disk audit. Never modifies anything.

.DESCRIPTION
  Reports drive usage, top-level consumers, largest files, known junk/cache
  folders, clutter hotspots, and every reparse point (junction, symlink, mount
  point, cloud placeholder, unknown) under the selected roots. Reparse points are
  never traversed, so sizes reflect real local usage.

.PARAMETER Drive
  Drive to audit, e.g. C: (default).

.PARAMETER UserProfile
  Profile to inspect for junctions/hotspots. Defaults to the current user.

.PARAMETER TopN
  How many largest files / folders to show.

.PARAMETER MinLargeFileMB
  Only list files at least this large.

.PARAMETER SkipLargestFiles
  Skip the (potentially slow) largest-file scan.

.PARAMETER PhysicalSize
  Also compute allocated size (sparse/compressed aware). Slower.

.PARAMETER OutFile
  Write the full report as JSON to this path (baseline for later comparison).

.PARAMETER Json
  Emit JSON to stdout instead of formatted text.

.EXAMPLE
  .\scan.ps1 -Drive C: -TopN 20

.EXAMPLE
  .\scan.ps1 -Drive C: -OutFile "$env:USERPROFILE\_AI_Rollback\baseline.json"
#>
[CmdletBinding()]
param(
  [string]$Drive = 'C:',
  [string]$UserProfile = $env:USERPROFILE,
  [int]$TopN = 20,
  [int]$MinLargeFileMB = 200,
  [switch]$SkipLargestFiles,
  [switch]$PhysicalSize,
  [string]$OutFile,
  [switch]$Json
)

$ErrorActionPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'lib\common.ps1')

function Resolve-Target {
  param([string]$LinkPath, [string]$Target)
  if (-not $Target) { return $null }
  $first = ($Target -split ',')[0]
  if ([System.IO.Path]::IsPathRooted($first)) { return (Get-FullPath $first) }
  return (Get-FullPath (Join-Path (Split-Path -Parent $LinkPath) $first))
}

function Get-LargestFiles {
  param([string]$Root, [int64]$MinBytes, [int]$Top)
  $list = New-Object System.Collections.Generic.List[object]
  $stack = New-Object System.Collections.Generic.Stack[string]
  $stack.Push($Root)
  while ($stack.Count -gt 0) {
    $cur = $stack.Pop()
    try {
      $di = New-Object System.IO.DirectoryInfo $cur
      foreach ($f in $di.EnumerateFiles()) {
        if (Test-ReparsePoint $f) { continue }
        try {
          if ($f.Length -ge $MinBytes) {
            $list.Add([pscustomobject]@{
                Path  = $f.FullName
                GB    = [math]::Round($f.Length / 1GB, 2)
                Bytes = $f.Length
              })
          }
        } catch { }
      }
      foreach ($d in $di.EnumerateDirectories()) {
        if (-not (Test-ReparsePoint $d)) { $stack.Push($d.FullName) }
      }
    } catch { }
  }
  return ($list | Sort-Object Bytes -Descending | Select-Object -First $Top)
}

$driveLetter = $Drive.TrimEnd(':', '\')
$driveRoot = $driveLetter + ':\'
$vol = Get-VolumeInfo $driveRoot
if (-not $vol) { throw "Drive not found: $Drive" }

# --- top-level folders ---------------------------------------------------
$topFolders = New-Object System.Collections.Generic.List[object]
foreach ($d in (Get-ChildItem -LiteralPath $driveRoot -Force -Directory -ErrorAction SilentlyContinue)) {
  if (Test-ReparsePoint $d) {
    $topFolders.Add([pscustomobject]@{
        Folder = $d.Name; GB = 0; PhysicalGB = 0; Files = 0; Links = 1
        Note = "link [$((Get-LinkKind $d.FullName))] -> $((Get-LinkTarget $d.FullName))"
      })
  } else {
    $s = Get-TreeStats -Path $d.FullName -PhysicalSize:$PhysicalSize
    $topFolders.Add([pscustomobject]@{
        Folder = $d.Name; GB = $s.GB; PhysicalGB = $s.PhysicalGB; Files = $s.Files; Links = $s.Links; Note = ''
      })
  }
}
$topFolders = @($topFolders | Sort-Object GB -Descending | Select-Object -First $TopN)

# --- known junk / cache / hotspot locations ------------------------------
. (Join-Path $PSScriptRoot 'lib\known.ps1')
$knownRows = @(Get-KnownLocations -DriveRoot $driveRoot -UserProfile $UserProfile -PhysicalSize:$PhysicalSize | ForEach-Object {
    [pscustomobject]@{
      Item       = $_.item
      GB         = [math]::Round($_.bytes / 1GB, 2)
      PhysicalGB = [math]::Round($_.allocated / 1GB, 2)
      Files      = $_.files
      Sparse     = $_.sparse
      Offline    = $_.offline
      Level      = $_.level
      Note       = $_.note
      Path       = $_.path
    }
  })

# --- reparse points ------------------------------------------------------
$reparse = New-Object System.Collections.Generic.List[object]
$roots = @(@{ Root = $driveRoot; Depth = 2 })
if ($UserProfile -and (Test-Path -LiteralPath $UserProfile)) { $roots += @{ Root = $UserProfile; Depth = 4 } }

$seen = @{}
foreach ($r in $roots) {
  foreach ($l in (Get-ReparseInventory -Root $r.Root -MaxDepth $r.Depth)) {
    $key = (Get-FullPath $l.Path).ToLowerInvariant()
    if ($seen.ContainsKey($key)) { continue }
    $seen[$key] = $true
    $resolved = Resolve-Target -LinkPath $l.Path -Target $l.Target
    $canon = Get-FullPath $l.Path
    $selfRef = $false
    if ($resolved -and $canon) {
      if ($canon -eq $resolved) { $selfRef = $true }
      elseif ($canon.StartsWith($resolved + '\', [StringComparison]::OrdinalIgnoreCase)) { $selfRef = $true }
      elseif ($resolved.StartsWith($canon + '\', [StringComparison]::OrdinalIgnoreCase)) { $selfRef = $true }
    }
    $reparse.Add([pscustomobject]@{
        Path    = $canon
        Kind    = $l.Kind
        Target  = $resolved
        Exists  = $(if ($resolved) { Test-Path -LiteralPath $resolved } else { $false })
        SelfRef = $selfRef
      })
  }
}
$reparse = @($reparse | Sort-Object Path)

# --- largest files -------------------------------------------------------
$largest = @()
if (-not $SkipLargestFiles) {
  $largest = @(Get-LargestFiles -Root $driveRoot -MinBytes ([int64]$MinLargeFileMB * 1MB) -Top $TopN)
}

$report = [pscustomobject]@{
  Drive       = $vol.Drive
  FileSystem  = $vol.FileSystem
  DriveType   = $vol.DriveType
  Serial      = $vol.Serial
  TotalGB     = [math]::Round($vol.SizeBytes / 1GB, 2)
  UsedGB      = [math]::Round(($vol.SizeBytes - $vol.FreeBytes) / 1GB, 2)
  FreeGB      = [math]::Round($vol.FreeBytes / 1GB, 2)
  PhysicalSize = [bool]$PhysicalSize
  TopFolders  = $topFolders
  Known       = $knownRows
  Reparse     = $reparse
  Largest     = $largest
  GeneratedAt = (Get-Date).ToString('o')
}

if ($OutFile) {
  Write-JsonAtomic -Path $OutFile -Object $report
  Write-Host "JSON baseline written: $OutFile" -ForegroundColor Green
}

if ($Json) {
  $report | ConvertTo-Json -Depth 8
  exit 0
}

Write-Host ''
Write-Host "=== Drive $($vol.Drive) [$($vol.DriveType), $($vol.FileSystem), serial $($vol.Serial)] ===" -ForegroundColor Cyan
Write-Host ("Total {0:N1} GB | Used {1:N1} GB | Free {2:N1} GB" -f $report.TotalGB, $report.UsedGB, $report.FreeGB)
Write-Host ''

Write-Host '=== Top-level folders ===' -ForegroundColor Cyan
$topFolders | Format-Table Folder, GB, PhysicalGB, Files, Links, Note -AutoSize | Out-String -Width 4096 | Write-Host

Write-Host '=== Known junk / cache / hotspot locations ===' -ForegroundColor Cyan
$knownRows | Sort-Object GB -Descending | Format-Table Item, GB, PhysicalGB, Files, Sparse, Offline, Level, Note, Path -AutoSize | Out-String -Width 4096 | Write-Host

Write-Host "=== Reparse points ($($reparse.Count), never traversed) ===" -ForegroundColor Cyan
if ($reparse.Count -eq 0) {
  Write-Host 'none found'
} else {
  $reparse | Format-Table Path, Kind, Target, Exists, SelfRef -AutoSize | Out-String -Width 4096 | Write-Host
}

if (-not $SkipLargestFiles) {
  Write-Host "=== Largest files (>= $MinLargeFileMB MB) ===" -ForegroundColor Cyan
  if ($largest.Count -eq 0) { Write-Host 'none found' }
  else { $largest | Format-Table GB, Path -AutoSize | Out-String -Width 4096 | Write-Host }
}

Write-Host ''
Write-Host 'Reminder: this was read-only. Nothing was changed.' -ForegroundColor Green
if (-not $PhysicalSize) {
  Write-Host 'Sizes are logical. Use -PhysicalSize for allocated size (sparse/compressed aware).' -ForegroundColor Gray
}
