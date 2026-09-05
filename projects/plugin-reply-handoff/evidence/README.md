# Evidence index

- Canonical plugin main inspected: 1a626b496dccdc21240990ee7d3bbe44700a604f.
- Existing orchestration PR #1: open, head 4d95bf6e140f4f774a8a2785aad681802b308a0d.
- Native plugin status: enabled=false, running=false; Unix initialize succeeds.
  The local Work adapter now uses the installed official Codex queue/app-server
  interface and does not read or retain credentials.
- Current CUA in-app browser exposes tab/AX operations. Reply observation stays
  in the trusted Browser host; Work delivery is handed to `codex queue` only
  after an app-server `thread/resume` ownership check.
- git diff --check: passed before submission.
- Actions / release / real E2E: pending. Mock tests are not real E2E evidence.

## Local verification requested by user

- Node v26.7.0: focused suite 48/48 passed, [report](local-tests.tap).
- Actual local loopback HTTP test: missing authorization → 401; missing independent Work bridge → 503, not a successful registration. Browser itself is mocked in that test.
- Actual machine readiness probe: capability_descriptor_absent; no signed-in
  Browser host or Work thread was started during local verification. The adapter
  is created automatically when the executable is present, binds the current
  `CODEX_THREAD_ID` when a caller omits `threadId`, and can be disabled with
  `CHATGPT_AUTO_CONFIRM_WORK_BRIDGE=0`.
- Local MCP smoke (no model turn): `work_bridge_status` returned
  `enabled=true`, `available=true`, `transport=codex-queue`,
  `model=gpt-5.6-luna`, `thinking=medium`; `browser_reply_handoff` was present
  in `tools/list`.
- Initial CI: https://github.com/bhrumom/fabushi-plugin-chatgpt-auto-confirm/actions/runs/33946773891 passed for e38714c9bfaa0eb6a01434c7a60e95d039935f11.
- Draft PR: https://github.com/bhrumom/fabushi-plugin-chatgpt-auto-confirm/pull/2.
- No real web-to-Work wake or scoped auto-confirmation is claimed until the
  signed-in host E2E is run. The bridge contract suite covers ownership,
  Luna/medium argv enforcement and event-ledger deduplication.
