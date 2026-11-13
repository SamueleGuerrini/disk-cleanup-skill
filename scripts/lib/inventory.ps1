<#
  Inventory engine for the reporting layer.

  One pass over a root produces bounded aggregates (no per-file list kept in
  memory), so a multi-million-file volume can be scanned without exhausting RAM.

  What is kept:
    * per-directory direct bytes/files (totals are summed at report time)
    * extension, year and risk totals
    * the largest files (bounded)
    * same-size groups (duplicate candidates, bounded)
    * cache hit counters and scan errors

  Reparse points are never followed. Cloud placeholders are counted as offline
  and contribute their logical size only (use -PhysicalSize for allocated size).

  Dot-source from a script:
    . (Join-Path $PSScriptRoot 'lib\inventory.ps1')
#>

if (-not (Get-Command Get-RiskLevelFast -ErrorAction SilentlyContinue)) {
  . (Join-Path $PSScriptRoot 'risk.ps1')
}

$script:InventoryCacheVersion = 1

# ---------------------------------------------------------------------------
# Cache
# ---------------------------------------------------------------------------

function Get-InventoryCachePath {
  param([string]$Root, [string]$VolumeSerial)

  $base = Join-Path $env:LOCALAPPDATA 'disk-cleanup\cache'
  $key = Get-StringSha256 (($Root + '|' + $VolumeSerial).ToLowerInvariant())
  return (Join-Path $base ($key.Substring(0, 24) + '.json.gz'))
}

function Read-InventoryCache {
  param([string]$Path, [string]$Root, [string]$VolumeSerial, [int]$MaxAgeHours)

  if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
  try {
    $age = (Get-Date) - (Get-Item -LiteralPath $Path).LastWriteTime
    if ($MaxAgeHours -gt 0 -and $age.TotalHours -gt $MaxAgeHours) { return $null }

    $fs = [System.IO.File]::OpenRead($Path)
    try {
      $gz = New-Object System.IO.Compression.GZipStream($fs, [System.IO.Compression.CompressionMode]::Decompress)
      try {
        $reader = New-Object System.IO.StreamReader($gz, [System.Text.Encoding]::UTF8)
        $json = $reader.ReadToEnd()
      } finally { $gz.Dispose() }
    } finally { $fs.Dispose() }

    $cache = ConvertFrom-JsonSafe $json
    if ($cache.version -ne $script:InventoryCacheVersion) { return $null }
    if ($cache.root -ne $Root) { return $null }
    if ($VolumeSerial -and $cache.serial -ne $VolumeSerial) { return $null }
    return $cache
  } catch {
    return $null
  }
}

function Write-InventoryCache {
  param([string]$Path, [string]$Root, [string]$VolumeSerial, $Dirs)

  if (-not $Path) { return }
  try {
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { [System.IO.Directory]::CreateDirectory($dir) | Out-Null }

    $payload = [ordered]@{
      version = $script:InventoryCacheVersion
      root    = $Root
      serial  = $VolumeSerial
      created = (Get-Date).ToString('o')
      dirs    = $Dirs
    }
    $json = ConvertTo-Json $payload -Depth 10 -Compress

    $tmp = "$Path.tmp.$([guid]::NewGuid().ToString('N'))"
    $fs = [System.IO.File]::Create($tmp)
    try {
      $gz = New-Object System.IO.Compression.GZipStream($fs, [System.IO.Compression.CompressionMode]::Compress)
      try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        $gz.Write($bytes, 0, $bytes.Length)
      } finally { $gz.Dispose() }
    } finally { $fs.Dispose() }
    Move-Item -LiteralPath $tmp -Destination $Path -Force
  } catch {
    # A cache failure must never fail the audit.
  }
}

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

function New-InventoryState {
  param([string]$Root)

  [pscustomobject]@{
    Root           = $Root
    StartedUtc     = (Get-Date).ToUniversalTime()
    FinishedUtc    = $null
    Partial        = $false
    PartialReason  = ''
    Files          = [int64]0
    Bytes          = [int64]0
    Allocated      = [int64]0
    Dirs           = [int64]0
    Errors         = [int64]0
    Links          = [int64]0
    Offline        = [int64]0
    CacheHits      = [int64]0
    CacheDirs      = [int64]0
    Sampled        = $false
    DirsMap        = @{}
    Ext            = @{}
    Years          = @{}
    Risk           = @{}
    Large          = New-Object System.Collections.Generic.List[object]
    SizeGroups     = @{}
    DupTruncated   = $false
    Locked         = New-Object System.Collections.Generic.List[object]
    ErrorSamples   = New-Object System.Collections.Generic.List[string]
    SampleDirs     = [int64]0
    SampleBytes    = [int64]0
  }
}

