---
name: actions-first-task-queue
description: "Run long-lived coding, release, deployment, or plugin-marketplace tasks through the Chat task queue. Build and test where the queue is running: local queues use the local checkout and local toolchain; GitHub Actions queues build and test only inside Actions. Use when work must recover from blockers, wait for external jobs, or continue automatically in a new Chat."
---

# Continuous Task Queue

Use `chatgpt-auto-confirm` as the controller. Work only in queue-owned **Chat** conversations, never Work. GitHub repository state is authoritative. An unchanged task continues from its persisted repository progress; an updated goal starts a fresh Chat with the updated repository project definition.

## What every round must do

Before the first, continuation, or review message is sent, select and verify GPT-5.6 Sol with Extra High reasoning. Repeat the GitHub repository and repository-relative code directory in every message. When task documents are configured, also repeat their repository-relative directory. Require use of the GitHub connector to read and modify that repository. A round may not end after only reading, inspecting, planning, emailing, or summarizing. Unless it is waiting for an already-started external operation or a genuine human blocker, it must make a verifiable code change and run the relevant test before ending.

At the start of every round:

1. Open the configured GitHub repository and locate the project by stable task id and configured project/document directory.
2. If the matching project is missing, create a dedicated repository project directory and add goal/scope, architecture, executable task, acceptance, and evidence documents. Register those files in the repository task control entry before implementation.
3. Re-read this skill and every current project file. Files may have changed since the previous Chat.
4. Inspect the existing implementation, persisted changes, branch state, and any operation still running.
5. Continue the remaining implementation. Do not restart, merely review results, rewrite plans, or stop after saying what should happen next.
6. Keep working until all project files, acceptance checks, tests, releases, and required evidence are complete.

The first Chat must receive the complete current goal, revision/digest, this skill path, GitHub repository, project directory, and code directory. If the project directory is absent, the first Chat creates it and registers its documents. From the second unfinished round onward, the controller repeats the same repository-backed objective in a fresh Chat and requires inspection of persisted repository progress before continuing.

The miniapp, not Chat, detects task updates. Before every dispatch it reads `tasks/actions-inbox.json` and all declared `specSources`, if any, then compares the current prompt and SHA-256 digest with the applied round. `specSources` may contain any number of files, including zero. Chat reads configured files to do the work, but it never decides whether a revision changed.

## Build and test where the controller runs

- When the queue controller and target checkout are running locally, run the required tests, builds, packaging, install checks, and runtime replacement locally. Do not send a local build to GitHub Actions merely because a workflow exists.
- When the queue controller is running inside GitHub Actions, keep project tests, builds, packaging, install checks, artifacts, and deployment verification inside that Actions run. Do not move them onto a user's machine.
- Use GitHub Actions as the source of truth for releases, deployments, protected-branch checks, cloud credentials, or acceptance evidence that inherently belongs to GitHub, regardless of where the controller runs.
- Detect execution location from the actual runtime (`GITHUB_ACTIONS=true` for Actions), not from the task's repository hosting or connector name.
- Add or repair workflow configuration only when cloud validation is genuinely required or the controller is already running in Actions.

## Route connectors and recover connectivity

- Use the GitHub connector for all cloud repository, pull-request, Actions, artifact, release, and merge evidence after code has reached GitHub.
- Use bhrum2 for the local checkout. Before synchronizing it, inspect the worktree, remote, and branch; fetch first and fast-forward only a clean checkout. Never overwrite local changes to force synchronization.
- If a local bhrum2 step pushes code, return `next_connector: "GitHub"` so the next fresh Chat checks cloud state through the GitHub connector. Return `next_connector: "bhrum2"` only when the next step genuinely needs local checkout work.
- Treat DNS failures, disconnects, connection resets, 429/502/503/504, and connector timeouts as recoverable. Do not loop the same request. Use the one-line wait directive; the queue probes connectivity and starts a fresh Chat when it is available.

## Keep commits small and intentional

Before staging, inspect the changed-file list. Stage named source files, workflow files, configuration, and required documentation only.

Never use blanket staging. Exclude caches, dependency folders, generated build output, local installers, unrelated media, and unrelated LFS objects. Do not wait for a large upload unless the asset is explicitly required by the release goal. Preserve user files rather than deleting them to make a commit clean.

## Completion, waiting, and blockers

Do not repeat the same failed command or connector path. Diagnose the cause first, then try an appropriate alternative such as local `gh`/`git`, a different authenticated connector, a corrected environment path, or a workflow change.

Do not stop merely because an operation is slow. Poll Actions, deployments, releases, and remote checks inside the same Chat whenever possible. Do not stop while useful work can continue.

There is exactly one report envelope, and it is a completion certificate. Emit it only when the entire repository project, all acceptance checks, required tests, releases, and evidence are complete. The queue stops only when `status=complete` and `all_tasks_complete=true`, with empty `remaining` and `blockers`.

```text
MAHAYANA_TASK_REPORT_V1_BEGIN
{"protocol":"mahayana.task-report.v1","task_id":"current task id","applied_task_revision":1,"applied_spec_digest":"current spec digest","status":"complete","all_tasks_complete":true,"summary":"entire project completed","completed":["completed project and release evidence"],"remaining":[],"blockers":[],"verification":["verifiable acceptance evidence"],"wait_seconds":0,"wait_reason":"","next_connector":"","next_task":""}
MAHAYANA_TASK_REPORT_V1_END
```

If the Chat is unfinished, waiting, blocked, ends early, or omits a valid completion certificate, emit no report template. The miniapp must preserve the repository state and send the same goal to a fresh Chat. There is no separate incomplete, blocked, waiting, next-step, Gmail, project-email, countdown, or legacy timed-task protocol in the prompt.

## Recover safely

Treat a Chat that shows no assistant or tool activity shortly after a verified send as a renderer failure, not as a long-running build. Restart only the queue-owned hidden ChatGPT process and continue from the persisted checkout in a new Chat.

Treat visible GitHub Actions or deployment progress as active work. Do not declare completion merely because a Chat stopped. A fast unfinished reply is backed off before another branch is sent so the queue cannot spin or trigger rate limits.

## Miniapp-owned task update detection

The task id is stable and the task definition is versioned state. Define `revision` and an optional `directive` in `tasks/actions-inbox.json`. `specSources` is optional and may be omitted or empty; there is no minimum or required filename. Before each round, the miniapp reads the inbox and every referenced file, if any, and computes a SHA-256 specification digest.

- Increment `revision` whenever possible. If file content or the goal changes without a revision bump, the miniapp still creates an internal next revision from the changed digest.
- Use `applyMode: "next_chat"` by default; the current Chat may finish its turn, but its result cannot complete the task after a newer revision exists.
- Use `applyMode: "interrupt"` only for urgent safety or architecture corrections. The queue stops only its hidden task-owned response, preserves the checkout, and immediately creates a fresh Chat on the new revision.
- Current prompts, directives, specification digests, sources, and the last 100 updates are versioned in queue state.
- An unchanged second-or-later round stays on its branch and receives only the short continuation instruction.
- A changed prompt or digest clears the old branch identity. The next Chat is a true first round containing the complete updated goal and configured task locations, if any. It must not create an email unless human intervention is required.
- Reports based on an older revision or digest are automatically superseded and cannot complete the updated task.
- Do not cancel and recreate the long-running workflow merely to update task requirements.
