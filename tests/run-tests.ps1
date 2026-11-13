<#
.SYNOPSIS
  Functional tests for the disk-cleanup scripts.

.DESCRIPTION
  Everything runs inside a throwaway sandbox under %TEMP%. The tests create real
  folders, real junctions and real manifest events, then check the observable
  result (exit codes, files on disk, link targets, manifest state).

  They never touch the user's real profile, and every sandbox is deleted with a
  reparse-safe walk so a test junction cannot pull an outside folder into the
  deletion.

  Requires a PowerShell host (PowerShell 7 preferred; Windows PowerShell 5.1
  works for a smoke test). The scripts are launched as child processes so their
  exit codes are real.

  Run this only in a disposable VM, Windows Sandbox or container. It creates
  real junctions and deletes real trees, even though everything stays inside its
  own sandbox under %TEMP%.

.PARAMETER Root
  Sandbox parent directory. Default: %TEMP%\disk-cleanup-tests

.PARAMETER Filter
  Run only cases whose name contains this text.

.PARAMETER Keep
  Keep the sandbox folders for inspection.

.EXAMPLE
  pwsh -NoProfile -File .\tests\run-tests.ps1

.EXAMPLE
  pwsh -NoProfile -File .\tests\run-tests.ps1 -Filter restore -Keep
#>
[CmdletBinding()]
param(
  [string]$Root = (Join-Path $env:TEMP 'disk-cleanup-tests'),
  [string]$Filter = '',
  [switch]$Keep
)

$ErrorActionPreference = 'Stop'
$script:Repo = Split-Path -Parent $PSScriptRoot
$script:Scripts = Join-Path $script:Repo 'scripts'
$script:Root = $Root
$script:Filter = $Filter

if (-not (Test-Path -LiteralPath (Join-Path $script:Scripts 'lib\common.ps1'))) {
  throw "Cannot find scripts under $script:Scripts. Run this file from the repo's tests folder."
}
. (Join-Path $script:Scripts 'lib\common.ps1')

$hostCmd = Get-Command pwsh -ErrorAction SilentlyContinue
if (-not $hostCmd) { $hostCmd = Get-Command powershell.exe -ErrorAction SilentlyContinue }
if (-not $hostCmd) { throw 'No PowerShell host found (pwsh or powershell.exe).' }
$script:HostExe = $hostCmd.Source
if ($PSVersionTable.PSVersion.Major -lt 7) {
  Write-Host 'WARN: harness is running under Windows PowerShell; the skill targets PowerShell 7.' -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# Harness
# ---------------------------------------------------------------------------
$script:Results = New-Object System.Collections.Generic.List[object]
$script:CaseErrors = $null
$script:CaseName = ''

function Start-Case {
  param([string]$Name)
  $script:CaseName = $Name
  $script:CaseErrors = New-Object System.Collections.Generic.List[string]
  Write-Host ''
  Write-Host "=== $Name ===" -ForegroundColor Cyan
}

function Add-Error {
  param([string]$Message)
  $script:CaseErrors.Add($Message)
  Write-Host "  FAIL: $Message" -ForegroundColor Red
}

function Assert-True {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { Add-Error $Message }
}

function Assert-False {
  param([bool]$Condition, [string]$Message)
  if ($Condition) { Add-Error $Message }
}

function Assert-Equal {
  param($Expected, $Actual, [string]$Message)
  if ($Expected -ne $Actual) {
    Add-Error ("{0} (expected '{1}', got '{2}')" -f $Message, $Expected, $Actual)
  }
}

function Assert-Match {
  param([string]$Text, [string]$Pattern, [string]$Message)
  if ($Text -notmatch $Pattern) {
    Add-Error ("{0} (output did not match /{1}/)" -f $Message, $Pattern)
  }
}

function End-Case {
  $ok = ($script:CaseErrors.Count -eq 0)
  $script:Results.Add([pscustomobject]@{
      Name   = $script:CaseName
      Ok     = $ok
      Errors = @($script:CaseErrors)
    })
  if ($ok) { Write-Host '  PASS' -ForegroundColor Green }
}

function Run-Case {
  param([string]$Name, [scriptblock]$Body)
  if ($script:Filter -and $Name -notlike "*$script:Filter*") { return }
  Start-Case $Name
  try {
    & $Body
  } catch {
    Add-Error "EXCEPTION: $($_.Exception.Message)"
  }
  End-Case
}

function New-CaseSandbox {
  param([string]$Name)
  $p = Join-Path $script:Root $Name
  Remove-Sandbox -Path $p
  New-Item -ItemType Directory -Force -Path $p | Out-Null
  return $p
}

function Remove-Sandbox {
  param([string]$Path)
  if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return }
  # Never traverse a link while deleting a sandbox.
  Remove-TreeNoFollow -Path $Path | Out-Null
  if (Test-Path -LiteralPath $Path) {
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
  }
}

