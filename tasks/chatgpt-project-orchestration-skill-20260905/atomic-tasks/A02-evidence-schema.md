# A02 — Evidence manifest schema

- **Status:** `planned`
- **Goal:** Define an immutable index for screenshots, complete video, trace, reports, logs, and artifacts.
- **Owns:** evidence manifest schema and digest rules
- **Depends on:** A00
- **Produces:** manifest validator and redaction-scan result fields
- **Acceptance:** each evidence item records journey, repository, source SHA, app version, producer, digest, timestamps, retention, and upload result without secrets.
- **Blocked by:** CI evidence storage and retention policy
