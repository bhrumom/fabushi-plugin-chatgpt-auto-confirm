---
name: recover-actions-chatgpt-renderer
description: Diagnose and repair GitHub Actions ChatGPT auto-confirm failures where an avatar-overlay or blank renderer, stale CDP connection, native local-network dialog, or authorization card prevents an authenticated Chat or parallel queue from starting. Use when the runner must be safely repaired, verified, merged, and resumed without weakening login checks.
---

# Recover Actions ChatGPT Renderer

Use this skill for the `chatgpt-auto-confirm` miniapp when an Actions run starts
ChatGPT but remains on a blank page, reports a dead renderer, retries with a
timeout, or leaves a ChatGPT authorization card waiting. It turns the failure
into evidence, repairs renderer ownership/lifecycle, and proves the fix on
`main` before starting the persistent queue.

## Safety boundaries

- Keep authentication strict. The native `verify_chatgpt_login` check remains a
  required success condition; an explicit login prompt is `needs_login`, not a
  reason to bypass verification.
- A headless Actions runner does not require every renderer to be hidden. A
  visible headless window is valid when it is a live Chat surface. Do not turn
  “hidden” into an authentication requirement.
- Never print or copy cookies, Codex auth, tokens, full page text, screenshots
  containing secrets, or task prompts. Use redacted booleans, labels, target ids,
  route classes, and text lengths only. Credential refresh belongs to
  `sync-action-credentials`.
- For project tests, builds, packaging, installation, and artifact validation,
  use GitHub Actions. Locally limit work to reading code, the skill validator,
  Git, and `gh` metadata.
- Start from a clean branch based on the latest `origin/main`; preserve
  unrelated changes and do not change queue business logic while fixing
  renderer lifecycle.

## Diagnose before changing code

1. Inspect the failed run and its artifacts. Prefer
   `parallel-queue-evidence.json`, `action-result.json`, and
   `task-queue/watcher-trace.log`; compare the failing renderer target with the
   renderer inventory after launch/navigation. Download artifacts with `gh`,
   but do not expose their sensitive contents.
2. Separate the two permission surfaces:
   - An in-page ChatGPT card has expected labels such as `deny` and `allow
     once`. Handle it only when the scan reports a candidate; success requires
     `clicked=true` and `confirmed=true` in the redacted trace.
   - A native macOS “find devices on local networks” dialog is an OS permission
     prompt. Use the existing accessibility approval helper and record only that
     it was found/approved. Do not kill the app, disable the OS policy, or
     confuse this dialog with ChatGPT's card.
3. Treat an explicit login page or login prompt as a real authentication
   failure. Stop with `needs_login` and use the existing credential-sync flow;
   never accept a blank page as proof of login.
4. Classify the renderer failure:
   - `avatar-overlay`, a stale WebSocket, or a target that changes after
     navigation means the old CDP connection is invalid.
   - `window.open` returning `false` means the app rejected the popup; repeated
     popup attempts are not recovery.
   - A CDP `Target.createTarget` page with `bridge=false`, no meaningful text,
     or an empty non-app document is not a usable Chat surface.

## Repair the renderer lifecycle

1. After every `Page.navigate`, reload, or renderer disconnect, fetch a fresh
   renderer list and select a new WebSocket. Close/forget the old overlay
   connection; never send CDP commands through it after navigation.
2. Prefer an already authenticated app renderer in the same ChatGPT process.
   Probe each candidate for app-root route, `bridge=true`, document readiness,
   visibility/runtime state, meaningful text, and absence of a login prompt.
   Prefer a normal primary renderer over a prewarm/controller renderer, but
   allow a visible headless renderer.
3. Allocate targets exclusively. Exclude the controller and every target
   already recorded in queue task ownership; task A and task B must not share a
   renderer or conversation. Persist the selected target in queue state before
   sending work.
4. Keep the recovery entry point internally injectable for fetch, WebSocket,
   and timer dependencies so renderer switching and bounded retries can be
   tested without external services. Keep the command-line invocation
   unchanged.
5. Retry only within a bounded deadline. Emit redacted diagnostics for target
   id, route class, bridge/readiness, runtime visibility, text length, selected
   target, timeout stage, and final page state. On exhaustion, fail clearly
   instead of looping.

## Preserve and verify authorization

Scan only known ChatGPT approval controls. When `allow once` is detected, click
that card and then verify the card's confirmed state; a click event alone is not
success. Do not click arbitrary buttons on a page whose surface or
authentication state is uncertain.

The final hidden-Chat verification remains the native login/Chat-surface check.
A successful renderer probe is a prerequisite, not a replacement for
authentication. Keep the existing rejection of real login pages and the
existing credential-sync path.

## Verify remotely and resume safely

1. Create a focused branch from current `origin/main`, edit only the miniapp
   skill/manifest/tests, commit named files, push, open a PR, and wait for the
   merge queue. Do not validate against a stale feature branch.
2. Require the plugin contract, bundled runtime, and macOS runtime checks to
   pass in Actions. Run the real smoke from `main` with
   `parallel_queue_smoke=true` and restored credentials. Use the repository's
   workflow inputs rather than inventing a web-login path.
3. Accept parallel smoke only when the evidence says `status=passed`, requested
   and effective concurrency are at least 2, task B was enqueued after task A
   started, both were observed running together, and each has a distinct
   non-empty `conversationId` and renderer `targetId`. Every worker must report
   `visibilityVerified=true` and a live Chat surface; the runtime state may be
   `visible` or `hidden-chat`.
4. Do not require a legacy execution-mode string. Read the mode emitted by the
   current runtime (currently `parallel-chat-windows`) and reject only an
   unknown/non-Chat mode. Inspect the trace for
   `headless-existing-window-probe`, `headless-existing-window-ready`, and
   `headless-parallel-existing-window-complete`; a
   `headless_window_target_not_ready` failure requires another diagnosis pass.
5. After smoke passes, start the normal run with
   `parallel_queue_smoke=false`. Confirm the job passed credential restoration
   and login verification and that `Run dynamic persistent task queue` is
   actually `in_progress`. Do not claim task processing merely because the
   workflow was dispatched.

See [references/renderer-diagnostics.md](references/renderer-diagnostics.md) for
the evidence schema, failure signatures, and the bounded retry matrix.

## Completion report

When this skill is used through the task queue, finish with the queue's
structured `MAHAYANA_TASK_REPORT_V1` report. Include the merged commit, smoke
run, persistent run step, and any remaining external work; never put
credentials or full diagnostics in the report.
