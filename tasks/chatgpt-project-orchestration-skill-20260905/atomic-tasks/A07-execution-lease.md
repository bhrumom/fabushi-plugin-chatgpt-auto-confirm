# A07 — Execution lease and idempotency

- **Status:** `planned`
- **Goal:** Make task claims, retries, and recovery idempotent.
- **Owns:** execution key, lease, attempt, and dedupe protocol
- **Depends on:** A01, A06
- **Produces:** claim/retry/recovery implementation
- **Acceptance:** one `project + revision + atom + spec_digest` cannot be actively claimed twice; an existing exact PR/head is resumed rather than reimplemented.
- **Blocked by:** persistent group-instance identity