<#
  Run a tool in a child pwsh so its `exit` codes are real process exit codes.
  stdout/stderr are redirected to files: native stderr redirected into the
  pipeline can raise NativeCommandError under ErrorActionPreference=Stop.
#>
function Invoke-Tool {
  param(
    [string]$Script,
    [string[]]$Arguments = @()
  )
  $stamp = [guid]::NewGuid().ToString('N')
  $outFile = Join-Path $env:TEMP "dc-test-$stamp.out"
  $errFile = Join-Path $env:TEMP "dc-test-$stamp.err"
  $old = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    & $script:HostExe -NoProfile -ExecutionPolicy Bypass -File $Script @Arguments 1> $outFile 2> $errFile
    $code = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $old
  }
  $text = ''
  if (Test-Path -LiteralPath $outFile) { $text += (Get-Content -LiteralPath $outFile -Raw) }
  if (Test-Path -LiteralPath $errFile) { $text += (Get-Content -LiteralPath $errFile -Raw) }
  Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
  return [pscustomobject]@{ ExitCode = $code; Output = "$text" }
}

function New-TestTree {
  param([string]$Path)
  [System.IO.Directory]::CreateDirectory($Path) | Out-Null
  [System.IO.Directory]::CreateDirectory((Join-Path $Path 'sub\deeper')) | Out-Null
  [System.IO.Directory]::CreateDirectory((Join-Path $Path 'empty')) | Out-Null
  [System.IO.Directory]::CreateDirectory((Join-Path $Path 'node_modules\pkg')) | Out-Null

  Set-Content -LiteralPath (Join-Path $Path 'a.txt') -Value 'hello world' -NoNewline
  $rng = New-Object System.Random 42
  $bytes = New-Object byte[] (64 * 1024)
  $rng.NextBytes($bytes)
  [System.IO.File]::WriteAllBytes((Join-Path $Path 'b.bin'), $bytes)
  Set-Content -LiteralPath (Join-Path $Path 'sub\c.txt') -Value 'nested content'
  Set-Content -LiteralPath (Join-Path $Path 'sub\deeper\d.txt') -Value 'deep'

  $unicodeDir = Join-Path $Path 'unicode [1] dir'
  [System.IO.Directory]::CreateDirectory($unicodeDir) | Out-Null
  Set-Content -LiteralPath (Join-Path $unicodeDir 'e.txt') -Value 'brackets and spaces'

  Set-Content -LiteralPath (Join-Path $Path 'node_modules\pkg\index.js') -Value 'module.exports = 1;'

  $t = [datetime]'2026-01-02T03:04:05Z'
  Get-ChildItem -LiteralPath $Path -Recurse -File | ForEach-Object { $_.LastWriteTimeUtc = $t }
}

function Get-ManifestOp {
  param([string]$ManifestPath)
  $events = Read-ManifestEvents -Path $ManifestPath
  $prepared = @($events | Where-Object { $_.event -eq 'prepared' }) | Select-Object -First 1
  if (-not $prepared) { return $null }
  return $prepared.op
}

function Get-EventNames {
  param([string]$ManifestPath)
  return @(Read-ManifestEvents -Path $ManifestPath | ForEach-Object { $_.event })
}

function Get-StagedFolder {
  param([string]$Parent)
  return @(Get-ChildItem -LiteralPath $Parent -Directory -Force -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -like '*.__prelink_*' } | Select-Object -First 1)
}

function Test-IsJunction {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return $false }
  $i = Get-Item -LiteralPath $Path -Force
  return ($i.LinkType -eq 'Junction')
}

