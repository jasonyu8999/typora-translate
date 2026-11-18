# E2E verification harness - Typora Translate plugin

End-to-end verification for the Typora 1.12.4 plugin that translates the
selected text through the right-click menu ("Translate to Chinese") or the
Ctrl+Shift+T hotkey.

Chrome DevTools Protocol is blocked in production Typora, so the harness drives
the real application with Win32 UI automation (foreground activation, SendInput
key chords, mouse_event clicks) and verifies the outcome through the
observability files the plugin writes plus pixel-checked screenshots.

## Requirements

- Windows 10/11, interactive desktop session (window capture + input injection
  need a real desktop; they do not work from a Windows service session 0).
- Windows PowerShell 5.1 (`powershell.exe`). PowerShell 7 is not installed on
  this machine; the scripts are 5.1-compatible and are ASCII-only so 5.1 parses
  them correctly.
- Typora is installed (`<Typora>\Typora.exe` by default).
- The plugin is installed by `install.ps1` (plugin files in
  `resources\plugin\typora-translate\` and the bootstrap script injected into
  `resources\window.html`).

## Commands

```powershell
# full suite: boot -> hotkey -> contextmenu, then stop the Typora tree it launched
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\e2e.ps1 -Phase all

# individual phases (mostly for debugging)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\e2e.ps1 -Phase boot
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\e2e.ps1 -Phase hotkey
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\e2e.ps1 -Phase contextmenu

# adopt an already-running Typora instance instead of launching a new one
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\e2e.ps1 -Phase all -Force

# keep Typora open after the run (debugging)
powershell.exe ... -Phase all -KeepOpen
```

Exit code: `0` only when every executed phase PASSed, `1` otherwise.

Optional parameters: `-TyporaExe <path>`, `-FixturePath <md>`,
`-BootTimeoutSec 60`, `-TranslateTimeoutSec 40`, `-MenuTimeoutSec 8`,
`-NoTranscript`.

## What each phase verifies

### boot
1. Static install state: `resources\plugin\typora-translate\{bootstrap.js, ui.js,
   service.js, styles.css}` exist and `resources\window.html` contains the
   typora-translate bootstrap marker.
2. Safety gate: a Typora instance not launched by the harness is refused
   (abort with a warning) unless `-Force` is used to adopt it.
3. Cold launch: deletes the stale `status.json`, launches
   `<Typora>\Typora.exe "tests\fixtures\sample-en.md"`,
   records the launched process tree, waits up to 60s for a window whose title
   matches the fixture.
4. Waits for `%APPDATA%\Typora\typora-translate\status.json` with
   `booted == true`, a fresh `bootAt`/`updatedAt` (freshness guard against
   stale data), and `menus.rich == true && menus.source == true`.
5. Saves `docs\screenshots\boot-loaded.png` and requires a non-blank frame
   (pixel analysis, PrintWindow then screen-grab fallback).

### hotkey
1. Focus Typora (verified `GetForegroundWindow() == hwnd`), click into the
   editor body, Ctrl+A to select the document, then Ctrl+Shift+T.
2. Waits up to 40s for `status.json.lastTranslate.ok == true` and a
   `resultText` containing CJK characters, written after the keystroke
   (freshness guard).
3. Requires a new `[TRANSLATE] ok` line in `plugin.log`; requires a new `[UI]`
   panel line when the plugin emits `[UI]` markers at all.
4. Saves `hotkey-before.png` (selection) and `hotkey-panel.png` (translation
   panel) and reports the before/after pixel-difference ratio.

### contextmenu
1. Focus Typora, click the editor, Ctrl+A.
2. Right-click inside the editor area (mouse_event), retrying at up to three
   click points if no menu event is observed (focus theft protection).
3. Requires a new `[MENU] show mode=... len=N` line in `plugin.log` with
   `N > 0`, and/or a fresh `status.json.lastSelection.textLen > 0`.
4. Saves `docs\screenshots\menu.png` (the open context menu, including the
   plugin's translate item) and requires a non-blank frame.

## Safety model (no user documents are ever harmed)

- Before launching, the harness writes the exact PID/start-time/exe-path of
  every Typora process it starts to
  `%TEMP%\typora-translate-e2e\state.json`.
- It only ever kills that recorded process tree, and only after re-verifying
  the executable path and start time (PID-reuse guard). A pre-existing Typora
  instance is never killed: boot aborts with a warning unless `-Force`
  (adopt, still never killed).
- `%APPDATA%` data is only read; the one exception is deleting the stale
  `status.json` before a cold launch so a previous run cannot produce a false
  PASS. `plugin.log` is never deleted (the harness reads it incrementally and
  is rotation-aware).

## Outputs

- `typora-translate\docs\screenshots\`: `boot-loaded.png`,
  `hotkey-before.png`, `hotkey-panel.png`, `menu.png` (plus `boot-fail.png` /
  `hotkey-panel-fail.png` on failure).
- `%TEMP%\typora-translate-e2e\run-<runid>.log`: full console transcript.
- `%TEMP%\typora-translate-e2e\summary-<runid>.json`: machine-readable results
  (per-phase PASS/FAIL, evidence strings, screenshot paths).
- `%TEMP%\typora-translate-e2e\state.json`: launched-process bookkeeping for
  the next run's cleanup.

## Focus-theft hardening

The DSH GUI (the web app this agent talks through) can steal the OS foreground
between tool commands, which would silently redirect injected clicks/keys to
the wrong window. The harness therefore:

- verifies `GetForegroundWindow() == target hwnd` immediately before and after
  every input batch (`Confirm-Foreground`);
- retries the whole select-all + hotkey sequence up to 3 times and the
  right-click sequence at 3 click points, re-focusing between attempts;
- uses `PrintWindow(PW_RENDERFULLCONTENT)` for evidence capture, which does not
  need the target window to be in the foreground.

## Win32 pitfalls handled by `win-ui.ps1`

- The harness process is made DPI-aware before any geometry work, so window
  rects, `SetCursorPos` and screenshots all agree in physical pixels
  (the desktop is at 125% scaling).
- `GetWindowTextW` must be declared with `CharSet.Unicode`, otherwise the title
  is truncated to its first character.
- `SetForegroundWindow` is often refused because of the foreground-activation
  lock; the helper taps ALT, attaches thread input to the current foreground
  thread, then verifies the result with retries.
- Electron/Chromium windows sometimes return black frames from plain
  `BitBlt`/`PrintWindow`; `Save-WindowScreenshot` validates the captured pixels
  (unique colour count + luminance range) and falls back to a foreground
  `CopyFromScreen` grab.
- `plugin.log` is read with `FileShare.ReadWrite` and decoded as UTF-8, even
  while the renderer keeps the file open for appending.