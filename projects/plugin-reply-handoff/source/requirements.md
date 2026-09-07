# Canonical requirement snapshot — 2026-09-05

User requests extending ChatGPT 自动确认 so an ordinary plugin process detects the
end of a web ChatGPT response and wakes a local Work task only then. Local executor
must be `gpt-5.6-luna` with medium reasoning; web planning/review uses GPT-5.6 Sol
Extra High, as in the provided conversation. The local model must not repeatedly
inspect or reason during unchanged web generation. Automatically resolve expected
confirmation requests within the entrusted task. After the feature is actually
ready, dispatch the desktop/Mahayana CLI task from the prior conversation.

The attachment was inspected selectively (167731 lines); it contains extensive
repeated waiting and a correction that plugin work belongs in this standalone
repository. Raw transcript is not copied into source control. Existing PR #1 is
still open at head 4d95bf6e140f4f774a8a2785aad681802b308a0d, not merged.

Original engineering scope for eventual dispatch: desktop first-message latency,
MiniApp cards instead of code-only bot replies, installed MiniApp bot discovery,
Mahayana CLI fusion and per-bot sessions, same-account device control, bot discovery
and control of MiniApps, and group-chat behavior. Read the governed Fabushi project
records and verify current PR/CI facts before executing that scope.