# ---------------------------------------------------------------------------
# A. Happy path: plan -> move -> verify -> purge
# ---------------------------------------------------------------------------
Run-Case 'A. move+junction happy path (brackets, unicode, Strict)' {
  $sb = New-CaseSandbox 'a'
  $src = Join-Path $sb 'My App [v2] dir'
  $dst = Join-Path $sb 'target\My App [v2] dir'
  New-TestTree -Path $src

  $plan = Join-Path $sb 'plan.json'
  $manifest = Join-Path $sb 'manifest.jsonl'
  $mirror = Join-Path $sb 'mirror.jsonl'

  $r = Invoke-Tool (Join-Path $script:Scripts 'make-plan.ps1') @(
    '-Source', $src, '-Destination', $dst, '-Verification', 'Strict',
    '-OutFile', $plan, '-Approve', '-ApprovedBy', 'test')
  Assert-Equal 0 $r.ExitCode "make-plan exit code`n$($r.Output)"
  Assert-True (Test-Path -LiteralPath $plan) 'plan file exists'

  $r = Invoke-Tool (Join-Path $script:Scripts 'move-and-link.ps1') @(
    '-PlanPath', $plan, '-Execute', '-ManifestPath', $manifest, '-ManifestMirrorPath', $mirror)
  Assert-Equal 0 $r.ExitCode "move-and-link exit code`n$($r.Output)"

  Assert-True (Test-IsJunction $src) 'source is a junction'
  Assert-Equal (Get-FullPath $dst) (Get-FullPath (Get-LinkTarget $src)) 'junction target is the destination'

  Assert-True (Test-Path -LiteralPath (Join-Path $dst 'a.txt')) 'top-level file copied'
  Assert-True (Test-Path -LiteralPath (Join-Path $dst 'b.bin')) 'binary file copied'
  Assert-True (Test-Path -LiteralPath (Join-Path $dst 'sub\deeper\d.txt')) 'nested file copied'
  Assert-True (Test-Path -LiteralPath (Join-Path $dst 'unicode [1] dir\e.txt')) 'bracket/space dir copied'
  Assert-False (Test-Path -LiteralPath (Join-Path $dst 'node_modules')) 'node_modules excluded from copy'

  $staged = Get-StagedFolder -Parent $sb
  Assert-True ($null -ne $staged) 'renamed original (.__prelink_) exists'
  if ($staged) {
    Assert-True (Test-Path -LiteralPath (Join-Path $staged.FullName 'node_modules\pkg\index.js')) 'staged original still has node_modules'
  }

  $events = Get-EventNames -ManifestPath $manifest
  foreach ($e in @('prepared', 'copy_verified', 'original_staged', 'link_created', 'verified', 'committed')) {
    Assert-True ($events -contains $e) "manifest contains '$e'"
  }
  Assert-True (Test-Path -LiteralPath $mirror) 'manifest mirror written'

  $op = Get-ManifestOp -ManifestPath $manifest
  Assert-True ($null -ne $op) 'operation id recorded'

  $r = Invoke-Tool (Join-Path $script:Scripts 'verify.ps1') @(
    '-ManifestPath', $manifest, '-ManifestMirrorPath', $mirror,
    '-UserProfile', $sb, '-SkipDriveScan')
  Assert-Equal 0 $r.ExitCode "verify exit code`n$($r.Output)"
  Assert-Match $r.Output 'RESULT: PASS' 'verify reports PASS'

  $r = Invoke-Tool (Join-Path $script:Scripts 'purge-staged.ps1') @(
    '-ManifestPath', $manifest, '-Id', $op, '-ConfirmPurge', $op)
  Assert-Equal 0 $r.ExitCode "purge dry-run exit code`n$($r.Output)"
  Assert-True (Test-Path -LiteralPath $staged.FullName) 'dry run did not delete the staged copy'

  $r = Invoke-Tool (Join-Path $script:Scripts 'purge-staged.ps1') @(
    '-ManifestPath', $manifest, '-Id', $op, '-ConfirmPurge', $op, '-Execute')
  Assert-Equal 0 $r.ExitCode "purge exit code`n$($r.Output)"
  Assert-False (Test-Path -LiteralPath $staged.FullName) 'staged copy purged'
  Assert-True (Test-Path -LiteralPath (Join-Path $src 'a.txt')) 'data still readable through the junction'

  $r = Invoke-Tool (Join-Path $script:Scripts 'verify.ps1') @(
    '-ManifestPath', $manifest, '-UserProfile', $sb, '-SkipDriveScan')
  Assert-Equal 0 $r.ExitCode "verify after purge exit code`n$($r.Output)"
}

