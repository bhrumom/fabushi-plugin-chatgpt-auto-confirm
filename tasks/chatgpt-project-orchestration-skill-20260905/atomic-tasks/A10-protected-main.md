# A10 — Protected-main merge gate

- **Status:** `planned`
- **Goal:** Merge only a reviewed, checked, exact PR head into a verifiably protected main.
- **Owns:** branch-protection probe, merge receipt, and main SHA lock
- **Depends on:** A09
- **Produces:** merge gate and receipt record
- **Acceptance:** direct push is rejected; protection/ruleset facts are recorded; the merge receipt identifies exact PR/head/base and resulting main SHA.
- **Blocked by:** repository protection configuration and API visibility
