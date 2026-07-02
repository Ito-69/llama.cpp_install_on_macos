# Server Config Profiles & Settings

Add user-facing server profiles (Fast/Balanced/Accurate) with GUI controls and RAM safety checks.

## Files

| File | Action |
|------|--------|
| `llama-menubar/Sources/llmctl/SettingsWindowController.swift` | **Create** — new settings window |
| `llama-menubar/Sources/llmctl/main.swift` | **Modify** — ServerManager loads new fields, MenuBarController adds "Server Settings…" |
| `llama-menubar/Sources/llmctl/ModelManager.swift` | **Modify** — writeServerConfig preserves/writes new fields |
| `install-llama.sh` | **Modify** — save_config (new fields), write_start_script (new args + RAM check) |

---

## 1. `server.conf` — new fields

```
NGL=40
FA=1
CTK="q8_0"
CTV="q8_0"
THREADS=0
BATCH_SIZE=512
PROFILE="balanced"
```

- `NGL`: GPU layers, integer 0–99 (0=CPU only, 99=all on GPU via Metal)
- `FA`: flash attention, 0 or 1
- `CTK`, `CTV`: KV cache quantization, one of `f16`, `q8_0`, `q4_0`
- `THREADS`: CPU threads, 0=auto
- `BATCH_SIZE`: prompt batch size, integer
- `PROFILE`: `"fast"`, `"balanced"`, `"accurate"` — for UI sync

### Profile presets (applied when user picks a profile)

**Apple Silicon** (detected via `sysctl hw.optional.arm64`):
| Profile | NGL | FA | CTK/CTV |
|---------|-----|----|---------|
| Fast    | 99  | 1  | q8_0    |
| Balanced| 40  | 1  | q8_0    |
| Accurate| 99  | 0  | f16     |

**Intel Mac**:
| Profile | NGL | FA | CTK/CTV |
|---------|-----|----|---------|
| Fast    | 1   | 0  | f16     |
| Balanced| auto| 0  | f16     |
| Accurate| 0   | 0  | f16     |

"When NGL = 0: no -ngl flag passed (CPU only)"
"When NGL = auto on Intel: pass -ngl 999 or just omit?"

Decision: for Intel Balanced `-ngl auto`, we pass `-ngl 999` (llama.cpp treats this as "auto"). For Intel Accurate, we pass no `-ngl` flag (=CPU only).

---

## 2. `install-llama.sh` changes

### 2a. `save_config()` — add new fields

```bash
NGL=${NGL:-40}
FA=${FA:-1}
CTK=${CTK:-q8_0}
CTV=${CTV:-q8_0}
THREADS=${THREADS:-0}
BATCH_SIZE=${BATCH_SIZE:-512}
PROFILE=${PROFILE:-balanced}
```

Insert these after `HOST="${HOST}"` in the heredoc.

### 2b. `write_start_script()` — add new args + RAM check

```bash
# RAM check (safety net)
TOTAL_RAM=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
MODEL_SIZE=$(stat -f%z "$MODEL_PATH" 2>/dev/null || echo 0)
# Rough estimate: context uses ~2 bytes * 64 layers * CONTEXT
CTX_RAM=$(( CONTEXT * 128 * 1024 ))  # ~128KB per token for a 7B model context
NEEDED=$(( MODEL_SIZE + CTX_RAM ))
if [ "$NEEDED" -gt "$TOTAL_RAM" ] && [ "$TOTAL_RAM" -gt 0 ]; then
  echo "[llama-menubar] WARNING: Model may need ~$(( NEEDED / 1073741824 )) GB RAM, system has $(( TOTAL_RAM / 1073741824 )) GB" >&2
fi
```

Then add flags to `exec`:

```bash
exec "${HOME}/.local/bin/llama-server" \
  -m "${MODEL_PATH}" \
  -c "${CONTEXT}" \
  --port "${PORT}" \
  --host "${HOST}" \
  -ngl "${NGL:-40}" \
  -fa "${FA:-0}" \
  -ctk "${CTK:-f16}" \
  -ctv "${CTV:-f16}" \
  -t "${THREADS:-0}" \
  -b "${BATCH_SIZE:-512}"
```

---

## 3. `main.swift` — ServerManager additions

### 3a. New properties in ServerManager

```swift
private(set) var ngl = "40"
private(set) var fa = "1"
private(set) var ctk = "q8_0"
private(set) var ctv = "q8_0"
private(set) var threads = "0"
private(set) var batchSize = "512"
private(set) var profile = "balanced"
```

