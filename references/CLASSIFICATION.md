# Classification and proposal format

## 1. Report risk levels (what the dashboard shows)

| Level | Meaning | Default action | Colour |
|---|---|---|---|
| `green` | Temporary or regenerable | Safe to delete | green |
| `yellow` | Archive material: media, ISOs, archives | Archive or move; verify first | amber |
| `orange` | User content, project files, binaries, models | Explicit confirmation required | orange |
| `red` | Protected system paths and kernel files | **Never move or delete** | red |
| `unrated` | No rule matched | Inspect; no automatic suggestion | grey |

`unrated` is deliberately **not** green. A folder nobody recognises must stay
user-led. The classifier in `scripts/lib/risk.ps1` returns `unrated` by default and
only `green` for known temporary/regenerable paths and extensions.

Examples of the rules:

- **green:** `%TEMP%`, `C:\Windows\Temp`, SoftwareDistribution downloads, Delivery
  Optimization cache, `D3DSCache`, crash dumps, WER reports, `*.tmp`, `*.part`,
  `*.crdownload`, `.3dmbak` when the matching `.3dm` exists.
- **yellow:** `*.zip`, `*.7z`, `*.rar`, `*.iso`, `*.img`, video and audio files.
- **orange:** `*.psd`, `*.blend`, `*.3dm`, model weights (`*.safetensors`, `*.ckpt`,
  `*.onnx`), documents (`*.pdf`, `*.docx`, …), databases, `*.exe`/`*.msi`.
- **red:** `C:\Windows` (including `WinSxS`, `Installer`, `System32`), `Program
  Files*`, `ProgramData`, `Recovery`, `$Recycle.Bin`, `System Volume Information`,
  `Boot`, the user profile root, `AppData` roots, `.ssh`, `.gnupg`, `.aws`, `.azure`,
  `.config`, and `pagefile.sys`/`hiberfil.sys`/`swapfile.sys`/`ntuser.dat`.

A more specific rule wins: a `.tmp` file inside `C:\Windows` is still red because
protected paths are checked before extensions.

---

## 2. Workflow tiers

| Tier | Recognition | Examples | Risk | Options |
|---|---|---|---|---|
| User-made / custom | Not a known system/cache location | `MyFolder`, custom projects, archives | Orange until confirmed | Keep, move+junction, user-guided cleanup; unclear ⇒ Unknown |
| Profile — common | Known shell folders | Downloads, Pictures, Videos, Documents, Desktop, Music | Yellow (if not in use/redirected) | Move+junction; review/clean only user-selected files |
| Regenerable / build | Known patterns | Unity `Library/`, `bin/`, `obj/`, `dist/`, `build/` | Green–Yellow | Delete/regenerate; exclude from moves |
| Dev caches & stores | Known paths/envs | npm/pnpm/yarn/bun, pip/uv, NuGet, Cargo, Gradle, Maven, Go, HuggingFace/torch, Playwright, electron, IDE caches, Docker | Yellow | Prune/clean; move+junction or relocate via config/env |
| Dependency/vendor | Known names | `node_modules`, venvs, vendor | Yellow | Prefer reinstall/regenerate; move only with care |
| Apps/runtimes | Known locations | games/Steam, editors/SDKs, per-user Programs | Orange–Red | App's own move/uninstall first; junction only if supported |
| System / Windows | System paths | Windows, WinSxS, Installer, System32, drivers | Red — do not touch | DISM cleanup only; safe temp/logs with admin + warnings |
| Virtual memory | Known files | pagefile.sys, hiberfil.sys, swapfile.sys | Red/manual | System settings, `powercfg`, reboot |
| Virtual disks | Known types | WSL ext4.vhdx, Docker/VM disks | Orange | Official tools, stopped only |
| AppData (broad) | Profile app data | Local/Roaming/LocalLow, Microsoft, Packages | Red | Targeted cleanup/per-app move; avoid wholesale junction |
| Unknown | Not confidently matched | odd/unfamiliar/system-like blobs | Unrated — user-led | Report facts only; user decides |

Low confidence ⇒ Unknown. Never invent a folder's purpose.

---

## 3. Proposal table (required columns)

| Item | Size | Class | Confidence | Risk | Proposed action | Target | Est. freed | Prereqs | Rollback |
|---|---|---|---|---|---|---|---|---|---|

Then ask the user to select per item/group and choose the safety layers
(`references/ROLLBACK.md`). For moves, record the approved item with
`scripts/make-plan.ps1 -Approve -ApprovedBy` (`references/PLAN.md`).

---

## 4. Action vocabulary

- `keep` — no change; record why.
- `delete-safe` — contents only, skip in use, explicit confirmation.
- `clean-cache` — prune via tool or approved paths.
- `move+junction` — copy → verify → stage → link → verify (transaction).
- `relocate-config` — point the tool at another drive (env/config).
- `inspect` — read-only follow-up before deciding.
- `unknown` — user-led; no action proposed.

---

## 5. Confidence

| Confidence | Meaning |
|---|---|
| High | Path matches a known rule or the user named it explicitly |
| Medium | Strong pattern match but app/OS behaviour is uncertain |
| Low | Ambiguous; treat as Unknown and ask |

Report the confidence next to the risk. A high-risk item with low confidence is a
reason to stop, not a reason to guess.
