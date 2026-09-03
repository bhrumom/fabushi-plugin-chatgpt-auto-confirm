# Native runtime modules

- `Models.swift`: persisted approval, audit, and task queue data models.
- `ApprovalAccessibility.swift`: macOS Accessibility discovery and approval actions.
- `IPCAndCDP.swift`: Unix IPC and Chrome DevTools Protocol clients.
- `HiddenChatAndApproval.swift`: hidden Chat renderer lifecycle and background approval scanning. Split authorization buttons open the adjacent scope menu first and choose the current-chat/session option when available; the native click path has a DOM fallback for isolated renderer contexts.
- `ApprovalWatcher.swift`: approval watcher decisions, status, and lifecycle.
- `QueueState.swift`: task queue persistence, validation, prompts, and public status.
- `QueueWorker.swift`: hidden Quick Chat worker creation and task dispatch.
- `QueueMonitoring.swift`: task monitoring, continuation, completion, and watchdog recovery. A terminal Chat without the required completion certificate is persisted as unfinished and dispatched to a fresh Chat.
- `ChatScripts.swift`: JavaScript evaluated inside the hidden Chat renderer.
- `main.swift`: command-line parsing and command dispatch only.
