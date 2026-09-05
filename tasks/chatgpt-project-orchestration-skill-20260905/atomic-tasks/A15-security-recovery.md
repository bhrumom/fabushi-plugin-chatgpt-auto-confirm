# A15 — Security, redaction, and recovery tests

- **Status:** `planned`
- **Goal:** Validate the negative and recovery paths after the full orchestration contract exists.
- **Owns:** secret scanning, duplicate-tab, disconnect, stale-review, context-migration, retry, and post-release recovery tests
- **Depends on:** A03, A04, A05, A06, A07, A08, A09, A10, A11, A12, A13, A14
- **Produces:** final negative/recovery suite and security evidence
- **Acceptance:** no password, cookie, API key, token, OTP, or private key value appears in prompt, task files, commits, logs, traces, screenshots, videos, or reports; each recovery path fails closed and is auditable.
- **Blocked by:** all preceding gates must be complete; this task is not partially complete in Wave 5
