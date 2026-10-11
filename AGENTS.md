# Workspace Rules: llama.cpp-macos-installer

## Release & Deployment Workflow
- **Never perform local-only updates:** All changes intended for the application must go through GitHub releases and the Homebrew tap.
- **Always follow the complete Release Workflow:**
  1. **Bump Version:** Update `VERSION` in `llamamate/build.sh` (e.g. `2.3.x`).
  2. **Build & Package DMG:** Run `bash release.sh <version>` to build the universal binary and generate `release-out/LlamaMate-<version>.dmg`.
  3. **Stage Changes:** Remove old DMG files from `release-out/`, add the new DMG, and stage all modified source files.
  4. **Commit & Push:** Commit with clear descriptive message (e.g. `feat: ... (v2.3.x)`) and push to `origin main` on `Ito-69/llama.cpp_install_on_macos`.
  5. **Create GitHub Release:**
     ```bash
     gh release create v<version> --target main --title "v<version>" --notes "<release notes>" "release-out/LlamaMate-<version>.dmg"
     ```
  6. **Homebrew Tap Sync:**
     - The GitHub Actions workflow (`.github/workflows/update-homebrew-tap.yml`) triggers on release publish to update `Casks/llamamate.rb` in `Ito-69/homebrew-llamamate`.
     - Confirm the action finishes and `Casks/llamamate.rb` is updated with the new version and SHA256.
  7. **Local Installation / Upgrade:**
     - Remind the user to upgrade through Homebrew:
       ```bash
       brew update && brew upgrade --cask llamamate
       ```
