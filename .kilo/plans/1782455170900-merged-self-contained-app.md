# Plan: Self-Contained llama-menubar.app (v2)

## Goal
Merge `install-llama.sh` into the menu bar app so the user downloads **one `.app`**, drags it to `/Applications`, opens it — everything works. No separate script download/install step.

## Confirmed Decisions
| Decision | Choice |
|---|---|
| First launch | Welcome dialog → user clicks "Install" |
| Output display | Post-execution (collect all, show when done) |
| Updates | Two separate items: "Check for App Update" + "Check for llama.cpp Update" |
| Prototype first | Restructure `llama-menubar/` in a new git branch, test locally, then decide how to merge |

## Target Directory Structure
```
llama-menubar/
├── Package.swift          # unchanged (SwiftPM, macOS 13+)
├── build.sh               # version-aware, copies Resources
├── Sources/
│   └── llmctl/
│       ├── main.swift     # RESTRUCTURED (see below)
│       ├── llama.png
│       └── llama.icns
└── Resources/
    └── install-llama.sh   # copied from ../install-llama.sh during build
```

Everything stays in a single SwiftPM target (`llmctl`). No new files needed — just a restructured `main.swift` and updated `build.sh` + `release.sh`.

## Architecture Overview

```
┌──────────────────────────────────────────────────┐
│                  AppDelegate                      │
│  applicationDidFinishLaunching:                  │
│    1. ensureScriptIsReady()                       │
│    2. if not installed → Welcome → Install → Menu │
│    3. else → Menu                                │
└──────────────────┬───────────────────────────────┘
                   │
    ┌──────────────┼──────────────┐
    ▼              ▼              ▼
ServerManager  UpdateManager  AppUpdateManager
(LGAgent ctl)  (llama.cpp     (GitHub release
                script ops)    version check)
    │              │              │
    └──────────────┼──────────────┘
                   ▼
          OutputWindowController
          (post-execution display)
```

### Data flow — First Install
```
User opens .app
  → AppDelegate: ensureSupportDir() creates ~/Library/Application Support/llama-menubar/
  → AppDelegate: copyBundledScript() copies install-llama.sh from bundle to above dir
  → AppDelegate: check if server.conf exists (~/.config/llama/server.conf)
  → NOT found → show NSAlert welcome dialog with [Cancel] [Install]
  → [Install] → OutputWindowController shows "Installing…" with spinner
  → Run bash install-llama.sh on bg thread → capture full stdout+stderr
  → Script finishes → display all output in NSTextView → hide spinner → [Close]
  → Menu bar icon appears, polling starts
```

### Data flow — Normal Launch
```
User opens .app (already installed)
  → AppDelegate: ensure support dir + fresh script copy (overwrite if bundle newer)
  → server.conf exists → show menu bar immediately
  → Start 5s polling for llama-server process
```

## Detailed Changes

### 1. main.swift — New/Modified Classes

#### `AppSupport` (new, or top-level constants + funcs)
```swift
let APP_SUPPORT_DIR = NSHomeDirectory() + "/Library/Application Support/llama-menubar"
let INSTALL_SCRIPT_PATH = APP_SUPPORT_DIR + "/install-llama.sh"

func ensureSupportDir() -> Bool { ... }
func copyBundledScript() -> Bool { ... }
func isInstalled() -> Bool { FileManager.default.fileExists(atPath: configPath) }
```
- `ensureSupportDir()`: create `APP_SUPPORT_DIR` if missing
- `copyBundledScript()`: copy from `Bundle.main.resourcePath! + "/install-llama.sh"` to `INSTALL_SCRIPT_PATH`, set executable (`chmod +x` via `FileManager.setAttributes` or run `chmod`)

#### `AppDelegate` — modified
```swift
func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)

    // 1. Prepare script
    guard ensureSupportDir(), copyBundledScript() else {
        // fatal error or alert
        return
    }

    // 2. Check install state
    if isInstalled() {
        showMenuBar()
    } else {
        showWelcomeAndInstall()
    }
}

private func showWelcomeAndInstall() {
    let alert = NSAlert()
    alert.messageText = "Welcome to llama-menubar"
    alert.informativeText = "This app will install llama.cpp, download a language model, and set up a local AI server in your menu bar.\n\nThis may take a few minutes depending on your internet speed."
    alert.addButton(withTitle: "Install")
    alert.addButton(withTitle: "Quit")
    guard alert.runModal() == .alertFirstButtonReturn else { NSApp.terminate(nil); return }

    // Run installation
    InstallManager.shared.install { [weak self] success in
        DispatchQueue.main.async {
            if success {
                self?.showMenuBar()
            } else {
                let err = NSAlert()
                err.messageText = "Installation incomplete"
                err.informativeText = "Check the output for details. You can re-install later from the menu."
                err.runModal()
                self?.showMenuBar() // show menu even if partial
            }
        }
    }
}

private func showMenuBar() {
    menuBar = MenuBarController()
}
```

