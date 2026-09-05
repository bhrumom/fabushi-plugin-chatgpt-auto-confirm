# A08 — Same-tab context handoff

- **Status:** `planned`
- **Goal:** Resume long or interrupted work in a fresh Chat within the same project-group tab.
- **Owns:** handoff packet, context rollover, and conversation binding
- **Depends on:** A01, A03, A05
- **Produces:** handoff serializer and migration tests
- **Acceptance:** handoff is allowed only after Stop Answering disappears and cards are clear; it carries durable paths, revision, digest, task, PR/head, evidence, blockers, and next action without secrets.
- **Blocked by:** same-tab fresh Chat API
