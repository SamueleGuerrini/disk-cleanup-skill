<#
  Known Windows junk/cache/hotspot locations.

  Shared by scan.ps1 (quick audit) and audit.ps1 (reporting layer) so the two
  never drift apart. Read-only: this only measures what exists.

  Dot-source from a script:
    . (Join-Path $PSScriptRoot 'lib\known.ps1')
#>

if (-not (Get-Command Get-TreeStats -ErrorAction SilentlyContinue)) {
  . (Join-Path $PSScriptRoot 'common.ps1')
}
if (-not (Get-Command Get-RiskLevelFast -ErrorAction SilentlyContinue)) {
  . (Join-Path $PSScriptRoot 'risk.ps1')
}

function Get-KnownLocations {
  param(
    [string]$DriveRoot = ($env:SystemDrive + '\'),
    [string]$UserProfile = $env:USERPROFILE,
    [switch]$PhysicalSize
  )

  $known = [ordered]@{
    'User Temp (%TEMP%)'                = @{ Path = $env:TEMP; Note = 'clear contents; skip in-use' }
    'Windows Temp'                      = @{ Path = (Join-Path $DriveRoot 'Windows\Temp'); Note = 'clear contents; not during updates' }
    'Windows Update Download Cache'     = @{ Path = (Join-Path $DriveRoot 'Windows\SoftwareDistribution\Download'); Note = 'stop wuauserv first' }
    'Delivery Optimization Cache'       = @{ Path = (Join-Path $DriveRoot 'Windows\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache'); Note = 'prefer Settings/Storage' }
    'Explorer Thumb/Icon Cache'         = @{ Path = (Join-Path $UserProfile 'AppData\Local\Microsoft\Windows\Explorer'); Note = 'close Explorer first' }
    'DirectX Shader Cache'              = @{ Path = (Join-Path $UserProfile 'AppData\Local\D3DSCache'); Note = 'games recompile' }
    'WER ReportArchive'                 = @{ Path = (Join-Path $DriveRoot 'ProgramData\Microsoft\Windows\WER\ReportArchive'); Note = 'crash reports' }
    'WER ReportQueue'                   = @{ Path = (Join-Path $DriveRoot 'ProgramData\Microsoft\Windows\WER\ReportQueue'); Note = 'crash reports' }
    'Crash Dumps (Minidump)'            = @{ Path = (Join-Path $DriveRoot 'Windows\Minidump'); Note = 'keep if debugging' }
    'LiveKernelReports'                 = @{ Path = (Join-Path $DriveRoot 'Windows\LiveKernelReports'); Note = 'kernel dumps' }
    'Previous Windows (Windows.old)'    = @{ Path = (Join-Path $DriveRoot 'Windows.old'); Note = 'remove via Disk Cleanup only' }
    'Windows Installer (DO NOT DELETE)' = @{ Path = (Join-Path $DriveRoot 'Windows\Installer'); Note = 'NEVER delete/junction' }
    'WinSxS (DO NOT DELETE)'            = @{ Path = (Join-Path $DriveRoot 'Windows\WinSxS'); Note = 'DISM only; never delete/junction' }
    'Prefetch (leave alone)'            = @{ Path = (Join-Path $DriveRoot 'Windows\Prefetch'); Note = 'no real benefit to clear' }
    'Downloads'                         = @{ Path = (Join-Path $UserProfile 'Downloads'); Note = 'clutter hotspot' }
    'Desktop'                           = @{ Path = (Join-Path $UserProfile 'Desktop'); Note = 'clutter hotspot' }
    'Pictures'                          = @{ Path = (Join-Path $UserProfile 'Pictures'); Note = 'media hotspot' }
    'Videos'                            = @{ Path = (Join-Path $UserProfile 'Videos'); Note = 'media hotspot' }
    'Documents'                         = @{ Path = (Join-Path $UserProfile 'Documents'); Note = 'user data' }
    'Recycle Bin'                       = @{ Path = (Join-Path $DriveRoot '$Recycle.Bin'); Note = 'purging is irreversible' }
  }

  $rows = New-Object System.Collections.Generic.List[object]
  foreach ($k in $known.Keys) {
    $entry = $known[$k]
    $p = $entry.Path
    # Access-denied on system-owned caches is normal when not elevated. Treat the
    # path as absent instead of aborting the whole audit.
    if (-not $p -or -not (Test-Path -LiteralPath $p -ErrorAction SilentlyContinue)) { continue }

    $s = Get-TreeStats -Path $p -PhysicalSize:$PhysicalSize
    $level = Get-RiskLevelFast -Path $p
    $rows.Add([pscustomobject]@{
        item      = $k
        path      = $p
        bytes     = $s.Bytes
        allocated = $s.PhysicalBytes
        files     = $s.Files
        links     = $s.Links
        sparse    = $s.SparseFiles
        offline   = $s.OfflineFiles
        level     = $level
        note      = $entry.Note
      })
  }

  foreach ($f in @('pagefile.sys', 'hiberfil.sys', 'swapfile.sys')) {
    $full = Join-Path $DriveRoot $f
    $i = Get-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
    if ($i) {
      $rows.Add([pscustomobject]@{
          item      = $i.Name
          path      = $full
          bytes     = [int64]$i.Length
          allocated = [int64]$i.Length
          files     = 1
          links     = 0
          sparse    = 0
          offline   = 0
          level     = 'red'
          note      = 'kernel-managed; not junctionable'
        })
    }
  }

  return @($rows | Sort-Object bytes -Descending)
}
