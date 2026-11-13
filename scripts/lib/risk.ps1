<#
  Risk classification for the reporting layer.

  The four reported levels are the ones from the request:

    green   low       recommended for deletion (temporary/regenerable)
    yellow  medium    recommended for archiving/moving
    orange  high      requires explicit user confirmation
    red     prohibited never move or delete

  Everything that does not match a rule is 'unrated' (grey), never green. This is
  deliberate: an unknown folder must stay user-led, and a report must not imply
  that an unrecognised file is safe to delete.

  Dot-source from a script:
    . (Join-Path $PSScriptRoot 'lib\risk.ps1')
#>

$script:RiskGreenExt = @(
  '.tmp', '.temp', '.crdownload', '.part', '.partial', '.download',
  '.3dmbak', '.chk', '.etl'
)

$script:RiskYellowExt = @(
  '.zip', '.7z', '.rar', '.tar', '.gz', '.bz2', '.xz', '.iso', '.img',
  '.mp4', '.mkv', '.avi', '.mov', '.wmv', '.flv', '.webm', '.m4v', '.mpg', '.mpeg',
  '.mp3', '.wav', '.flac', '.aac', '.ogg', '.m4a'
)

$script:RiskOrangeExt = @(
  '.psd', '.psb', '.ai', '.indd', '.blend', '.blend1', '.3dm', '.max', '.c4d', '.skp',
  '.safetensors', '.ckpt', '.onnx', '.pt', '.pth', '.pkl', '.h5', '.pb',
  '.pdf', '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx', '.odt', '.ods', '.odp',
  '.tex', '.bib', '.epub', '.mobi',
  '.sql', '.db', '.sqlite', '.sqlite3', '.mdb', '.accdb',
  '.exe', '.msi', '.msix', '.appx'
)

$script:RiskGreenPathFragments = @(
  '\appdata\local\temp\',
  '\windows\temp\',
  '\softwaredistribution\download\',
  '\deliveryoptimization\cache\',
  '\d3dscache\',
  '\crashdumps\',
  '\wer\reportarchive\',
  '\wer\reportqueue\',
  '\inetcache\',
  '\nvidia\dxcache\',
  '\nvidia\glcache\',
  '\microsoft\windows\explorer\'
)

$script:RiskRedExact = @()
$script:RiskRedSubtrees = @()
$script:RiskRedFiles = @('pagefile.sys', 'hiberfil.sys', 'swapfile.sys', 'bootmgr', 'bootnxt', 'ntuser.dat')