#### `InstallManager` (new)
```swift
final class InstallManager: NSObject {
    static let shared = InstallManager()
    private var activeControllers: [OutputWindowController] = []

    func install(completion: @escaping (Bool) -> Void) {
        let controller = OutputWindowController(title: "Installing llama.cpp…", showApplyInitially: false)
        activeControllers.append(controller)
        controller.show()
        controller.appendText("Installing…\n")

        let scriptDir = URL(fileURLWithPath: INSTALL_SCRIPT_PATH).deletingLastPathComponent().path

        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/bash")
            task.arguments = [INSTALL_SCRIPT_PATH, "--install-agent", "--skip-server"]
            // (or desired default: download model + install agent + start server?
            //  discussion point below)
            let outPipe = Pipe()
            let errPipe = Pipe()
            task.standardOutput = outPipe
            task.standardError = errPipe
            task.currentDirectoryURL = URL(fileURLWithPath: scriptDir)

            do { try task.run() } catch { ... }

            // Read all output (non-streaming, post-exec)
            task.waitUntilExit()
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            var fullOutput = ""
            if let s = String(data: outData, encoding: .utf8) { fullOutput += s }
            if let s = String(data: errData, encoding: .utf8) { fullOutput += s }

            let success = task.terminationStatus == 0

            DispatchQueue.main.async {
                controller.setOutput(fullOutput)
                controller.finish(exitCode: task.terminationStatus, applyEnabled: false) { _ in
                    self.activeControllers.removeAll { $0 === controller }
                    completion(success)
                }
            }
        }
    }
}
```

#### `UpdateManager` — modified (rename to `LlamaCppUpdateManager` or keep)
- Remove all candidate path discovery — always use `INSTALL_SCRIPT_PATH`
- `runScript` simplified: no streaming, use `readDataToEndOfFile` post-exec, display all at once
- Keep `--check-update` detection and inline "Apply Update" button logic

#### `AppUpdateManager` (new)
```swift
final class AppUpdateManager {
    static let shared = AppUpdateManager()

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    func check(completion: @escaping (String?) -> Void) {
        // Fetch https://api.github.com/repos/ivantonov/llama.cpp-macos-installer/releases/latest
        // Parse JSON, compare tag_name (strip "v" prefix) with currentVersion
        // If newer → return download URL; else → nil
    }

    func showResult() {
        check { latestURL in
            if let url = latestURL {
                // Show "Update available" alert with "Download" button
                // Open URL in browser
            } else {
                // Show "You're up to date" alert
            }
        }
    }
}
```

#### `OutputWindowController` — fixed
- Remove the streaming reader loops
- Add `func setOutput(_ text: String)` to set the full text at once
- Keep the spinner, buttons, title, finish logic
- Simplify: show window with spinner → caller runs script → when done, `setOutput()` + `finish()`

#### `MenuBarController` — modified menu
```
Menu:
  llama.cpp — running/stopped     (disabled)
  model label                     (disabled)
  ─────
  Open WebUI                      ⌘O
  Restart Server                  ⌘R   (or Start/Stop)
  ─────
  Tail Logs                       ⌘L
  ─────
  Check for App Update...              🔔 NEW
  Check for llama.cpp Update...        (was "Check for Update...")
  Apply llama.cpp Update...            (was "Apply Update...")
  ─────
  Launch at Login
  ─────
  Quit                            ⌘Q
```

### 2. build.sh — changes