# ---------------------------------------------------------------------------
# B. Restore conflict policies
# ---------------------------------------------------------------------------
Run-Case 'B. restore refuses conflicts, KeepTarget preserves new work' {
  $sb = New-CaseSandbox 'b'
  $src = Join-Path $sb 'App'
  $dst = Join-Path $sb 'target\App'
  New-TestTree -Path $src
  $manifest = Join-Path $sb 'manifest.jsonl'

  $r = Invoke-Tool (Join-Path $script:Scripts 'move-and-link.ps1') @(
    '-Source', $src, '-Destination', $dst, '-Verification', 'Basic',
    '-Execute', '-ManifestPath', $manifest, '-ManifestMirrorPath', (Join-Path $sb 'mirror.jsonl'))
  Assert-Equal 0 $r.ExitCode "move exit code`n$($r.Output)"
  $op = Get-ManifestOp -ManifestPath $manifest

  Set-Content -LiteralPath (Join-Path $dst 'new-work.txt') -Value 'written after the move'

  $r = Invoke-Tool (Join-Path $script:Scripts 'restore-staged.ps1') @(
    '-ManifestPath', $manifest, '-Id', $op, '-Execute')
  Assert-Equal 1 $r.ExitCode "Abort policy must fail on conflicts`n$($r.Output)"
  Assert-Match $r.Output 'conflicts found' 'Abort explains the conflict'
  Assert-True (Test-IsJunction $src) 'junction untouched after refused restore'

  $r = Invoke-Tool (Join-Path $script:Scripts 'restore-staged.ps1') @(
    '-ManifestPath', $manifest, '-Id', $op, '-ConflictPolicy', 'KeepTarget', '-Execute')
  Assert-Equal 0 $r.ExitCode "KeepTarget restore exit code`n$($r.Output)"
  Assert-False (Test-IsJunction $src) 'source is a real directory after restore'
  Assert-True (Test-Path -LiteralPath (Join-Path $src 'new-work.txt')) 'post-move work survived the restore'
  Assert-False (Test-Path -LiteralPath $dst) 'live target moved back to the original path'
}

# ---------------------------------------------------------------------------
# C. Tampered plan is rejected
# ---------------------------------------------------------------------------
Run-Case 'C. tampered plan is rejected before touching the disk' {
  $sb = New-CaseSandbox 'c'
  $src = Join-Path $sb 'App'
  $dst = Join-Path $sb 'target\App'
  New-TestTree -Path $src
  $plan = Join-Path $sb 'plan.json'
  $manifest = Join-Path $sb 'manifest.jsonl'

  $r = Invoke-Tool (Join-Path $script:Scripts 'make-plan.ps1') @(
    '-Source', $src, '-Destination', $dst, '-OutFile', $plan, '-Approve', '-ApprovedBy', 'test')
  Assert-Equal 0 $r.ExitCode "make-plan exit code`n$($r.Output)"

  $obj = Get-Content -LiteralPath $plan -Raw | ConvertFrom-Json
  $obj.items[0].expected_bytes = [int64]$obj.items[0].expected_bytes + 4096
  $obj | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $plan -Encoding UTF8

  $r = Invoke-Tool (Join-Path $script:Scripts 'move-and-link.ps1') @(
    '-PlanPath', $plan, '-Execute', '-ManifestPath', $manifest)
  Assert-True ($r.ExitCode -ne 0) "tampered plan must fail`n$($r.Output)"
  Assert-Match $r.Output 'hash mismatch' 'failure names the approval hash'
  Assert-False (Test-IsJunction $src) 'source untouched'
  Assert-False (Test-Path -LiteralPath $dst) 'no destination created'
  Assert-False (Test-Path -LiteralPath $manifest) 'no manifest event written'
}

