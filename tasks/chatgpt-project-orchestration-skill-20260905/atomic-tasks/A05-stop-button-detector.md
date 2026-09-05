# A05 — Stop Answering detector

- **Status:** `planned`
- **Goal:** Make the visible Stop Answering control the authoritative RUNNING state.
- **Owns:** localized semantic detector and state transitions
- **Depends on:** A04
- **Produces:** detector and UI-state tests
- **Acceptance:** while Stop Answering exists, the controller cannot read results, send any message, create a fresh Chat, switch group, or close the tab.
- **Blocked by:** Browser accessibility semantics must be stable enough for locale-aware matching
