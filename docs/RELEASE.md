# Release Process

This document outlines the steps to release a new version of BetterCapture.

## Versioning Scheme

BetterCapture uses [Calendar Versioning (CalVer)](https://calver.org/) with the format `YYYY.MINOR.PATCH`.

- `YYYY`: The current year (e.g., 2026).
- `MINOR`: Incremental release number within the year.
- `PATCH`: Incremental number for bug fixes or small updates.

Example versions: `v2026.1.0`, `v2026.1.1`.

## Steps to Release

### 1. Create a GitHub Release

1. Navigate to the **Releases** section of the repository on GitHub.
2. Click **Draft a new release**.
3. Click **Choose a tag** and type the new version (e.g., `v2026.1.0`).
4. Select **Create new tag: [version] on publish**.
5. Fill in the release title (usually the same as the version) and provide release notes.
6. Click **Publish release**.

Once the release is published, a GitHub Action will automatically:

- Build the application.
- Sign and notarize the app.
- Create a DMG file: `BetterCapture-[version]-arm64.dmg`.
- Update the `appcast.xml` for Sparkle updates.
- Upload the DMG and `appcast.xml` back to the GitHub Release.

### 3. Update Homebrew Tap

After the release is complete and the DMG is attached to the GitHub Release, you must manually update the Homebrew formula.

1. Go to the [jsattler/homebrew-tap](https://github.com/jsattler/homebrew-tap) repository.
2. Update the `bettercapture.rb` formula:
   - **Version:** Update to the new release version.
   - **URL:** Update the download URL to point to the new DMG.
   - **SHA256:** Calculate the SHA256 of the new DMG file.
     - You can download the DMG and run: `shasum -a 256 BetterCapture-[version]-arm64.dmg`
     - Or get it from the CI logs if available.
3. Commit and push the changes to the homebrew-tap repository.
