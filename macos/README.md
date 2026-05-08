# macOS right-click integration

Add a Finder right-click → **Quick Actions → Convert to Amiga 8SVX** entry that runs `amiga_sample_convert.sh` on whatever audio file(s) you select. Optionally extend it to auto-upload the converted samples to a network share (e.g. a MiSTer FPGA's `sdcard`) in a single click.

## Why wrappers?

Quick Actions, Shortcuts, and Folder Actions all run their shell scripts under a non-interactive shell that does **not** inherit your terminal's `PATH`. That means `sox` (typically at `/opt/homebrew/bin/sox` on Apple Silicon, `/usr/local/bin/sox` on Intel) is invisible by default and the converter fails with "sox not found."

The wrappers in this directory fix that once, in scripts you can keep under version control, so the GUI side stays a one-line call.

| Wrapper                                                                  | What it does                                                                                   | Local `.iff` left behind?     |
| ------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------- | ----------------------------- |
| [convert-to-amiga.sh](convert-to-amiga.sh)                               | Clean conversion, default settings.                                                            | Yes, next to the source file. |
| [convert-to-amiga-P24.sh](convert-to-amiga-P24.sh)                       | Pitches up 24 semitones for the crunchy aliased Amiga jungle workflow. Play at C-1 in OctaMED. | Yes, next to the source file. |
| [convert-and-upload-to-amiga.sh](convert-and-upload-to-amiga.sh)         | Converts, auto-mounts a configurable SMB share, uploads the `.iff`.                            | **No** — only on the share.   |
| [convert-and-upload-to-amiga-P24.sh](convert-and-upload-to-amiga-P24.sh) | `-P 24` variant of the upload wrapper.                                                         | **No.**                       |

All four append their output to the same log file so you can watch progress in real time:

```bash
tail -f ~/Library/Logs/amiga_sample_convert.log
```

Make them executable once after cloning:

```bash
chmod +x macos/convert-to-amiga.sh macos/convert-to-amiga-P24.sh \
         macos/convert-and-upload-to-amiga.sh macos/convert-and-upload-to-amiga-P24.sh
```

## Shortcuts.app setup (recommended, macOS 12+)

1. Open **Shortcuts.app** → **File → New Shortcut**.
2. In the right-hand sidebar (ⓘ icon), set:
   - **Use as Quick Action**: ✔
   - **Receive**: **Files & Folders** from **Finder**
3. Search for the **Run Shell Script** action and drag it into the workflow.
4. Configure the action:
   - **Shell**: `/bin/zsh`
   - **Pass input**: **as arguments**
   - **Run as Administrator**: leave **unchecked**
   - **Script**:

     ```zsh
     /ABSOLUTE/PATH/TO/amiga_smpl/macos/convert-to-amiga.sh "$@"
     ```

     Replace the path with wherever you cloned this repo (`pwd` in the repo root).

5. Rename the shortcut (this is the label that appears in the right-click menu), e.g. **Convert to Amiga 8SVX**.
6. Save (⌘S).

Repeat with the other wrappers for whichever variants you want available in the right-click menu (`-P 24`, upload, upload+`-P 24`). Naming suggestions:

- **Convert to Amiga 8SVX**
- **Convert to Amiga 8SVX (-P 24)**
- **Convert & upload to Amiga**
- **Convert & upload to Amiga (-P 24)**

In Finder: select audio files, folders, or any mix → right-click → **Quick Actions → ...**. Multi-select works because the wrapper forwards all `"$@"` to the converter, which auto-enables batch mode for >2 inputs.

### Folder support

The converter handles directories natively (scanned non-recursively for audio files; output written alongside each source for the basic wrappers, or directly to the SMB share for the upload wrappers) and silently skips non-audio files. With the **Receive: Files & Folders** setting recommended above, right-click works for:

- single audio files
- single folders (converts everything audio inside)
- multi-selection of mixed files and folders (each file converted, each folder expanded; non-audio entries like `.txt` or `.DS_Store` skipped with a log line)
- selection containing only non-audio files (warns and exits cleanly — no error dialog)

## SMB upload workflow

The upload wrappers extend the basic conversion with an automatic upload step to a network share. The intended target is a MiSTer FPGA's `sdcard` SMB share, but any SMB destination works.

Pipeline:

1. Auto-mount the configured SMB share with AppleScript's `mount volume` — uses macOS Keychain credentials transparently when present, falls back to a GUI prompt on first use, no-ops if the share is already mounted.
2. Create the target subdirectory on the share if missing.
3. Run the converter with `-o` pointing at a script-owned tmp directory. Capture every produced `.iff` path via the converter's `AMIGA_OUTPUT_MANIFEST` env var (a one-line-per-output manifest file). Writing into tmp instead of next to the source is required so we can read the result back when the input is in a TCC-protected location like `~/Desktop`, `~/Documents`, or iCloud Drive.
4. Copy each `.iff` from tmp to the SMB target using zsh's `sysread`/`syswrite` builtins. We avoid `/bin/cp` here because external binaries invoked from a Shortcut need their own Files-and-Folders entitlement to traverse protected dirs; shell builtins inherit the script's own access.
5. Clean up tmp on exit (`trap`).

The upload wrappers intentionally **do not** leave a local copy of the `.iff`. If you want one alongside the source, run the basic wrapper instead — they're separate Quick Actions for that reason.

### Configuration

The default target is `smb://mister/sdcard/games/Amiga/shared/samples`. To override, copy [config.sample](config.sample) to `~/.config/amiga_sample_convert/config` and edit:

```bash
mkdir -p ~/.config/amiga_sample_convert
cp macos/config.sample ~/.config/amiga_sample_convert/config
$EDITOR ~/.config/amiga_sample_convert/config
```

The config file is plain zsh, sourced at runtime. Recognized keys:

| Key                   | Purpose                                                          |
| --------------------- | ---------------------------------------------------------------- |
| `AMIGA_SMB_URL`       | Full `smb://` URL with optional `user@` and any subpath.         |
| `AMIGA_CONVERT_FLAGS` | Extra flags forwarded to `amiga_sample_convert.sh` on every run. |

You can also set `AMIGA_SMB_URL` directly in the Shortcut's shell script body if you'd rather not maintain a config file. Precedence: env var → config file → built-in default.

### First-run mount

The first time the wrapper runs against a new SMB host, macOS will pop a GUI dialog asking for credentials. Tick **Remember this password in my keychain** so subsequent runs are silent. After that, every right-click → upload should be a single fire-and-forget action with no prompts.

If the host is unreachable (e.g. MiSTer powered off, you're not on the LAN), the wrapper logs an error and exits 1 — it never tries to retry forever.

## Folder Action setup (fully automatic, optional)

If you want a "drop in to convert" workflow:

1. Open **Automator** → **New Document → Folder Action**.
2. At the top, set **Folder Action receives files and folders added to:** → pick or create a watched folder (e.g. `~/AmigaSampleInbox`).
3. Drag in **Run Shell Script**:
   - **Shell**: `/bin/zsh`
   - **Pass input**: **as arguments**
   - **Script**: same one-liner as in the Shortcuts setup above (use whichever wrapper matches the workflow you want).
4. Save with a memorable name. The workflow is stored in `~/Library/Workflows/Applications/Folder Actions/`.

Anything dropped into the watched folder is processed automatically. Useful as a render target from a DAW.

## Troubleshooting

| Symptom                                                              | Fix                                                                                                                                                                                                            |
| -------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| "sox not found" in the log                                           | The wrapper's hardcoded `PATH` doesn't match where Homebrew put sox. Edit [convert-to-amiga.sh](convert-to-amiga.sh) and prepend the correct directory, or run `which sox` in your terminal and add that.      |
| Quick Action menu entry never appears                                | macOS only shows Quick Actions whose declared input type matches the selection. Make sure the Shortcut is set to receive **Files & Folders** (or **Any**).                                                     |
| Shortcut fails with "couldn't convert from Media to Folder"          | The Run Shell Script action's **Input** dropdown is coercing input to a specific type. Set it to take the action's input directly without coercion, and **Pass input: as arguments**.                          |
| Converted file appears with no `_P24` suffix                         | The variant wrapper wasn't used. The converter reserves room for the tag before truncating to 24 chars, so a missing suffix means the wrong wrapper is wired up.                                               |
| Right-click runs but nothing happens                                 | Check `tail -n 50 ~/Library/Logs/amiga_sample_convert.log` for errors. If the log is empty or missing, the wrapper never ran — make sure **Run as Administrator** is **unchecked** in the Shell Script action. |
| "Operation not permitted" copying from `~/Desktop` (upload wrapper)  | You're on an old version of the upload wrapper that wrote `.iff` next to the source. Pull latest — the current wrapper writes to a tmp dir and copies via shell builtins to bypass macOS TCC.                  |
| Upload wrapper exits 1 even though the log shows a successful upload | Old version of the wrapper had an exit-code leak. Pull latest.                                                                                                                                                 |
| First mount prompts for credentials every time                       | Tick **Remember this password in my keychain** in the dialog.                                                                                                                                                  |
| `mount volume` fails silently                                        | Check the URL by mounting manually first: Finder → ⌘K → paste your `AMIGA_SMB_URL`. Once that succeeds and is keychain-saved, the wrapper will reuse it.                                                       |

## Uninstall

Delete the shortcut from Shortcuts.app (or the workflow from `~/Library/Services/` for Automator-built ones). Removing the repo removes the wrappers automatically — there's no system-level install. If you set up a config file, delete `~/.config/amiga_sample_convert/config` to reset to defaults.
