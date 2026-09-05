# A06 — Atomic DAG and conflict graph

- **Status:** `planned`
- **Goal:** Schedule independent atoms in parallel while preventing overlapping writes and unresolved dependencies.
- **Owns:** atom allocator, read/write sets, interface dependencies, and conflict graph
- **Depends on:** A00, A01
- **Produces:** DAG schema and scheduler checks
- **Acceptance:** every atom has a single observable goal, explicit ownership, dependencies, inputs/outputs, and objective acceptance; overlapping write sets cannot run concurrently.
- **Blocked by:** target project must provide file/subsystem ownership
