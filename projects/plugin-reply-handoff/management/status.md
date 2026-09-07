# Status / changelog

2026-09-05: requirement reconstructed from the user's attachment and current
standalone plugin main. Existing browser host still needs an active execution
lease; installed native approval watcher reports disabled. Added the reply event
lifecycle, explicit missing-host rejection, fixed English “Stop answering”
detection, and a bundled local Work adapter backed by the supported Codex queue
and app-server ownership probe. Real hosting, automatic confirmation, publication
and original task dispatch remain incomplete. Existing plugin PR #1 is preserved.

2026-09-05 local-validation follow-up: user explicitly authorized local verification. 48 focused tests passed; initial remote CI also passed (43 tests before added HTTP readiness test). Actual host descriptor is absent. Added bounded callback timeouts and rollback on failed registration persistence, plus automatic binding to the current `CODEX_THREAD_ID` when a local Work caller omits its own id. Feature remains in progress pending a signed-in host E2E and protected-main delivery.

2026-09-05 delivery follow-up: commits `60e1e3f` and `b3cf3b5` are pushed on
`codex/reply-event-handoff`; dedicated CI Run
https://github.com/bhrumom/fabushi-plugin-chatgpt-auto-confirm/actions/runs/33948958618
passed for `b3cf3b5`. Draft PR #2 remains open; signed-in Browser → local Work
E2E, scoped approval evidence, protected-main merge and publication are still
pending.
