# Plan: Apply-Update from Check window + Launch at Login toggle

## Goal
Two UX improvements to the `llama-menubar` Swift app:

1. **One-click update flow** — when `Check for Update...` reports a newer build, the same alert shows an "Apply Update" button so the user doesn't need to close it and pick the menu again.
2. **Launch at Login toggle** — a menu item in the status bar menu that adds/removes the app from macOS Login Items via `SMAppService`.

No new dependencies, no script changes. Touches only `llama-menubar/Sources/llmctl/main.swift` and `llama-menubar/build.sh` (for the new `--enable-login-item` LaunchAgent plist — wait, no: using SMAppService, no plist needed).

## Affected files
- `llama-menubar/Sources/llmctl/main.swift` (only)
- `README.md` (small docs update for the new menu item)

## Design

### 1. "Apply Update" button in Check-for-Update alert

**Change in `UpdateManager`:**
- Detect "update available" in the captured output by substring match:
  - `"newer version available"` → update available
  - `"up to date"` → no update
  - `"not installed"` → no installed build (skip the button)
- Refactor `showOutputWindow` to:
  - Accept a third parameter `updateAvailable: Bool` (default `false`)
  - When `true`, add a second button titled "Apply Update"
  - Return the `NSApplication.ModalResponse` from the alert to the caller
- In `runScript`:
  - Parse the output to set `updateAvailable`
  - When `runScript` is invoked from `checkUpdate`, capture the return code
  - If the user pressed "Apply Update" (`response == .alertSecondButtonReturn`), call `applyUpdate()` (which uses the same `runScript` path but with `--upgrade` and triggers cleanup)

**Detection logic (regex/substring is fine):**
```swift
let available = output.contains("newer version available")
```

### 2. "Launch at Login" toggle

**Use `SMAppService.mainApp`** (macOS 13+, no helper app required).

- New `LaunchAtLoginManager` class:
  - `isEnabled()` → `SMAppService.mainApp.status == .enabled`
  - `setEnabled(_ enable: Bool)` → `register()` or `unregister()`
- In `MenuBarController.refresh()`:
  - Add a menu item "Launch at Login" with state checked when enabled
  - Action: `@objc func toggleLaunchAtLogin(_ sender: NSMenuItem)`
  - Place it just above "Quit"
- Edge case: if `Bundle.main.bundlePath` doesn't start with `/Applications/`, show a one-time alert explaining SMAppService only works when the app is in `/Applications`. Detect via:
  ```swift
  if !Bundle.main.bundlePath.hasPrefix("/Applications/") {
      // show warning
  }
  ```
  Still toggle the state — the registration call will surface the OS error and we surface it via NSAlert.

**New menu structure (final):**
```
llama.cpp — running
Qwen2.5 7B Q4_K_M
─────────
Open WebUI                       ⌘O
Restart Server                   ⌘R
Stop Server
─────────
Tail Logs                        ⌘L
─────────
Check for Update...
Apply Update...
─────────
Launch at Login           ☑
─────────
Quit                              ⌘Q
```

## Tasks (in order)

1. Modify `UpdateManager.runScript` to capture script output, compute `updateAvailable`, and pass to `showOutputWindow`.
2. Modify `UpdateManager.showOutputWindow` to:
   - Accept `updateAvailable: Bool`
   - When `true`, add "Apply Update" as `.alertSecondButtonReturn`
   - Return `NSApplication.ModalResponse` to the caller
3. Modify `UpdateManager.checkUpdate` to call `applyUpdate()` when "Apply Update" is pressed.
4. Add `LaunchAtLoginManager` class with `isEnabled()` / `setEnabled(_:)`.
5. Wire "Launch at Login" menu item in `MenuBarController.refresh()` with `@objc toggleLaunchAtLogin`.
6. Handle the `/Applications/` location warning.

## Validation
1. `cd llama-menubar && ./build.sh` — must compile without warnings.
2. `cp -r llama-menubar.app /Applications/ && open /Applications/llama-menubar.app`.
3. **Update flow:**
   - Click Check for Update → window shows output, plus "Apply Update" button if a newer build exists.
   - Press Apply Update → same window closes, a new "Update Result" window shows the `--upgrade` output.
4. **Login toggle:**
   - Open System Settings → General → Login Items → confirm `llama-menubar` appears after toggling on.
   - Toggle off → confirm it disappears.
   - Run app from build dir (not /Applications) → confirm warning alert appears.

## Risks / edge cases
- `SMAppService.mainApp` requires the app's bundle to be at a stable, code-signed (or at least ad-hoc signed) path. The current `.app` is ad-hoc signed only by `codesign` in the build script — confirm this still works; if not, fall back to writing a tiny LaunchAgent plist.
- Long-running `--upgrade` will block the main thread via `runModal`. Mitigated by spawning the script on `DispatchQueue.global` (already done) and only running the modal *after* it completes.
- The output window still uses `NSAlert.runModal()` which is blocking — no change in behavior, but the "Apply Update" button is added safely before showing.

## Out of scope
- Code signing / notarization of the universal binary.
- Auto-check on startup (only manual check via menu).
- Preferences window — using a menu item per the user's choice.
