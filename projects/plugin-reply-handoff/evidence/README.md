# Evidence index

- Canonical plugin main inspected: 1a626b496dccdc21240990ee7d3bbe44700a604f.
- Existing orchestration PR #1: open, head 4d95bf6e140f4f774a8a2785aad681802b308a0d.
- Native plugin status: enabled=false, running=false; Unix initialize succeeds,
  but does not provide a verified Work wake API. No credentials retained.
- Current CUA in-app browser exposes tab/AX operations; no supported independent
  observer or Work delivery adapter is exposed. No raw app protocol attempted.
- git diff --check: passed before submission.
- Actions / release / real E2E: pending. Mock tests are not real E2E evidence.
