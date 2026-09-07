# Native runtime modules

- `Models.swift`: persisted approval, audit, and task queue data models.
- `ApprovalAccessibility.swift`: macOS Accessibility discovery and approval actions.
- `IPCAndCDP.swift`: Unix IPC and Chrome DevTools Protocol clients.
- `HiddenChatAndApproval.swift`: plugin-owned Chat renderer lifecycle and approval scanning. The renderer may be visible or hidden; exact profile/port/target ownership and the real Chat surface remain mandatory. Split authorization buttons open the adjacent scope menu first and choose the current-chat/session option when available; the native click path has a DOM fallback for isolated renderer contexts.
- `ApprovalWatcher.swift`: approval watcher decisions, status, and lifecycle.
- `QueueState.swift`: task queue persistence, validation, prompts, and public status.
- `QueueWorker.swift`: plugin-owned Quick Chat worker creation and task dispatch, with visible/hidden runtime reporting and exact retry cleanup.
- `QueueMonitoring.swift`: task monitoring, natural work-result handoff to a fresh planner Chat, planner completion/next-task handling, and watchdog recovery.
- `ChatScripts.swift`: JavaScript evaluated inside the plugin-owned Chat renderer.
- `main.swift`: command-line parsing and command dispatch only.
