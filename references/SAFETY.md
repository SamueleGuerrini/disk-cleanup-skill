# Safety rules and incident lessons

This file is the "never/always" checklist for any disk cleanup. Load it before any
move, delete, link, or system cleanup.

## 1. Why an agent is risky here

File systems have hidden dependencies. An agent sees paths; it does not see the app
that resolves them, the service that holds them open, the build that assumes them,
or the junction that redirects them. Reported incidents include:

- **Junction/alias misinterpretation:** an agent followed Windows junctions/aliases
  during a recursive cleanup and deleted tens of thousands of files from a user
  profile instead of a project temp folder.
- **Escaping/quoting corruption across shells:** a delete command passed through
  several shells (Bash → SSH → PowerShell → cmd); the path was truncated/mangled and
  the recursive delete hit a root or home directory.
- **Unix-style paths on Windows:** `/c/Users/name` was treated as a disposable temp
  path, and `rm -rf` removed the home folder.
- **Unverified cwd:** a `cd` failed, then `rm -rf *` ran in the wrong directory.
- **Empty variables/wildcards:** `$TEMP_DIR/*` with an empty variable became `/*`.
- **8.3 short names:** `PROGRA~1`/`ADMIN~1` mistaken for temp/backup folders.

These are not hypothetical; they are the reason this workflow is audit-first,
per-item-approved, junction-aware, plan-bound, and verified afterwards.

## 2. Path rules

- Resolve and **print the absolute canonical path** before any write/delete:
  `[System.IO.Path]::GetFullPath($path)`.
- Refuse to act on drive roots (`C:\`), user profile roots, `C:\Windows`,
  `C:\Program Files*`, `C:\ProgramData`, `AppData` roots, `WinSxS`, `Installer`,
  `System32`.
- Never assume a path starting with `/`, `/c/`, or containing `~` is temporary.
- No trailing backslash before a closing quote in composed commands.
- Do not mix POSIX and Windows path syntax. Detect the OS and shell first.
- Do not nest shells (`cmd /c` inside PowerShell, or PowerShell inside Bash) for
  file operations. Prefer native cmdlets/.NET APIs.
- Never chain `cd` and a destructive command with `;`. Use `&&` and verify
  `Get-Location`/`pwd` immediately before acting.
- Quote every path. Never use unquoted variables or unverified wildcards in
  destructive commands.
- Use `-LiteralPath` for any path that may contain `[`, `]`, `*`, or `?`. A folder
  named `Project [2024]` is a real folder, not a wildcard pattern.
- Do not pass a path to a tool that re-parses it differently than the shell did.
  Prefer a single native call over a composed command string.

## 3. Reparse points (junctions, symlinks, mounts)

- Detect before acting:
  `Get-ChildItem -Recurse -Force -Directory | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }`
- Never traverse reparse points during size scans or recursive deletes. `/XJ` for
  robocopy; explicit attribute checks for custom enumeration.
- Removing a junction removes the **link only**:
  `[System.IO.Directory]::Delete($path, $false)` (preferred) or
  `cmd /c rmdir "<path>"`. **Never** `Remove-Item -Recurse` or `rmdir /s` on a link.
- Never place a junction inside a folder that will later be deleted recursively.
- Flag self-referential links (target is the path itself or an ancestor): they waste
  no space but corrupt size scans and break tools run from that directory.
- Planning refuses a move tree that contains a reparse point. Move or materialize
  those links separately; do not "let the copy tool deal with it".
- Purge uses `Remove-TreeNoFollow`, which checks the attribute before descending.
  Never replace it with `Remove-Item -Recurse`.

## 4. Copy/move/delete rules

- Copy → verify → stage/delete source → create link → verify.
- Verify with your own file/byte counts (or hashes for critical data). Do not parse
  localized robocopy summary labels as the only check.
- Abort on any mismatch and keep the source intact.
- Prefer soft delete: quarantine or Recycle Bin. Permanent deletion needs explicit,
  informed approval and an exact-path confirmation.
- Delete **contents** of cache/temp folders, not the root folders.
- Skip locked/in-use files; report them instead of forcing. Never terminate a
  process to unlock a file as part of a cleanup.
- Never delete `C:\Windows\Installer`, `C:\Windows\WinSxS`, `System32`, or user data
  outside the approved scope.
- `pagefile.sys`/`hiberfil.sys` are kernel-managed: not junctionable, not deletable
  by hand. Use System settings / `powercfg`.
- Recycle Bin fallthrough: if a file is too large for the Recycle Bin, the delete
  becomes permanent. Check the item size and the bin's limit before relying on it.

## 5. Data that "same size" does not capture

- **Alternate data streams (ADS):** Zone.Identifier/mark-of-the-web and app metadata
  are separate streams. A plain copy may drop them.
- **ACLs:** security descriptors are not copied by a plain data copy. A moved folder
  can silently lose or gain access rights.
- **Hardlinks:** two paths can share one allocation unit. Copying duplicates the
  data; moving within a volume preserves it.
- **Sparse files:** logical size can be far larger than allocated size. Copying can
  materialize holes and consume much more space.
- **Compression/EFS:** per-file compression or encryption may not survive a copy.
- **Cloud placeholders:** online-only files hydrate on read/copy. That consumes
  bandwidth and disk space, and can be very slow.
- **Reparse points inside the tree:** a copy tool may follow or skip them. Plan for
  them explicitly.

If any of these are present, say so in the proposal and in the manifest.

## 6. Cloud, removable, and network targets

- **OneDrive/Dropbox/Google Drive:** do not junction a folder into a synced tree.
  The sync client may re-upload, delete, or fight the link. Hydrate or exclude
  placeholders deliberately.
- **Removable drives:** a junction into a USB drive breaks when the drive is absent
  or the letter changes. Require explicit acceptance (`-AllowRemovable`).
- **Network shares:** junctions cannot target UNC paths; mapped drives that go
  offline break worse than a missing USB drive. Refused by the scripts.
- **Drive letters:** record the target volume serial in the plan and manifest. A
  re-lettered drive is a different volume as far as the plan is concerned.

## 7. Confirmation rules

Require explicit confirmation before:

- deleting or moving **any directory**
- any bulk file operation
- emptying the Recycle Bin
- removing `C:\Windows.old`
- anything **orange** or **red**
- any item classified **Unknown**
- purging staged data

Silence, a previous approval for a different item, or "you decide" is not approval
for a destructive step. Approval must be bound to the exact plan item (hash), not to
a description of it.

## 8. Backups and rollback limits

- A **restore point** protects system files, registry, and installed programs. It
  does **not** back up personal files in `C:\Users\<User>`. The 24-hour frequency
  limit can silently skip creation — always verify the point exists.
- **Volume Shadow Copy** is block-level and can include user files, but restoring
  individual files is non-trivial and it is not a long-term backup.
- **Git stash/branch** protects one repository's working tree, not other folders,
  caches, or untracked data outside the repo.
- **Quarantine** protects staged data only until purge.
- **A junction is not a backup.** If the target drive dies, the original path is a
  dead link.

For irreplaceable data, use an independent, verified backup (external/cloud/image)
before any bulk operation.

## 9. Isolation

- For system-level or bulk work, prefer a VM/container/sandbox or a verified full
  backup.
- Keep the manifest and staged data until the user confirms everything works.
- Run the destructive test suite only in a disposable VM/sandbox
  (`references/TESTING.md`).
- If unsure at any point: **stop and ask**.