### 3b. Load in `loadConfig()`

Add cases after `.case "MODEL_PATH"`:

```swift
case "NGL":       ngl = parts[1]
case "FA":        fa = parts[1]
case "CTK":       ctk = parts[1].replacingOccurrences(of: "\"", with: "")
case "CTV":       ctv = parts[1].replacingOccurrences(of: "\"", with: "")
case "THREADS":   threads = parts[1]
case "BATCH_SIZE": batchSize = parts[1]
case "PROFILE":   profile = parts[1].replacingOccurrences(of: "\"", with: "")
```

### 3c. Add static helpers

```swift
static func isAppleSilicon() -> Bool {
    var ret = true
    // sysctl hw.optional.arm64 — returns 1 on Apple Silicon
    if let f = fopen("/usr/sbin/sysctl", "r") { fclose(f) } // just check arch
    var info = utsname()
    uname(&info)
    let machine = withUnsafeBytes(of: &info.machine) { Data($0) }
    let s = String(data: machine.prefix(while: { $0 != 0 }), encoding: .utf8) ?? ""
    return s == "arm64"
}
```

Actually simpler: use `ProcessInfo.processInfo.processorInfo` or just check `sysctl`:

```swift
static func isAppleSilicon() -> Bool {
    var hw = 0
    var size = MemoryLayout<Int>.size
    sysctlbyname("hw.optional.arm64", &hw, &size, nil, 0)
    return hw != 0
}
```

### 3d. Apply profile preset method

```swift
func applyProfile(_ profile: String) {
    self.profile = profile
    let isAS = ServerManager.isAppleSilicon()
    switch profile {
    case "fast":
        ngl = isAS ? "99" : "1"
        fa = isAS ? "1" : "0"
        ctk = isAS ? "q8_0" : "f16"
        ctv = isAS ? "q8_0" : "f16"
    case "balanced":
        ngl = isAS ? "40" : "0"
        fa = isAS ? "1" : "0"
        ctk = isAS ? "q8_0" : "f16"
        ctv = isAS ? "q8_0" : "f16"
    case "accurate":
        ngl = isAS ? "99" : "0"
        fa = "0"
        ctk = "f16"
        ctv = "f16"
    default: break
    }
}
```

Note: For Intel "balanced" (-ngl auto) and Intel "accurate" (no KV cache opts) — we pass `ngl = "0"` which means no -ngl flag; and ctk/ctv = "f16" which is default (no optimization).

### 3e. MenuBarController — add "Server Settings…" item

In `refresh()`, after "Models…" menu item:

```swift
let settings = NSMenuItem(title: "Server Settings…", action: #selector(openSettings), keyEquivalent: "")
settings.target = self
menu.addItem(settings)
```

With action:

```swift
@objc private func openSettings() {
    SettingsWindowController.shared.showWindow()
}
```

---

## 4. `ModelManager.swift` — write new fields

### 4a. `writeServerConfig()` — read and preserve new fields

Add reading:

```swift
var ngl = "40"
var fa = "1"
var ctk = "q8_0"
var ctv = "q8_0"
var threads = "0"
var batchSize = "512"
var profile = "balanced"
for line in content.components(separatedBy: .newlines) {
    let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
    guard parts.count == 2 else { continue }
    switch parts[0] {
    case "PORT":        port = parts[1]
    case "CONTEXT":     context = parts[1]
    case "HOST":        host = parts[1].replacingOccurrences(of: "\"", with: "")
    case "NGL":         ngl = parts[1]
    case "FA":          fa = parts[1]
    case "CTK":         ctk = parts[1].replacingOccurrences(of: "\"", with: "")
    case "CTV":         ctv = parts[1].replacingOccurrences(of: "\"", with: "")
    case "THREADS":     threads = parts[1]
    case "BATCH_SIZE":  batchSize = parts[1]
    case "PROFILE":     profile = parts[1].replacingOccurrences(of: "\"", with: "")
    default: break
    }
}
```

Then write all fields:

```swift
let newContent = """
# llama.cpp — generated by llama-menubar
MODEL_LABEL="\(label)"
MODEL_REPO="\(repo)"
MODEL_FILE="\(file)"
MODEL_PATH="\(modelPath)"
PORT=\(port)
CONTEXT=\(context)
HOST="\(host)"
NGL=\(ngl)
FA=\(fa)
CTK="\(ctk)"
CTV="\(ctv)"
THREADS=\(threads)
BATCH_SIZE=\(batchSize)
PROFILE="\(profile)"
"""
```

