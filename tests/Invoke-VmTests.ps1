<#
.SYNOPSIS
  Run the disk-cleanup test suite on a remote/disposable Windows VM.

.DESCRIPTION
  Copies this repository to the target machine, runs tests\run-tests.ps1 there,
  streams the output back, and removes the remote copy afterwards.

  Nothing is executed on the local machine. The suite still creates junctions and
  deletes trees, so the target must be a disposable VM, not a production host.

  Requires PowerShell Remoting on the target (Enable-PSRemoting -Force) and an
  account that can create folders under -RemoteParent.

.PARAMETER ComputerName
  Target host reachable over WinRM.

.PARAMETER VMName
  Hyper-V VM name (uses New-PSSession -VMName; needs the Hyper-V module and
  administrative rights on the host).

.PARAMETER Session
  Reuse an existing PSSession instead of creating one.

.PARAMETER Credential
  Credential for -ComputerName / -VMName.

.PARAMETER RepoPath
  Repository to send. Default: the parent of this tests folder.

.PARAMETER RemoteParent
  Remote working directory. Default: C:\ProgramData\disk-cleanup-vmtest

.PARAMETER Filter
  Only run cases whose name contains this text.

.PARAMETER Keep
  Keep the remote copy and the sandbox folders for inspection.

.PARAMETER SkipCleanup
  Do not remove the remote working directory.

.EXAMPLE
  .\Invoke-VmTests.ps1 -ComputerName 'test-vm' -Credential (Get-Credential)

.EXAMPLE
  .\Invoke-VmTests.ps1 -VMName 'Win11-Test' -Filter 'recovery'
#>
[CmdletBinding(DefaultParameterSetName = 'Computer')]
param(
  [Parameter(ParameterSetName = 'Computer', Mandatory = $true)][string]$ComputerName,
  [Parameter(ParameterSetName = 'VM', Mandatory = $true)][string]$VMName,
  [Parameter(ParameterSetName = 'Session', Mandatory = $true)][System.Management.Automation.Runspaces.PSSession]$Session,
  [pscredential]$Credential,
  [string]$RepoPath = (Split-Path -Parent $PSScriptRoot),
  [string]$RemoteParent = 'C:\ProgramData\disk-cleanup-vmtest',
  [string]$Filter = '',
  [switch]$Keep,
  [switch]$SkipCleanup
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath (Join-Path $RepoPath 'tests\run-tests.ps1'))) {
  throw "Not a disk-cleanup repository: $RepoPath"
}

$session = $null
$ownsSession = $false
switch ($PSCmdlet.ParameterSetName) {
  'Computer' {
    $session = New-PSSession -ComputerName $ComputerName -Credential $Credential -ErrorAction Stop
    $ownsSession = $true
  }
  'VM' {
    if (-not (Get-Command New-PSSession -ErrorAction SilentlyContinue)) { throw 'Hyper-V PowerShell module not available.' }
    $session = New-PSSession -VMName $VMName -Credential $Credential -ErrorAction Stop
    $ownsSession = $true
  }
  'Session' { $session = $Session }
}

$zip = Join-Path $env:TEMP ("disk-cleanup-vmtest-" + [guid]::NewGuid().ToString('N') + '.zip')
$remoteZip = Join-Path $RemoteParent 'repo.zip'
$remoteRepo = Join-Path $RemoteParent 'repo'
$exitCode = 1

try {
  Write-Host "Target: $($session.ComputerName)" -ForegroundColor Cyan
  Write-Host 'Preparing remote workspace...' -ForegroundColor Cyan

  Invoke-Command -Session $session -ScriptBlock {
    param($parent, $repo)
    if (Test-Path -LiteralPath $repo) { Remove-Item -LiteralPath $repo -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
  } -ArgumentList $RemoteParent, $remoteRepo

  Compress-Archive -Path (Join-Path $RepoPath '*') -DestinationPath $zip -Force
  Copy-Item -LiteralPath $zip -Destination $remoteZip -ToSession $session -Force
  Invoke-Command -Session $session -ScriptBlock {
    param($z, $r)
    Expand-Archive -LiteralPath $z -DestinationPath $r -Force
  } -ArgumentList $remoteZip, $remoteRepo

  Write-Host 'Running the suite on the target...' -ForegroundColor Cyan
  $result = Invoke-Command -Session $session -ScriptBlock {
    param($repo, $filter, $keep)
    $exe = Get-Command pwsh -ErrorAction SilentlyContinue
    if (-not $exe) { $exe = Get-Command powershell.exe -ErrorAction SilentlyContinue }
    if (-not $exe) { return [pscustomobject]@{ Output = 'No PowerShell host found.'; ExitCode = 127 } }
    $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $repo 'tests\run-tests.ps1'))
    if ($filter) { $argv += @('-Filter', $filter) }
    if ($keep) { $argv += '-Keep' }
    $text = & $exe.Source @argv *>&1 | Out-String
    return [pscustomobject]@{ Output = $text; ExitCode = $LASTEXITCODE }
  } -ArgumentList $remoteRepo, $Filter, [bool]$Keep

  $result.Output
  $exitCode = [int]$result.ExitCode
} finally {
  if (-not $SkipCleanup) {
    try {
      Invoke-Command -Session $session -ScriptBlock {
        param($parent)
        if (Test-Path -LiteralPath $parent) { Remove-Item -LiteralPath $parent -Recurse -Force -ErrorAction SilentlyContinue }
      } -ArgumentList $RemoteParent
    } catch {
      Write-Warning "Remote cleanup failed: $($_.Exception.Message)"
    }
  }
  if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue }
  if ($ownsSession -and $session) { Remove-PSSession -Session $session -ErrorAction SilentlyContinue }
}

Write-Host ''
if ($exitCode -eq 0) {
  Write-Host 'VM RESULT: PASS' -ForegroundColor Green
} else {
  Write-Host "VM RESULT: FAIL (exit $exitCode)" -ForegroundColor Red
}
exit $exitCode
