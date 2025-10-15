# pragma

`pragma` is a lightweight Zig CLI that wraps `codex exec` so coding agents can run sub-agents without a larger toolchain. The tool accepts a single positional argument — the system prompt that should govern the sub-agent — and handles the rest:

- Frames the call with a minimal sub-agent persona and reminds the model to ask for extra context when needed.
- Invokes `codex exec --skip-git-repo-check --json -c 'mcp_servers={}'` (make sure `codex` is on your `$PATH`).
- Streams the JSONL output, capturing the final `agent_message` item and emitting its markdown back to stdout.

## Build

```bash
# Requires Zig 0.11+ (install via Homebrew: brew install zig)
zig build
```

## Run

```bash
# Single-turn invocation with a system prompt
zig build run -- "Act as a focused CSS sub-agent. Return a markdown checklist."
```

If the sub-agent needs environment or repository details, include them in the system prompt you pass to `pragma` (or instruct the agent to request them explicitly).

- Override the default Markdown contract from inside the directive itself. Prepend metadata lines or blocks at the top of the prompt:

```text
pragma-output-format: json
Summarize outstanding risks for this repo.
```

```text
<<<pragma-output-contract
Emit YAML with keys result, verification, risks.
pragma-output-contract>>>
Operate as a release auditor.
```

If both a format and a custom block are present, the block wins.

## Install via Homebrew Tap

This repository doubles as a Homebrew tap. To build `pragma` from the latest `main` branch using Homebrew:

```bash
brew tap tkersey/pragma https://github.com/tkersey/pragma
brew install --HEAD tkersey/pragma/pragma
```

The formula fetches this repository, runs `zig build -Doptimize=ReleaseFast`, and installs the resulting binary. The `--HEAD` flag is currently required because we no longer ship notarized release archives; Homebrew builds from source instead.

Need a reproducible build? After tapping, you can check out the tap to a specific commit and reinstall:

```bash
cd "$(brew --repo tkersey/pragma)"
git checkout <commit>
brew reinstall --HEAD tkersey/pragma/pragma
```

## Scorecard Generation

```bash
# Convert a JSONL log produced by `codex exec --json` into a rubric-ready stub
zig build scorecard -- evaluations/runs/run-2025-10-15-1.jsonl run-2025-10-15-1
```

Pass `-` instead of a file path to read JSONL from stdin. The second argument is optional and shows up as the run identifier in the output.

When `zig` is unavailable you can still inspect `src/main.zig` to understand the prompt assembly pipeline and integrate similar logic elsewhere.
