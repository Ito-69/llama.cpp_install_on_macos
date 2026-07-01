# llama-menubar: Model Management

## Goal

Add a Models management window to llama-menubar so users can browse, download, activate, and delete GGUF models from Hugging Face — without touching the terminal.

## Decisions (resolved)

| Decision | Choice |
|---|---|
| Scope | Browse + managed collection (download, activate, delete, paste URL) |
| Discovery source | Embedded shortlist (8–12 curated) + HF API search |
| Quantization selection | Show all `.gguf` files in repo with sizes (user picks) |
| After-download flow | Download → "Use this model now?" dialog (Yes = activate + restart) |
| Disk space | "Installed Models" submenu in window with Make Active / Delete |
| UI surface | Single dedicated Models window (not submenus in menu bar) |
| Download progress | In-window progress bar + log (no separate OutputWindowController) |
| API client | Swift URLSession for browse/search; Python `hf` for downloads only |
| Version bump | 2.1.0 (new feature) |

## Menu bar change

Add a single item to the menu (between "Restart Server" and the App Update section, or wherever fits the current flow):

- **Models…** (⌘M) — opens / brings-to-front the Models window

## Models window

`NSPanel`, 720×500, resizable, single-instance (re-clicking `Models…` activates the existing window).

```
┌─────────────────────────────────────────────────────────────┐
│  Active: Qwen2.5 7B Q4_K_M (~4.7 GB) — running              │  ← header (always visible)
├─────────────────────────────────────────────────────────────┤
│  [ Active ] [ Browse ] [ Installed ] [ Install from URL ]   │  ← NSTabView
├─────────────────────────────────────────────────────────────┤
│  <tab content>                                              │
│                                                              │
│                                                              │
├─────────────────────────────────────────────────────────────┤
│  [progress ████░░░░]  Downloading Qwen2.5-7B-… 42%          │  ← footer (visible when active)
│  > fetching…                                                 │
│  > 1.9 GB / 4.7 GB                                          │
├─────────────────────────────────────────────────────────────┤
│                                              [ Close ]       │
└─────────────────────────────────────────────────────────────┘
```

### Tabs

1. **Active** — read-only: current model label, file, size, repo. Buttons: `Change Model…` (switches to Browse tab), `Reveal in Finder`.
2. **Browse**
   - **Sub-tab: Shortlist** — NSTableView, columns: Name, Params, Quant, Size, Downloads. ~10 rows from hardcoded list (Qwen2.5 7B/14B/32B, Llama 3.1 8B, Mistral Nemo, Phi-3 Mini, Gemma 2 9B, DeepSeek-LLM 7B, etc.).
   - **Sub-tab: Search** — NSSearchField + NSTableView. Queries `https://huggingface.co/api/models?search=<q>&filter=gguf&limit=30`. Shows name, downloads, last modified.
   - Selecting a row → fetches `https://huggingface.co/api/models/<repo_id>` and then file picker (see below).
3. **Installed** — NSTableView of all `*.gguf` in `~/models/`. Columns: filename, size. Active row marked with ✓. Right-click or trailing buttons: `Make Active` (disabled if active), `Delete…` (confirmation). Empty state: "(none — use Browse or Install from URL)".
4. **Install from URL** — Text field + paste button. Accepts:
   - `https://huggingface.co/<repo>` → query `list_repo_files`
   - `<repo_id>` (e.g. `bartowski/Qwen2.5-7B-Instruct-GGUF`) → query `list_repo_files`
   - `https://huggingface.co/<repo>/resolve/main/<file>` → parse both, skip file picker
   Then proceed to file picker or directly to download.

### File picker (shared by Browse, URL paste, Change Model)

Modal `NSPanel` 560×360. NSTableView of GGUF files in the chosen repo:
- File name
- Size (GB, from `Content-Length` HEAD request, cached)
- RAM hint (color cell: green ≤16 GB, yellow 16–32 GB, red >32 GB — based on `sysctl hw.memsize`)
- Quantization (parsed from filename suffix: Q2_K, Q3_K_M, Q4_K_S, Q4_K_M, Q5_K_M, Q6_K, Q8_0, F16)

Buttons: `Cancel` | `Download`.

### Download flow

1. Modal sheet with progress bar + scrolling log text view + `Cancel` button.
2. Spawns: `python3 -m huggingface_hub download <REPO> <FILE> --local-dir ~/models` (uses pip3-installed `huggingface_hub` from app support).
3. Streams stdout/stderr into log. Parses progress lines (huggingface_hub prints percentage + bytes).
4. On exit 0: dismiss sheet, show "Use this model now?" alert. **Yes** → write `server.conf` (`MODEL_LABEL`, `MODEL_REPO`, `MODEL_FILE`, `MODEL_PATH`) + `ServerManager.restartServer()`. **No** → file stays in `~/models`, refresh Installed tab.
5. On exit ≠ 0: show error alert with log excerpt.
6. Cancel → kill subprocess, return to file picker.

