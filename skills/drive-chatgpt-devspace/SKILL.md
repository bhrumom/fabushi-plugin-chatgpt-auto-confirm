---
name: drive-chatgpt-devspace
description: Drive a coding task through the actual Chat surface of a plugin-owned ChatGPT.app instance using the devspace1 connector. The instance may be visible or hidden. Use when an AI must create a fresh Chat for every outbound message, select devspace1, verify the send, auto-confirm authorization cards, stream user-visible thinking/tool progress, hand a natural work result to a fresh planner Chat, recover from a three-hour stall by closing the old plugin Chat, and wait for ChatGPT's final reply before independently validating the repository.
---

# Drive ChatGPT Devspace

Use the `chatgpt-auto-confirm` plugin as the only controller. It operates a dedicated plugin-owned `ChatGPT.app` instance; that instance may be visible or hidden, while the user's visible Work task is never switched or clicked.

For long-lived release, deployment, marketplace, or CI work, also apply the bundled `actions-first-task-queue` skill. A local controller builds and tests locally; a controller running in GitHub Actions builds and tests inside Actions. Releases, deployments, and GitHub-native acceptance evidence still use Actions when required. Unrelated large files must not be staged or uploaded.

## Non-negotiable boundaries

- Operate the desktop app's real **Chat** surface. Do not use ChatGPT web, Chrome, the visible Codex/Work composer, macOS coordinate clicks, or a worker task as the message destination.
- Require `workerUsed: false`, `surface: "chat"`, `chatMode: true`, and exact plugin target/profile ownership before sending. `runtimeState` may be `hidden` or `visible`; `backgroundOnly` is diagnostic only and must reflect that state.
- If the plugin-owned Chat surface is unavailable, stop with an error. Never fall back to the user's visible Work/worker page or an unowned ChatGPT target.
- Re-check the owned Chat surface throughout polling, before every approval scan or follow-up. If it ever ceases to report `chatMode: true` and `surface: "chat"`, return `chat_surface_drift` immediately with a screenshot and page diagnostics. Never approve, type, or continue on Work.
- Never append an outbound message to an existing conversation. Every actual send, including a stall recovery, must first create a fresh **Chat**. Existing conversations are read-only monitoring targets only.
- Treat returned `thinking` as user-visible reasoning summaries and tool activity, not private model chain-of-thought. Redact credentials before relaying it.
- Once `send_and_watch` starts, only consume its progress and final output. Do not inspect, edit, build, or validate the target repository in parallel.

## Run the workflow

1. Call `chat_status` and enforce the owned Chat fields above. Do not bind an old `conversationId` when a message will be sent.
2. Call `send_and_watch` with:
   - the complete task in `message`;
   - `connector: "devspace1"`;
   - `newChat: true` and no old `conversationId` for every outbound message;
   - `approveAll: true`;
   - `timeout: 21600` unless the user requests another total limit;
   - `stagnationTimeout: 10800` for 3 hours without new visible progress;
   - `noFinalReplyTimeout: 300` so a sent turn that ends without an assistant final reply is closed and resent in a fresh Work Chat after five minutes;
   - `maxRecoveryAttempts: 5`;
   - select GPT-5.6 Sol and Extra High reasoning effort for complex implementation tasks when the model selector is available;
   - `autoContinueIncomplete: true`;
   - `maxTaskContinuations: 0` (continue through fresh branch Chats until complete);
   - `role: "work"` and `autoPlanAfterWork: true` for an execution Chat; the plugin creates a fresh `role: "planner"` Chat after a stable natural result;
   - `originalGoal`, `taskId`, `appliedRevision`, and `appliedDigest` so the planner can validate the same project revision;
   - `pollIntervalMs: 500`.

The work Chat receives only the executable natural-language goal. It must not receive `MAHAYANA_TASK_REPORT_V1` or any completion/next-step template. The fresh planner Chat receives the original goal and the work Chat's natural result, and it alone receives the report contract. If the planner returns a non-empty `next_task`, the plugin sends that raw arrangement to another fresh work Chat without appending the planner template.
3. Require `preparation.newChatClicked: true` before accepting any send.
4. Read `thinking_progress` events as live status. Important fields are `thinking`, `activityCharCount`, `devspaceActivity`, `devspaceWaiting`, and `waitingForApproval`.
5. Keep waiting. Authorization cards are confirmed internally, including repeated cards that appear after edits, shell commands, formatting, or builds.

