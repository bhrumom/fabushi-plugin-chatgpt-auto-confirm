# Renderer diagnostics reference

Use this reference after reading the main skill. It keeps the operational details
out of the always-loaded instructions while preserving the evidence that made
the renderer fix reliable.

## Redacted evidence fields

Safe fields to retain in a trace or report:

| Field | Meaning | Safe representation |
| --- | --- | --- |
| `targetId` | CDP target ownership | full id is acceptable in a short-lived Action artifact; do not pair it with cookies or page text |
| `bridge` | preload/electron bridge is available | boolean |
| `ready` | document lifecycle | `loading`, `interactive`, or `complete` |
| `visibility` / `runtimeState` | renderer presentation | `visible`, `hidden`, `hidden-chat`, or `missing` |
| `text` | page content probe | character count, never the full text |
| `candidateLabels` | approval-card detection | normalized labels such as `allow once` |
| `clicked` / `confirmed` | approval result | boolean |
| `conversationId` | task isolation | compare distinctness; avoid exposing unrelated prompt content |

Never include cookie values, auth headers, page HTML, full screenshots, local
profile paths, or the body of a user's task in diagnostics.

## Expected successful trace

The exact target ids vary. A successful repair has the following shape:

```text
controller-discovery complete target=<controller> probes=1
headless-existing-window-probe target=<primary> visibility=visible bridge=true ready=complete text=<positive>
headless-existing-window-ready target=<primary> visibility=visible
headless-parallel-existing-window-complete target=<primary>
task=actions-parallel-a ... conversation=<a>
headless-existing-window-probe target=<second> visibility=hidden bridge=true ready=complete text=<positive>
headless-existing-window-ready target=<second> visibility=hidden-chat
headless-parallel-existing-window-complete target=<second>
task=actions-parallel-b ... conversation=<b>
approval-before-read-detected ... candidateLabels=["allow once"]
approval-before-read ... clicked=true confirmed=true label=allow once
```

The primary renderer may be visible on a headless runner. The acceptance rule is
that both targets are live Chat surfaces and are distinct, not that both are
hidden.

## Failure signatures and next action

| Signature | Interpretation | Next action |
| --- | --- | --- |
| `avatar-overlay` or old WebSocket timeout after navigation | stale CDP binding | refresh target inventory and reconnect to the new app renderer |
| `window.open ... opened=false` | ChatGPT rejected popup creation | stop retrying popups; reuse an existing authenticated renderer |
| `Target.createTarget` with `bridge=false` or `text=0` | bare page without app preload | reject it and continue bounded candidate scan |
| `not_chat_surface` | candidate is a shell, prewarm page, or unrelated route | try the next unowned app renderer |
| `candidateLabels=[]` | no approval card present | do not click; continue surface/authentication checks |
| `clicked=true confirmed=false` | click was not accepted | capture redacted state, retry the bounded approval scan, then fail if confirmation never appears |
| explicit login prompt / `needs_login` | credentials are not valid for this process | stop and run credential synchronization; do not weaken verification |
| `headless_window_target_not_ready` after bounded retries | no usable main renderer appeared | fail with the redacted inventory and final page state; do not start the task queue |

## Action sequence

```text
PR checks -> merge queue -> verify main
  -> parallel_queue_smoke=true
  -> inspect parallel-queue-evidence.json and watcher-trace.log
  -> parallel smoke passed
  -> parallel_queue_smoke=false
  -> verify "Run dynamic persistent task queue" is in_progress
```

The smoke artifact must show two overlapping tasks, distinct conversations and
targets, effective concurrency 2, and `visibilityVerified=true` for both. The
persistent run is the final operational handoff; a dispatched or queued workflow
alone is not proof that tasks are being processed.