function Initialize-RiskRules {
  if ($script:RiskRedExact.Count -gt 0) { return }

  $addExact = {
    param([string]$p)
    if ([string]::IsNullOrWhiteSpace($p)) { return }
    $f = [System.IO.Path]::GetFullPath($p)
    if ($f.Length -gt 3) { $f = $f.TrimEnd('\') }
    $script:RiskRedExact += $f
  }
  $addTree = {
    param([string]$p)
    if ([string]::IsNullOrWhiteSpace($p)) { return }
    $f = [System.IO.Path]::GetFullPath($p)
    if ($f.Length -gt 3) { $f = $f.TrimEnd('\') }
    $script:RiskRedSubtrees += $f
  }

  $sys = $env:SystemDrive
  $win = $env:WINDIR
  if ($sys) {
    & $addTree (Join-Path $sys 'Program Files')
    & $addTree (Join-Path $sys 'Program Files (x86)')
    & $addTree (Join-Path $sys 'ProgramData')
    & $addTree (Join-Path $sys 'Recovery')
    & $addTree (Join-Path $sys '$Recycle.Bin')
    & $addTree (Join-Path $sys 'System Volume Information')
    & $addTree (Join-Path $sys 'Boot')
  }
  if ($win) {
    & $addTree $win
    & $addTree (Join-Path $win 'WinSxS')
    & $addTree (Join-Path $win 'Installer')
    & $addTree (Join-Path $win 'System32')
    & $addTree (Join-Path $win 'SysWOW64')
  }

  # These roots must never be moved as a whole; their children can be classified.
  if ($env:USERPROFILE) {
    & $addExact $env:USERPROFILE
    & $addExact (Join-Path $env:USERPROFILE 'AppData')
    & $addExact (Join-Path $env:USERPROFILE 'AppData\Local')
    & $addExact (Join-Path $env:USERPROFILE 'AppData\Roaming')
    & $addExact (Join-Path $env:USERPROFILE 'AppData\LocalLow')
    & $addTree (Join-Path $env:USERPROFILE '.ssh')
    & $addTree (Join-Path $env:USERPROFILE '.gnupg')
    & $addTree (Join-Path $env:USERPROFILE '.aws')
    & $addTree (Join-Path $env:USERPROFILE '.azure')
    & $addTree (Join-Path $env:USERPROFILE '.config')
  }
}

function Get-RiskAction {
  param([string]$Level)
  switch ($Level) {
    'green' { return 'Safe to delete (temporary or regenerable)' }
    'yellow' { return 'Archive or move; verify first' }
    'orange' { return 'User confirmation required' }
    'red' { return 'Never move or delete' }
    default { return 'Inspect; no automatic suggestion' }
  }
}

<#
  Classify one path.

  Has3dmSibling applies to .3dmbak: the backup is only low risk when the matching
  .3dm still exists next to it.
#>
function Get-RiskForPath {
  param(
    [string]$Path,
    [switch]$IsDirectory,
    [datetime]$LastWriteUtc = [datetime]::MinValue,
    [switch]$Has3dmSibling
  )

  Initialize-RiskRules

  $full = [System.IO.Path]::GetFullPath($Path)
  if ($full.Length -gt 3) { $full = $full.TrimEnd('\') }
  $leaf = [System.IO.Path]::GetFileName($full)
  $lower = $full.ToLowerInvariant()
  $withSlash = $lower + '\'

  # 1. Explicit junk cache locations win over the Windows/AppData red subtrees.
  foreach ($frag in $script:RiskGreenPathFragments) {
    if ($withSlash.Contains($frag)) {
      return [pscustomobject]@{ Level = 'green'; Reason = "Temporary/cache location ($frag)"; Action = (Get-RiskAction 'green') }
    }
  }

  # 2. Never-move system files.
  if (-not $IsDirectory -and ($script:RiskRedFiles -contains $leaf.ToLowerInvariant())) {
    return [pscustomobject]@{ Level = 'red'; Reason = 'Kernel or profile system file'; Action = (Get-RiskAction 'red') }
  }

  # 3. Never-move system trees.
  foreach ($p in $script:RiskRedSubtrees) {
    if ($full.Equals($p, [StringComparison]::OrdinalIgnoreCase) -or
        $full.StartsWith($p + '\', [StringComparison]::OrdinalIgnoreCase)) {
      return [pscustomobject]@{ Level = 'red'; Reason = "Protected system path ($p)"; Action = (Get-RiskAction 'red') }
    }
  }
  foreach ($p in $script:RiskRedExact) {
    if ($full.Equals($p, [StringComparison]::OrdinalIgnoreCase)) {
      return [pscustomobject]@{ Level = 'red'; Reason = 'Never move this root as a whole'; Action = (Get-RiskAction 'red') }
    }
  }

  if ($IsDirectory) {
    if ($leaf -ieq '.git') {
      return [pscustomobject]@{ Level = 'orange'; Reason = 'Repository history; regenerate with care'; Action = (Get-RiskAction 'orange') }
    }
    if ($leaf -ieq 'node_modules') {
      return [pscustomobject]@{ Level = 'yellow'; Reason = 'Regenerable dependencies; reinstall after removal'; Action = (Get-RiskAction 'yellow') }
    }
    if ($leaf -match '(?i)(course|tutorial|archive|backup|old|video)') {
      return [pscustomobject]@{ Level = 'yellow'; Reason = 'Name suggests an archive or media collection; user decides'; Action = (Get-RiskAction 'yellow') }
    }
    return [pscustomobject]@{ Level = 'unrated'; Reason = 'No directory rule matched'; Action = (Get-RiskAction 'unrated') }
  }

  $ext = [System.IO.Path]::GetExtension($leaf).ToLowerInvariant()

  # Old installers in Downloads are low risk; installers elsewhere are not.
  if ($ext -in @('.exe', '.msi', '.msix', '.appx')) {
    if ($lower.Contains('\downloads\') -and $LastWriteUtc -ne [datetime]::MinValue -and
        $LastWriteUtc -lt [datetime]::UtcNow.AddDays(-365)) {
      return [pscustomobject]@{ Level = 'green'; Reason = 'Old installer in Downloads (older than 1 year)'; Action = (Get-RiskAction 'green') }
    }
    return [pscustomobject]@{ Level = 'orange'; Reason = 'Installer or executable; may be needed'; Action = (Get-RiskAction 'orange') }
  }

  if ($ext -eq '.3dmbak') {
    if ($Has3dmSibling) {
      return [pscustomobject]@{ Level = 'green'; Reason = 'Backup of an existing .3dm model'; Action = (Get-RiskAction 'green') }
    }
    return [pscustomobject]@{ Level = 'unrated'; Reason = '.3dmbak without a matching .3dm'; Action = (Get-RiskAction 'unrated') }
  }

  if ($script:RiskGreenExt -contains $ext) {
    return [pscustomobject]@{ Level = 'green'; Reason = "Temporary extension ($ext)"; Action = (Get-RiskAction 'green') }
  }
  if ($script:RiskOrangeExt -contains $ext) {
    return [pscustomobject]@{ Level = 'orange'; Reason = "User data or creative artifact ($ext)"; Action = (Get-RiskAction 'orange') }
  }
  if ($script:RiskYellowExt -contains $ext) {
    return [pscustomobject]@{ Level = 'yellow'; Reason = "Media or archive ($ext)"; Action = (Get-RiskAction 'yellow') }
  }

  return [pscustomobject]@{ Level = 'unrated'; Reason = 'No file rule matched'; Action = (Get-RiskAction 'unrated') }
}

function Get-RiskRank {
  param([string]$Level)
  switch ($Level) {
    'red' { return 5 }
    'orange' { return 4 }
    'yellow' { return 3 }
    'green' { return 2 }
    default { return 1 }
  }
}

# ---------------------------------------------------------------------------
# Fast classifier
#
# Called once per file by the inventory engine, so it must not allocate or walk
# lists. Rules are compiled into lookup tables and two regular expressions.
# It deliberately mirrors Get-RiskForPath; when the two disagree, the slow one
# is authoritative and this one is the bug.
# ---------------------------------------------------------------------------

$script:RiskFastReady = $false
$script:RiskFastExtMap = @{}
$script:RiskFastGreenRegex = $null
$script:RiskFastRedRegex = $null

function Initialize-RiskFast {
  if ($script:RiskFastReady) { return }

  $map = @{}
  foreach ($e in $script:RiskYellowExt) { $map[$e] = 'yellow' }
  foreach ($e in $script:RiskOrangeExt) { $map[$e] = 'orange' }
  foreach ($e in $script:RiskGreenExt) { $map[$e] = 'green' }
  $script:RiskFastExtMap = $map

  $green = @(
    '\\appdata\\local\\temp\\',
    '\\windows\\temp\\',
    '\\softwaredistribution\\download\\',
    '\\deliveryoptimization\\cache\\',
    '\\d3dscache\\',
    '\\crashdumps\\',
    '\\wer\\reportarchive\\',
    '\\wer\\reportqueue\\',
    '\\inetcache\\',
    '\\nvidia\\dxcache\\',
    '\\nvidia\\glcache\\',
    '\\microsoft\\windows\\explorer\\'
  ) -join '|'
  $opts = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Compiled
  $script:RiskFastGreenRegex = New-Object System.Text.RegularExpressions.Regex -ArgumentList @($green, $opts)

  $red = '^[a-z]:\\(windows|program files|program files \(x86\)|programdata|recovery|\$recycle\.bin|system volume information|boot)(\\|$)'
  $script:RiskFastRedRegex = New-Object System.Text.RegularExpressions.Regex -ArgumentList @($red, $opts)

  $script:RiskFastReady = $true
}

function Get-RiskLevelFast {
  param(
    [string]$Path,
    [string]$Extension,
    [int64]$LastWriteTicks = 0
  )

  Initialize-RiskFast
  $lower = $Path.ToLowerInvariant()

  if ($script:RiskFastGreenRegex.IsMatch($lower)) { return 'green' }
  if ($script:RiskFastRedRegex.IsMatch($lower)) { return 'red' }

  $ext = $Extension
  if (-not $ext) { $ext = [System.IO.Path]::GetExtension($Path).ToLowerInvariant() }

  if ($ext -eq '.3dmbak') {
    $model = [System.IO.Path]::ChangeExtension($Path, '.3dm')
    if ([System.IO.File]::Exists($model)) { return 'green' }
    return 'unrated'
  }

  if ($ext -in @('.exe', '.msi', '.msix', '.appx')) {
    if ($lower.Contains('\downloads\')) {
      if ($LastWriteTicks -gt 0 -and
          [datetime]::FromFileTimeUtc($LastWriteTicks) -lt [datetime]::UtcNow.AddDays(-365)) {
        return 'green'
      }
    }
    return 'orange'
  }

  $level = $script:RiskFastExtMap[$ext]
  if ($level) { return $level }
  return 'unrated'
}