function Merge-InventoryState {
  param($Target, $Source)

  $Target.Files += $Source.Files
  $Target.Bytes += $Source.Bytes
  $Target.Allocated += $Source.Allocated
  $Target.Dirs += $Source.Dirs
  $Target.Errors += $Source.Errors
  $Target.Links += $Source.Links
  $Target.Offline += $Source.Offline
  $Target.CacheHits += $Source.CacheHits
  $Target.CacheDirs += $Source.CacheDirs
  $Target.SampleDirs += $Source.SampleDirs
  $Target.SampleBytes += $Source.SampleBytes
  if ($Source.Partial) {
    $Target.Partial = $true
    if (-not $Target.PartialReason) { $Target.PartialReason = $Source.PartialReason }
  }

  foreach ($k in $Source.DirsMap.Keys) {
    $s = $Source.DirsMap[$k]
    if ($Target.DirsMap.ContainsKey($k)) {
      $t = $Target.DirsMap[$k]
      $t.b += $s.b; $t.f += $s.f; $t.a += $s.a
    } else {
      $Target.DirsMap[$k] = @{ b = [int64]$s.b; f = [int64]$s.f; a = [int64]$s.a }
    }
  }
  foreach ($map in @('Ext', 'Years', 'Risk')) {
    foreach ($k in $Source.$map.Keys) {
      $s = $Source.$map[$k]
      if ($Target.$map.ContainsKey($k)) {
        $t = $Target.$map[$k]
        $t.b += $s.b; $t.c += $s.c
      } else {
        $Target.$map[$k] = @{ b = [int64]$s.b; c = [int64]$s.c }
      }
    }
  }
  foreach ($item in $Source.Large) { $Target.Large.Add($item) }
  foreach ($k in $Source.SizeGroups.Keys) {
    $s = $Source.SizeGroups[$k]
    if ($Target.SizeGroups.ContainsKey($k)) {
      $t = $Target.SizeGroups[$k]
      $t.n += $s.n
      foreach ($p in $s.p) { if ($t.p.Count -lt 12) { $t.p.Add($p) } }
    } else {
      $Target.SizeGroups[$k] = @{ n = [int64]$s.n; p = (New-Object System.Collections.Generic.List[string]) }
      foreach ($p in $s.p) { if ($Target.SizeGroups[$k].p.Count -lt 12) { $Target.SizeGroups[$k].p.Add($p) } }
    }
  }
  foreach ($item in $Source.Locked) { $Target.Locked.Add($item) }
  if ($Source.DupTruncated) { $Target.DupTruncated = $true }
}

# ---------------------------------------------------------------------------
# Aggregation
# ---------------------------------------------------------------------------