## New Swift files / changes

### New: `HuggingFaceAPI.swift`
- `searchModels(query: String, completion: @escaping ([ModelSummary]) -> Void)`
- `listRepoFiles(repo: String, completion: @escaping ([RepoFile]) -> Void)` — uses `https://huggingface.co/api/models/<repo>` then resolves tree for `main` branch.
- `ModelSummary { id, downloads, lastModified }`
- `RepoFile { path, size, quant }`
- Uses stored `HF_TOKEN` from `UserDefaults` for authenticated requests.

### New: `ModelsWindowController.swift`
- Singleton (`static let shared = ModelsWindowController()`).
- Owns the `NSPanel` and `NSTabView`.
- Coordinates child controllers for each tab.
- Exposes `showWindow()` that activates the panel.

### New: `ModelManager.swift`
- `downloadModel(repo:file:progress:completion:)` — spawns `hf` subprocess, parses progress.
- `activateModel(path:)` — writes `server.conf` (preserving PORT/CONTEXT/HOST), calls `ServerManager.restartServer()`.
- `deleteModel(path:)` — removes file, refreshes Installed tab.
- `listInstalledModels() -> [InstalledModel]` — scans `~/models/*.gguf` with sizes.

### Modified: `main.swift`
- `MenuBarController.refresh()`: add `Models…` item before the separator before App Update.
- `ServerManager.loadConfig()`: also read `MODEL_PATH` (currently only reads `MODEL_LABEL` and `PORT`) — needed for Active tab to show size.

## Edge cases

- **HF API rate-limited (HTTP 429):** alert "Hugging Face rate limit reached. Add a token in About → HF Token… for higher limits."
- **Repo has no `.gguf` files:** "No GGUF quantizations found in this repo."
- **No internet:** alert "No internet connection."
- **Disk full mid-download:** subprocess exits non-zero; alert with error.
- **Server running during download:** do not touch it. Activate explicitly restarts.
- **`~/models` empty:** Installed tab shows empty state.
- **User pastes URL with file:** skip file picker, go straight to download sheet.
- **Activate while download active:** Make Active buttons disabled in Installed tab during download.
- **No HF token + curated model works fine** (curated uses fixed repo+file, no API search needed).
- **Search returns zero results:** "No GGUF models found for '<q>'."

## Script (`install-llama.sh`) changes

**None required.** Reuse existing flags:
- Download: `--model-repo <R> --model-file <F> --skip-server --skip-install`
- `save_config()` already writes `MODEL_REPO` / `MODEL_FILE` / `MODEL_PATH` correctly.

If during implementation we find `hf` discovery is fragile, add `--hf-cli-path <path>` override — otherwise skip.

## Validation

Manual test plan on both Mac architectures (arm64, x86_64):
1. Open Models window from menu bar, confirm window appears, Active tab shows current model.
2. Browse → Shortlist → pick a model → file picker shows correct sizes → Download → progress streams → "Use this now?" → Yes → server restarts, WebUI loads with new model, Active tab updates.
3. Browse → Search → search "llama" → pick non-curated repo → file picker → Download.
4. Install from URL → paste `https://huggingface.co/bartowski/Qwen2.5-7B-Instruct-GGUF` → file picker → Download.
5. Installed tab → Make Active on a different model → restart, switch back.
6. Installed tab → Delete a model → confirmation → file removed.
7. Unplug internet → Browse Search → "No internet" alert.
8. Cancel mid-download → sheet dismisses, partial file cleaned up.
9. RAM hint colors render correctly on 8 GB / 16 GB / 32 GB+ machines.
10. Existing install / update / uninstall / Launch at Login flows still work.

## Versioning & release

- Bump `VERSION` in `llama-menubar/build.sh` to `2.1.0`.
- `release.sh 2.1.0` → upload to GitHub.
- Update `README.md` "Menu Bar App" table: add Models window description. Add new section "Managing Models" with the tabs overview and the 3 ways to install (Browse / URL / Active tab change).

## Risks

- HF API shapes change → wrap responses with `Codable` types and surface raw JSON in alerts on parse failure.
- `hf` subprocess progress parsing is format-dependent → use a permissive regex and fall back to indeterminate progress bar.
- Window state on relaunch → do not save size; always open at default 720×500.
- Models window opened during first-launch install (before server.conf exists) → defer opening until server is running, or show "Install llama.cpp first" in Active tab.

## Out of scope

- Model fine-tuning, LoRA adapters, vision models (mmproj files) — defer to a later release.
- Per-model context length / GPU layers overrides.
- Sharing models across multiple users.
- Editing the active model from `server.conf` directly (not user-facing).