# ---------------------------------------------------------------------------
# D. make-plan refuses unsafe inputs
# ---------------------------------------------------------------------------
Run-Case 'D. make-plan refuses protected, nested and linked sources' {
  $sb = New-CaseSandbox 'd'
  $plan = Join-Path $sb 'plan.json'

  $r = Invoke-Tool (Join-Path $script:Scripts 'make-plan.ps1') @(
    '-Source', (Join-Path $env:WINDIR 'System32'), '-Destination', (Join-Path $sb 'x'), '-OutFile', $plan)
  Assert-True ($r.ExitCode -ne 0) "protected path must be refused`n$($r.Output)"
  Assert-Match $r.Output 'protected path' 'refusal names the protected path'

  $src = Join-Path $sb 'App'
  New-TestTree -Path $src
  $r = Invoke-Tool (Join-Path $script:Scripts 'make-plan.ps1') @(
    '-Source', $src, '-Destination', (Join-Path $src 'inside'), '-OutFile', $plan)
  Assert-True ($r.ExitCode -ne 0) "destination inside source must be refused`n$($r.Output)"
  Assert-Match $r.Output 'inside the source' 'refusal explains the nesting'

  $canary = Join-Path $sb 'canary'
  New-Item -ItemType Directory -Force -Path $canary | Out-Null
  Set-Content -LiteralPath (Join-Path $canary 'keep.txt') -Value 'do not move'
  $link = Join-Path $sb 'link-source'
  New-Item -ItemType Junction -Path $link -Target $canary | Out-Null
  $r = Invoke-Tool (Join-Path $script:Scripts 'make-plan.ps1') @(
    '-Source', $link, '-Destination', (Join-Path $sb 'y'), '-OutFile', $plan)
  Assert-True ($r.ExitCode -ne 0) "junction source must be refused`n$($r.Output)"
  Assert-Match $r.Output 'reparse point' 'refusal names the reparse point'
}

# ---------------------------------------------------------------------------
# E. Nested junctions: refused by planning, never traversed by deletion
# ---------------------------------------------------------------------------
Run-Case 'E. nested junction is refused and never traversed' {
  $sb = New-CaseSandbox 'e'
  $src = Join-Path $sb 'App'
  $canary = Join-Path $sb 'canary'
  New-TestTree -Path $src
  New-Item -ItemType Directory -Force -Path $canary | Out-Null
  $canaryFile = Join-Path $canary 'precious.bin'
  $rng = New-Object System.Random 7
  $bytes = New-Object byte[] (256 * 1024)
  $rng.NextBytes($bytes)
  [System.IO.File]::WriteAllBytes($canaryFile, $bytes)
  New-Item -ItemType Junction -Path (Join-Path $src 'canary-link') -Target $canary | Out-Null

  $plan = Join-Path $sb 'plan.json'
  $r = Invoke-Tool (Join-Path $script:Scripts 'make-plan.ps1') @(
    '-Source', $src, '-Destination', (Join-Path $sb 'target\App'), '-OutFile', $plan)
  Assert-True ($r.ExitCode -ne 0) "nested junction must be refused`n$($r.Output)"
  Assert-Match $r.Output 'reparse points' 'refusal names reparse points'

  $stats = Get-TreeStats -Path $src
  Assert-Equal 6 $stats.Files 'tree stats count only real files (junction not followed)'
  Assert-Equal 1 $stats.Links 'tree stats reports the junction as a link'
  Assert-True ($stats.Bytes -lt (256 * 1024)) 'canary bytes are not included in the source total'

  $result = Remove-TreeNoFollow -Path $src
  Assert-False (Test-Path -LiteralPath $src) 'tree removed'
  Assert-Equal 1 $result.Links 'junction unlinked, not traversed'
  Assert-True (Test-Path -LiteralPath $canaryFile) 'canary file survived the recursive delete'
  Assert-Equal ([int64](256 * 1024)) ([int64](Get-Item -LiteralPath $canaryFile).Length) 'canary content intact'
}

