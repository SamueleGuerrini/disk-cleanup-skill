<#
.SYNOPSIS
  Enable Windows Sandbox (Containers-DisposableClientVM) and explain the reboot.

.DESCRIPTION
  Windows Sandbox is a disposable Windows VM. The test suite creates junctions and
  deletes trees, so this is the right place to run it.

  The script self-elevates. Enabling the feature requires administrator rights and
  a reboot. It does not reboot for you.

.EXAMPLE
  .\Enable-WindowsSandbox.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$feature = 'Containers-DisposableClientVM'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
  Write-Host 'Requesting administrator rights...' -ForegroundColor Yellow
  $exe = (Get-Process -Id $PID).Path
  Start-Process -FilePath $exe -Verb RunAs -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath
  )
  exit 0
}

$state = Get-WindowsOptionalFeature -Online -FeatureName $feature -ErrorAction Stop
if ($state.State -eq 'Enabled') {
  Write-Host 'Windows Sandbox is already enabled.' -ForegroundColor Green
  if (-not (Test-Path 'C:\Windows\System32\WindowsSandbox.exe')) {
    Write-Host 'WindowsSandbox.exe is missing; a reboot may still be pending.' -ForegroundColor Yellow
  }
  exit 0
}

Write-Host "Enabling $feature ..." -ForegroundColor Cyan
$result = Enable-WindowsOptionalFeature -Online -FeatureName $feature -All -NoRestart -ErrorAction Stop
if ($result.RestartNeeded) {
  Write-Host ''
  Write-Host 'Enabled. Reboot Windows, then launch tests\windows-sandbox.wsb (fill in HOST_REPO and HOST_RESULTS first).' -ForegroundColor Yellow
} else {
  Write-Host 'Enabled without a reboot. Launch tests\windows-sandbox.wsb (fill in HOST_REPO and HOST_RESULTS first).' -ForegroundColor Green
}
exit 0