function Add-InventoryFile {
  param(
    $State,
    [string]$Directory,
    [string]$Name,
    [int64]$Size,
    [int64]$Allocated,
    [int64]$LastWriteTicks,
    [int]$Attributes,
    $Options
  )

  $state.Files++
  $state.Bytes += $Size
  $state.Allocated += $Allocated

  $d = $state.DirsMap[$Directory]
  if (-not $d) {
    $d = @{ b = [int64]0; f = [int64]0; a = [int64]0 }
    $state.DirsMap[$Directory] = $d
  }
  $d.b += $Size; $d.f++; $d.a += $Allocated

  $ext = [System.IO.Path]::GetExtension($Name).ToLowerInvariant()
  if (-not $ext) { $ext = '(none)' }
  $e = $state.Ext[$ext]
  if (-not $e) { $e = @{ b = [int64]0; c = [int64]0 }; $state.Ext[$ext] = $e }
  $e.b += $Size; $e.c++

  if ($LastWriteTicks -gt 0) {
    $year = [string]([datetime]::FromFileTimeUtc($LastWriteTicks).Year)
    $y = $state.Years[$year]
    if (-not $y) { $y = @{ b = [int64]0; c = [int64]0 }; $state.Years[$year] = $y }
    $y.b += $Size; $y.c++
  }

  $full = Join-Path $Directory $Name
  $level = Get-RiskLevelFast -Path $full -Extension $ext -LastWriteTicks $LastWriteTicks
  $r = $state.Risk[$level]
  if (-not $r) { $r = @{ b = [int64]0; c = [int64]0 }; $state.Risk[$level] = $r }
  $r.b += $Size; $r.c++

  if ($Size -ge $script:InvLargeMin) {
    $state.Large.Add([pscustomobject]@{
        path = $full; bytes = $Size; lwt = $LastWriteTicks; risk = $level
      })
    if ($state.Large.Count -gt ($script:InvLargeLimit * 4)) {
      $kept = @($state.Large | Sort-Object bytes -Descending | Select-Object -First $script:InvLargeLimit)
      $state.Large.Clear()
      foreach ($k in $kept) { $state.Large.Add($k) }
    }
  }

  if ($Size -ge $script:InvDupMin) {
    $key = [string]$Size
    $g = $state.SizeGroups[$key]
    if (-not $g) {
      if ($state.SizeGroups.Count -lt $script:InvDupGroupLimit) {
        $g = @{ n = [int64]0; p = (New-Object System.Collections.Generic.List[string]) }
        $state.SizeGroups[$key] = $g
      } else {
        $state.DupTruncated = $true
        $g = $null
      }
    }
    if ($g) {
      $g.n++
      if ($g.p.Count -lt 12) { $g.p.Add($full) }
    }
  }
}

function Test-InventoryStop {
  param($State, $Options)

  if ($Options.MaxFiles -gt 0 -and $State.Files -ge $Options.MaxFiles) {
    $State.Partial = $true
    $State.PartialReason = "file limit reached ($($Options.MaxFiles))"
    return $true
  }
  if ($Options.DeadlineUtc -and (Get-Date).ToUniversalTime() -ge $Options.DeadlineUtc) {
    $State.Partial = $true
    $State.PartialReason = "time limit reached ($($Options.MaxSeconds)s)"
    return $true
  }
  if ($Options.MemoryLimitMB -gt 0 -and ($State.Files % 2000) -eq 0) {
    $usedMB = [System.GC]::GetTotalMemory($false) / 1MB
    if ($usedMB -gt $Options.MemoryLimitMB) {
      $State.Partial = $true
      $State.PartialReason = "memory limit reached ($($Options.MemoryLimitMB) MB)"
      return $true
    }
  }
  return $false
}

