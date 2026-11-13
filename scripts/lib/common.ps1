<#
  Shared helpers for the disk-cleanup scripts (v2).

  Dot-source from a script:
    . (Join-Path $PSScriptRoot 'lib\common.ps1')

  Nothing here executes on load. All functions are read-only unless their name
  says otherwise (Write-*, Remove-*).
#>

$script:CleanupToolVersion = '2.0'

# ---------------------------------------------------------------------------
# Basic path helpers
# ---------------------------------------------------------------------------

function Get-FullPath {
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
  try { $full = [System.IO.Path]::GetFullPath($Path) } catch { return $null }
  if ($full.Length -gt 3) { $full = $full.TrimEnd('\') }
  return $full
}

function Test-ReparsePoint {
  param([System.IO.FileSystemInfo]$Item)
  if ($null -eq $Item) { return $false }
  return (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Test-CloudPlaceholder {
  param([System.IO.FileSystemInfo]$Item)
  # Offline = 0x1000, RecallOnDataAccess = 0x400000
  $attrs = [int]$Item.Attributes
  if (($attrs -band 0x1000) -ne 0) { return $true }
  if (($attrs -band 0x400000) -ne 0) { return $true }
  return $false
}

function Get-LinkTarget {
  param([string]$Path)
  try {
    $i = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    $t = @($i.Target) -join ','
    if (-not $t) { return $null }
    return ($t -replace '^\\\\\?\\', '' -replace '^\\\?\?\\', '')
  } catch { return $null }
}

function Get-LinkKind {
  param([string]$Path)
  try {
    $i = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
  } catch { return 'Missing' }
  if (-not (Test-ReparsePoint $i)) { return 'None' }
  $t = @($i.Target) -join ','
  if ($t -match '^\\\\\?\\Volume\{') { return 'MountPoint' }
  if (Test-CloudPlaceholder $i) { return 'CloudPlaceholder' }
  switch ($i.LinkType) {
    'Junction' { return 'Junction' }
    'SymbolicLink' { return 'SymbolicLink' }
    'HardLink' { return 'HardLink' }
  }
  return 'UnknownReparse'
}

<#
  Resolve a path component by component, following reparse points, and report
  every link that was traversed. This is a *diagnostic* resolver, not a security
  boundary: it is used to detect redirections, not to prove a path is safe.
#>
function Get-RealPath {
  param([string]$Path, [int]$MaxLinks = 16)

  $full = Get-FullPath $Path
  if (-not $full) { return $null }

  $links = New-Object System.Collections.Generic.List[object]
  $cur = $full
  $loop = $false

  for ($round = 0; $round -lt $MaxLinks; $round++) {
    $root = [System.IO.Path]::GetPathRoot($cur)
    if (-not $root) { break }
    $rest = $cur.Substring($root.Length)
    $parts = @($rest.Split('\') | Where-Object { $_ -ne '' })
    $built = $root
    $changed = $false

    foreach ($p in $parts) {
      $next = Join-Path $built $p
      $isLink = $false
      if (Test-Path -LiteralPath $next) {
        try {
          $item = Get-Item -LiteralPath $next -Force -ErrorAction Stop
          $isLink = Test-ReparsePoint $item
        } catch { }
      }
      if ($isLink) {
        $raw = Get-LinkTarget $next
        if ($raw) {
          $kind = Get-LinkKind $next
          $first = ($raw -split ',')[0]
          $targetFull = if ([System.IO.Path]::IsPathRooted($first)) {
            Get-FullPath $first
          } else {
            Get-FullPath (Join-Path (Split-Path -Parent $next) $first)
          }
          $links.Add([pscustomobject]@{
              Path   = (Get-FullPath $next)
              Kind   = $kind
              Raw    = $raw
              Target = $targetFull
            })
          $built = $targetFull
          $changed = $true
          continue
        }
      }
      $built = $next
    }

    if (-not $changed) {
      return [pscustomobject]@{ Path = (Get-FullPath $built); Links = $links; LoopDetected = $false }
    }
    $cur = $built
  }

  $loop = $true
  return [pscustomobject]@{ Path = (Get-FullPath $cur); Links = $links; LoopDetected = $loop }
}

# ---------------------------------------------------------------------------
# Volume / destination eligibility
# ---------------------------------------------------------------------------

function Get-VolumeInfo {
  param([string]$Path)
  $full = Get-FullPath $Path
  if (-not $full) { return $null }
  $root = [System.IO.Path]::GetPathRoot($full)
  if (-not $root) { return $null }
  $letter = $root.TrimEnd('\')
  $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$letter'" -ErrorAction SilentlyContinue
  if (-not $disk) { return $null }
  $typeName = switch ([int]$disk.DriveType) {
    2 { 'Removable' }
    3 { 'Fixed' }
    4 { 'Network' }
    5 { 'CDRom' }
    6 { 'RamDisk' }
    default { 'Unknown' }
  }
  [pscustomobject]@{
    Drive        = $letter
    Root         = $root
    DriveType    = $typeName
    DriveTypeId  = [int]$disk.DriveType
    FileSystem   = $disk.FileSystem
    Serial       = $disk.VolumeSerialNumber
    FreeBytes    = [int64]$disk.FreeSpace
    SizeBytes    = [int64]$disk.Size
    IsFixed      = ([int]$disk.DriveType -eq 3)
    IsRemovable  = ([int]$disk.DriveType -eq 2)
    IsNetwork    = ([int]$disk.DriveType -eq 4)
  }
}

function Get-BitLockerState {
  param([string]$Drive)
  $cmd = Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue
  if (-not $cmd) { return $null }
  try {
    $v = Get-BitLockerVolume -MountPoint $Drive -ErrorAction Stop
    return [pscustomobject]@{ Status = "$($v.ProtectionStatus)"; Lock = "$($v.LockStatus)" }
  } catch { return $null }
}

<#
  Decide whether a destination volume is acceptable for a junction-backed move.
  Returns Errors (blocking), Warnings (require explicit acknowledgement), Volume.
#>
function Test-DestinationDrive {
  param(
    [string]$Destination,
    [int64]$RequiredBytes = 0,
    [switch]$AllowRemovable
  )

  $errors = New-Object System.Collections.Generic.List[string]
  $warnings = New-Object System.Collections.Generic.List[string]
  $vol = Get-VolumeInfo $Destination

  if (-not $vol) {
    $errors.Add("Cannot resolve volume for destination: $Destination")
    return [pscustomobject]@{ Ok = $false; Errors = $errors; Warnings = $warnings; Volume = $null }
  }

  switch ($vol.DriveTypeId) {
    3 { }
    2 {
      if (-not $AllowRemovable) {
        $errors.Add("Destination is a removable drive ($($vol.Drive)). Use -AllowRemovable after accepting that a missing drive breaks every junction.")
      } else {
        $warnings.Add("Destination is removable ($($vol.Drive)). If it is not mounted at logon, every junction into it is broken.")
      }
    }
    4 { $errors.Add("Destination is a network drive ($($vol.Drive)). Junctions to network shares are not supported; use a local fixed volume.") }
    5 { $errors.Add("Destination is a CD/DVD drive ($($vol.Drive)).") }
    6 { $errors.Add("Destination is a RAM disk ($($vol.Drive)); data is lost on reboot.") }
    default { $errors.Add("Destination drive type is unsupported ($($vol.DriveType)).") }
  }

  if ($vol.FileSystem -notin @('NTFS', 'ReFS')) {
    $errors.Add("Destination filesystem is $($vol.FileSystem). Directory junctions require NTFS (ReFS support is limited).")
  }

  if ($RequiredBytes -gt 0) {
    $reserve = [int64]([math]::Max(1GB, $RequiredBytes * 0.05))
    $needed = $RequiredBytes + $reserve
    if ($vol.FreeBytes -lt $needed) {
      $errors.Add(("Destination has {0:N1} GB free; need about {1:N1} GB including reserve." -f ($vol.FreeBytes / 1GB), ($needed / 1GB)))
    } elseif ($vol.FreeBytes -lt ($RequiredBytes * 1.5)) {
      $warnings.Add(("Destination free space is tight: {0:N1} GB free for {1:N1} GB of data." -f ($vol.FreeBytes / 1GB), ($RequiredBytes / 1GB)))
    }
  }

  if ($vol.IsRemovable -or $vol.IsNetwork) {
    $warnings.Add("Drive letter stability matters: a changed letter breaks the junction. Prefer a fixed internal volume.")
  }

  $bl = Get-BitLockerState $vol.Drive
  if ($bl -and $bl.Lock -eq 'Locked') {
    $errors.Add("Destination volume is BitLocker-locked. Unlock it before moving data.")
  } elseif ($bl -and $bl.Status -eq 'On') {
    $warnings.Add("Destination is BitLocker-encrypted. Ensure auto-unlock is enabled, or the junction is broken at boot.")
  }

  return [pscustomobject]@{
    Ok       = ($errors.Count -eq 0)
    Errors   = $errors
    Warnings = $warnings
    Volume   = $vol
  }
}

# ---------------------------------------------------------------------------
# Protected paths
# ---------------------------------------------------------------------------

function Get-ProtectedPaths {
  param([string]$ExtraUserProfile)

  $paths = New-Object System.Collections.Generic.List[string]
  $add = {
    param($p)
    $f = Get-FullPath $p
    if ($f -and -not ($paths -contains $f)) { $paths.Add($f) }
  }

  foreach ($d in (Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue)) {
    & $add ($d.DeviceID + '\')
  }

  $windir = $env:WINDIR
  if ($windir) {
    & $add $windir
    & $add (Join-Path $windir 'System32')
    & $add (Join-Path $windir 'SysWOW64')
    & $add (Join-Path $windir 'WinSxS')
    & $add (Join-Path $windir 'Installer')
    & $add (Join-Path $windir 'Boot')
    & $add (Join-Path $windir 'Fonts')
  }

  $sysDrive = $env:SystemDrive
  if ($sysDrive) {
    & $add (Join-Path $sysDrive 'Program Files')
    & $add (Join-Path $sysDrive 'Program Files (x86)')
    & $add (Join-Path $sysDrive 'ProgramData')
    & $add (Join-Path $sysDrive 'Users')
    & $add (Join-Path $sysDrive 'Recovery')
    & $add (Join-Path $sysDrive 'System Volume Information')
    & $add (Join-Path $sysDrive '$Recycle.Bin')
  }

  $profiles = @()
  if ($ExtraUserProfile) { $profiles += $ExtraUserProfile }
  if ($env:USERPROFILE) { $profiles += $env:USERPROFILE }
  foreach ($p in $profiles) {
    $p = Get-FullPath $p
    if (-not $p) { continue }
    & $add $p
    & $add (Join-Path $p 'AppData')
    & $add (Join-Path $p 'AppData\Local')
    & $add (Join-Path $p 'AppData\Roaming')
    & $add (Join-Path $p 'AppData\LocalLow')
    & $add (Join-Path $p '.ssh')
    & $add (Join-Path $p '.gnupg')
    & $add (Join-Path $p '.aws')
    & $add (Join-Path $p '.azure')
    & $add (Join-Path $p '.config')
    & $add (Join-Path $p '.local')
    & $add (Join-Path $p 'NTUSER.DAT')
    & $add (Join-Path $p 'ntuser.dat')
  }

  # Other user profile roots (but not their subfolders).
  if ($env:SystemDrive) {
    $users = Join-Path $env:SystemDrive 'Users'
    if (Test-Path -LiteralPath $users) {
      foreach ($d in (Get-ChildItem -LiteralPath $users -Force -Directory -ErrorAction SilentlyContinue)) {
        & $add $d.FullName
      }
    }
  }

  return $paths
}

function Test-ProtectedPath {
  param([string]$Path, [string[]]$Protected)
  $f = Get-FullPath $Path
  if (-not $f) { return $true }
  if ($f.Length -le 3) { return $true }
  foreach ($p in $Protected) {
    if ($f.Equals($p, [StringComparison]::OrdinalIgnoreCase)) { return $true }
  }
  return $false
}

# ---------------------------------------------------------------------------
# Size / tree helpers
# ---------------------------------------------------------------------------

$script:NativeLoaded = $false
function Initialize-Native {
  if ($script:NativeLoaded) { return }
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DiskCleanupNative {
  [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
  public static extern uint GetCompressedFileSize(string lpFileName, out uint lpFileSizeHigh);
}
'@ -ErrorAction SilentlyContinue
  $script:NativeLoaded = $true
}

function Get-AllocatedBytes {
  param([string]$Path)
  Initialize-Native
  $high = [uint32]0
  $low = [DiskCleanupNative]::GetCompressedFileSize($Path, [ref]$high)
  if ($low -eq [uint32]4294967295) {
    $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
    if ($err -ne 0) { return $null }
  }
  return (([int64]$high -shl 32) + [int64]$low)
}

<#
  Walk a tree without following reparse points. Excluded names are skipped
  entirely (their contents are neither counted nor copied).
#>
function Get-TreeStats {
  param(
    [string]$Path,
    [string[]]$ExcludeNames = @(),
    [switch]$PhysicalSize
  )

  $files = [int64]0
  $bytes = [int64]0
  $physical = [int64]0
  $sparse = [int64]0
  $offline = [int64]0
  $links = [int64]0
  $dirs = [int64]0
  $stack = New-Object System.Collections.Generic.Stack[string]
  $stack.Push($Path)

  while ($stack.Count -gt 0) {
    $cur = $stack.Pop()
    try {
      $di = New-Object System.IO.DirectoryInfo $cur
      foreach ($f in $di.EnumerateFiles()) {
        if (Test-ReparsePoint $f) { $links++; continue }
        if (Test-CloudPlaceholder $f) { $offline++ }
        if (($f.Attributes -band [System.IO.FileAttributes]::SparseFile) -ne 0) { $sparse++ }
        try {
          $files++
          $bytes += $f.Length
          if ($PhysicalSize) {
            $a = Get-AllocatedBytes $f.FullName
            if ($null -ne $a) { $physical += $a } else { $physical += $f.Length }
          }
        } catch { }
      }
      foreach ($d in $di.EnumerateDirectories()) {
        if (Test-ReparsePoint $d) { $links++; continue }
        if ($ExcludeNames -contains $d.Name) { continue }
        $dirs++
        $stack.Push($d.FullName)
      }
    } catch { }
  }

  [pscustomobject]@{
    Path          = $Path
    Files         = $files
    Bytes         = $bytes
    PhysicalBytes = $(if ($PhysicalSize) { $physical } else { $bytes })
    Dirs          = $dirs
    Links         = $links
    SparseFiles   = $sparse
    OfflineFiles  = $offline
    GB            = [math]::Round($bytes / 1GB, 2)
    PhysicalGB    = [math]::Round($(if ($PhysicalSize) { $physical } else { $bytes }) / 1GB, 2)
  }
}

<#
  Build a relative-path -> metadata map. Rejects reparse points and
  case-insensitive duplicate paths, which would make verification ambiguous.
#>
function Get-FileMap {
  param(
    [string]$Root,
    [string[]]$ExcludeNames = @()
  )

  $map = New-Object System.Collections.Hashtable ([System.StringComparer]::OrdinalIgnoreCase)
  $stack = New-Object System.Collections.Generic.Stack[string]
  $stack.Push($Root)
  $links = New-Object System.Collections.Generic.List[string]

  while ($stack.Count -gt 0) {
    $cur = $stack.Pop()
    try {
      $di = New-Object System.IO.DirectoryInfo $cur
      foreach ($f in $di.EnumerateFiles()) {
        if (Test-ReparsePoint $f) { $links.Add($f.FullName); continue }
        $rel = $f.FullName.Substring($Root.Length).TrimStart('\')
        if ($map.ContainsKey($rel)) {
          throw "Case-insensitive path collision: $rel"
        }
        $map[$rel] = [pscustomobject]@{
          Size     = [int64]$f.Length
          MTimeUtc = $f.LastWriteTimeUtc
          Full     = $f.FullName
        }
      }
      foreach ($d in $di.EnumerateDirectories()) {
        if (Test-ReparsePoint $d) { $links.Add($d.FullName); continue }
        if ($ExcludeNames -contains $d.Name) { continue }
        $stack.Push($d.FullName)
      }
    } catch { throw }
  }

  [pscustomobject]@{ Map = $map; Links = $links }
}

function Get-FileSha256 {
  param([string]$Path)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  $fs = $null
  try {
    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    $hash = $sha.ComputeHash($fs)
    return (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
  } finally {
    if ($fs) { $fs.Dispose() }
    $sha.Dispose()
  }
}

<#
  Compare source and destination trees.

  Basic    : same relative paths, same sizes.
  Standard : Basic + last-write time (2s tolerance).
  Strict   : Standard + SHA-256 for every file (slow; use for irreplaceable data).
#>
function Compare-Trees {
  param(
    [string]$Source,
    [string]$Destination,
    [string[]]$ExcludeNames = @(),
    [ValidateSet('Basic', 'Standard', 'Strict')][string]$Level = 'Standard',
    [int]$MaxReport = 25
  )

  $src = Get-FileMap -Root $Source -ExcludeNames $ExcludeNames
  $dst = Get-FileMap -Root $Destination

  $mismatches = New-Object System.Collections.Generic.List[object]
  $missing = New-Object System.Collections.Generic.List[string]
  $extra = New-Object System.Collections.Generic.List[string]

  if ($src.Links.Count -gt 0 -or $dst.Links.Count -gt 0) {
    return [pscustomobject]@{
      Ok         = $false
      Level      = $Level
      Files      = $dst.Map.Count
      Bytes      = 0
      Mismatches = @([pscustomobject]@{ Kind = 'ReparsePoint'; Detail = (($src.Links + $dst.Links) -join '; ') })
      Missing    = @()
      Extra      = @()
    }
  }

  foreach ($rel in $src.Map.Keys) {
    if (-not $dst.Map.ContainsKey($rel)) { $missing.Add($rel); continue }
    $s = $src.Map[$rel]
    $d = $dst.Map[$rel]
    if ($s.Size -ne $d.Size) {
      $mismatches.Add([pscustomobject]@{ Kind = 'Size'; Path = $rel; Source = $s.Size; Destination = $d.Size })
      continue
    }
    if ($Level -in @('Standard', 'Strict')) {
      $delta = [math]::Abs(($s.MTimeUtc - $d.MTimeUtc).TotalSeconds)
      if ($delta -gt 2) {
        $mismatches.Add([pscustomobject]@{ Kind = 'Timestamp'; Path = $rel; Source = $s.MTimeUtc.ToString('o'); Destination = $d.MTimeUtc.ToString('o') })
        continue
      }
    }
    if ($Level -eq 'Strict') {
      $hs = Get-FileSha256 $s.Full
      $hd = Get-FileSha256 $d.Full
      if ($hs -ne $hd) {
        $mismatches.Add([pscustomobject]@{ Kind = 'Hash'; Path = $rel; Source = $hs; Destination = $hd })
      }
    }
  }

  foreach ($rel in $dst.Map.Keys) {
    if (-not $src.Map.ContainsKey($rel)) { $extra.Add($rel) }
  }

  $ok = ($missing.Count -eq 0 -and $extra.Count -eq 0 -and $mismatches.Count -eq 0)

  $bytes = [int64]0
  foreach ($k in $src.Map.Keys) { $bytes += $src.Map[$k].Size }

  [pscustomobject]@{
    Ok         = $ok
    Level      = $Level
    Files      = $src.Map.Count
    Bytes      = $bytes
    Mismatches = @($mismatches | Select-Object -First $MaxReport)
    Missing    = @($missing | Select-Object -First $MaxReport)
    Extra      = @($extra | Select-Object -First $MaxReport)
    MissingCount = $missing.Count
    ExtraCount   = $extra.Count
    MismatchCount = $mismatches.Count
  }
}

# ---------------------------------------------------------------------------
# Reparse inventory
# ---------------------------------------------------------------------------

function Get-ReparseInventory {
  param(
    [string]$Root,
    [string[]]$ExcludeNames = @(),
    [int]$MaxDepth = 64
  )

  $found = New-Object System.Collections.Generic.List[object]
  $stack = New-Object System.Collections.Generic.Stack[object]
  $stack.Push([pscustomobject]@{ Path = $Root; Level = 0 })

  while ($stack.Count -gt 0) {
    $cur = $stack.Pop()
    try {
      $di = New-Object System.IO.DirectoryInfo $cur.Path
      foreach ($f in $di.EnumerateFiles()) {
        if (Test-ReparsePoint $f) {
          $kind = Get-LinkKind $f.FullName
          $found.Add([pscustomobject]@{ Path = $f.FullName; Kind = $kind; IsDirectory = $false; Target = (Get-LinkTarget $f.FullName) })
        }
      }
      foreach ($d in $di.EnumerateDirectories()) {
        if (Test-ReparsePoint $d) {
          $kind = Get-LinkKind $d.FullName
          $found.Add([pscustomobject]@{ Path = $d.FullName; Kind = $kind; IsDirectory = $true; Target = (Get-LinkTarget $d.FullName) })
        } elseif (-not ($ExcludeNames -contains $d.Name) -and $cur.Level -lt $MaxDepth) {
          $stack.Push([pscustomobject]@{ Path = $d.FullName; Level = ($cur.Level + 1) })
        }
      }
    } catch { }
  }

  return $found
}

# ---------------------------------------------------------------------------
# JSON / hashing / atomic writes
# ---------------------------------------------------------------------------

function Get-StringSha256 {
  param([string]$Text)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    return (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
  } finally { $sha.Dispose() }
}

function ConvertTo-CanonicalJson {
  param($InputObject, [int]$Depth = 0)

  if ($Depth -gt 32) {
    throw 'Canonical JSON exceeded 32 levels of nesting (possible object cycle).'
  }
  if ($null -eq $InputObject) { return 'null' }
  # ConvertFrom-Json may hand back DateTime values for ISO strings; they must not
  # be walked as objects (DateTime.Date refers back to a DateTime).
  if ($InputObject -is [datetime]) { return (ConvertTo-Json $InputObject.ToString('o') -Compress) }
  if ($InputObject -is [datetimeoffset]) { return (ConvertTo-Json $InputObject.ToString('o') -Compress) }
  if ($InputObject -is [string] -or $InputObject -is [bool] -or $InputObject -is [int] -or
      $InputObject -is [long] -or $InputObject -is [double] -or $InputObject -is [decimal]) {
    return (ConvertTo-Json $InputObject -Compress)
  }
  if ($InputObject -is [System.Collections.IDictionary]) {
    $keys = @($InputObject.Keys | Sort-Object)
    $parts = @()
    foreach ($k in $keys) {
      $parts += (ConvertTo-Json ([string]$k) -Compress) + ':' + (ConvertTo-CanonicalJson -InputObject $InputObject[$k] -Depth ($Depth + 1))
    }
    return '{' + ($parts -join ',') + '}'
  }
  if ($InputObject -is [System.Collections.IEnumerable]) {
    $parts = @()
    foreach ($i in $InputObject) { $parts += ConvertTo-CanonicalJson -InputObject $i -Depth ($Depth + 1) }
    return '[' + ($parts -join ',') + ']'
  }
  $props = @($InputObject.PSObject.Properties | Where-Object { $_.Name -notlike '__*' -and $_.Name -ne 'approval' } | Sort-Object Name)
  $parts = @()
  foreach ($p in $props) {
    $parts += (ConvertTo-Json $p.Name -Compress) + ':' + (ConvertTo-CanonicalJson -InputObject $p.Value -Depth ($Depth + 1))
  }
  return '{' + ($parts -join ',') + '}'
}

<#
  ConvertFrom-Json with date parsing disabled.

  PowerShell 7.5+ turns ISO-8601 strings into [datetime] by default. That breaks
  approval hashing (a round-tripped plan no longer matches the object that was
  hashed) and can surprise any consumer of the manifest. -DateKind String keeps
  the original text, so hashes stay stable across read/write cycles.
#>
function ConvertFrom-JsonSafe {
  param([string]$Json)
  $cmd = Get-Command ConvertFrom-Json -ErrorAction SilentlyContinue
  if ($cmd -and $cmd.Parameters.ContainsKey('DateKind')) {
    return ($Json | ConvertFrom-Json -DateKind String)
  }
  return ($Json | ConvertFrom-Json)
}

function Get-ItemHash {
  param($Item)
  return (Get-StringSha256 (ConvertTo-CanonicalJson $Item))
}

function Write-JsonAtomic {
  param([string]$Path, $Object)
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $tmp = "$Path.tmp.$([guid]::NewGuid().ToString('N'))"
  ($Object | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $tmp -Encoding UTF8
  Move-Item -LiteralPath $tmp -Destination $Path -Force
}

# ---------------------------------------------------------------------------
# Manifest event log (append-only JSONL)
# ---------------------------------------------------------------------------

function Write-ManifestEvent {
  param(
    [string]$Path,
    [hashtable]$Event,
    [string]$MirrorPath
  )

  if (-not $Event.ContainsKey('time')) { $Event['time'] = (Get-Date).ToString('o') }
  if (-not $Event.ContainsKey('tool')) { $Event['tool'] = "disk-cleanup/$script:CleanupToolVersion" }
  if (-not $Event.ContainsKey('host')) { $Event['host'] = $env:COMPUTERNAME }
  if (-not $Event.ContainsKey('user')) { $Event['user'] = $env:USERNAME }

  $json = ($Event | ConvertTo-Json -Compress -Depth 12) + "`n"
  $encoding = New-Object System.Text.UTF8Encoding($false)

  foreach ($p in @($Path, $MirrorPath)) {
    if (-not $p) { continue }
    $dir = Split-Path -Parent $p
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [System.IO.File]::AppendAllText($p, $json, $encoding)
  }
}

function Read-ManifestEvents {
  param([string]$Path)
  $events = New-Object System.Collections.Generic.List[object]
  if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $events }
  $lineNo = 0
  foreach ($line in (Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)) {
    $lineNo++
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try {
      $e = ConvertFrom-JsonSafe $line
      $e | Add-Member -NotePropertyName '__line' -NotePropertyValue $lineNo -Force
      $events.Add($e)
    } catch {
      Write-Warning "Invalid JSON in manifest at line $lineNo (skipped)"
    }
  }
  return $events
}

<#
  Group manifest events by operation id and compute the current state.
  Returns a hashtable: op -> object with Events, LastState, LastEvent, Open,
  Committed, Restored, Purged, Failed.
#>
function Get-OperationStates {
  param($Events)

  $rank = @{
    prepared        = 1
    copy_started    = 2
    copy_verified   = 3
    original_staged = 4
    link_created    = 5
    verified        = 6
    committed       = 7
  }

  $byOp = @{}
  $restored = @{}
  $purged = @{}

  foreach ($e in $Events) {
    if ($e.event -eq 'restore' -and $e.restored_from) { $restored[$e.restored_from] = $true }
    if ($e.event -eq 'purge' -and $e.purged_op) { $purged[$e.purged_op] = $true }
    if (-not $e.op) { continue }
    if (-not $byOp.ContainsKey($e.op)) {
      $byOp[$e.op] = [pscustomobject]@{
        Op        = $e.op
        Events    = New-Object System.Collections.Generic.List[object]
        LastState = ''
        LastEvent = ''
        Rank      = 0
        Failed    = $false
      }
    }
    $st = $byOp[$e.op]
    $st.Events.Add($e)
    if ($rank.ContainsKey($e.event) -and $rank[$e.event] -ge $st.Rank) {
      $st.Rank = $rank[$e.event]
      $st.LastState = $e.event
    }
    $st.LastEvent = $e.event
    if ($e.event -eq 'failed') { $st.Failed = $true }
  }

  foreach ($op in $byOp.Keys) {
    $st = $byOp[$op]
    $isRestored = $restored.ContainsKey($op)
    $isPurged = $purged.ContainsKey($op)
    $committed = ($st.LastState -eq 'committed')
    $open = ($st.Rank -gt 0 -and $st.Rank -lt 7 -and -not $st.Failed)
    $st | Add-Member -NotePropertyName Restored -NotePropertyValue $isRestored -Force
    $st | Add-Member -NotePropertyName Purged -NotePropertyValue $isPurged -Force
    $st | Add-Member -NotePropertyName Committed -NotePropertyValue $committed -Force
    $st | Add-Member -NotePropertyName Open -NotePropertyValue $open -Force
  }

  return $byOp
}

# ---------------------------------------------------------------------------
# Safe deletion (never follows reparse points)
# ---------------------------------------------------------------------------

function Remove-TreeNoFollow {
  param([string]$Path)

  $result = [pscustomobject]@{
    Files = [int64]0
    Dirs  = [int64]0
    Links = [int64]0
    Bytes = [int64]0
    Errors = New-Object System.Collections.Generic.List[string]
  }

  $stack = New-Object System.Collections.Generic.Stack[object]
  $stack.Push([pscustomobject]@{ Path = $Path; Visited = $false })

  while ($stack.Count -gt 0) {
    $cur = $stack.Pop()
    try {
      $di = New-Object System.IO.DirectoryInfo $cur.Path
      if ($cur.Visited) {
        [System.IO.Directory]::Delete($di.FullName, $false)
        $result.Dirs++
        continue
      }
      if (Test-ReparsePoint $di) {
        [System.IO.Directory]::Delete($di.FullName, $false)
        $result.Links++
        continue
      }
      $stack.Push([pscustomobject]@{ Path = $di.FullName; Visited = $true })
      foreach ($f in $di.EnumerateFiles()) {
        try {
          if (Test-ReparsePoint $f) {
            [System.IO.File]::Delete($f.FullName)
            $result.Links++
          } else {
            $result.Bytes += $f.Length
            [System.IO.File]::Delete($f.FullName)
            $result.Files++
          }
        } catch {
          try {
            [System.IO.File]::SetAttributes($f.FullName, [System.IO.FileAttributes]::Normal)
            [System.IO.File]::Delete($f.FullName)
            $result.Files++
          } catch { $result.Errors.Add("$($f.FullName): $($_.Exception.Message)") }
        }
      }
      foreach ($d in $di.EnumerateDirectories()) {
        $stack.Push([pscustomobject]@{ Path = $d.FullName; Visited = $false })
      }
    } catch {
      $result.Errors.Add("$($cur.Path): $($_.Exception.Message)")
    }
  }

  return $result
}

# ---------------------------------------------------------------------------
# Misc
# ---------------------------------------------------------------------------

function Test-IsAdmin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p = New-Object Security.Principal.WindowsPrincipal($id)
  return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-NewOperationId {
  return "$(Get-Date -Format 'yyyyMMdd-HHmmss')-$([guid]::NewGuid().ToString('N').Substring(0,6))"
}

function Format-GB {
  param([int64]$Bytes)
  return ('{0:N2} GB' -f ($Bytes / 1GB))
}

function Get-PlanItem {
  param([string]$PlanPath, [string]$ItemId)

  if (-not (Test-Path -LiteralPath $PlanPath)) { throw "Plan not found: $PlanPath" }
  $plan = ConvertFrom-JsonSafe (Get-Content -LiteralPath $PlanPath -Raw)
  if (-not $plan.items) { throw "Plan has no items: $PlanPath" }

  $items = @($plan.items)
  if ($ItemId) {
    $match = @($items | Where-Object { $_.id -eq $ItemId })
    if ($match.Count -ne 1) { throw "Plan item not found or ambiguous: $ItemId" }
    return $match[0]
  }
  if ($items.Count -ne 1) {
    throw "Plan has $($items.Count) items; specify -PlanItemId."
  }
  return $items[0]
}

function Test-PlanApproval {
  param($Item)
  if (-not $Item.approval -or -not $Item.approval.approved_by -or -not $Item.approval.item_sha256) {
    return [pscustomobject]@{ Ok = $false; Reason = 'Plan item is not approved (missing approval block).' }
  }
  $expected = Get-ItemHash $Item
  if ($expected -ne $Item.approval.item_sha256) {
    return [pscustomobject]@{ Ok = $false; Reason = 'Plan item changed after approval (hash mismatch). Re-approve it.' }
  }
  return [pscustomobject]@{ Ok = $true; Reason = "Approved by $($Item.approval.approved_by) at $($Item.approval.approved_at)" }
}
