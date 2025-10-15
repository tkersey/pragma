# Homebrew Tap Guide

This repository doubles as a Homebrew tap so macOS users can install `pragma` directly from source. The formula lives in `Formula/pragma.rb` and defaults to building the current `main` branch.

## Install from the tap

```bash
brew tap tkersey/pragma https://github.com/tkersey/pragma
brew install --HEAD tkersey/pragma/pragma
pragma --version  # optional sanity check
```

The `--HEAD` flag is required because we no longer publish notarized release archives. Homebrew clones this repository, runs `zig build -Doptimize=ReleaseFast`, and installs the resulting binary.

## Validate local changes

The tap clone that Homebrew uses lives at `$(brew --repo tkersey/pragma)`. You can edit the formula there (or copy over your working copy) and then reinstall:

```bash
cd "$(brew --repo tkersey/pragma)"
# edit Formula/pragma.rb or copy in a new version
brew reinstall --HEAD tkersey/pragma/pragma
```

Homebrew will rebuild from source using whatever formula and project state exists in that directory.

## Pin to a specific revision

After tapping, the repository lives at `$(brew --repo tkersey/pragma)`. Check out whatever commit you want Homebrew to build from, then reinstall:

```bash
brew tap tkersey/pragma https://github.com/tkersey/pragma
cd "$(brew --repo tkersey/pragma)"
git checkout <commit-or-tag>
brew reinstall --HEAD tkersey/pragma/pragma
```

## Optional metadata for future releases

If you decide to ship prebuilt artifacts again, populate `Formula/pragma.json` with the version, download URL, and SHA256 checksum. When those fields are set the formula will install the archive instead of compiling from source.

```bash
scripts/update_formula.sh v0.3.0 https://example.com/pragma-macos.zip <sha256>
```

## Troubleshooting

| Symptom | Resolution |
| --- | --- |
| `zig: command not found` during build | Homebrew should install Zig automatically via the `depends_on "zig" => :build` declaration. Install `brew install zig` manually if needed. |
| Build fails with write permission errors | Make sure you are outside read-only sandboxes; Homebrew builds in its own staging area with write access. |
| Want a clean reinstall | `brew uninstall pragma && brew install --HEAD tkersey/pragma/pragma`. |

With these steps the repository remains both the source tree and its own tap, giving contributors and users a one-liner installation path that always matches the latest code.