Keep the persistent watcher running at a short interval while a task is active. It must combine plugin-owned renderer approval scanning with all loaded ChatGPT app windows, so a clean plugin page can never suppress a pending card in another loaded window. This scan must not activate ChatGPT, move the pointer, switch tasks, or alter the user's visible page.

For long-running supervision, maintain a 10-minute heartbeat. Each heartbeat checks watcher health, the active plugin Chat target, its `hidden`/`visible` runtime state, pending approval cards, new thinking/tool content, final-reply state, and devspace1 connectivity. Restart the already-built watcher when unhealthy, but never send from the heartbeat.

Before treating the request as sent, require every `sendVerification.stages` entry to succeed. In particular, require `connectorConfirmed`, `inputConfirmed`, `messageConfirmed`, and `sent` to be true. The input step replaces any stale draft already present in a new Chat. The message step must observe a new user message bubble containing the submitted instruction; a button click or Enter key event alone is not success.

If preparation, Apps selection, text entry, or message confirmation fails, stop immediately. Report `failedStage`, `errorCode`, `stages`, `screenshotPath`, redacted `pageContent`, and `pageButtons`. Do not start a reply timeout for a message that the page did not confirm.

For an interrupted controller process, `resumeExisting: true` may bind the same Chat only to monitor it without sending. If another message is required, start a fresh Chat instead.

## Stall and recovery behavior

A stall requires 3 continuous hours with no change in the visible thinking summary, devspace tool activity, or central Chat content. Do not treat a slow build as stalled while its visible activity changes.

The 3-hour timer applies only while ChatGPT still appears to be running. If generation has stopped and the stable response explicitly says the task is unfinished, blocked, or failed, return immediately with `chat_finished_incomplete`, the visible response, and diagnostics. Never wait for the stall timer after the Chat has ended.

If the sent user turn is present but the session ends without any new assistant final reply, the plugin must not treat the empty state as a result or send it to the planner. After the bounded `noFinalReplyTimeout` window (default five minutes), it closes the exact old plugin Chat/profile/process, opens a fresh Work Chat, and resends the same Work instruction. This retry is separate from the planner handoff and is bounded by `maxRecoveryAttempts`.

Do not let an unfinished Chat stop while useful work can continue. `MAHAYANA_TASK_REPORT_V1` is a planner-only completion/arrangement certificate: a work Chat emits natural language only, while a fresh planner Chat emits the certificate after inspecting the work result and repository state. An unfinished, waiting, blocked, or prematurely ended work Chat emits no task report; the controller closes that plugin-owned Chat when retrying and sends the same objective to a fresh Chat.

At the start of every first, continuation, and review Chat, locate the matching project in the configured GitHub repository by stable task id and project directory. If it is missing, create the repository project with goal/scope, architecture, executable work, acceptance, and evidence documents, then register those files in the task control entry.

Do not end a working Chat merely because Actions, deployments, releases, or remote checks are still running. Continue polling inside the task Chat. When external waiting must cross Chats, return the same report envelope with a realistic delay and `all_tasks_complete=false`.

For GitHub-backed work, use the GitHub connector for cloud state and bhrum2 for the local checkout. Set `next_connector` when the next fresh Chat must switch between those contexts. Treat disconnects, DNS failures, upstream 502/503/504, and connector timeouts as a recoverable wait, not as completion or an instruction to repeat a failed request.

Treat a work reply with stable natural content as a handoff candidate only when the work send/finish checks pass; the plugin then creates the planner Chat. Treat `complete` as a terminal candidate only when the planner's structured report exists and all normal completion checks pass. A planner reply without the report is `task_report_missing`, not success. The Worker attachment is a result handoff, never an instruction-sending fallback.

On the first or second stall, the plugin must:

1. Capture a screenshot and the central Chat text.
2. Classify the event as `devspace_timeout` when the latest visible activity belongs to devspace1; otherwise classify it as `page_stalled`.
3. Do not click ChatGPT's stop control. Close only the exact old plugin-owned target/profile/process, preserving the checkout and user-owned ChatGPT/Codex processes.
4. Create a fresh plugin-owned Chat, select devspace1 again, and send a continuation that identifies the same checkout and tells ChatGPT to inspect whether the last action returned or landed, retry only that step if necessary, preserve completed work, and finish verification. The fresh target may be visible or hidden.
5. Reset the idle timer and continue streaming progress from the fresh Chat; the old plugin Chat is not a send target or preserved execution branch.

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