### 4b. Add `saveSettings()` method

```swift
func saveSettings(ngl: String, fa: String, ctk: String, ctv: String, threads: String, batchSize: String, context: String, port: String, profile: String) throws {
    // Read existing config, update all fields, write back
    guard let content = try? String(contentsOfFile: CONFIG_PATH, encoding: .utf8) else {
        throw NSError(...)
    }
    // Parse all existing fields, overwrite with new values
    var modelLabel = "", modelRepo = "", modelFile = "", modelPath = "", host = "0.0.0.0"
    for line in content.components(separatedBy: .newlines) {
        ...
    }
    let newContent = """
    # llama.cpp — generated by llama-menubar
    MODEL_LABEL="\(modelLabel)"
    MODEL_REPO="\(modelRepo)"
    MODEL_FILE="\(modelFile)"
    MODEL_PATH="\(modelPath)"
    PORT=\(port)
    CONTEXT=\(context)
    HOST="\(host)"
    NGL=\(ngl)
    FA=\(fa)
    CTK="\(ctk)"
    CTV="\(ctv)"
    THREADS=\(threads)
    BATCH_SIZE=\(batchSize)
    PROFILE="\(profile)"
    """
    try newContent.write(toFile: CONFIG_PATH, atomically: true, encoding: .utf8)
    ServerManager.shared.reloadConfigAndRestart()
}
```

Actually, it's cleaner to read all values from ServerManager (which already loads the config) instead of re-parsing. Let me simplify:

```swift
func saveSettings(ngl: String, fa: String, ctk: String, ctv: String, threads: String, batchSize: String, context: String, port: String, profile: String) throws {
    let sm = ServerManager.shared
    let newContent = """
    # llama.cpp — generated by llama-menubar
    MODEL_LABEL="\(sm.modelLabel)"
    MODEL_REPO="\(sm.modelRepo)"
    MODEL_FILE="\(sm.modelFile)"
    MODEL_PATH="\(sm.modelPath)"
    PORT=\(port)
    CONTEXT=\(context)
    HOST="\(sm.host)"
    NGL=\(ngl)
    FA=\(fa)
    CTK="\(ctk)"
    CTV="\(ctv)"
    THREADS=\(threads)
    BATCH_SIZE=\(batchSize)
    PROFILE="\(profile)"
    """
    try newContent.write(toFile: CONFIG_PATH, atomically: true, encoding: .utf8)
    ServerManager.shared.reloadConfigAndRestart()
}
```

But ServerManager needs `modelRepo`, `modelFile`, `host` properties. Let me add those too.

Currently ServerManager has: `modelLabel`, `modelPath`, `port`. We need to add: `modelRepo`, `modelFile`, `host`.

---

## 5. `SettingsWindowController.swift` — new file

Create a new Swift file with a settings window (NSPanel). Layout:

### Profile section
- Label: "Profile"
- NSPopUpButton: "Fast", "Balanced", "Accurate"
- Description text below (auto-updates when profile changes)

### Controls section
- **GPU layers** (-ngl): label + NSSlider (0–99, integer snap) + value label
- **Context size** (-c): label + NSPopUpButton (2048, 4096, 8192, 16384, 32768)
- **Flash attention** (-fa): NSButton (checkbox)
- **KV cache type** (-ctk / -ctv): label + NSPopUpButton (f16, q8_0, q4_0) — shared popup for both
- **Threads** (-t): label + NSTextField (placeholder "0 = auto")
- **Batch size** (-b): label + NSTextField
- **Port**: label + NSTextField

### RAM estimate section
- Label showing estimated RAM usage vs available RAM
- Updated whenever context or profile changes

### Buttons
- "Apply & Restart" — writes config, restarts server
- "Cancel" — closes window

### Profile → control sync
When profile changes, auto-fill all controls with profile presets.
When user modifies a control manually, profile switches to "Custom" (or keeps the current profile name but controls are no longer locked).

Decision: when user changes any control after picking a profile, the profile popup stays on the selected profile but the controls reflect manual edits. They can re-select a profile to reset controls.

