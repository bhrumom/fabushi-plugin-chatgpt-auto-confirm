---
name: drive-chatgpt-devspace
description: Drive a coding task through the actual Chat surface of a hidden second ChatGPT.app instance using the devspace1 connector. Use when an AI must create a fresh Chat for every outbound message, select devspace1, verify the send, auto-confirm authorization cards, stream user-visible thinking/tool progress, recover from a three-hour stall in another new Chat without stopping the old Chat, and wait for ChatGPT's final reply before independently validating the repository.
---

# Drive ChatGPT Devspace

Use the `chatgpt-auto-confirm` plugin as the only controller. It operates a hidden second `ChatGPT.app` instance so the user's visible Work task is not switched or clicked.

For long-lived release, deployment, marketplace, or CI work, also apply the bundled `actions-first-task-queue` skill. A local controller builds and tests locally; a controller running in GitHub Actions builds and tests inside Actions. Releases, deployments, and GitHub-native acceptance evidence still use Actions when required. Unrelated large files must not be staged or uploaded.

## Non-negotiable boundaries

- Operate the desktop app's real **Chat** surface. Do not use ChatGPT web, Chrome, the visible Codex/Work composer, macOS coordinate clicks, or a worker task as the message destination.
- Require `backgroundOnly: true`, `workerUsed: false`, `surface: "chat"`, and `chatMode: true` before sending.
- If the hidden Chat surface is unavailable, stop with an error. Never fall back to the visible Work/worker page.
- Re-check the hidden surface throughout polling, before every approval scan or follow-up. If it ever ceases to report `chatMode: true` and `surface: "chat"`, return `chat_surface_drift` immediately with a screenshot and page diagnostics. Never approve, type, or continue on Work.
- Never append an outbound message to an existing conversation. Every actual send, including a stall recovery, must first create a fresh **Chat**. Existing conversations are read-only monitoring targets only.
- Treat returned `thinking` as user-visible reasoning summaries and tool activity, not private model chain-of-thought. Redact credentials before relaying it.
- Once `send_and_watch` starts, only consume its progress and final output. Do not inspect, edit, build, or validate the target repository in parallel.

## Run the workflow

1. Call `chat_status` and enforce the four hidden-Chat fields above. Do not bind an old `conversationId` when a message will be sent.
2. Call `send_and_watch` with:
   - the complete task in `message`;
   - `connector: "devspace1"`;
   - `newChat: true` and no old `conversationId` for every outbound message;
   - `approveAll: true`;
   - `timeout: 21600` unless the user requests another total limit;
   - `stagnationTimeout: 10800` for 3 hours without new visible progress;
   - `maxRecoveryAttempts: 5`;
   - select GPT-5.6 Sol and Extra High reasoning effort for complex implementation tasks when the model selector is available;
   - `autoContinueIncomplete: true`;
   - `maxTaskContinuations: 0` (continue through fresh branch Chats until complete);
   - `pollIntervalMs: 500`.
3. Require `preparation.newChatClicked: true` before accepting any send.
4. Read `thinking_progress` events as live status. Important fields are `thinking`, `activityCharCount`, `devspaceActivity`, `devspaceWaiting`, and `waitingForApproval`.
5. Keep waiting. Authorization cards are confirmed internally, including repeated cards that appear after edits, shell commands, formatting, or builds.

Keep the persistent watcher running at a short interval while a task is active. It must combine hidden-renderer approval scanning with all loaded ChatGPT app windows, so a clean hidden page can never suppress a pending card in another loaded window. This scan must not activate ChatGPT, move the pointer, switch tasks, or alter the user's visible page.

For long-running supervision, maintain a 10-minute heartbeat. Each heartbeat checks watcher health, the active hidden Chat target, pending approval cards, new thinking/tool content, final-reply state, and devspace1 connectivity. Restart the already-built watcher when unhealthy, but never send from the heartbeat.

Before treating the request as sent, require every `sendVerification.stages` entry to succeed. In particular, require `connectorConfirmed`, `inputConfirmed`, `messageConfirmed`, and `sent` to be true. The input step replaces any stale draft already present in a new Chat. The message step must observe a new user message bubble containing the submitted instruction; a button click or Enter key event alone is not success.

