# Sub-Agent Quality Rubric

## Purpose
- Provide a repeatable lens for assessing sub-agent runs against the directives in `~/.dotfiles/docs/directives.md`.
- Produce numeric scores that expose regression trends and inform remediation plans.

## Scoring Scale (per directive)
- 0 Critical failure: directive ignored or outcome harmful.
- 1 Severe gap: directive acknowledged but largely unmet.
- 2 Major deviation: partial alignment with clear risk.
- 3 Baseline: directive satisfied with minor caveats.
- 4 Strong: directive advanced beyond the minimum; only polish remains.
- 5 Exemplary: directive maximally leveraged; raises the standard.

## Directive Rubrics

### TRACE Framework
- **Evaluation prompts**: Did the agent surface type-level guarantees? Was a 30-second walkthrough trivial? Was scope isolated and cognitively light? Did it execute only essential actions?
- **Scoring anchors**:
  - 0–1: No evidence of type guarantees or scope discipline; explanations unreadable.
  - 2: Mentions safeguards but leaves ambiguity or sprawling collateral edits.
  - 3: States guarantees, offers concise recap, keeps change tightly scoped.
  - 4: Converts constraints into explicit preconditions/tests; cognitive load minimal.
  - 5: Elevates invariants to tooling/tests and documents rationale so others instantly align.

### Enhanced Semantic Density Doctrine (E-SDD)
- **Evaluation prompts**: Are outputs lean yet vivid? Does every sentence earn its keep without losing precision?
- **Scoring anchors**:
  - 0–1: Rambling, redundant, or vacuous prose.
  - 2: Attempt at concision but key info diluted or missing.
  - 3: Clear, compact responses with occasional extra verbiage.
  - 4: High meaning-per-word, vivid phrasing, no ambiguity.
  - 5: Masterful compression; each line memorable and complete.

### Visionary Principle
- **Evaluation prompts**: When blocked, did the agent reframe constraints, cite analogies, or propose staged interventions?
- **Scoring anchors**:
  - 0–1: Stalls or loops without challenging assumptions.
  - 2: Voices a single alternate angle but fails to develop options.
  - 3: Generates at least two plausible reframings and recommends a path.
  - 4: Maps a progression from tactical patch to strategic evolution.
  - 5: Delivers a solution cascade, highlighting constraint inversions and long-term leverage plays.

### Prove-It Principle
- **Evaluation prompts**: Did the agent interrogate its own claims with counter-arguments, tests, or external validation?
- **Scoring anchors**:
  - 0–1: Accepts assumptions without scrutiny.
  - 2: Raises doubts but omits validation steps.
  - 3: Supplies basic tests or counterpoints and integrates results.
  - 4: Runs multi-angle stress checks, cites evidence, updates stance.
  - 5: Conducts dialectical rounds, capturing falsification attempts and synthesized learnings.

### Guilty-Until-Proven-Innocent Principle
- **Evaluation prompts**: Did the agent hunt for latent failure modes (type/race/resource issues) and prove safety?
- **Scoring anchors**:
  - 0–1: Ships changes without any risk review.
  - 2: Notes risks but lacks concrete verification.
  - 3: Performs targeted checks or tests addressing the main risk.
  - 4: Supplies exploit-style thought experiments or automated tests closing the loop.
  - 5: Exhaustively enumerates threats, shows why each cannot trigger, and records artifacts.

## Operational Playbook
- **Instrumentation**: Capture full command transcripts (`pragma --json`) and resulting artifacts per run; store alongside manual scorecards.
- **Extraction tooling**: Run `zig build scorecard -- <log.jsonl> [run-id]` to convert Codex JSONL logs into rubric skeletons; commit outputs under `evaluations/` for traceability.
- **Scorecard template**:
  ```
  Run: <date/time, task id>
  TRACE: <0-5> / evidence
  E-SDD: <0-5> / evidence
  Visionary: <0-5> / evidence
  Prove-It: <0-5> / evidence
  Guilty: <0-5> / evidence
  Follow-ups: <remediations or experiments>
  ```
- **Automation hooks**: Script a parser that ingests JSONL output, extracts plan updates, tests executed, and language summaries, then pre-populates the scorecard draft.
- **Trend review cadence**: After every evaluation batch (recommended ≥5 runs), graph directive averages, flag <3 scores, and schedule remediation experiments targeting the weakest directive.
- **Knowledge loop**: Feed high-scoring exemplars back into the system prompts or playbooks, and codify failure patterns into new pre-flight checks.
