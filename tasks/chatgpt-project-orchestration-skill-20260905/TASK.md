# ChatGPT project orchestration skill task

- **Task ID:** `chatgpt-project-orchestration-skill-20260905`
- **Origin trace:** user request; Fabushi mirror `FAB-P0005 / MSR-403` was identified as the wrong repository and will be reverted; canonical implementation is this standalone plugin repository
- **Status:** in-progress
- **Started:** 2026-09-05
- **Branch:** `codex/chatgpt-project-orchestration-skill`
- **Commit:** `31f130a` initial implementation; review-fix commit is the current PR head
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
4. The focused contract test and the standalone plugin GitHub Actions workflow
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
- Remote: PR validation workflow added for the exact PR head; plugin runtime Actions
  build/test/evidence upload, protected merge, and canonical `main` readback remain pending.
- No local application build, packaging, device, or E2E run is permitted.

## Implementation summary

Added the discoverable `chatgpt-project-orchestration` Skill, its detailed protocol
reference, metadata, architecture output, 16-task DAG, and contract-test coverage.
The contract test also corrected two stale repository-local assertions: the native
task-inbox path belongs to `native/QueueState.swift`, and empty prompt prefixes are
an array contract rather than a newline-joined string. No application build was run.

## Review feedback applied

- Save only a redacted canonical requirement snapshot.
- Bind review approval to repository, PR, head SHA, base SHA, task ID, and spec digest.
- Add independent A00-A15 task records and correct the A09/A15 dependency waves.
- Make the Stop Answering retry prohibition explicit and expand contract coverage.
- Add exact-PR-head macOS runtime/contract validation in `.github/workflows/pull-request-validation.yml`.

## Next action

Push the review fixes, wait for exact-head Actions, obtain a fresh code-review verdict,
then use the protected merge queue and read back canonical `main`.
