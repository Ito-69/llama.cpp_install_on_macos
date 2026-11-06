# Workspace Rules: llama.cpp-macos-installer

## Release & Deployment Workflow
- **Never perform local-only updates:** All changes intended for the application must go through GitHub releases and the Homebrew tap.
- **Always follow the complete Release Workflow:**
  1. **Bump Version:** Update `VERSION` in `llamamate/build.sh` (e.g. `2.4.x`). It is the single source of truth for the version.
  2. **Release Notes:** Write `release-notes/v<version>.md` (Markdown, same style as previous releases).
  3. **Commit & Merge:** Commit the source changes, version bump and notes with a clear message (e.g. `chore: release v2.4.x`) and merge them into `main` on `Ito-69/llama.cpp_install_on_macos`. The DMG is **not** committed — `release-out/` is gitignored.
  4. **Tag → CI build:** Create and push the tag on the merged commit:
     ```bash
     git tag v<version> && git push origin v<version>
     ```
     `.github/workflows/release.yml` builds the universal app and DMG on a macOS runner, verifies it, and creates a **draft** GitHub Release with the DMG and the notes from step 2. The tag must match `VERSION` or the build fails.
  5. **Test & Publish:** Download the DMG from the draft release, smoke-test the app, then click **Publish release** in the GitHub UI. Publishing must be done by a person (a release published by `GITHUB_TOKEN` does not trigger other workflows).
  6. **Homebrew Tap Sync:**
     - `.github/workflows/update-homebrew-tap.yml` triggers on release publish and updates `Casks/llamamate.rb` in `Ito-69/homebrew-llamamate`.
     - Confirm the action finishes and `Casks/llamamate.rb` is updated with the new version and SHA256.
  7. **Local Installation / Upgrade:**
     - Remind the user to upgrade through Homebrew:
       ```bash
       brew update && brew upgrade --cask llamamate
       ```
- **Local fallback:** `bash release.sh` still builds `release-out/LlamaMate-<version>.dmg` locally on a Mac (e.g. if CI is unavailable); upload it with `gh release upload v<version> release-out/LlamaMate-<version>.dmg`.