function Invoke-InventoryScanInternal {
  param([string]$Root, [hashtable]$Options)

  $script:InvLargeMin = [int64]$Options.LargeFileMinBytes
  $script:InvLargeLimit = [int]$Options.LargeFileCount
  $script:InvDupMin = [int64]$Options.DupMinBytes
  $script:InvDupGroupLimit = [int]$Options.DupGroupLimit

  $state = New-InventoryState -Root $Root
  $state.Sampled = [bool]$Options.SampleSeconds

  $cache = $null
  if ($Options.UseCache -and $Options.CachePath -and -not $Options.RefreshCache) {
    $cache = Read-InventoryCache -Path $Options.CachePath -Root $Root -VolumeSerial $Options.VolumeSerial -MaxAgeHours $Options.CacheMaxAgeHours
  }
  $newCache = @{}

  $stack = New-Object System.Collections.Generic.Stack[string]
  $stack.Push($Root)
  $sinceProgress = [datetime]::UtcNow
  $sampleDeadline = $null
  if ($Options.SampleSeconds -gt 0) {
    $sampleDeadline = [datetime]::UtcNow.AddSeconds($Options.SampleSeconds)
  }

  while ($stack.Count -gt 0) {
    $dir = $stack.Pop()

    if (Test-InventoryStop -State $state -Options $Options) { break }
    if ($sampleDeadline -and [datetime]::UtcNow -ge $sampleDeadline) {
      $state.Partial = $true
      $state.PartialReason = "sample window reached ($($Options.SampleSeconds)s)"
      $state.Sampled = $true
      break
    }

    $state.Dirs++
    $di = $null
    try { $di = New-Object System.IO.DirectoryInfo $dir } catch { $state.Errors++; continue }
    if (-not $di.Exists) { continue }

    $entry = $null
    if ($cache) {
      $prop = $null
      try { $prop = $cache.dirs.PSObject.Properties[$dir] } catch { $prop = $null }
      if ($prop) {
        $c = $prop.Value
        if ([int64]$c.m -eq $di.LastWriteTimeUtc.Ticks) { $entry = $c }
      }
    }

    if ($entry) {
      $state.CacheHits++
      $state.CacheDirs++
      $state.Links += [int64]$entry.l
      $state.Offline += [int64]$entry.o
      foreach ($f in $entry.f) {
        if ($Options.MaxFiles -gt 0 -and $state.Files -ge $Options.MaxFiles) { break }
        try {
          Add-InventoryFile -State $state -Directory $dir -Name ([string]$f[0]) -Size ([int64]$f[1]) `
            -Allocated ([int64]$f[2]) -LastWriteTicks ([int64]$f[3]) -Attributes ([int]$f[4]) -Options $Options
        } catch {
          $state.Errors++
          if ($state.ErrorSamples.Count -lt 20) { $state.ErrorSamples.Add(("$dir : " + $_.Exception.Message)) }
        }
      }
      if (Test-InventoryStop -State $state -Options $Options) { break }
      foreach ($sub in $entry.d) {
        $child = Join-Path $dir $sub
        if (-not $state.DirsMap.ContainsKey($child)) {
          $state.DirsMap[$child] = @{ b = [int64]0; f = [int64]0; a = [int64]0 }
        }
        $stack.Push($child)
      }
      $newCache[$dir] = $entry
      continue
    }

    $files = New-Object System.Collections.Generic.List[object]
    $subs = New-Object System.Collections.Generic.List[string]
    $links = [int64]0
    $offline = [int64]0
    $stopNow = $false

    try {
      foreach ($item in $di.EnumerateFileSystemInfos()) {
        # With a file cap, check every entry so the run stops at the cap instead of
        # overshooting by up to 511 files. Without a cap, keep the cheap modulo probe.
        $checkNow = ($Options.MaxFiles -gt 0 -and $state.Files -ge $Options.MaxFiles) -or (($state.Files % 512) -eq 0)
        if ($checkNow -and (Test-InventoryStop -State $state -Options $Options)) {
          $stopNow = $true
          break
        }
        $attrs = [int]$item.Attributes
        if (($attrs -band [int][System.IO.FileAttributes]::ReparsePoint) -ne 0) {
          $links++
          continue
        }
        if ($item -is [System.IO.DirectoryInfo]) {
          $subs.Add($item.Name)
          $child = Join-Path $dir $item.Name
          if (-not $state.DirsMap.ContainsKey($child)) {
            $state.DirsMap[$child] = @{ b = [int64]0; f = [int64]0; a = [int64]0 }
          }
          continue
        }

        $size = [int64]$item.Length
        $lwt = [int64]$item.LastWriteTimeUtc.ToFileTimeUtc()
        $alloc = $size
        if ($Options.PhysicalSize) {
          $a = Get-AllocatedBytes -Path $item.FullName
          if ($null -ne $a) { $alloc = [int64]$a }
        }
        if (($attrs -band 0x1000) -ne 0 -or ($attrs -band 0x400000) -ne 0) {
          $offline++
          $alloc = [int64]0
        }

        try {
          Add-InventoryFile -State $state -Directory $dir -Name $item.Name -Size $size -Allocated $alloc `
            -LastWriteTicks $lwt -Attributes $attrs -Options $Options
        } catch {
          $state.Errors++
          if ($state.ErrorSamples.Count -lt 20) { $state.ErrorSamples.Add(("$dir\$($item.Name) : " + $_.Exception.Message)) }
        }
        $files.Add(@($item.Name, $size, $alloc, $lwt, $attrs))
      }
    } catch {
      $state.Errors++
      if ($state.ErrorSamples.Count -lt 20) { $state.ErrorSamples.Add(("$dir : " + $_.Exception.Message)) }
    }

    $state.Links += $links
    $state.Offline += $offline
    if ($stopNow) { break }
    if ($Options.UseCache) {
      $newCache[$dir] = @{ m = $di.LastWriteTimeUtc.Ticks; f = $files; d = $subs; l = $links; o = $offline }
    }

    foreach ($s in $subs) { $stack.Push((Join-Path $dir $s)) }

    if ($Options.OnProgress -and ((Get-Date).ToUniversalTime() - $sinceProgress).TotalSeconds -ge $Options.ProgressIntervalSeconds) {
      $sinceProgress = [datetime]::UtcNow
      & $Options.OnProgress $state
    }
  }

  if ($Options.UseCache -and -not $state.Partial) {
    Write-InventoryCache -Path $Options.CachePath -Root $Root -VolumeSerial $Options.VolumeSerial -Dirs $newCache
  }

  if ($state.Sampled) {
    $state.SampleDirs = $state.Dirs
    $state.SampleBytes = $state.Bytes
  }

  $state.FinishedUtc = (Get-Date).ToUniversalTime()
  return $state
}

