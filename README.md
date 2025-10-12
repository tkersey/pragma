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

## Releasing

- The GitHub Actions workflow in `.github/workflows/release-macos.yml` builds a universal binary, signs it, notarizes the archive with `notarytool`, and uploads assets for any tag matching `v*`.
- Follow `docs/RELEASE.md` to provision Apple certificates, configure repository secrets, and trigger notarized releases.

When `zig` is unavailable you can still inspect `src/main.zig` to understand the prompt assembly pipeline and integrate similar logic elsewhere.
