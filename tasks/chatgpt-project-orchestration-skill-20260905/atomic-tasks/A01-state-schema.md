# A01 — Project, group, and atom state schema

- **Status:** `planned`
- **Goal:** Define a durable, non-sensitive schema for project, group, atom, Chat, revision, digest, and lease state.
- **Owns:** orchestration state schema and migration notes
- **Depends on:** A00
- **Produces:** versioned state schema and validator
- **Acceptance:** state distinguishes `reviewed_pr_head_sha` from `accepted_main_sha`, supports revision/spec digest, and preserves `BLOCKED`, `SUPERSEDED`, and `INVALIDATED`.
- **Blocked by:** runtime storage contract not yet selected