# ---------------------------------------------------------------------------
# F. Crash recovery: interrupted before the link, restore the staged original
# ---------------------------------------------------------------------------
Run-Case 'F. recovery restores a staged original after an interrupted move' {
  $sb = New-CaseSandbox 'f'
  $src = Join-Path $sb 'App'
  $dst = Join-Path $sb 'target\App'
  $staged = Join-Path $sb 'App.__prelink_20260101-000000'
  $manifest = Join-Path $sb 'manifest.jsonl'
  New-TestTree -Path $src
  $stats = Get-TreeStats -Path $src

  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
  Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force
  Rename-Item -LiteralPath $src -NewName (Split-Path -Leaf $staged)

  $op = 'test-crash-f'
  Write-ManifestEvent -Path $manifest -Event @{
    op = $op; event = 'prepared'; source = $src; target = $dst; staged = $null
    stage_mode = 'Rename'; exclude = @('node_modules'); verification = 'Basic'
    expected_files = [int64]$stats.Files; expected_bytes = [int64]$stats.Bytes
    expected_physical_bytes = [int64]$stats.PhysicalBytes
    rollback = 'L1'
  }
  Write-ManifestEvent -Path $manifest -Event @{
    op = $op; event = 'copy_verified'; files = [int64]$stats.Files; bytes = [int64]$stats.Bytes
    verification = 'Basic'; mismatches = 0
  }
  Write-ManifestEvent -Path $manifest -Event @{
    op = $op; event = 'original_staged'; stage_mode = 'Rename'; staged = $staged
    files = [int64]$stats.Files; bytes = [int64]$stats.Bytes
  }

  $r = Invoke-Tool (Join-Path $script:Scripts 'move-and-link.ps1') @(
    '-Recover', '-OperationId', $op, '-Execute', '-ManifestPath', $manifest,
    '-ManifestMirrorPath', (Join-Path $sb 'mirror.jsonl'))
  Assert-Equal 0 $r.ExitCode "recovery exit code`n$($r.Output)"
  Assert-True (Test-Path -LiteralPath $src) 'original path restored'
  Assert-False (Test-IsJunction $src) 'restored path is a real directory'
  Assert-True (Test-Path -LiteralPath (Join-Path $src 'sub\deeper\d.txt')) 'restored content present'
  Assert-False (Test-Path -LiteralPath $staged) 'staged copy consumed by the restore'

  $states = Get-OperationStates -Events (Read-ManifestEvents -Path $manifest)
  Assert-False $states[$op].Open 'operation is no longer open'
  Assert-True $states[$op].Failed 'operation recorded as failed/rolled back'
}

# ---------------------------------------------------------------------------
# G. Crash recovery: data verified, source gone, link never created
# ---------------------------------------------------------------------------
Run-Case 'G. recovery recreates a missing junction from verified data' {
  $sb = New-CaseSandbox 'g'
  $src = Join-Path $sb 'App'
  $dst = Join-Path $sb 'target\App'
  $manifest = Join-Path $sb 'manifest.jsonl'
  New-TestTree -Path $src
  $stats = Get-TreeStats -Path $src

  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
  Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force
  Remove-TreeNoFollow -Path $src | Out-Null

  $op = 'test-crash-g'
  Write-ManifestEvent -Path $manifest -Event @{
    op = $op; event = 'prepared'; source = $src; target = $dst; staged = $null
    stage_mode = 'Delete'; exclude = @('node_modules'); verification = 'Basic'
    expected_files = [int64]$stats.Files; expected_bytes = [int64]$stats.Bytes
    expected_physical_bytes = [int64]$stats.PhysicalBytes
    rollback = 'L1'
  }

  $r = Invoke-Tool (Join-Path $script:Scripts 'move-and-link.ps1') @(
    '-Recover', '-OperationId', $op, '-Execute', '-ManifestPath', $manifest,
    '-ManifestMirrorPath', (Join-Path $sb 'mirror.jsonl'))
  Assert-Equal 0 $r.ExitCode "recovery exit code`n$($r.Output)"
  Assert-True (Test-IsJunction $src) 'junction recreated'
  Assert-Equal (Get-FullPath $dst) (Get-FullPath (Get-LinkTarget $src)) 'junction points at verified data'
  Assert-True (Test-Path -LiteralPath (Join-Path $src 'a.txt')) 'data reachable through the new junction'

  $states = Get-OperationStates -Events (Read-ManifestEvents -Path $manifest)
  Assert-True $states[$op].Committed 'operation marked committed'
}

