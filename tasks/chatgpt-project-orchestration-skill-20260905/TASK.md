# ChatGPT project orchestration skill task

- **Task ID:** `chatgpt-project-orchestration-skill-20260905`
- **Origin trace:** user request; Fabushi mirror `FAB-P0005 / MSR-403` was identified as the wrong repository and will be reverted; canonical implementation is this standalone plugin repository
- **Status:** in-progress
- **Started:** 2026-09-05
- **Branch:** `codex/chatgpt-project-orchestration-skill`
- **Commits:** `31f130a` initial implementation; `4d95bf6` review fixes; `ca1b356` exact-head workflow scope fix
- **PR:** [#1](https://github.com/bhrumom/fabushi-plugin-chatgpt-auto-confirm/pull/1)

## Objective

Add a reusable skill to this standalone `fabushi-plugin-chatgpt-auto-confirm`
repository for the user's architecture → atomic execution → code review →
test/release → formal release workflow.

## Acceptance

1. The skill is discoverable through `.codex-plugin/plugin.json`'s `skills: ./skills`
   entry and has valid `SKILL.md` frontmatter plus `agents/openai.yaml` metadata.
2. It defines five project groups, one browser tab per group, same-tab fresh Chat
   isolation/context rollover, Chat mode, GPT-5.6 Sol/Extra High, and the
   stop-answering control gate.
3. It requires durable task records, exact-head review, protected-main packaged
   E2E evidence, complete operation video, video review, and traceable formal
   release before completion.
4. The focused contract test and the standalone plugin PR-validation workflow
   pass for the exact PR head, then the protected PR is merged to `main`.

## Open-source-first decision

Reviewed the user-provided `xai-org/grok-build` (`main` @
`72a61251fcffb464bcc687aeb5a998e5a98ec0c9`, Apache-2.0), `openai/codex`
(`main` @ `459a79eb85400af759e9220c7bafb4429ae07516`, Apache-2.0), and
`bhrum/grok-bot-0.18-reconstructed` (`main` @
`107877b4e2134fd167d239411386f09e42eadd6d`) as capability references. The
skill borrows no source code and keeps the orchestration contract plugin-owned;
the unofficial/low-activity reconstruction is not a dependency. Full findings
are in [ARCHITECTURE.md](ARCHITECTURE.md).

## Verification and evidence

- Local lightweight: skill validator, focused contract test (10/10), and
  `git diff --check`.
- Remote: full-runtime diagnostic run `33945901577` built content and the macOS runtime successfully,
  then exposed 9 pre-existing full-runtime test failures unrelated to this Skill. The
  validation workflow is now narrowed to content generation plus the focused Skill contract
  test for exact PR heads at current head `ca1b356`; protected merge and canonical `main`
  readback remain pending.
- No local application build, packaging, device, or E2E run is permitted.

## Implementation summary

Added the discoverable `chatgpt-project-orchestration` Skill, its detailed protocol
reference, metadata, architecture output, 16-task DAG, independent A00-A15 records,
and contract-test coverage.
The contract test also corrected two stale repository-local assertions: the native
task-inbox path belongs to `native/QueueState.swift`, and empty prompt prefixes are
an array contract rather than a newline-joined string. No application build was run.

## Review feedback applied

- Save only a redacted canonical requirement snapshot.
- Bind review approval to repository, PR, head SHA, base SHA, task ID, and spec digest.
- Add independent A00-A15 task records and correct the A09/A15 dependency waves.
- Make the Stop Answering retry prohibition explicit and expand contract coverage.
- Add exact-PR-head Skill contract validation in `.github/workflows/pull-request-validation.yml`;
  the full runtime test failures are recorded as a separate baseline issue rather than hidden.

## Next action

Push the review fixes and exact-head workflow scope, wait for exact-head Actions, obtain a fresh code-review verdict,
then use the protected merge queue and read back canonical `main`.
