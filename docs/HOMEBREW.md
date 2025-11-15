# Homebrew Tap Guide

This repository doubles as a Homebrew tap so macOS users can install `pragma` directly from source. The formula lives in `Formula/pragma.rb` and now defaults to installing the notarized archive described in `Formula/pragma.json`.

## Install from the tap

```bash
brew tap tkersey/pragma https://github.com/tkersey/pragma
brew install tkersey/pragma/pragma
pragma --version  # optional sanity check
```

Homebrew downloads the signed archive under `Formula/pragma.json` (currently built from tag releases) and installs it directly. Use `--HEAD` if you want to compile from the latest commit instead:

```bash
brew reinstall --HEAD tkersey/pragma/pragma
```

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

## Release metadata

`Formula/pragma.json` stores the version, download URL, and SHA256 checksum for the prebuilt archive. The `scripts/update_formula.sh` helper rewrites that file every time a new notarized binary is uploaded to GitHub Releases:

```bash
scripts/update_formula.sh 0.3.0 https://github.com/tkersey/pragma/releases/download/v0.3.0/pragma-macos-v0.3.0.zip <sha256>
```

## Troubleshooting

| Symptom | Resolution |
| --- | --- |
| `zig: command not found` during build | Homebrew should install Zig automatically via the `depends_on "zig" => :build` declaration. Install `brew install zig` manually if needed. |
| Build fails with write permission errors | Make sure you are outside read-only sandboxes; Homebrew builds in its own staging area with write access. |
| Want a clean reinstall | `brew uninstall pragma && brew install --HEAD tkersey/pragma/pragma`. |

With these steps the repository remains both the source tree and its own tap, giving contributors and users a one-liner installation path that always matches the latest code.
