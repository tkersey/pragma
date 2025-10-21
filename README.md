# pragma

`pragma` is a lightweight Zig CLI that wraps `codex exec` so coding agents can run sub-agents without a larger toolchain. Feed it either a one-off system prompt or the name of a reusable directive file and it handles the rest:

- Frames the call with a minimal sub-agent persona and reminds the model to ask for extra context when needed.
- Invokes `codex exec --skip-git-repo-check --json -c 'mcp_servers={}'` (make sure `codex` is on your `$PATH`).
- Streams the JSONL output, capturing the final `agent_message` item and emitting its markdown back to stdout.
- Optionally loads Anthropic-style directive files (`---` YAML frontmatter + Markdown body) from `.pragma/directives/`, `directives/`, or a path you specify via CLI/env.

## Build

```bash
# Requires Zig 0.16.0-dev.747+493ad58ff (install via zigup: brew install zigup && zigup 0.16.0-dev.747+493ad58ff)
zig build
```

## Run

```bash
# Single-turn invocation with a system prompt
zig build run -- "Act as a focused CSS sub-agent. Return a markdown checklist."

# Reuse a stored directive and append task-specific context
zig build run -- --directive review -- "Concentrate on the latest database migration."

# Validate stored directives (skips names starting with "codex")
zig build run -- --validate-directives

# Keep run artifacts even if no spill files were needed
zig build run -- --keep-run-artifacts --directive review -- "Capture the full codex transcript."

# Execute a multi-step manifest
zig build run -- --manifest plans/release.json
```

If the sub-agent needs environment or repository details, include them in the system prompt you pass to `pragma` (or instruct the agent to request them explicitly). When running by directive, any extra CLI text (after `--`) is appended after a blank line inside the directive body.

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

### Directives

Pragma understands the same directive structure Anthropic ships for Claude Code subagents: a Markdown file whose YAML frontmatter carries metadata.

```markdown
---
name: review
description: Structured code review with actionable diffs.
output_contract: json
---
You are a code reviewer...
```

Place directive files in one of the following locations (first match wins):

1. The path passed to `--directives-dir`.
2. `$PRAGMA_DIRECTIVES_DIR`.
3. `~/.pragma/directives/`.
4. `.pragma/directives/` relative to the working directory.
5. `directives/` relative to the working directory.

You can also provide an absolute or relative file path directly via `--directive`, e.g. `--directive ./my/agents/security.md`.

Frontmatter currently recognizes `output_contract`. Set it to `markdown`, `json`, or `plain`, or supply a multi-line block scalar to define a custom contract. Inline `pragma-output-format:` / `pragma-output-contract` markers embedded in the directive body continue to work and take precedence if present.

### Manifests

Pragma orchestrates multi-step workflows from a JSON manifest. Each manifest defines an optional `core_prompt`, an optional default `directive`, and a `steps` array. Steps run serially by default; set `"parallel": true` on a step to fan out the nested `"tasks"` concurrently.

```json
{
  "directive": "review",
  "core_prompt": "Shared context for every task.",
  "steps": [
    {
      "name": "Serial Review",
      "prompt": "Focus on the latest changes."
    },
    {
      "name": "Parallel Checks",
      "parallel": true,
      "tasks": [
        { "name": "Check A", "prompt": "Look for syntax issues." },
        { "name": "Check B", "prompt": "Inspect documentation." }
      ]
    }
  ]
}
```

Each step or task may override the `directive` and supply additional prompt text. On POSIX platforms, parallel groups launch dedicated `codex` subprocesses and stream results via `std.Io.poll`. Windows currently falls back to a thread-per-task model while the async I/O implementation catches up.

### Run Artifacts

Pragma watches the raw Codex streams and automatically offloads large payloads to disk:

- stdout above 64 KiB or stderr above 16 KiB is saved under `~/.pragma/runs/<timestamp>/`, and the CLI prints a notice pointing to the exact file.
- The in-terminal view stays concise: stderr previews are capped at 4 KiB, and stdout continues to show only the final agent message.
- Override the thresholds with `PRAGMA_SPILL_STDOUT` and `PRAGMA_SPILL_STDERR` (byte counts). Adjust history pruning with `PRAGMA_RUN_HISTORY` (defaults to the 20 most recent runs).
- Use `--keep-run-artifacts` or `PRAGMA_KEEP_RUN=1` to retain logs even when nothing overflowed, e.g. for hand-off to another tool.
- All numeric environment knobs must now be unsigned integers; invalid values trigger an immediate error instead of silently falling back to defaults.
- Limit concurrent Codex processes by setting `PRAGMA_PARALLEL_LIMIT` (defaults to the detected CPU count, with a minimum of 4). Values less than 1 are rejected.

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
