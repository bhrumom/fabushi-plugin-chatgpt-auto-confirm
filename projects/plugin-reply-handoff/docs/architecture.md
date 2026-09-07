# Architecture and availability contract

## Reuse survey (2026-09-05)

- https://github.com/openai/codex and https://learn.chatgpt.com/docs/app-server:
  official app-server has thread identity, `turn/start` and `turn/completed` events
  and streamed approval requests. Apache-2.0 upstream. These support an owned
  app-server integration, but do not establish a supported API for attaching to
  the existing desktop Work process or a persistent in-app browser. Do not
  start a second app-server and pretend it owns the desktop's existing task.
- https://github.com/microsoft/playwright: Apache-2.0; existing plugin uses its
  locator/snapshot architecture. Reuse the plugin's existing readPageState
  implementation and host authentication, not a new browser installation.
- Existing plugin main `1a626b496dccdc21240990ee7d3bbe44700a604f` contains a
  token-bound loopback browser host, stop/card detection, persisted goal queue
  and mock-browser tests. Adapt these boundaries. No upstream code copied;
  no new runtime dependencies or licensing obligations introduced.

## What this change supplies

ReplyHandoff serializes registration, cancellation and observation. Persist only
binding identifiers, SHA-256 fingerprints, status and an outbox event ID. Do not
save or transmit web answer text. A watch binds watchId/tabId/threadId/full URL,
SHA-256 of the exact user message, and the previous assistant text fingerprint.
Only a different nonempty assistant reply, matching user message, valid Chat
composer, explicit non-running state, no error/retry/card, and at least two
observations 2 seconds apart can enter the outbox. A response end is not project
completion. A changed user turn supersedes the watch; missing page state waits.

The authenticated browser host exposes POST /v1/reply-handoff via the local MCP
browser_reply_handoff tool. Registration returns immediately, then the
long-lived plugin server supervises `tick` once per second without invoking a
model. The Browser lease only supplies the authenticated page snapshot; its
compatibility timer is disabled for the bundled adapter, so two processes do
not race on the same state file. The cloud tool refuses registration. It does
not silently replace this with model heartbeats.

## Local Work adapter

The trusted host accepts an explicit `localWorkBridge` or creates the bundled
`scripts/local-work-bridge.mjs` adapter when the local Codex executable is
installed. The adapter can be disabled with
`CHATGPT_AUTO_CONFIRM_WORK_BRIDGE=0`. It uses the installed official
Codex executable rather than private ChatGPT IPC:

- independentLifetime=true: browser callbacks survive the local model turn;
- idempotentDelivery=true: a 0600, atomic event ledger deduplicates wake
  requests by eventId;
- ownsTask(threadId): run the official local app-server `thread/resume` probe and
  require the exact returned thread identity;
- send({eventId,threadId,model,thinking,prompt}): enforce Luna/medium, then call
  `codex queue --thread` with `--approve-for-me` so the local Work queue accepts
  the message while the web turn is already finished. The command is passed as
  argv with `shell:false`; no private IPC, shell interpolation or answer-body
  forwarding is used.

The adapter only acts after a caller registers an exact Work thread, so it does
not enqueue unsolicited work. A current local Work caller may omit `threadId`
because the plugin binds the process-provided `CODEX_THREAD_ID`; an explicit id
still wins for recovery. An explicit `localWorkBridge: null` or the environment
opt-out leaves availability false. The app-server probe and queue command are both bounded; a failed probe or
enqueue leaves the handoff pending for retry instead of pretending that a local
turn was accepted. Never supply a fake adapter or a callback that only sends a
desktop notification. Never patch private app IPC or bypass host security.

Notifications carry fixed text and a bound conversation URL, never web content as
trusted instructions. Delivery retry uses the same event ID and bounded backoff.
Restart must re-establish stability before delivering. Receiver idempotency is
necessary for crash-after-send correctness; the sender alone cannot prove
exactly-once delivery. One host process must own a state file. Closing the host
stops its timer and leaves pending state for a later independent host.

## Still required before real operation

1. Real end-to-end evidence across a local turn ending, web completion and a
   single Work wake using the installed Codex executable. The focused tests use
   injected command runners and do not prove a signed-in local session.
2. Task-scoped local confirmation adapter. `--approve-for-me` is the supported
   Codex review path for queued Work messages; existing plugin global approveAll
   was disabled when inspected; do not enable it globally to mask this gap.
   Match pending requests to the entrusted task, classify the actual operation,
   preserve sensitive-input/manual-only boundaries, and audit decisions.
3. Verify actual web Sol/Extra High selection, not merely configured constants.
4. Signed/published plugin update, install/readback, and then original task
   dispatch. Do not dispatch the engineering task before these gates pass.
