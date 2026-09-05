# A14 — Tested-artifact promotion and formal release

- **Status:** `planned`
- **Goal:** Publish only the artifact that passed QA and video review.
- **Owns:** artifact lineage, version mapping, release manifest, rollback, and post-release smoke
- **Depends on:** A10, A11, A13
- **Produces:** release receipt and post-release verification
- **Acceptance:** published artifact digest equals QA digest or has a reproducible equivalence proof; tag, source SHA, version, assets, rollback point, and release URL are recorded.
- **Blocked by:** release service and artifact promotion capability