If preparation, Apps selection, text entry, or message confirmation fails, stop immediately. Report `failedStage`, `errorCode`, `stages`, `screenshotPath`, redacted `pageContent`, and `pageButtons`. Do not start a reply timeout for a message that the page did not confirm.

For an interrupted controller process, `resumeExisting: true` may bind the same Chat only to monitor it without sending. If another message is required, start a fresh Chat instead.

## Stall and recovery behavior

A stall requires 3 continuous hours with no change in the visible thinking summary, devspace tool activity, or central Chat content. Do not treat a slow build as stalled while its visible activity changes.

The 3-hour timer applies only while ChatGPT still appears to be running. If generation has stopped and the stable response explicitly says the task is unfinished, blocked, or failed, return immediately with `chat_finished_incomplete`, the visible response, and diagnostics. Never wait for the stall timer after the Chat has ended.

Do not let an unfinished Chat stop while useful work can continue. `MAHAYANA_TASK_REPORT_V1` is a final completion certificate only: emit it only with `status=complete` and `all_tasks_complete=true` after the entire repository project is complete. An unfinished, waiting, blocked, or prematurely ended Chat emits no task report; the controller preserves repository state and sends the same objective to a fresh Chat.

At the start of every first, continuation, and review Chat, locate the matching project in the configured GitHub repository by stable task id and project directory. If it is missing, create the repository project with goal/scope, architecture, executable work, acceptance, and evidence documents, then register those files in the task control entry.

Do not end a working Chat merely because Actions, deployments, releases, or remote checks are still running. Continue polling inside the task Chat. When external waiting must cross Chats, return the same report envelope with a realistic delay and `all_tasks_complete=false`.

For GitHub-backed work, use the GitHub connector for cloud state and bhrum2 for the local checkout. Set `next_connector` when the next fresh Chat must switch between those contexts. Treat disconnects, DNS failures, upstream 502/503/504, and connector timeouts as a recoverable wait, not as completion or an instruction to repeat a failed request.

Treat `complete` as a candidate for controller handoff only when the structured report exists and all normal completion checks pass. A reply without the report is `task_report_missing`, not success. Attach the completed Chat to the user's current Worker only after this candidate is returned; the controlling AI must independently validate it before declaring the goal accepted. The Worker attachment is a result handoff, never an instruction-sending fallback.

On the first or second stall, the plugin must:

1. Capture a screenshot and the central Chat text.
2. Classify the event as `devspace_timeout` when the latest visible activity belongs to devspace1; otherwise classify it as `page_stalled`.
3. Do not click ChatGPT's stop control and do not close the unchanged old Chat or its renderer.
4. Create a fresh Chat directly, select devspace1 again, and send a continuation that identifies the same checkout and tells ChatGPT to inspect whether the last action returned or landed, retry only that step if necessary, preserve completed work, and finish verification. If the normal new-task control is unavailable, use the global new-Chat flow or a separate hidden target.
5. Reset the idle timer and continue streaming progress while retaining the old Chat for a late result.

After `maxRecoveryAttempts`, stop instead of looping forever. Return the error, screenshots, `pageContent`, `pageButtons`, visible thinking, and recovery history.

Devspace itself independently returns `DEVSPACE_TOOL_TIMEOUT` when a tool invocation fails to return within its own 5-minute limit. This is separate from the Chat page's 3-hour visible-stall timer; shell commands can also use a shorter tool-specific timeout.

## Decide whether the task completed

Accept success only when all conditions hold:

- `ok: true`;
- `reply.done: true`;
- `reply.content` is non-empty;
- `timedOut: false`;
- `stalled: false`.

If any condition fails, report the plugin evidence and do not claim the coding task completed. A visible authorization card means ChatGPT is waiting for permission, not that devspace1 itself is hung.

Tool-activity rows such as `Link ... bash`, `Link ... read`, or `已使用 devspace1 集成` are not a final answer. A collapsed `思考` section is also not final when its visible text says the task is unfinished (`尚未完成`, `还需要继续`, or equivalent). Require substantive assistant content and a stable completion signal across consecutive polls.

Only after a valid final reply may the controlling AI inspect the target checkout, review the diff, run independent tests, and compare the implementation with the original request. Preserve unrelated user changes throughout validation.
