# Homebrew Tap Guide

This repository doubles as a Homebrew tap so macOS users can install `pragma` with `brew`. The tap lives in `Formula/pragma.rb` and can build from `main` (HEAD) or install prebuilt release binaries.

## 1. Local smoke test (optional)

```bash
brew tap tkersey/pragma https://github.com/tkersey/pragma
brew install --HEAD tkersey/pragma/pragma
pragma --version  # ensure the binary runs
```

The `--HEAD` flag builds from source using the checked-in formula. Once a notarized release is published (see below) the flag is no longer required.

## 2. Cut a signed release

Follow `docs/RELEASE.md` to tag a version and let the `release-macos` workflow produce a notarized `pragma-macos.zip` plus a `.sha256` checksum. Those assets are uploaded to the matching GitHub release.

## 3. Update the formula metadata

After the workflow finishes:

1. Download `pragma-macos.zip.sha256` from the release assets or copy it from `artifacts/pragma-macos.zip.sha256` in the workflow logs.
2. Update `Formula/pragma.json` with the new version number and checksum:

   ```json
   {
     "version": "0.2.0",
     "macos": {
       "url": "https://github.com/tkersey/pragma/releases/download/v0.2.0/pragma-macos.zip",
       "sha256": "<sha256 from pragma-macos.zip.sha256>"
     }
   }
   ```

   Keep the `url` in sync with the release tag (including the leading `v`).
3. Commit the change and push to `main` alongside the tag. Homebrew users can now run `brew install tkersey/pragma/pragma` without the `--HEAD` flag.

## 4. Validating the tap

Run these checks before announcing the release:

```bash
brew uninstall pragma
brew install tkersey/pragma/pragma
brew test tkersey/pragma/pragma
```

`brew test` executes the `test do` block in the formula to confirm basic functionality.

## 5. Common troubleshooting

- **`Download failed`**: double-check the `url` in the formula matches the release tag (including the leading `v`).
- **`SHA256 mismatch`**: recalculate the checksum locally with `shasum -a 256 pragma-macos.zip` and confirm it matches the release asset.
- **`zig` not found when building HEAD**: ensure `depends_on "zig" => :build` remains in the formula so Homebrew installs Zig automatically.

With these steps in place, the repository serves as both the source tree and a Homebrew tap, giving users a one-liner installation path.
