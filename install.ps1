<#
.SYNOPSIS
  Install the disk-cleanup skill and the /clean-disk command for OpenCode on Windows.

.DESCRIPTION
  Designed for OpenCode V2 on Windows 10/11. Other agents that read SKILL.md and
  run PowerShell may work, but they were not tested and are not supported.

  Installs into %USERPROFILE%\.config\opencode by default:
    skills\disk-cleanup\     the skill
    commands\clean-disk.md   the slash command

  Run it from a checkout to link that checkout (live updates). Run it from
  anywhere else and it clones the public repository into place. No admin needed.

.PARAMETER ConfigDir
  OpenCode config directory. Default: %USERPROFILE%\.config\opencode

.PARAMETER Copy
  Copy the checkout instead of creating a directory junction.

.PARAMETER Force
  Replace an existing install instead of updating it.

.PARAMETER Uninstall
  Remove the skill and the command installed at these paths.

.EXAMPLE
  .\install.ps1

.EXAMPLE
  .\install.ps1 -Copy

.EXAMPLE
  .\install.ps1 -Uninstall
#>
[CmdletBinding()]
param(
  [string]$ConfigDir = (Join-Path $env:USERPROFILE '.config\opencode'),
  [switch]$Copy,
  [switch]$Force,
  [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$RepoUrl = 'https://github.com/SamueleGuerrini/disk-cleanup-skill.git'

function Info { param([string]$Message) Write-Host $Message -ForegroundColor Cyan }
function Ok { param([string]$Message) Write-Host $Message -ForegroundColor Green }
function Warn { param([string]$Message) Write-Host $Message -ForegroundColor Yellow }
function Fail {
  param([string]$Message)
  Write-Host "ERROR: $Message" -ForegroundColor Red
  exit 1
}

function Test-IsReparsePoint {
  param([string]$Path)
  $item = Get-Item -LiteralPath $Path -Force
  return [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
}

function Remove-InstalledPath {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return }
  if (Test-IsReparsePoint $Path) {
    # Delete the link only, never the target.
    [IO.Directory]::Delete($Path, $false)
  } else {
    Remove-Item -LiteralPath $Path -Recurse -Force
  }
}

if ($ConfigDir.StartsWith('~')) {
  $ConfigDir = Join-Path $HOME $ConfigDir.Substring(1).TrimStart([char[]]@('\', '/'))
}
$ConfigDir = [IO.Path]::GetFullPath($ConfigDir)

$skillsDir = Join-Path $ConfigDir 'skills'
$commandsDir = Join-Path $ConfigDir 'commands'
$skillDir = Join-Path $skillsDir 'disk-cleanup'
$commandTarget = Join-Path $commandsDir 'clean-disk.md'

if ($Uninstall) {
  Remove-InstalledPath $skillDir
  Ok "Removed $skillDir"
  if (Test-Path -LiteralPath $commandTarget) {
    Remove-Item -LiteralPath $commandTarget -Force
    Ok "Removed $commandTarget"
  }
  exit 0
}

# A checkout is present when this script sits next to SKILL.md. When the script
# is piped from the web, $PSScriptRoot is empty and the repo is cloned instead.
$repoRoot = $PSScriptRoot
$localCheckout = $false
if ($repoRoot) {
  $localCheckout = (Test-Path -LiteralPath (Join-Path $repoRoot 'SKILL.md')) -and
    (Test-Path -LiteralPath (Join-Path $repoRoot 'scripts\audit.ps1'))
}

$git = Get-Command git -ErrorAction SilentlyContinue
if (-not $git) {
  Warn 'git was not found on PATH.'
}

Info "OpenCode config: $ConfigDir"
New-Item -ItemType Directory -Force -Path $skillsDir | Out-Null
New-Item -ItemType Directory -Force -Path $commandsDir | Out-Null

$installed = $false

if (Test-Path -LiteralPath $skillDir) {
  if (Test-IsReparsePoint $skillDir) {
    Info 'Replacing the existing junction...'
    Remove-InstalledPath $skillDir
  } elseif (Test-Path -LiteralPath (Join-Path $skillDir '.git')) {
    if ($Force) {
      Info 'Replacing the existing clone...'
      Remove-InstalledPath $skillDir
    } elseif ($git) {
      Info 'Updating the existing clone...'
      & $git.Source -C $skillDir pull --ff-only --quiet
      if ($LASTEXITCODE -ne 0) {
        Warn 'Could not fast-forward the existing clone; keeping it as is.'
      }
      $installed = $true
    } else {
      Warn 'Existing clone found, but git is missing; keeping it as is.'
      $installed = $true
    }
  } elseif ($Force) {
    Info 'Replacing the existing directory...'
    Remove-InstalledPath $skillDir
  } else {
    Fail "Already installed at $skillDir. Re-run with -Force to replace it."
  }
}

if (-not $installed) {
  if ($localCheckout -and -not $Copy) {
    New-Item -ItemType Junction -Path $skillDir -Target $repoRoot | Out-Null
    Ok "Linked $skillDir -> $repoRoot"
  } elseif ($localCheckout) {
    New-Item -ItemType Directory -Force -Path $skillDir | Out-Null
    Get-ChildItem -LiteralPath $repoRoot -Force |
      Where-Object { $_.Name -ne '.git' } |
      ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $skillDir -Recurse -Force
      }
    Ok "Copied $repoRoot -> $skillDir"
  } else {
    if (-not $git) {
      Fail 'git is required to download the skill. Install git, or run this script from a checkout.'
    }
    Info 'Cloning the skill...'
    & $git.Source clone --depth 1 --quiet $RepoUrl $skillDir
    if ($LASTEXITCODE -ne 0) { Fail 'git clone failed.' }
    Ok "Cloned into $skillDir"
  }
}

$commandSource = Join-Path $skillDir 'commands\clean-disk.md'
if (-not (Test-Path -LiteralPath $commandSource)) {
  Fail "Command file missing: $commandSource"
}
Copy-Item -LiteralPath $commandSource -Destination $commandTarget -Force
Ok "Installed $commandTarget"

if (-not (Test-Path -LiteralPath (Join-Path $skillDir 'SKILL.md'))) {
  Fail "Verification failed: $skillDir\SKILL.md is missing."
}
if (-not (Test-Path -LiteralPath $commandTarget)) {
  Fail "Verification failed: $commandTarget is missing."
}

Write-Host ''
Ok 'Done.'
Write-Host "  skill    $skillDir"
Write-Host "  command  $commandTarget"
Write-Host ''
Write-Host 'Next:' -ForegroundColor Cyan
Write-Host '  opencode'
Write-Host '  /clean-disk'
Write-Host ''
Warn 'Designed for OpenCode V2 on Windows. Other agents were not tested.'
if (-not (Get-Command opencode -ErrorAction SilentlyContinue)) {
  Warn 'opencode was not found on PATH; install it before running /clean-disk.'
}