<#
  Rehydrate a state that was serialized by a worker runspace. JSON turns the
  hashtables into PSCustomObjects and the generic lists into arrays, so they must
  be rebuilt before Merge-InventoryState can touch them.
#>
function ConvertFrom-InventoryStateJson {
  param([string]$Json)

  $o = ConvertFrom-JsonSafe $Json
  $s = New-InventoryState -Root $o.Root
  foreach ($name in @('Partial', 'PartialReason', 'Files', 'Bytes', 'Allocated', 'Dirs', 'Errors',
      'Links', 'Offline', 'CacheHits', 'CacheDirs', 'Sampled', 'DupTruncated', 'SampleDirs', 'SampleBytes')) {
    $s.$name = $o.$name
  }
  $s.StartedUtc = [datetime]$o.StartedUtc
  $s.FinishedUtc = [datetime]$o.FinishedUtc

  foreach ($name in @('DirsMap', 'Ext', 'Years', 'Risk')) {
    $map = @{}
    $src = $o.$name
    if ($src) {
      foreach ($p in $src.PSObject.Properties) {
        $v = $p.Value
        $map[$p.Name] = @{ b = [int64]$v.b; f = [int64]$v.f; c = [int64]$v.c; a = [int64]$v.a }
      }
    }
    $s.$name = $map
  }

  $s.Large = New-Object System.Collections.Generic.List[object]
  foreach ($l in @($o.Large)) { if ($l) { $s.Large.Add($l) } }

  $s.SizeGroups = @{}
  if ($o.SizeGroups) {
    foreach ($p in $o.SizeGroups.PSObject.Properties) {
      $g = @{ n = [int64]$p.Value.n; p = (New-Object System.Collections.Generic.List[string]) }
      foreach ($path in @($p.Value.p)) { $g.p.Add([string]$path) }
      $s.SizeGroups[$p.Name] = $g
    }
  }

  $s.Locked = New-Object System.Collections.Generic.List[object]
  foreach ($l in @($o.Locked)) { if ($l) { $s.Locked.Add($l) } }

  return $s
}