### Layout:
```
┌──────────────────────────────────────┐
│  Profile: [Fast ▼]                   │
│  ─── GPU layers ────[====●======] 40 │
│  Context size: [8192 ▼]              │
│  ☐ Flash attention                   │
│  KV cache quant: [q8_0 ▼]           │
│  Threads: [0      ] (0 = auto)       │
│  Batch size: [512   ]                │
│  Port: [8080    ]                    │
│                                       │
│  RAM: ~4.7 GB model + ~2 GB ctx      │
│       ≈ 6.7 GB needed, 18 GB avail ✓ │
│                                       │
│  [Apply & Restart]  [Cancel]         │
└──────────────────────────────────────┘
```

---

## 6. RAM check — implementation details

### In Swift (SettingsWindowController):

```swift
private func updateRamEstimate() {
    let totalRAM = ProcessInfo.processInfo.physicalMemory
    let modelSize = (try? FileManager.default.attributesOfItem(atPath: ServerManager.shared.modelPath)[.size] as? Int64) ?? 0
    let ctxTokens = Int(contextValue) ?? 8192
    let bytesPerToken: Int64 = 2 * 64  // ~2 bytes * 64 layers = 128KB per token
    let ctxRAM = Int64(ctxTokens) * bytesPerToken * 1024  // convert to bytes
    // Actually: context RAM is ~ context_size * (n_embd * n_layers * 2) / ~32
    // Rough: for a 7B model, 8192 context ≈ 2-4 GB
    // Simpler estimate: model_size * 0.3 for KV cache (very rough)
    let ctxEstimate = modelSize / 3  // rough KV cache estimate
    let needed = modelSize + ctxEstimate
    let neededGB = Double(needed) / 1_000_000_000.0
    let totalGB = Double(totalRAM) / 1_000_000_000.0
    
    if needed > Int64(totalRAM) {
        ramLabel.stringValue = String(format: "⚠️ %.1f GB needed, %.0f GB available — may crash!", neededGB, totalGB)
        ramLabel.textColor = .systemRed
    } else if needed > Int64(Double(totalRAM) * 0.8) {
        ramLabel.stringValue = String(format: "⚠️ %.1f GB needed, %.0f GB available — close other apps", neededGB, totalGB)
        ramLabel.textColor = .systemOrange
    } else {
        ramLabel.stringValue = String(format: "%.1f GB needed, %.0f GB available ✓", neededGB, totalGB)
        ramLabel.textColor = .secondaryLabelColor
    }
}
```

### In start script (install-llama.sh):

```bash
# RAM check (safety net before starting server)
TOTAL_RAM=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
MODEL_SIZE=$(stat -f%z "$MODEL_PATH" 2>/dev/null || echo 0)
# Estimate KV cache: CONTEXT * 2 bytes * ~64 layers * ~4096 hidden / 32 heads
# Simpler: roughly 30% of model size for 8192 context
CTX_RAM=$(( MODEL_SIZE / 3 ))
NEEDED=$(( MODEL_SIZE + CTX_RAM ))
if [ "$TOTAL_RAM" -gt 0 ] && [ "$NEEDED" -gt "$TOTAL_RAM" ]; then
  echo "[llama-menubar] WARNING: Model may need ~$(( NEEDED / 1073741824 )) GB RAM" \
       "but system has $(( TOTAL_RAM / 1073741824 )) GB. Expect crash or swap." >&2
fi
```

---

## 7. Implementation order

1. **`install-llama.sh`**: update `save_config()` + `write_start_script()` with new fields and RAM check
2. **`main.swift`**: add new properties to ServerManager, load them, add `isAppleSilicon()`, add `applyProfile()`, add menu item
3. **`ModelManager.swift`**: update `writeServerConfig()` to preserve/write new fields, add `saveSettings()`
4. **`SettingsWindowController.swift`**: new file — build the window
5. **Build & test**

---

## 8. Migration / backward compatibility

- Old server.conf files missing new fields → defaults are used (NGL=40, FA=1, etc.)
- The start script uses `${NGL:-40}` etc. for safe defaults
- Settings window can be opened independently any time

---

## 9. Risk / edge cases

| Risk | Mitigation |
|------|-----------|
| User picks Fast profile on low-RAM machine | RAM check warning in UI + start script safety net |
| User changes controls then picks profile | Profile re-applies all preset values |
| server.conf missing (not installed yet) | Settings window shows "Not installed" message |
| Port conflict | User can change port in settings |
| Apple Silicon detection fails | Fall back to Intel presets |
| Context too large for model | llama-server will OOM; RAM check gives warning |