# ---------------------------------------------------------------------------
# H. Purge refuses to destroy the last copy when the link is wrong
# ---------------------------------------------------------------------------
Run-Case 'H. purge refuses a wrong link unless explicitly overridden' {
  $sb = New-CaseSandbox 'h'
  $src = Join-Path $sb 'App'
  $dst = Join-Path $sb 'target\App'
  $manifest = Join-Path $sb 'manifest.jsonl'
  New-TestTree -Path $src

  $r = Invoke-Tool (Join-Path $script:Scripts 'move-and-link.ps1') @(
    '-Source', $src, '-Destination', $dst, '-Verification', 'Basic',
    '-Execute', '-ManifestPath', $manifest, '-ManifestMirrorPath', (Join-Path $sb 'mirror.jsonl'))
  Assert-Equal 0 $r.ExitCode "move exit code`n$($r.Output)"
  $op = Get-ManifestOp -ManifestPath $manifest
  $staged = Get-StagedFolder -Parent $sb
  Assert-True ($null -ne $staged) 'staged copy exists'

  # Replace the junction with a real folder: the live data is now unreachable
  # from the original path, so purging would destroy the only intact copy.
  [System.IO.Directory]::Delete($src, $false)
  New-Item -ItemType Directory -Force -Path $src | Out-Null
  Set-Content -LiteralPath (Join-Path $src 'decoy.txt') -Value 'not the real data'

  $r = Invoke-Tool (Join-Path $script:Scripts 'purge-staged.ps1') @(
    '-ManifestPath', $manifest, '-Id', $op, '-ConfirmPurge', $op, '-Execute')
  Assert-Equal 1 $r.ExitCode "purge must refuse`n$($r.Output)"
  Assert-True (Test-Path -LiteralPath $staged.FullName) 'staged copy preserved'

  $r = Invoke-Tool (Join-Path $script:Scripts 'purge-staged.ps1') @(
    '-ManifestPath', $manifest, '-Id', $op, '-ConfirmPurge', $op, '-AllowMissingLink', '-Execute')
  Assert-Equal 0 $r.ExitCode "override purge exit code`n$($r.Output)"
  Assert-False (Test-Path -LiteralPath $staged.FullName) 'staged copy purged after explicit override'
  Assert-True (Test-Path -LiteralPath (Join-Path $dst 'a.txt')) 'live target untouched'
}

# ---------------------------------------------------------------------------
# I. verify.ps1 flags unfinished transactions and broken links
# ---------------------------------------------------------------------------
Run-Case 'I. verify flags unfinished transactions and broken links' {
  $sb = New-CaseSandbox 'i'
  $manifest = Join-Path $sb 'manifest.jsonl'

  Write-ManifestEvent -Path $manifest -Event @{
    op = 'test-unfinished'; event = 'prepared'
    source = (Join-Path $sb 'App'); target = (Join-Path $sb 'target\App')
    staged = $null; stage_mode = 'Rename'; exclude = @(); verification = 'Basic'
    expected_files = 1; expected_bytes = 1
  }

  $broken = Join-Path $sb 'broken-link'
  $vanishing = Join-Path $sb 'vanishing-target'
  New-Item -ItemType Directory -Force -Path $vanishing | Out-Null
  New-Item -ItemType Junction -Path $broken -Target $vanishing | Out-Null
  Remove-Item -LiteralPath $vanishing -Recurse -Force

  $r = Invoke-Tool (Join-Path $script:Scripts 'verify.ps1') @(
    '-ManifestPath', $manifest, '-UserProfile', $sb, '-SkipDriveScan')
  Assert-Equal 1 $r.ExitCode "verify must fail`n$($r.Output)"
  Assert-Match $r.Output 'Unfinished at state' 'unfinished transaction reported'
  Assert-Match $r.Output 'broken link' 'broken junction reported'
  Assert-Match $r.Output 'RESULT: FAIL' 'summary is FAIL'
}

# ---------------------------------------------------------------------------
# Cleanup + summary
# ---------------------------------------------------------------------------
if (-not $Keep) { Remove-Sandbox -Path $script:Root }

Write-Host ''
Write-Host '================ SUMMARY ================' -ForegroundColor Cyan
foreach ($res in $script:Results) {
  $color = if ($res.Ok) { 'Green' } else { 'Red' }
  $label = if ($res.Ok) { 'PASS' } else { 'FAIL' }
  Write-Host ("[{0}] {1}" -f $label, $res.Name) -ForegroundColor $color
  if (-not $res.Ok) {
    foreach ($e in $res.Errors) { Write-Host "       - $e" -ForegroundColor Red }
  }
}

$failed = @($script:Results | Where-Object { -not $_.Ok })
Write-Host ''
if ($failed.Count -gt 0) {
  Write-Host ("RESULT: FAIL - {0} of {1} case(s) failed." -f $failed.Count, $script:Results.Count) -ForegroundColor Red
  exit 1
}
if ($script:Results.Count -eq 0) {
  Write-Host 'RESULT: no cases matched the filter.' -ForegroundColor Yellow
  exit 2
}
Write-Host ("RESULT: PASS - {0} case(s)." -f $script:Results.Count) -ForegroundColor Green
if ($Keep) { Write-Host "Sandboxes kept under: $script:Root" -ForegroundColor Yellow }
exit 0
