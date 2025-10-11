# Release & Notarization Guide

This project ships a signed and notarized macOS CLI via the `release-macos` GitHub Actions workflow. The workflow produces a universal (arm64 + x86_64) binary, signs it with your Developer ID Application certificate, submits the archive to Apple for notarization, and uploads the notarized zip to a GitHub Release.

## 1. Apple prerequisites

1. Enroll in the Apple Developer Program and accept the latest agreements.
2. Create a **Developer ID Application** certificate and export it (`.p12`).
3. Generate an **App-Specific Password** (or an App Store Connect API key triple: `issuer`, `key`, `key_id`).

> Apple removed `altool` support on **November 1 2023**—`notarytool` is the only notarization interface going forward.

## 2. Repository secrets

Store the following secrets in your GitHub repository settings:

| Secret | Description |
| --- | --- |
| `MACOS_SIGN_P12` | Base64-encoded Developer ID Application `.p12` export |
| `MACOS_SIGN_P12_PASSWORD` | Password used when exporting the `.p12` |
| `MACOS_SIGNING_IDENTITY` | Signing identity label, e.g. `Developer ID Application: Jane Doe (TEAMID)` |
| `MACOS_KEYCHAIN_PASSWORD` | Throwaway password used to protect the temporary CI keychain |
| `APPLE_ID` | Apple ID email used for notarization |
| `APPLE_TEAM_ID` | 10-character Team ID |
| `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password (or replace the `notarytool store-credentials` step with API-key flags) |

The workflow also uses the built-in `GITHUB_TOKEN` to upload release assets.

## 3. Triggering a release

1. Update version metadata as needed (e.g. tag `vX.Y.Z`).
2. Push the tag or manually dispatch the workflow:
   ```bash
   git tag v0.1.0
   git push origin v0.1.0
   ```
3. The workflow runs on `macos-13`, installs Zig via Homebrew, builds both architectures, and runs `lipo` to create a universal binary.
4. After codesigning, the workflow zips the binary, notarizes the archive with `xcrun notarytool submit --wait`, and uploads both the zip and its SHA-256 checksum to the matching GitHub Release.

## 4. Local validation (optional)

For developer machines you can reuse the same sequence:

```bash
zig build -Doptimize=ReleaseFast
codesign --force --options runtime --timestamp --sign "Developer ID Application: Jane Doe (TEAMID)" zig-out/bin/pragma
xcrun notarytool submit pragma.zip --apple-id you@example.com --team-id TEAMID --password xxxx-xxxx-xxxx-xxxx --wait
```

Remember that stapling is not available for bare executables; the notarization ticket is attached to the archive by Apple and verified online by Gatekeeper.

## 5. Troubleshooting

- **`Team is not yet configured for notarization`** – contact Apple Developer Support to enable the service for your Team ID.
- **`notarytool` authentication failures** – confirm the stored credentials name matches `NOTARY_PROFILE` and that the temporary keychain is unlocked.
- **Codesign errors** – ensure the certificate is trusted on the runner (`security set-key-partition-list` in the workflow handles this) and that the binary is universal before signing (run `lipo -info dist/pragma`).

Once the workflow succeeds, the published release asset `pragma-macos.zip` is ready for end users: it is signed, notarized, and accompanied by a checksum file for integrity verification.
