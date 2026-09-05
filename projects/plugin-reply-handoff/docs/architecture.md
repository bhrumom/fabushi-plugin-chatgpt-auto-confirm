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
browser_reply_handoff tool. A host timer checks once per second without invoking
a model. It returns a registration receipt immediately. The cloud tool refuses
registration. It does not silently replace this with model heartbeats.

## Required external adapter — currently unavailable

The trusted host must supply localWorkBridge with:

- independentLifetime=true: browser callbacks survive the local model turn;
- idempotentDelivery=true: durably deduplicate wake requests by eventId;
- ownsTask(threadId): verify this user-authorized local Work binding;
- send({eventId,threadId,model,thinking,prompt}): enqueue a local Work message,
  enforce Luna/medium and acknowledge {accepted:true,eventId} after durable
  acceptance. Queue safely while the task is busy; do not duplicate turns.

This declaration is an integration contract, not proof that a host exists.
Current CUA only exposes per-turn browser operations; the plugin's older
Playwright host requires a live execution lease. Neither provides this adapter.
Default availability is false. Never supply a fake adapter or a callback that
only sends a desktop notification. Never patch private app IPC or bypass host
security. The user has not been told this is deployed or zero-token hosting.

Notifications carry fixed text and a bound conversation URL, never web content as
trusted instructions. Delivery retry uses the same event ID and bounded backoff.
Restart must re-establish stability before delivering. Receiver idempotency is
necessary for crash-after-send correctness; the sender alone cannot prove
exactly-once delivery. One host process must own a state file. Closing the host
stops its timer and leaves pending state for a later independent host.

## Still required before real operation

1. Supported independent browser + desktop Work adapter and real end-to-end
   evidence across a local turn ending, web completion and a single Work wake.
2. Task-scoped local confirmation adapter. Existing plugin global approveAll
   was disabled when inspected; do not enable it globally to mask this gap.
   Match pending requests to the entrusted task, classify the actual operation,
   preserve sensitive-input/manual-only boundaries, and audit decisions.
3. Verify actual web Sol/Extra High selection, not merely configured constants.
4. Signed/published plugin update, install/readback, and then original task
   dispatch. Do not dispatch the engineering task before these gates pass.
