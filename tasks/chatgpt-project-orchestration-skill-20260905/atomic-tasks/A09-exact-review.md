# A09 — Exact PR/head review

- **Status:** `planned`
- **Goal:** Bind review approval to the exact repository, PR, head SHA, base SHA, atom, and spec digest.
- **Owns:** review key and stale-approval invalidation
- **Depends on:** A01
- **Produces:** reviewer gate and review record schema
- **Acceptance:** `SHA256(repository + pr_number + head_sha + base_sha + atomic_task_id + spec_digest)` is recorded; any component change makes approval stale.
- **Blocked by:** GitHub review/check API access