```bash
VERSION="2.0.0"
APP_NAME="llama-menubar"
BUILD_ARM64=".build/arm64/release"
BUILD_X86_64=".build/x86_64/release"
UNIVERSAL_DIR=".build"

# Build both slices (same as before)

# Create app bundle
mkdir -p "${APP_NAME}.app/Contents/MacOS"
cp "${UNIVERSAL_DIR}/llmctl-universal" "${APP_NAME}.app/Contents/MacOS/llmctl"

mkdir -p "${APP_NAME}.app/Contents/Resources"
cp Sources/llmctl/llama.png "${APP_NAME}.app/Contents/Resources/llama.png"
cp Sources/llmctl/llama.icns "${APP_NAME}.app/Contents/Resources/llama.icns"

# Bundle install-llama.sh
cp "../install-llama.sh" "${APP_NAME}.app/Contents/Resources/install-llama.sh"

# Generate Info.plist with version
cat > "${APP_NAME}.app/Contents/Info.plist" <<EOF
  ...
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${VERSION}</string>
  ...
EOF
```

### 3. release.sh — changes

```bash
cd "$(dirname "$0")"
VERSION="${1:-2.0.0}"   # allow override via argument
OUTDIR="release-out"

rm -rf "$OUTDIR"
mkdir -p "$OUTDIR"

(cd llama-menubar && ./build.sh)

ditto -c -k --sequesterRsrc --keepParent \
  "llama-menubar/llama-menubar.app" \
  "$OUTDIR/llama-menubar-${VERSION}.zip"

echo "  Release ready: $OUTDIR/llama-menubar-${VERSION}.zip"
```

## Design Decisions & Edge Cases

### Script defaults for first install
The welcome install will run the script with `--install-agent --skip-server` (set up LaunchAgent but don't start server yet). After install, the app starts polling and the user can Start via the menu. This is cleaner than having the script start a server in the background before the app is ready.

Alternative: run script with no special flags (default: install + download model + start server + install agent). This is the full script experience. I recommend the latter — the user expects everything to work immediately after install.

**Resolved**: Run with default flags (full install, model download, server start, agent install). The app window shows all progress. After completion, server should be running and menu bar shows green.

### Ensuring the script is always fresh
On every app launch, `copyBundledScript()` overwrites the Application Support copy with the bundle's version. This ensures that updating the .app also updates the script. Existing downloaded archives in the support dir are not affected.

### What if support dir already has llama-b* archives?
When the user updates the app, the script in Application Support is overwritten but archives remain. The new script's `--check-update` will find the existing archives and know the installed build number. No data loss.

### What if the user has already installed llama.cpp (old method)?
The app checks for `~/.config/llama/server.conf`. If present, it skips the install flow and goes straight to the menu bar. The bundled script path takes over for future updates.

### v1 → v2 migration
Users who already have llama-menubar v1 and llama.cpp installed:
1. Download v2 .app, replace old one in /Applications
2. Open v2 → detects existing install → menu bar appears
3. Under the hood, the app creates support dir + copies script
4. All future updates go through the managed script path
5. Old `UserDefaults("installScriptPath")` is ignored / migrated

## Implementation Order

| Step | Description | Files |
|---|---|---|
| 1 | Add `APP_SUPPORT_DIR`, `INSTALL_SCRIPT_PATH`, `ensureSupportDir()`, `copyBundledScript()` | main.swift |
| 2 | Add `InstallManager` with post-execution output | main.swift |
| 3 | Modify `AppDelegate` for first-launch flow | main.swift |
| 4 | Rewrite `OutputWindowController` — drop streaming, add `setOutput()` | main.swift |
| 5 | Simplify `UpdateManager` to use `INSTALL_SCRIPT_PATH` only, drop streaming | main.swift |
| 6 | Add `AppUpdateManager` with GitHub release check | main.swift |
| 7 | Update `MenuBarController` menu items | main.swift |
| 8 | Update `build.sh` with version + Info.plist changes | build.sh |
| 9 | Update `release.sh` — only .app zip | release.sh |
| 10 | Build and test locally | terminal |
| 11 | Create git branch `merge-proto` and commit | git |
| 12 | Present for review before merging to main | — |

## Testing

1. `cd llama-menubar && ./build.sh` — should produce `llama-menubar.app`
2. `./release.sh 2.0.0` — should produce `release-out/llama-menubar-2.0.0.zip`
3. Test fresh install flow:
   - Move current llama-menubar away, remove `~/.config/llama/server.conf`
   - Open the .app
   - Verify welcome dialog appears
   - Click Install — verify OutputWindow shows script output
   - Verify server starts, menu bar shows green icon
4. Test normal launch:
   - Open .app again (server.conf exists)
   - Verify menu bar appears immediately, server status correct
5. Test "Check for App Update" — should show "You're up to date" for now
6. Test "Check for llama.cpp Update" — should find latest build from GitHub
7. Test Launch at Login toggle
8. Test Start/Stop/Restart
