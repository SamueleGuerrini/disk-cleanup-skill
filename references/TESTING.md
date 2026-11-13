# Testing the scripts

The suite creates real junctions, stages real folders, and deletes real trees. Run
it in a **disposable** Windows machine — a VM, Windows Sandbox, or a Windows
container — never on the machine whose data you care about.

`tests/VM-TESTING.md` covers the sandbox/VM options. This file covers what the
suite checks and how to run it.

---

## 1. Why isolation is mandatory

A safety bug can turn a "sandbox" test into a real recursive delete. The suite is
designed so everything it touches lives under `%TEMP%\disk-cleanup-tests`, and each
case gets its own folder that is deleted with a reparse-safe delete. That design is
a mitigation, not a guarantee.

Windows Sandbox is a good fit: it is disposable, it has its own filesystem, and the
repository can be mapped read-only.

---

## 2. Running the suite

Inside the isolated machine:

```powershell
cd <repo>\tests
pwsh -NoProfile -File .\run-tests.ps1
```

Options:

| Parameter | Effect |
|---|---|
| `-Root` | Test root (default `%TEMP%\disk-cleanup-tests`) |
| `-Filter` | Run only cases whose name contains this string (e.g. `-Filter C`) |
| `-Keep` | Keep the sandboxes for inspection |

Exit codes: `0` all passed, `1` at least one failed, `2` the filter matched nothing.

Each script under test is launched as a **child `pwsh -File` process**, so the suite
observes real exit codes rather than the caller's `$LASTEXITCODE`.

---

## 3. What each case covers

| Case | Scenario | Key assertions |
|---|---|---|
| **A** | Plan → move → junction → verify → purge, with spaces, brackets, unicode, `node_modules` exclusion, Strict (SHA-256) verification | junction exists and points at the target; excluded folder was not copied; hash verification passes; purge removes staged data |
| **B** | Restore with a conflict | `Abort` refuses; `KeepTarget` preserves post-move work and retains the staged copy |
| **C** | Plan edited after approval | executor rejects before any disk change (hash mismatch) |
| **D** | Protected paths, destination inside source, junction source | all refused |
| **E** | Nested junction in the source | planning refuses; deletion never traverses the link |
| **F** | Crash before link creation | staged original restored to the source path |
| **G** | Crash after data verification | missing junction recreated from the verified destination |
| **H** | Purge with the original path not the expected junction | purge refuses (would destroy the last copy) |
| **I** | Unfinished transaction / broken link | `verify.ps1` flags both |

The cases are independent. A failure prints `PASS`/`FAIL` per assertion and a
summary repeats every failure.

---

## 4. Windows Sandbox

### Enable (once, elevated, then reboot)

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName Containers-DisposableClientVM -All
```

`tests/Enable-WindowsSandbox.ps1` does the same with a status check.

### Run

Use the template `tests/windows-sandbox.wsb`:

1. Replace `HOST_REPO` with the repository's absolute path.
2. Replace `HOST_RESULTS` with an empty folder for output.
3. Run `WindowsSandbox.exe .\tests\windows-sandbox.wsb`.

To keep your real host paths out of version control, copy the template to
`tests/windows-sandbox.local.wsb`, edit that copy, and run it instead. Files
matching `tests/*.local.wsb` are gitignored.

The repository is mapped **read-only**. Results land in `test-output.txt` and
`exit.txt` in the mapped results folder.

Windows Sandbox ships Windows PowerShell 5.1. Install PowerShell 7 inside the
sandbox for the closest match to the supported runtime (`pwsh -File` is used by the
suite).

---

## 5. Other isolation options

- **Hyper-V VM:** `.\Invoke-VmTests.ps1 -VMName 'Win11-Test'`. Restore a clean
  checkpoint before, discard changes after.
- **Any VM over WinRM:** enable `Enable-PSRemoting -Force` on the VM, then
  `.\Invoke-VmTests.ps1 -ComputerName 'test-vm' -Credential (Get-Credential)`.
  The script copies the repo, runs the suite, streams output, and removes the
  remote copy.
- **Windows container:** only with a matching Windows base image; Linux containers
  cannot run these scripts (NTFS junctions, ACLs, WMI).

---

## 6. Reading and keeping a failure

- Keep the sandbox: `.\run-tests.ps1 -Keep`, then inspect
  `%TEMP%\disk-cleanup-tests\<case>` and the JSONL manifest inside it.
- If a test left a junction behind, delete the sandbox with a reparse-safe tool,
  not `rmdir /s`.
- Record the run (date, host, PowerShell version, case results) before changing the
  scripts again. A passing suite is only meaningful for the revision it ran against.

---

## 7. What the suite does not prove

- It does not test every Windows build, filesystem filter driver, or antivirus
  product.
- It does not test a real app's tolerance for a junction (Unity, IDEs, databases).
- It does not test removable/network targets or BitLocker states.
- It does not replace a backup.

A green suite means the transaction logic behaves as designed. It does not mean a
specific move is safe for a specific application.