function Invoke-InventoryScan {
  param(
    [string]$Root,
    [hashtable]$Options
  )

  $script:InvLargeMin = [int64]$Options.LargeFileMinBytes
  $script:InvLargeLimit = [int]$Options.LargeFileCount
  $script:InvDupMin = [int64]$Options.DupMinBytes
  $script:InvDupGroupLimit = [int]$Options.DupGroupLimit

  $workers = [int]$Options.Workers
  if ($workers -lt 1) { $workers = 1 }
  if ($PSVersionTable.PSVersion.Major -lt 7) { $workers = 1 }

  if ($workers -le 1 -or $Options.SampleSeconds -gt 0) {
    $single = Invoke-InventoryScanInternal -Root $Root -Options $Options
    $single | Add-Member -NotePropertyName Workers -NotePropertyValue 1 -Force
    return $single
  }

  # Partition by top-level directory so workers never share a subtree.
  $parts = @()
  $rootLinks = [int64]0
  try {
    foreach ($d in ([System.IO.DirectoryInfo]$Root).EnumerateDirectories()) {
      if (([int]$d.Attributes -band [int][System.IO.FileAttributes]::ReparsePoint) -ne 0) { $rootLinks++; continue }
      $parts += $d.FullName
    }
  } catch { }

  if ($parts.Count -le 1) {
    return (Invoke-InventoryScanInternal -Root $Root -Options $Options)
  }

  $state = New-InventoryState -Root $Root
  $state.Sampled = $false
  $state.Dirs = 1
  $state.Links += $rootLinks
  $lib = Join-Path $PSScriptRoot 'inventory.ps1'
  $workerOptions = $Options.Clone()
  $workerOptions.OnProgress = $null

  # Files directly in the root belong to no partition, so count them here.
  try {
    foreach ($f in ([System.IO.DirectoryInfo]$Root).EnumerateFiles()) {
      $attrs = [int]$f.Attributes
      if (($attrs -band [int][System.IO.FileAttributes]::ReparsePoint) -ne 0) { $state.Links++; continue }
      $size = [int64]$f.Length
      $lwt = [int64]$f.LastWriteTimeUtc.ToFileTimeUtc()
      $alloc = $size
      if ($Options.PhysicalSize) {
        $a = Get-AllocatedBytes -Path $f.FullName
        if ($null -ne $a) { $alloc = [int64]$a }
      }
      if (($attrs -band 0x1000) -ne 0 -or ($attrs -band 0x400000) -ne 0) { $state.Offline++; $alloc = [int64]0 }
      try {
        Add-InventoryFile -State $state -Directory $Root -Name $f.Name -Size $size -Allocated $alloc `
          -LastWriteTicks $lwt -Attributes $attrs -Options $Options
      } catch { $state.Errors++ }
    }
  } catch { $state.Errors++ }

  if ($Options.OnProgress) { & $Options.OnProgress $state }

  $done = 0
  $results = $parts | ForEach-Object -Parallel {
    $libPath = $using:lib
    . $libPath
    . (Join-Path (Split-Path -Parent $libPath) 'common.ps1')
    # $using: is materialized once per runspace and runspaces are reused across
    # items, so clone before mutating anything.
    $opts = ($using:workerOptions).Clone()
    $opts.OnProgress = $null
    if ($opts.UseCache -and $opts.CachePath) {
      # Each worker owns one subtree, so each gets its own cache file. Sharing one
      # file would make workers overwrite each other's directory snapshots.
      $suffix = (Get-StringSha256 $_).Substring(0, 8)
      $opts.CachePath = $opts.CachePath -replace '\.json\.gz$', "-$suffix.json.gz"
    }
    $s = Invoke-InventoryScanInternal -Root $_ -Options $opts
    $s | ConvertTo-Json -Depth 10 -Compress
  } -ThrottleLimit $workers

  foreach ($json in $results) {
    $part = ConvertFrom-InventoryStateJson -Json $json
    Merge-InventoryState -Target $state -Source $part
    $done++
    if ($Options.OnProgress) { & $Options.OnProgress $state }
  }

  $state | Add-Member -NotePropertyName Workers -NotePropertyValue $workers -Force
  $state.FinishedUtc = (Get-Date).ToUniversalTime()
  return $state
}

# ---------------------------------------------------------------------------
# Report projection
# ---------------------------------------------------------------------------

function ConvertTo-InventoryReport {
  param(
    $State,
    $Volume,
    [int64]$MinDirBytes = 1MB,
    [int]$MaxTreeNodes = 20000,
    [int]$MaxExt = 40,
    [int]$MaxDupGroups = 2000,
    [int]$MaxLarge = 500
  )

  $root = $State.Root

  # Sum directory totals bottom-up.
  $totals = @{}
  foreach ($k in $State.DirsMap.Keys) {
    $totals[$k] = [int64]$State.DirsMap[$k].b
  }
  if (-not $totals.ContainsKey($root)) { $totals[$root] = [int64]0 }
  $ordered = @($State.DirsMap.Keys | Sort-Object { $_.Length } -Descending)
  foreach ($k in $ordered) {
    $parent = Split-Path -Parent $k
    if ($parent -and $totals.ContainsKey($parent)) {
      $totals[$parent] += $totals[$k]
    }
  }
  if (-not $totals.ContainsKey($root)) { $totals[$root] = [int64]0 }

  $nodes = New-Object System.Collections.Generic.List[object]
  $included = @{}
  foreach ($k in $totals.Keys) {
    if ($k -eq $root) { continue }
    if ($totals[$k] -ge $MinDirBytes) {
      $included[$k] = $true
      $p = Split-Path -Parent $k
      while ($p -and $p.Length -ge $root.Length -and -not $included.ContainsKey($p)) {
        $included[$p] = $true
        if ($p -eq $root) { break }
        $p = Split-Path -Parent $p
      }
    }
  }
  $included[$root] = $true

  $truncated = $false
  foreach ($k in ($included.Keys | Sort-Object { $totals[$_] } -Descending)) {
    if ($nodes.Count -ge $MaxTreeNodes) { $truncated = $true; break }
    $rel = $k.Substring($root.Length).TrimStart('\')
    $nodes.Add([pscustomobject]@{
        path   = $rel
        name   = $(if ($rel) { Split-Path -Leaf $k } else { $k })
        bytes  = $totals[$k]
        files  = $(if ($State.DirsMap.ContainsKey($k)) { $State.DirsMap[$k].f } else { 0 })
        parent = $(if ($rel) { Split-Path -Parent $rel } else { '' })
      })
  }

  $ext = @($State.Ext.Keys | ForEach-Object {
      [pscustomobject]@{ ext = $_; bytes = $State.Ext[$_].b; files = $State.Ext[$_].c }
    } | Sort-Object bytes -Descending | Select-Object -First $MaxExt)

  $years = @($State.Years.Keys | Sort-Object | ForEach-Object {
      [pscustomobject]@{ year = $_; bytes = $State.Years[$_].b; files = $State.Years[$_].c }
    })

  $risk = @('green', 'yellow', 'orange', 'red', 'unrated') | ForEach-Object {
    $lvl = $_
    $v = $State.Risk[$lvl]
    [pscustomobject]@{
      level = $lvl
      bytes = $(if ($v) { $v.b } else { 0 })
      files = $(if ($v) { $v.c } else { 0 })
      action = (Get-RiskAction $lvl)
    }
  }

  $large = @($State.Large | Sort-Object bytes -Descending | Select-Object -First $MaxLarge | ForEach-Object {
      [pscustomobject]@{
        path = $_.path
        bytes = $_.bytes
        last_write = $(if ($_.lwt -gt 0) { [datetime]::FromFileTimeUtc($_.lwt).ToString('o') } else { $null })
        risk = $_.risk
        action = (Get-RiskAction $_.risk)
      }
    })

  $dups = @($State.SizeGroups.Keys | ForEach-Object {
      $g = $State.SizeGroups[$_]
      if ($g.n -lt 2) { return }
      [pscustomobject]@{
        size = [int64]$_
        count = $g.n
        wasted = [int64]$_ * ($g.n - 1)
        paths = $g.p.ToArray()
      }
    } | Sort-Object wasted -Descending | Select-Object -First $MaxDupGroups)

  [pscustomobject]@{
    schema = 1
    root = $root
    volume = $Volume
    meta = [pscustomobject]@{
      started = $State.StartedUtc.ToString('o')
      finished = $(if ($State.FinishedUtc) { $State.FinishedUtc.ToString('o') } else { (Get-Date).ToUniversalTime().ToString('o') })
      elapsed_seconds = [math]::Round((($(if ($State.FinishedUtc) { $State.FinishedUtc } else { Get-Date }).ToUniversalTime() - $State.StartedUtc).TotalSeconds), 1)
      files = $State.Files
      dirs = $State.Dirs
      bytes = $State.Bytes
      allocated = $State.Allocated
      errors = $State.Errors
      links = $State.Links
      offline = $State.Offline
      partial = $State.Partial
      partial_reason = $State.PartialReason
      sampled = $State.Sampled
      cache_hits = $State.CacheHits
      cache_dirs = $State.CacheDirs
      dup_truncated = $State.DupTruncated
      tree_truncated = $truncated
      workers = $(if ($State.Workers) { $State.Workers } else { 1 })
    }
    tree = $nodes.ToArray()
    ext = $ext
    years = $years
    risk = @($risk)
    large = $large
    dups = $dups
  }
}
