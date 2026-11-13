# Testing in a VM

The suite creates real directory junctions and deletes real trees. Everything it
touches lives inside its own sandbox under `%TEMP%`, but a bug in a safety check
could still reach outside it. Run the suite in a disposable Windows machine, not
on the machine whose data you care about.

Nothing in the suite touches the audited volumes by design: no `C:\Users`
scan, no drive-wide walk. It only exercises the transaction scripts against
generated folders.

## What the suite covers

| Case | Checks |
|---|---|
| A | plan + move + junction + verify + purge, with spaces, brackets, unicode, `node_modules` exclusion, Strict (SHA-256) verification |
| B | restore refuses conflicts under `Abort`; `KeepTarget` preserves post-move work |
| C | a plan edited after approval is rejected before any disk change |
| D | protected paths, destination-inside-source, and junction sources are refused |
| E | a nested junction is refused by planning and never traversed by deletion |
| F | crash before link creation restores the staged original |
| G | crash after data verification recreates the missing junction |
| H | purge refuses to destroy the last copy when the original path is not the expected junction |
| I | verify flags unfinished transactions and broken links |

## Option 1: any Windows VM over WinRM

On the VM (once, in an elevated shell):

```powershell
Enable-PSRemoting -Force
```

From this machine:

```powershell
cd .\tests
.\Invoke-VmTests.ps1 -ComputerName 'test-vm' -Credential (Get-Credential)
```

The script zips the repository, copies it to `C:\ProgramData\disk-cleanup-vmtest`,
runs `tests\run-tests.ps1` there, streams the output back, and removes the remote
copy. `-Filter` and `-Keep` are passed through.

The VM needs a PowerShell host. PowerShell 7 is recommended; Windows PowerShell
5.1 works as a fallback.

## Option 2: Hyper-V VM

Requires the Hyper-V module and an elevated shell on the host.

```powershell
.\Invoke-VmTests.ps1 -VMName 'Win11-Test'
```

Before a run, restore the VM to a clean checkpoint. After the run, discard the
VM's changes. Never point this at a VM that holds real user data.

## Option 3: Windows Sandbox

`tests\windows-sandbox.wsb` is a template:

1. Enable the feature in an elevated shell, then reboot:
   `Enable-WindowsOptionalFeature -Online -FeatureName Containers-DisposableClientVM -All`
2. Replace `HOST_REPO` with this repository's absolute path.
3. Replace `HOST_RESULTS` with an empty folder for the output.
4. Run `WindowsSandbox.exe .\tests\windows-sandbox.wsb`.

The repository is mapped read-only. Results land in `test-output.txt` and
`exit.txt` in the mapped results folder. Windows Sandbox ships Windows PowerShell
5.1 only; install PowerShell 7 inside the sandbox for the closest match to the
supported runtime.

## Option 4: Windows container

Only if the host already runs Windows containers with a matching base image:

```powershell
docker run --rm -v "${PWD}:C:\repo:ro" mcr.microsoft.com/windows/servercore:ltsc2022 `
  powershell -NoProfile -ExecutionPolicy Bypass -File C:\repo\tests\run-tests.ps1
```

Linux containers cannot run these scripts (they depend on NTFS junctions, ACLs
and WMI).

## Reading a failure

Each case prints `PASS` or a list of failed assertions. The summary at the end
repeats every failure. Exit code `0` means all cases passed, `1` means at least
one failed, `2` means the filter matched nothing.

Keep the sandbox on failure:

```powershell
.\run-tests.ps1 -Keep
```

Then inspect `%TEMP%\disk-cleanup-tests\<case>` and the JSONL manifest inside it.
Delete that folder with a reparse-safe tool, not `rmdir /s`, if a test left a
junction behind.
