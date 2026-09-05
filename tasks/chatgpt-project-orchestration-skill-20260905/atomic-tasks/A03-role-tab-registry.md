# A03 — Role and tab registry

- **Status:** `planned`
- **Goal:** Enforce one active browser tab per project-group role and safe duplicate cleanup.
- **Owns:** group-instance registry, tab lease, heartbeat, and cleanup rules
- **Depends on:** A01
- **Produces:** registry implementation and recovery tests
- **Acceptance:** an active group owns exactly one tab; RUNNING, permission-pending, or result-pending tabs cannot be closed; orphan cleanup is auditable.
- **Blocked by:** Browser controller must expose stable tab identity
