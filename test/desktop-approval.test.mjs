import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import test from 'node:test';
import { runInNewContext } from 'node:vm';
import worker from '../worker/src/index.ts';

const hiddenApprovalSource = readFileSync(
  new URL('../native/HiddenChatAndApproval.swift', import.meta.url),
  'utf8',
);
const approvalScriptMatch = hiddenApprovalSource.match(
  /func autoApproveDedicatedAuthorizationJS\(\) -> String \{[\s\S]*?#"""([\s\S]*?)"""#/,
);
assert.ok(approvalScriptMatch, 'embedded authorization script must be extractable');
const approvalScript = approvalScriptMatch[1].trim();

const chatScriptsSource = readFileSync(
  new URL('../native/ChatScripts.swift', import.meta.url),
  'utf8',
);
const extractTripleQuotedScript = (source, functionSignature) => {
  const functionStart = source.indexOf(functionSignature);
  assert.notEqual(functionStart, -1, `${functionSignature} must exist`);
  const scriptStartMarker = 'return """';
  const scriptStart = source.indexOf(scriptStartMarker, functionStart);
  assert.notEqual(scriptStart, -1, `${functionSignature} script must start`);
  const contentStart = scriptStart + scriptStartMarker.length;
  const contentEnd = source.indexOf('"""', contentStart);
  assert.notEqual(contentEnd, -1, `${functionSignature} script must end`);
  return source.slice(contentStart, contentEnd).trim();
};
const selectConversationScript = extractTripleQuotedScript(
  hiddenApprovalSource,
  'func selectBackgroundConversationJS(_ conversationId: String) -> String',
);
const continueInNewTaskScript = extractTripleQuotedScript(
  chatScriptsSource,
  'func continueInNewTaskJS(expectedConversationId: String? = nil) -> String',
);
const renderInterpolatedSwiftScript = (script, expected) => script
  .replace('\\(expected)', JSON.stringify(expected))
  .replaceAll('\\\\', '\\');

const queueMonitoringSource = readFileSync(
  new URL('../native/QueueMonitoring.swift', import.meta.url),
  'utf8',
);
const queueWorkerSource = readFileSync(
  new URL('../native/QueueWorker.swift', import.meta.url),
  'utf8',
);
const queueTerminalDecisionSource = readFileSync(
  new URL('../native/QueueTerminalDecision.swift', import.meta.url),
  'utf8',
);
const nativeDirectory = new URL('../native/', import.meta.url);
const nativeSource = readdirSync(nativeDirectory)
  .filter(name => name.endsWith('.swift'))
  .sort()
  .map(name => readFileSync(new URL(name, nativeDirectory), 'utf8'))
  .join('\n');
const call = async (name, args = {}) => {
  const response = await worker.fetch(new Request('https://example.test/mcp', {
    method: 'POST', body: JSON.stringify({ jsonrpc: '2.0', id: 9, method: 'tools/call',
      params: { name, arguments: args } }),
  }));
  return response.json();
};

test('start emits a scoped desktop host request', async () => {
  const result = await call('start', { rules: [{
    application: 'GitHub', action: 'Enable auto-merge', resource: 'bhrumom/fabushi',
  }] });
  assert.equal(result.result.structuredContent.hostRequest.capability,
    'desktop.chatgpt-approvals.start');
  assert.equal(result.result.structuredContent.hostRequest.approval, 'required');
});

test('start rejects broad wildcard rules', async () => {
  const result = await call('start', { rules: [{ application: 'GitHub', action: '*', resource: 'all' }] });
  assert.equal(result.error.code, -32602);
});

test('start supports every recognized approval card without chat titles', async () => {
  const chatUrl = 'https://chatgpt.com/c/hidden-task-101';
  const result = await call('start', { approveAll: true, intervalMs: 750, chatUrls: [chatUrl] });
  const request = result.result.structuredContent.hostRequest;
  assert.equal(request.capability, 'desktop.chatgpt-approvals.start');
  assert.equal(request.params.approveAll, true);
  assert.deepEqual(request.params.chatTitles, []);
  assert.deepEqual(request.params.chatUrls, [chatUrl]);
});

test('status is a read-only host request', async () => {
  const result = await call('status');
  assert.equal(result.result.structuredContent.hostRequest.approval, 'none');
});

test('outbound sends discard old chat URLs while read-only reply requests keep them', async () => {
  const chatUrl = 'https://chatgpt.com/c/hidden-task-202';
  const sent = await call('send_and_watch', {
    message: '检查隐藏任务', connector: 'devspace1', chatUrl,
  });
  assert.equal(sent.result.structuredContent.hostRequest.params.chatUrl, null);
  assert.equal(sent.result.structuredContent.hostRequest.params.newChat, true);
  const reply = await call('get_reply', { chatUrl });
  assert.equal(reply.result.structuredContent.hostRequest.params.chatUrl, chatUrl);
});

test('dispatch_goal makes the plugin own the complete fresh-Chat policy', async () => {
  const result = await call('dispatch_goal', {
    goal: '把 RustDesk 开源仓库融合进当前项目并完成全部功能与验证',
    connector: 'wrong-connector',
    previousProgress: '不要把这段内容发给 ChatGPT',
  });
  const request = result.result.structuredContent.hostRequest;
  assert.equal(request.capability, 'browser.in-app.dispatch-and-watch');
  assert.equal(request.approval, 'required');
  assert.deepEqual(request.params, {
    message: '把 RustDesk 开源仓库融合进当前项目并完成全部功能与验证',
    browser: 'iab',
    capability: 'browser.in-app.dispatch-and-watch',
    connector: null,
    model: 'GPT-5.6 Sol',
    reasoning: 'Extra High',
    surface: 'chat',
    newChat: true,
    resumeExisting: false,
    goalOnlyDispatch: false,
    approveAll: true,
    timeout: 21600,
    stagnationTimeout: 10800,
    noFinalReplyTimeout: 300,
    maxRecoveryAttempts: 5,
    autoContinueIncomplete: true,
    maxTaskContinuations: 0,
    continuationMessage: null,
    maxConcurrentJobs: 2,
    pollIntervalMs: 500,
  });
});

test('dispatch_goal rejects an empty goal', async () => {
  const result = await call('dispatch_goal', { goal: '   ' });
  assert.equal(result.error.code, -32602);
});

test('Work Chat returns a natural result and a fresh planner Chat owns the certificate', () => {
  assert.match(chatScriptsSource, /func taskReportContract\(/);
  assert.match(chatScriptsSource, /MAHAYANA_TASK_REPORT_CONTRACT_V6/);
  assert.match(chatScriptsSource, /规划\/验收 Chat，不是工作 Chat/);
  assert.match(chatScriptsSource, /只有规划\/验收 Chat 可以输出 MAHAYANA_TASK_REPORT_V1/);
  assert.match(chatScriptsSource, /"status":"complete"/);
  assert.match(chatScriptsSource, /"all_tasks_complete":true/);
  assert.match(chatScriptsSource, /func acceptancePlannerMessage\(/);
  assert.match(chatScriptsSource, /工作 Chat 自然结果 BEGIN/);
  assert.match(nativeSource, /taskId: task\.id/);
  assert.match(nativeSource, /appliedRevision: task\.currentRevision/);
  assert.match(nativeSource, /messageWithoutTaskReportContract/);
  assert.match(nativeSource, /let outbound = automationTaskMessage/);
  assert.match(nativeSource, /startAutomationPlanner/);
  assert.match(nativeSource, /plannerHandoff/);
  assert.match(nativeSource, /role == "work"/);
  assert.match(nativeSource, /naturalWorkResult/);
  assert.doesNotMatch(
    queueWorkerSource,
    /messageWithTaskReportContract\([\s\S]*?automationTaskMessage\(/,
  );
});

test('planner and Work turns recover through their own fresh-Chat boundaries', () => {
  assert.match(nativeSource, /let reportMissing = role == "planner"/);
  assert.match(nativeSource, /let workReplyReady = role == "work"/);
  assert.match(nativeSource, /planner_report_missing/);
  assert.match(nativeSource, /task_report_missing/);
  assert.match(nativeSource, /planner_handoff_not_confirmed/);
  assert.match(nativeSource, /childParams\["role"\] = role == "planner" \? "work"/);
  assert.match(nativeSource, /messageWithoutTaskReportContract/);
  assert.match(nativeSource, /relayFreshChatContinuation\(childParams\)/);
});

test('miniapp treats an explicit revision bump as a task update even when text is unchanged', () => {
  assert.match(nativeSource, /let declaredRevision = max\(1, entry\["revision"\] as\? Int \?\? previousRevision\)/);
  assert.match(nativeSource, /let changed = declaredRevision > previousRevision/);
});

test('initial outbound messages create a new Chat and same-task continuations use the reply action', async () => {
  const conversationId = '6a5f93ae-5118-83e8-a96a-2a7f321dd0e8';
  const sent = await call('send_and_watch', {
    message: '继续同一会话', connector: 'devspace1', conversationId, newChat: true,
  });
  const params = sent.result.structuredContent.hostRequest.params;
  assert.equal(params.conversationId, null);
  assert.equal(params.newChat, true);
  const resumed = await call('send_and_watch', {
    message: '只读监视', conversationId, resumeExisting: true,
  });
  const resumeParams = resumed.result.structuredContent.hostRequest.params;
  assert.equal(resumeParams.conversationId, conversationId);
  assert.equal(resumeParams.newChat, false);
  assert.match(nativeSource, /selectBackgroundConversationJS/);
  assert.match(nativeSource, /conversation_sidebar_row_not_found/);
  assert.match(nativeSource, /conversationFingerprint/);
  assert.match(nativeSource, /conversation_body_not_ready/);
  assert.match(nativeSource, /messagesReady: true/);
  assert.match(nativeSource, /新建任务/);
  assert.match(nativeSource, /新对话/);
  assert.match(nativeSource, /New task/);
  assert.match(nativeSource, /activityCharCount >= 80/);
  assert.match(nativeSource, /do not treat that regression as/);
  assert.match(nativeSource, /__reactFiber\$/);
  assert.match(nativeSource, /new_chat_conversation_not_created/);
  assert.match(nativeSource, /new_chat_creation_not_confirmed/);
  assert.match(nativeSource, /unmaterializedBlankConversation/);
  assert.match(nativeSource, /prepare_new_chat_baseline_failed/);
  assert.match(nativeSource, /new_chat_click_no_result/);
  assert.match(nativeSource, /allow forty seconds/);
  assert.match(nativeSource, /Prefer the portal owned by the current composer/);
  assert.match(nativeSource, /continueInNewTaskJS/);
  assert.match(nativeSource, /continuationClicked/);
  assert.match(nativeSource, /continue_in_new_task_button_not_found/);
  assert.match(nativeSource, /stage=prepare-continuation/);
  assert.match(nativeSource, /continuation_conversation_click_failed/);
  assert.match(nativeSource, /restoreHiddenConversation/);
  assert.match(nativeSource, /currentComposerConversationIdentityJS/);
  assert.match(nativeSource, /source: conversationId \? 'composer-portal' : 'none'/);
  assert.match(nativeSource, /route-failed-but-conversation-confirmed/);
  assert.match(nativeSource, /restorationMatchesExpectedConversation/);
  assert.match(nativeSource, /strategy=.*restoration/);
  assert.match(nativeSource, /branch-required/);
  assert.match(nativeSource, /same_task_branch_not_confirmed/);
  assert.match(nativeSource, /assistantResponseCount/);
  assert.match(nativeSource, /no-assistant-response/);
  assert.match(nativeSource, /forceFullGoalPrompt = true/);
  assert.match(nativeSource, /automationTaskMessage\(task, forceFullGoal: forceFullGoalPrompt\)/);
  assert.match(nativeSource, /let isContinuation = !forceFullGoal/);
  assert.match(nativeSource, /fresh_chat_after_unanswered_dispatch_not_confirmed/);
  assert.match(nativeSource, /blankConversationReused/);
  assert.doesNotMatch(nativeSource, /continuationFallback/);
  assert.doesNotMatch(nativeSource, /queueUsesHostedRenderer|CHATGPT_AUTO_CONFIRM_HOSTED/);
  assert.doesNotMatch(nativeSource, /无法恢复上一轮会话，未点击/);
});

test('send_and_watch streams visible thinking and recovers in a fresh Chat after three hours', async () => {
  const sent = await call('send_and_watch', {
    message: '继续完成任务', connector: 'devspace1',
  });
  const params = sent.result.structuredContent.hostRequest.params;
  assert.equal(params.newChat, true);
  assert.equal(params.timeout, 21600);
  assert.equal(params.stagnationTimeout, 10800);
  assert.equal(params.noFinalReplyTimeout, 300);
  assert.equal(params.maxRecoveryAttempts, 5);
  assert.equal(params.autoContinueIncomplete, true);
  assert.equal(params.maxTaskContinuations, 0);
  assert.match(nativeSource, /"thinking_progress"/);
  assert.match(nativeSource, /closeBackgroundTargets/);
  assert.match(nativeSource, /prepareNewChatTarget/);
  assert.match(nativeSource, /oldChatClosed/);
  assert.match(nativeSource, /"oldChatPreserved": false/);
  assert.match(nativeSource, /fresh_plugin_chat_after_stall/);
  assert.match(nativeSource, /defaultChatNoFinalReplyTimeoutSeconds = 300/);
  assert.match(nativeSource, /noFinalReplySessionEnded/);
  assert.match(nativeSource, /fresh_plugin_chat_after_no_final_reply/);
  assert.match(nativeSource, /sessionEndedWithoutFinalReply/);
  assert.match(nativeSource, /no_final_reply_after_retries/);
  assert.match(nativeSource, /stopRequested/);
  assert.doesNotMatch(nativeSource, /fresh_chat_fallback/);
  const stallRecoveryStart = nativeSource.indexOf(
    'if noFinalReplySessionEnded',
  );
  const stallRecoveryEnd = nativeSource.indexOf('// Save state', stallRecoveryStart);
  assert.ok(stallRecoveryStart >= 0 && stallRecoveryEnd > stallRecoveryStart);
  assert.match(nativeSource.slice(stallRecoveryStart, stallRecoveryEnd), /closeBackgroundTargets/);
  assert.match(nativeSource, /message: continuationMessage/);
  assert.match(nativeSource, /newChat: false/);
  assert.doesNotMatch(nativeSource, /private func stopAndContinueJS/);
  assert.match(nativeSource, /"continuedInNewTask"/);
  assert.match(nativeSource, /DEVSPACE_TOOL_TIMEOUT|devspace_timeout/);
  assert.match(nativeSource, /继续在此聊天/);
  assert.match(nativeSource, /autoConfirmChatContinuationJS/);
  assert.match(nativeSource, /stage=chat-continuation/);
  assert.match(nativeSource, /chat_surface_drift/);
  assert.match(nativeSource, /surface: 'chat'/);
  assert.match(nativeSource, /continueInChatPrompt/);
  assert.match(
    nativeSource,
    /expression: autoConfirmChatContinuationJS\(\)[\s\S]*dispatchRecommendedCDPClick\([\s\S]*chatContinuation/,
  );
  assert.match(
    nativeSource,
    /autoConfirmChatContinuationJS\(\)[\s\S]*chatStatusJS\(\)/,
  );
  assert.match(nativeSource, /An omitted accountId means/);
  assert.match(nativeSource, /selectedAccount = nil/);
  assert.match(nativeSource, /parentProcessID\(matchedProcessID\)/);
  assert.doesNotMatch(nativeSource, /expression: autoConfirmWorkHandoffJS\(\)/);
  assert.match(nativeSource, /REDACTED_API_KEY/);
  assert.match(nativeSource, /connector_selection_not_confirmed/);
  assert.match(nativeSource, /isInComposerBand/);
  assert.match(nativeSource, /message_input_not_confirmed/);
  assert.match(nativeSource, /message_send_not_confirmed/);
  assert.match(nativeSource, /containsFullSubmittedMessage/);
  assert.match(nativeSource, /sendJS, timeout: 35\.0/);
  assert.match(nativeSource, /verifySentMessageJS/);
  assert.match(nativeSource, /recoveredAfterExecutionContextLoss/);
  assert.match(nativeSource, /never send the message a second time here/);
  assert.match(nativeSource, /baselineUserIdentities/);
  assert.match(nativeSource, /isNewBubble/);
  assert.match(nativeSource, /virtualizationAware/);
  assert.match(nativeSource, /sendVerification/);
  assert.match(nativeSource, /approval_watcher_start_failed/);
  assert.match(nativeSource, /completionCandidate/);
  assert.match(nativeSource, /responseActionsComplete/);
  assert.match(nativeSource, /appContentMessages\.length > 0/);
  assert.match(nativeSource, /responseActionTurnBoundToLast/);
  assert.match(nativeSource, /!awaitingAssistant/);
  assert.match(nativeSource, /completedResponseUI/);
  assert.match(nativeSource, /responseActions\.copy/);
  assert.match(nativeSource, /responseActions\.branch/);
  assert.match(nativeSource, /responseActions\.moreActions/);
  assert.match(nativeSource, /responseActions\.like/);
  assert.match(nativeSource, /responseActions\.dislike/);
  assert.match(nativeSource, /good response/);
  assert.match(nativeSource, /bad response/);
  assert.match(nativeSource, /more actions/);
  assert.match(
    nativeSource,
    /responseActions\.branch \|\| responseActions\.moreActions/,
  );
  assert.match(nativeSource, /overflowOpened/);
  assert.match(nativeSource, /overflowCandidates/);
  assert.match(nativeSource, /approval_click_not_confirmed/);
  assert.match(nativeSource, /traceQueueApproval/);
  assert.match(nativeSource, /stage=approval-/);
  assert.match(nativeSource, /candidateLabels/);
  assert.match(nativeSource, /detectDedicatedAuthorizationJS/);
  assert.match(nativeSource, /sessionScopeLabels/);
  assert.match(nativeSource, /menuTriggerCount/);
  assert.match(nativeSource, /sessionScopeAvailable/);
  assert.match(nativeSource, /isAdjacentSplitControl/);
  assert.match(nativeSource, /session_scope_menu_opened/);
  assert.match(nativeSource, /session_scope_option/);
  assert.match(nativeSource, /autoApproveDedicatedAuthorizationJS\(\)/);
  assert.match(nativeSource, /pointer_events_unavailable/);
  assert.match(nativeSource, /cardFingerprint/);
  assert.match(nativeSource, /fnv1a32:/);
  assert.match(nativeSource, /Input\.dispatchMouseEvent/);
  assert.match(nativeSource, /retryActionsDesktopTransientError/);
  assert.match(nativeSource, /state\["authenticated"\] as\? Bool \?\? false/);
  assert.match(nativeSource, /controls\.flatMap\(element =>/);
  assert.match(nativeSource, /allowed\.has\(labelFor\(node\)\)/);
  assert.match(nativeSource, /session-scope/);
  assert.match(nativeSource, /session_scope_option_not_found/);
  assert.match(nativeSource, /dispatchPointerClick\(sessionControl\)/);
  assert.match(nativeSource, /dispatchPointerClick\(sessionOption\)/);
  assert.match(nativeSource, /sessionScopeLabel/);
  assert.match(nativeSource, /timeout: 8\.0/);
  assert.match(nativeSource, /strategy=per-card/);
  assert.match(
    nativeSource,
    /approval\?\["confirmed"\] as\? Bool == true[\s\S]*task\.lastError = nil[\s\S]*task\.lastProgressAt = now[\s\S]*return/,
  );
  assert.match(nativeSource, /approval-watcher-before/);
  assert.match(nativeSource, /approval-ipc-detected/);
  assert.match(nativeSource, /approval-.*-before/);
  assert.match(nativeSource, /yyyyMMdd-HHmmss-SSS/);
  assert.match(nativeSource, /retainedConversationDiagnosticCount = 5/);
  assert.match(nativeSource, /\.live\.json/);
  assert.match(nativeSource, /\.final\.json/);
  assert.match(nativeSource, /writeQueueConversationDiagnostic\(task\)/);
  assert.match(nativeSource, /finalReason: "terminal_observed"/);
  assert.match(nativeSource, /pruneQueueConversationDiagnostics/);
  assert.match(nativeSource, /data-content-search-unit-key\$=":assistant"/);
  assert.match(nativeSource, /data-content-search-unit-key\$=":user"/);
  assert.match(nativeSource, /const appUserBubbles =/);
  assert.match(nativeSource, /const appContentUsers =/);
  assert.match(
    nativeSource,
    /const appUsers = appContentUsers\.length > 0 \? appContentUsers : appUserBubbles/,
  );
  assert.doesNotMatch(
    nativeSource,
    /\[data-user-message-bubble\], '\s*\+\s*'\[data-content-search-unit-key/,
  );
  assert.match(nativeSource, /data-content-search-turn-key/);
  assert.match(nativeSource, /data-turn-key/);
  assert.match(nativeSource, /在新任务中继续|新任务/);
  assert.match(nativeSource, /queue_monitor_current_dispatch_marker_pending/);
  assert.match(nativeSource, /current_dispatch_marker_timeout/);
  assert.match(nativeSource, /stage=continuation-queued/);
  assert.match(nativeSource, /stage=terminal-observed/);
  assert.match(nativeSource, /queue_monitor_current_dispatch_marker_active/);
  assert.match(nativeSource, /page_stalled_but_response_active/);
  assert.match(nativeSource, /Never click Stop or close its renderer/);
  assert.match(nativeSource, /completedThinkingToggles/);
  assert.match(nativeSource, /completedSectionText/);
  assert.match(nativeSource, /completedActivity\.length > 0/);
  assert.match(nativeSource, /toolOnlyCompletedActivity/);
  assert.match(nativeSource, /explicitlyIncomplete/);
  assert.match(nativeSource, /terminalIncomplete/);
  assert.match(
    queueTerminalDecisionSource,
    /let terminalIncomplete = reply\["terminalIncomplete"\] as\? Bool == true[\s\S]*let completedResponseUI = responseActionsComplete[\s\S]*let terminalEvidence = completedResponseUI/,
  );
  assert.doesNotMatch(
    queueTerminalDecisionSource,
    /let terminalIncomplete = reply\["terminalIncomplete"\] as\? Bool == true\s*\|\|\s*reply\["explicitlyIncomplete"\]/,
  );
  assert.match(
    queueTerminalDecisionSource,
    /terminal: !responseIsInFlight && terminalEvidence/,
  );
  assert.match(
    queueMonitoringSource,
    /let responseIsInFlight = terminalDecision\.responseIsInFlight/,
  );
  assert.match(
    queueMonitoringSource,
    /if responseIsInFlight \{[\s\S]*page_stalled_but_response_active[\s\S]*return\s*\}\s*queueContinuation\(&task, report: nil, reason: "page_stalled"\)/,
  );
  assert.match(nativeSource, /chat_finished_incomplete/);
  assert.match(nativeSource, /MAHAYANA_TASK_REPORT_V1_BEGIN/);
  assert.match(nativeSource, /hasClosedTaskReport/);
  assert.match(nativeSource, /structuredIncomplete/);
  assert.match(nativeSource, /mahayana\.task-report\.v1/);
  assert.match(nativeSource, /relayFreshChatContinuation/);
  assert.match(nativeSource, /task_continuation_limit_reached/);
  assert.match(nativeSource, /task_continuation_started/);
  assert.match(nativeSource, /chat_surface_drift/);
  assert.match(nativeSource, /liveSurface\["chatMode"\]/);
  assert.match(nativeSource, /never approve or type on Work/);
  assert.match(nativeSource, /explicitFinalResult/);
  assert.match(
    nativeSource,
    /&& \(structuredComplete \|\| \(!explicitlyIncomplete && explicitFinalResult\)\)/,
  );
  assert.match(
    nativeSource,
    /structuredIncomplete \|\| \(!hasClosedTaskReport && explicitlyIncomplete\)/,
  );
  assert.match(
    queueMonitoringSource,
    /if terminal, hasClosedTaskReport, parsedReport == nil \{[\s\S]*stage=report-parse-failed action=continue[\s\S]*closed_task_report_not_fully_complete[\s\S]*queueContinuation[\s\S]*return/,
  );
  assert.match(nativeSource, /尚未\.\{0,12\}完成/);
  assert.match(nativeSource, /Date\(\)\.timeIntervalSince\(candidateSince\) >= 4\.0/);
  assert.doesNotMatch(nativeSource,
    /devspaceWaiting[^\n]*\n\s*\|\|[^\n]*devspaceActivity/);
});

test('task queue tools preserve dependencies, resource locks, review gate and concurrency', async () => {
  const queued = await call('enqueue_tasks', {
    tasks: [{
      id: 'release', title: '发布', prompt: '完成发布', connector: 'devspace1',
      dependsOn: [], resourceLocks: ['repo:fabushi'],
    }],
    maxConcurrent: 2,
    reviewGate: true,
  });
  const request = queued.result.structuredContent.hostRequest;
  assert.equal(request.capability, 'desktop.chatgpt-approvals.queue-enqueue');
  assert.equal(request.params.maxConcurrent, 2);
  assert.deepEqual(request.params.tasks[0].resourceLocks, ['repo:fabushi']);
  const wait = await call('wait_for_review', { timeout: 60 });
  assert.equal(wait.result.structuredContent.hostRequest.capability,
    'desktop.chatgpt-approvals.queue-wait-review');
  assert.equal(wait.result.structuredContent.hostRequest.approval, 'none');
  const reviewed = await call('review_task', {
    taskId: 'release', accepted: false, feedback: '补充安装包验证',
  });
  assert.equal(reviewed.result.structuredContent.hostRequest.capability,
    'desktop.chatgpt-approvals.queue-review');
  const retried = await call('retry_task', {
    taskId: 'release', feedback: '从最新落盘进度继续', connector: 'GitHub',
  });
  assert.equal(retried.result.structuredContent.hostRequest.capability,
    'desktop.chatgpt-approvals.queue-retry');
  const updated = await call('update_task', {
    taskId: 'release', revision: 2, expectedRevision: 1,
    specSources: ['docs/plugin-marketplace.md'],
    specSnapshot: 'updated marketplace requirements',
    specDigest: 'sha256:updated',
    directive: 'Use the latest marketplace architecture',
    applyMode: 'interrupt', source: 'miniapp-ui',
  });
  assert.equal(updated.result.structuredContent.hostRequest.capability,
    'desktop.chatgpt-approvals.queue-update');
  assert.equal(updated.result.structuredContent.hostRequest.params.revision, 2);
  assert.equal(updated.result.structuredContent.hostRequest.params.applyMode, 'interrupt');
  assert.equal(updated.result.structuredContent.hostRequest.params.source, 'miniapp-ui');
  assert.equal(retried.result.structuredContent.hostRequest.params.connector, 'GitHub');
  const actionsRunner = await call('start_actions_runner', {});
  assert.equal(actionsRunner.result.structuredContent.hostRequest.capability,
    'desktop.chatgpt-approvals.actions-runner-start');
  assert.equal(actionsRunner.result.structuredContent.hostRequest.approval, 'required');
  assert.match(nativeSource, /case "queue_retry"/);
  assert.match(nativeSource, /case "queue_update"/);
  assert.match(nativeSource, /case "start_actions_runner"/);
  assert.match(nativeSource, /case "queue_watchdog"/);
  assert.match(nativeSource, /case "queue_heartbeat"/);
  assert.match(nativeSource, /watcherWasAlive/);
  assert.match(nativeSource, /revisionWasCurrent/);
  assert.match(nativeSource, /queue_heartbeat_failed/);
  assert.match(nativeSource, /A retry starts a fresh Chat ownership cycle/);
  assert.match(nativeSource, /tasks\[index\]\.workerTargetId = nil/);
  assert.match(nativeSource, /没有找到与 conversationId 匹配的队列专用 Chat renderer/);
  assert.match(nativeSource, /tasks\[index\]\.workerTargetId = controller\.targetId/);
  assert.match(nativeSource, /state\.queueWorkerMode = sharedConversationQueueWorkerMode/);
  assert.match(nativeSource, /const matches = \[\.\.\.text\.matchAll/);
  assert.match(nativeSource, /任务发送轮次/);
  assert.match(nativeSource, /tasks\[index\]\.attempts = attachedAttempt/);
  assert.match(nativeSource, /let requestedAttempt = params\["attempt"\] as\? Int/);
  assert.match(nativeSource, /tasks\[index\]\.attempts = requestedAttempt/);
  assert.match(nativeSource, /queueChatStartTimeoutSeconds = 300/);
  assert.match(nativeSource, /verifyDispatchMarkerJS\(dispatchMarker: dispatchMarker\)/);
  assert.match(nativeSource, /guard dispatchVerified else/);
  assert.match(nativeSource, /let previousTaskConversationId = tasks\[index\]\.conversationId/);
  assert.match(nativeSource, /tasks\[index\]\.conversationId = conversationId/);
  assert.match(nativeSource, /tasks\[index\]\.dispatchLocalConversationId = attachedLiveConversationId/);
  assert.match(nativeSource, /let freshChatRecoveryReasons = \["chat_start_no_reply", "page_stalled"\]/);
  assert.match(nativeSource, /let requiresFreshRecoveryChat = freshChatRecoveryReasons\.contains/);
  assert.doesNotMatch(chatScriptsSource, /existingBranch: true/);
  assert.doesNotMatch(nativeSource, /stage=continuation-blocked/);
  assert.match(nativeSource, /durableTaskBindingMatches/);
  assert.match(nativeSource, /hasTaskMarker/);
  assert.match(nativeSource, /textLength > 100, hasInput/);
  assert.match(nativeSource, /\[role="textbox"\]/);
  assert.match(nativeSource, /serial-shared-controller-reuse/);
  assert.match(nativeSource, /profilePath == hiddenChatProfilePath\(\)/);
  assert.match(nativeSource, /current-dispatch-marker/);
  assert.match(nativeSource, /dispatchMarkerConfirmed/);
  assert.match(nativeSource, /promoted-marker-conversation/);
  assert.match(nativeSource, /dispatchMarker: "任务发送轮次：\\\(task\.attempts\)"/);
  assert.match(nativeSource, /github_actions_watchdog_recovery/);
  assert.match(nativeSource, /operator_recovery/);
  assert.match(nativeSource, /case "queue_watch"/);
  assert.match(nativeSource, /resourceLocks/);
  assert.match(nativeSource, /dependsOn/);
  assert.match(nativeSource, /awaiting_review/);
  assert.match(nativeSource, /reviewFeedback/);
  assert.match(nativeSource, /worker_exited_without_result/);
  assert.match(nativeSource, /monitorAutomationTask/);
  assert.match(nativeSource, /virtual-list parent/);
  assert.doesNotMatch(nativeSource, /let continuationLimit = max\(1, task\.maxTaskContinuations\)/);
  assert.match(nativeSource, /do not use it as a lifetime limit/);
  assert.doesNotMatch(nativeSource, /approval_duplicate_circuit_open/);
  assert.match(nativeSource, /confirmed-renderer-ghost/);
  assert.match(nativeSource, /confirmed_approval_renderer_ghost_ignored/);
  assert.match(nativeSource, /boundedContent/);
  assert.match(nativeSource, /value\.slice\(-25000\)/);
  assert.match(nativeSource, /let controllerIsSafe = runtimeState == \.hidden/);
  assert.match(nativeSource, /unassigned-controller-fallback-begin/);
  assert.match(nativeSource, /approval_rate_circuit_open/);
  assert.match(nativeSource, /background_chat_closed_requires_restart/);
  assert.doesNotMatch(nativeSource, /queue_worker_closed_requires_retry/);
  assert.match(nativeSource, /CHATGPT_AUTO_CONFIRM_ALLOW_VISIBLE_AX/);
  assert.match(nativeSource, /requestIdentityAvailable/);
  assert.match(nativeSource, /watchdogTaskHasNonRecoverableFailure/);
  assert.match(nativeSource, /connector_selection_not_confirmed/);
  assert.match(nativeSource, /activeConversationId is shared by every visible row/);
  assert.match(nativeSource, /getAttribute\('aria-current'\) === 'page'/);
  assert.match(nativeSource, /activeRowConversationIds/);
  assert.match(nativeSource, /userContent: boundedContent\(userContent\)/);
  assert.match(nativeSource, /identitySource == "portal"/);
  assert.match(nativeSource, /conversationSource/);
  assert.match(nativeSource, /const conversationId = portalConversationId\s*\n\s*\|\| routeConversationId\s*\n\s*\|\| activeConversationId/);
  assert.match(nativeSource, /dispatchMarkerVerifiedAt/);
  assert.match(nativeSource, /dispatchLocalConversationId/);
  assert.match(nativeSource, /attachedConversationWithoutDispatchMarker/);
  assert.match(nativeSource, /operatorTaskBindingMatches/);
  assert.match(nativeSource, /verifiedDispatchConversationBinding/);
  assert.match(nativeSource, /hasCurrentDispatchEvidence/);
  assert.match(nativeSource, /freshly prepared blank Chat owns a stable local id/);
  assert.match(nativeSource, /never replace a local id with/);
  assert.match(nativeSource, /appendTextPreservingConnector/);
  assert.match(nativeSource, /model_picker_not_found/);
  assert.match(nativeSource, /use standard speed/);
  assert.match(nativeSource, /使用标准速度/);
  assert.match(nativeSource, /neutralPromoLabels/);
  assert.match(nativeSource, /const isProjectPicker = button =>/);
  assert.match(nativeSource, /top-level Chat\/Work switch is authoritative/);
  assert.match(nativeSource, /const workComposer = !quickRoot[\s\S]*data-codex-composer/);
  assert.match(nativeSource, /stale Work[\s\S]*transient flag/);
  assert.match(nativeSource, /confirmedChatMode: chatSelection\?\["alreadySelected"\]/);
  assert.match(nativeSource, /High5\.6 SolMedium/);
  assert.match(nativeSource, /label\.includes\('chatgpt 模型'\)/);
  assert.match(nativeSource, /const explicit = \[\.\.\.scope\.querySelectorAll\(/);
  assert.match(nativeSource, /const explicit = \[\.\.\.scope\.querySelectorAll\([\s\S]*?const textMatch/);
  assert.match(nativeSource, /const textMatch[\s\S]*?const popupButton/);
  assert.match(nativeSource, /isProjectPicker\(button\)/);
  assert.match(nativeSource, /reasoning_high_not_selected/);
  assert.match(nativeSource, /quick_chat_thinking_not_selected/);
  assert.match(nativeSource, /quick_chat_target_model_not_selected/);
  assert.match(nativeSource, /quickChatModelConfirmed = desiredModelMentioned/);
  assert.match(nativeSource, /const desiredQuickChatReasoning = 'Extra High'/);
  assert.match(nativeSource, /const desiredReasoning = 'Extra High'/);
  assert.match(nativeSource, /本轮发送前小程序必须重新选择并确认模型/);
  assert.match(nativeSource, /GitHub 代码源（每轮都必须明确使用）/);
  assert.match(nativeSource, /本轮工作门槛/);
  assert.match(nativeSource, /quick-chat-extra-high-selection/);
  assert.match(nativeSource, /submenuExtraHighSelected: true/);
  assert.match(nativeSource, /const scope = quickChatRoot\(\) \|\| document;/);
  assert.match(nativeSource, /allPrefixedModelChoices\('Extra High'\)/);
  assert.match(nativeSource, /quickChatKeyboardTarget/);
  assert.match(nativeSource, /quickChatSliderElements/);
  assert.match(nativeSource, /data-reasoning-slider/);
  assert.match(nativeSource, /quickChatSelectionConfirmed/);
  assert.match(nativeSource, /max - 1/);
  assert.match(nativeSource, /quickChatSelectionEvidence/);
  assert.match(nativeSource, /dispatchQuickChatEnter/);
  assert.match(nativeSource, /modelSelectionEvidence/);
  assert.match(nativeSource, /dispatchQuickChatArrowRight/);
  assert.match(nativeSource, /Input\.dispatchKeyEvent/);
  assert.match(nativeSource, /selectExtraHighReasoningWithTrustedCDP/);
  assert.match(nativeSource, /quick-chat-thinking-keyboard-selection/);
  assert.match(nativeSource, /dispatchPointerClick\(picker\)/);
  assert.match(nativeSource, /model switcher is a Radix trigger/);
  assert.match(nativeSource, /quickChatStrongMode/);
  assert.match(nativeSource, /composer\?\.contains\(left\)/);
  assert.doesNotMatch(nativeSource, /pickerEvidence: 'quick-chat-host-selection'/);
  assert.match(nativeSource, /pickerEvidence: 'selected_button_state'/);
  assert.match(nativeSource, /selectedLabel === 'extra high'/);
  assert.match(nativeSource, /allExactModelChoices\('Extra High'\)/);
  assert.match(nativeSource, /selectedLabel === '极高'/);
  assert.doesNotMatch(nativeSource, /pickerEvidence: "Bypassed"/);
  assert.match(nativeSource, /createQueueWorkerTarget/);
  assert.match(nativeSource, /queueWorkerProfilePath/);
  assert.match(nativeSource, /parallel-dedicated-hidden-chat-processes/);
  assert.match(nativeSource,
    /let maxConcurrent = min\(4, max\(1, state\.queueMaxConcurrent \?\? 2\)\)/);
  assert.match(nativeSource, /createIndependentQueueWorkerTarget/);
  assert.match(nativeSource, /targetId != controllerTargetId/);
  assert.match(nativeSource,
    /queueAllowsVisibleDedicatedRenderer\(\) && !runningOnGitHubActions\(\)/);
  assert.match(nativeSource, /headless-parallel-hidden-window-begin/);
  assert.match(nativeSource, /headless-parallel-hidden-window-complete/);
  assert.match(nativeSource, /parallel-headless-chat-windows/);
  assert.match(nativeSource, /openHeadlessParallelQueueWindow/);
  assert.match(nativeSource, /Target.createTarget/);
  assert.match(nativeSource, /headless-window-target-ready/);
  assert.match(nativeSource, /dedicated-hosted-profile/);
  assert.match(nativeSource, /hostedPersistentQueueUsesPrewarmWorker/);
  assert.match(nativeSource, /hosted-prewarm-worker-begin/);
  assert.match(nativeSource, /hosted-prewarm-worker-complete/);
  assert.match(nativeSource, /model-selection-before/);
  assert.match(nativeSource, /model-selection-failed/);
  assert.match(nativeSource, /writeQueueConversationDiagnostic\(task, finalReason: "start_failed"\)/);
  assert.match(nativeSource, /CHATGPT_AUTO_CONFIRM_PARALLEL_STATE/);
  assert.match(nativeSource, /launchDedicatedQueueChatProcessViaLaunchServices/);
  assert.match(nativeSource, /dedicated-launchservices-first-start/);
  assert.match(nativeSource, /effectiveAccountId == hostedAccountId/);
  assert.match(nativeSource, /dedicated-avatar-overlay-navigation/);
  assert.match(nativeSource, /dedicated-empty-shell-navigation/);
  assert.match(nativeSource, /dedicated-chat-target-timeout/);
  assert.match(nativeSource, /dedicatedRendererTargetExists/);
  assert.match(nativeSource, /boundedDedicatedRendererTargets/);
  assert.match(nativeSource, /boundedDedicatedRendererTargetExists/);
  assert.match(nativeSource, /CDPClient\.fetchTargets\(portOverride: port\)/);
  assert.match(nativeSource, /fetchTargetsOverLocalSocket/);
  assert.match(nativeSource, /Darwin\.socket\(AF_INET, SOCK_STREAM, 0\)/);
  assert.match(nativeSource, /transfer-encoding: chunked/);
  assert.match(nativeSource, /9330\.\.\.9380/);
  assert.match(nativeSource, /dedicatedRendererTargetSummary/);
  assert.match(nativeSource, /dedicatedRendererBootstrapTimeout/);
  assert.match(nativeSource, /let dedicatedRendererBootstrapTimeout: TimeInterval = 20\.0/);
  assert.match(nativeSource, /dedicated-process-renderer-timeout/);
  assert.match(nativeSource, /dedicated-renderer-bootstrap-recovery/);
  assert.match(nativeSource, /dedicated-interactive-shell-navigation/);
  assert.match(nativeSource, /ready == "interactive"/);
  assert.match(nativeSource, /interactiveNavigationCount < 2/);
  assert.match(nativeSource, /Do not replace a document that is still naturally loading/);
  assert.match(nativeSource, /dedicated-process-bootstrap-attempt/);
  assert.match(nativeSource, /dedicated-process-bootstrap-retry/);
  assert.match(nativeSource, /dedicatedTaskWorkerProcessRecords/);
  assert.match(nativeSource, /profileTail\.range\(of: " --"\)/);
  assert.doesNotMatch(nativeSource, /profileTail\.prefix \{ !\$0\.isWhitespace \}/);
  assert.match(
    nativeSource,
    /data = output\.fileHandleForReading\.readDataToEndOfFile\(\)[\s\S]*process\.waitUntilExit\(\)/,
  );
  assert.match(nativeSource, /processReservedPorts/);
  assert.match(nativeSource, /dedicated-process-bootstrap-launchservices/);
  assert.match(
    nativeSource,
    /bootstrapAttempt == 1[\s\S]*launchDedicatedQueueChatProcess\([\s\S]*else \{[\s\S]*launchDedicatedQueueChatProcessViaLaunchServices/,
  );
  assert.match(nativeSource, /dedicated-process-terminate-force/);
  assert.match(nativeSource, /dedicated-process-terminated/);
  assert.match(nativeSource, /dedicated-process-terminate-failed/);
  assert.match(nativeSource, /let shouldNavigate = \(/);
  assert.match(nativeSource, /ready == "complete"/);
  assert.match(nativeSource, /setHiddenPageFocusEmulation/);
  assert.match(nativeSource, /bringPageToFront/);
  assert.match(nativeSource, /probeBridge=/);
  assert.match(nativeSource, /single-process-hidden-chat-conversations/);
  assert.match(nativeSource, /single-process-hidden-chat-windows/);
  assert.match(nativeSource, /createDedicatedParallelQueueWorkerTarget/);
  assert.match(nativeSource, /copyProfileForDedicatedQueueWorker/);
  assert.match(nativeSource, /launchDedicatedQueueChatProcess/);
  assert.match(nativeSource, /Applications\/ChatGPT\.app\/Contents\/MacOS\/ChatGPT/);
  assert.match(nativeSource, /var dedicatedQueueChatLaunchers: \[Int: Process\] = \[:\]/);
  assert.match(nativeSource, /dedicatedQueueChatLaunchers\[port\] = launcher/);
  const dedicatedLaunch = nativeSource.match(
    /func launchDedicatedQueueChatProcess[\s\S]*?(?=\nfunc dedicatedQueueChatTarget)/,
  )?.[0] ?? '';
  assert.doesNotMatch(dedicatedLaunch, /launcher\.run\(\)\s*launcher\.waitUntilExit\(\)/);
  assert.match(nativeSource, /existingApplicationPids/);
  assert.match(nativeSource, /application\.hide\(\)/);
  assert.match(nativeSource, /application\.isHidden/);
  assert.match(nativeSource, /dedicated-process-launched/);
  assert.match(nativeSource, /dedicated-headless-probe-deferred/);
  assert.match(nativeSource, /configuration\.hides = false/);
  assert.match(nativeSource, /initialRoute=%2F/);
  assert.match(nativeSource, /func queueAllowsVisibleDedicatedRenderer\(\)/);
  assert.match(nativeSource, /CHATGPT_AUTO_CONFIRM_HEADLESS/);
  assert.match(nativeSource, /dedicated-chat-target-visible-headless/);
  assert.match(nativeSource, /approveHeadlessChatGPTLocalNetworkPrompt/);
  assert.match(nativeSource, /clickCompactChatGPTLocalNetworkWindowViaQuartz/);
  assert.match(nativeSource, /CGWindowListCopyWindowInfo/);
  assert.match(nativeSource, /dedicated-native-local-network-geometry-detected/);
  assert.match(nativeSource, /runningApplications\.contains/);
  assert.match(nativeSource, /dedicated-native-local-network-screen-fallback/);
  assert.match(nativeSource, /find devices on local networks/);
  assert.match(nativeSource, /AXSystemDialog/);
  assert.match(nativeSource, /key code 36/);
  assert.match(nativeSource, /dedicated-native-local-network-permission-allowed/);
  assert.match(nativeSource, /dedicated-avatar-overlay-retire/);
  assert.match(nativeSource, /nativePromptApprovalObserved/);
  assert.match(nativeSource, /button \"Allow\"/);
  assert.match(nativeSource, /unhideDedicatedProcessForPort/);
  assert.match(nativeSource, /Target\.activateTarget/);
  assert.match(nativeSource, /dedicated-visible-renderer-wake/);
  assert.match(nativeSource, /blankNavigationCount < 3/);
  assert.match(nativeSource, /queueTargetStateIsUsableForQueue/);
  assert.match(nativeSource, /stage=dedicated-process-hidden/);
  assert.match(nativeSource, /parallelDedicatedProcessQueueWorkerMode/);
  assert.match(nativeSource, /CHATGPT_AUTO_CONFIRM_PROFILE_PATH/);
  assert.match(nativeSource, /configuredHiddenChatProfilePath\(\)/);
  assert.match(nativeSource, /launcher\.processIdentifier/);
  assert.match(nativeSource, /activate\(options: \[\.activateIgnoringOtherApps\]\)/);
  assert.match(nativeSource, /"conversationId": task\.conversationId/);
  assert.match(nativeSource, /stableSamples >= 3/);
  assert.match(nativeSource, /openBackgroundQueueWindow\(/);
  assert.match(nativeSource, /controllerTargetId: controller\.targetId/);
  assert.match(nativeSource, /prewarm_reset_failed/);
  assert.match(nativeSource, /prewarm_hidden_chat_surface_timeout/);
  assert.match(nativeSource, /candidateLabels/);
  assert.match(nativeSource, /switch mode, current mode:/);
  assert.match(nativeSource, /dispatchPointerClick\(modeSwitch\)/);
  assert.match(nativeSource, /new PointerEvent\('pointerdown'/);
  assert.match(nativeSource, /const isChatLabel = label => label === 'chat'/);
  assert.match(nativeSource, /const explicitChatTab = modeTabs\(\)/);
  assert.match(nativeSource, /surface\.workComposer && explicitChatTab/);
  assert.match(nativeSource, /plugin sender never reaches the Chat surface/);
  assert.match(nativeSource, /persisted-atom-update/);
  assert.match(nativeSource, /home-composer-mode-v1/);
  assert.match(nativeSource, /force-persisted-mode/);
  assert.match(nativeSource, /func forcePrimaryComposerModeJS\(_ requestedMode: String\)/);
  assert.match(nativeSource, /func clickCodexModeJS\(\)/);
  assert.match(nativeSource, /normalize\(child\.textContent\) === 'codex'/);
  assert.match(nativeSource, /expression: clickCodexModeJS\(\)/);
  assert.match(nativeSource, /reset-stale-mode begin/);
  assert.match(nativeSource, /expression: composerSurfaceStateJS\(\)/);
  assert.doesNotMatch(nativeSource, /includeChatGPT && label === 'chatgpt'/);
  assert.match(nativeSource, /const isChatGPTMenuChoice = candidate =>/);
  assert.match(nativeSource, /role === 'menuitemradio'/);
  assert.match(nativeSource, /candidate\.closest\('\[role="menu"\], \[role="listbox"\]'\)/);
  assert.match(nativeSource, /labelsFor\(candidate\)\.some\(label => label === 'chatgpt'\)/);
  assert.match(nativeSource, /normalize\(child\.textContent\) === 'chatgpt'/);
  assert.match(nativeSource, /error: 'mode_switch_dispatched'/);
  assert.match(nativeSource, /retryAfterModeSwitch: true/);
  assert.match(nativeSource, /__mahayanaChatModeSwitchAttempted/);
  assert.doesNotMatch(nativeSource, /\[\.\.\.candidates\(\)\]\.reverse\(\)\.find/);
  assert.match(nativeSource, /label\.includes\('current mode: chatgpt'\)/);
  assert.match(nativeSource,
    /'new chat', '新聊天', 'new conversation', '新对话',[\s\S]*'new task', '新建任务', '新任务'/);
  assert.match(nativeSource, /button\.innerText,[\s\S]*button\.getAttribute\('title'\)/);
  assert.match(nativeSource, /alreadySelected: true/);
  assert.match(nativeSource, /__mahayanaConfirmedChatGPTMode = true/);
  assert.match(nativeSource, /__mahayanaConfirmedChatGPTMode === true/);
  assert.doesNotMatch(nativeSource,
    /destroyed execution context[\s\S]*__mahayanaConfirmedChatGPTMode = true/);
  assert.match(nativeSource, /confirmedChatMode: Bool = false/);
  assert.match(nativeSource, /if \(confirmedChatMode\) window\.__mahayanaConfirmedChatGPTMode = true/);
  assert.doesNotMatch(nativeSource, /confirmedChatMode: chatSelection\?\["ok"\] as\? Bool == true/);
  assert.match(nativeSource, /chatSelection\?\["retryAfterModeSwitch"\] as\? Bool == true/);
  assert.match(nativeSource, /chatSelected: true,[\s\S]*dispatchOnly: true/);
  assert.match(nativeSource, /negative preflight[\s\S]*must not leave every task queued forever/);
  assert.match(nativeSource, /watcher-trace\.log/);
  assert.match(nativeSource, /stage=prepare-new-chat/);
  assert.match(nativeSource, /label === 'quick chat'/);
  assert.match(nativeSource, /data-pip-obstacle="quick-chat"/);
  assert.match(nativeSource, /prewarm_hidden_target_not_chat/);
  assert.match(nativeSource, /entryScripts/);
  assert.match(nativeSource, /prewarmCreationFailure/);
  assert.doesNotMatch(nativeSource, /hosted_chat_login_required|actionsWebLoginState/);
  assert.doesNotMatch(nativeSource, /CDPClient\.createTarget\([\s\S]{0,300}https:\/\/chatgpt\.com/);
  assert.match(nativeSource, /desktop_prewarm_reset_failed/);
  assert.match(nativeSource, /conversation_changed_before_send/);
  assert.match(nativeSource, /conversation_changed_during_send/);
  assert.match(nativeSource, /conversation_changed_before_dispatch/);
  assert.match(nativeSource,
    /state\.queueWorkerMode != sharedConversationQueueWorkerMode,[\s\S]*CDPClient\.closeTarget/);
  assert.match(nativeSource, /configuredHiddenChatPort\(\)/);
  assert.match(nativeSource, /"activeWorkers": activeWorkers/);
  assert.match(nativeSource, /single-process-hidden-prewarm/);
  assert.match(nativeSource, /isolated-dedicated-process/);
  assert.match(nativeSource, /stopQueueWorker/);
  assert.match(nativeSource, /startAutomationReview/);
  assert.match(nativeSource, /reviewConversationId/);
  assert.match(nativeSource, /chat_review_\\\(report\.status\)/);
  assert.match(nativeSource, /app:\/\/-\/index\.html/);
  assert.doesNotMatch(nativeSource, /existing-process-hidden-target/);
  assert.match(nativeSource, /quickChatPrewarmServiceJS/);
  assert.match(nativeSource, /reset-prewarm/);
  assert.match(nativeSource, /renderer-ready/);
  assert.match(nativeSource, /quick-chat-prewarm/);
  assert.match(nativeSource, /hiddenAppURL = "app:\/\/-\/index\.html\?initialRoute=%2F"/);
  assert.match(nativeSource, /Quick Chat itself is feature-gated per account/);
  assert.match(nativeSource, /safeText=/);
  assert.match(nativeSource, /selectionLabels=/);
  assert.match(nativeSource, /continueHiddenOnboardingJS/);
  assert.match(nativeSource, /desktop app's informational onboarding/);
  assert.match(nativeSource, /'go to chatgpt'.*'skip'/s);
  assert.match(nativeSource, /querySelectorAll\('button, a, \[role="button"\]'\)/);
  assert.doesNotMatch(nativeSource, /'turn on'.*'not now'/);
  assert.match(nativeSource, /routeMatches=/);
  assert.match(nativeSource, /Page\.setWebLifecycleState/);
  assert.match(nativeSource, /Emulation\.setFocusEmulationEnabled/);
  assert.match(nativeSource, /Emulation\.setIdleOverride/);
  assert.match(nativeSource, /eventLoopDelayMs/);
  assert.match(nativeSource, /setTimeout\(resolve, 50\)/);
  assert.match(nativeSource, /eventLoopDelayMs < 2_500/);
  assert.match(nativeSource, /wakeHiddenRenderer/);
  assert.match(nativeSource, /func wakeHiddenQueueRenderer/);
  assert.match(nativeSource, /timeout: TimeInterval = 12\.0/);
  assert.match(nativeSource, /prewarm-renderer-wake timeout/);
  assert.match(nativeSource, /discoveryDeadline = discoveryStartedAt\.addingTimeInterval\(30\.0\)/);
  assert.match(nativeSource, /while Date\(\) < discoveryDeadline/);
  assert.doesNotMatch(nativeSource, /for _ in 0\.\.<120/);
  assert.match(nativeSource, /document\.dispatchEvent\(new Event\('visibilitychange'\)\)/);
  assert.match(nativeSource, /window\.dispatchEvent\(new Event\('focus'\)\)/);
  assert.match(nativeSource, /Visibility is therefore diagnostic rather than a hard requirement/);
  assert.match(nativeSource, /parallelDedicatedProcessQueueWorkerMode/);
  assert.match(nativeSource, /A fresh parallel task must never fall back to a renderer/);
  assert.match(nativeSource, /Each parallel task owns a fresh plugin Chat BrowserWindow/);
  assert.match(nativeSource, /visibility == "hidden"/);
  assert.match(nativeSource, /queueTargetIsHidden/);
  assert.match(nativeSource, /queue_worker_visibility_not_hidden/);
  assert.match(nativeSource, /queueOwnedSharedControllerVisible/);
  assert.match(nativeSource, /queue-owned-shared-controller-visible-accepted/);
  assert.match(nativeSource, /state\.backgroundProfilePath == hiddenChatProfilePath\(\)/);
  assert.match(nativeSource, /Missing, suspended, and non-Chat renderers are disposable/);
  assert.match(nativeSource, /queue_monitor_hidden_target_rebuild_failed/);
  assert.match(nativeSource, /queue_monitor_hidden_target_recovery_failed/);
  assert.match(nativeSource, /queue_monitor_hidden_target_recreated_without_durable_conversation/);
  assert.match(nativeSource, /runtimeState == \.hiddenNonChat/);
  assert.match(nativeSource, /expression: clickChatJS\(\)/);
  assert.match(nativeSource, /if runtimeState == \.visible/);
  assert.match(nativeSource,
    /closeDedicatedAutomationTarget\(task, state: state\)[\s\S]*createIndependentQueueWorkerTarget\(&state\)/);
  assert.match(nativeSource, /hiddenWorkerLastHeartbeatAt/);
  assert.match(nativeSource, /hiddenWorkerRecoveryCount/);
  assert.match(nativeSource, /"runtimeState": workerRuntimeState\.map\(queueTargetRuntimeStateName\)/);
  assert.match(nativeSource, /"visibilityVerified": workerVisibilityVerified/);
  assert.doesNotMatch(nativeSource, /openNewWindowUsingApplicationMenu/);
  assert.doesNotMatch(nativeSource, /kAXMinimizedAttribute/);
  assert.match(nativeSource, /state\.queueWorkerTargetId/);
  assert.match(nativeSource, /queue_monitor_requires_background_window/);
  assert.match(nativeSource, /deferAutomationTaskForWorkerRecovery/);
  assert.match(nativeSource, /waiting_for_queue_worker_recovery/);
  assert.match(nativeSource, /worker-recovery-deferred/);
  assert.match(nativeSource, /let delay = min\(300, 15 \* \(1 << min\(4, recoveryCount - 1\)\)\)/);
  assert.match(nativeSource, /let hasPendingQueueWork = tasks\.contains/);
  assert.match(nativeSource, /\$0\.status == "queued" \|\| \$0\.status == "running" \|\| \$0\.status == "waiting"/);
  assert.match(nativeSource, /only while idle/);
  assert.match(nativeSource, /!hasPendingQueueWork/);
  assert.doesNotMatch(nativeSource, /stopLegacyQueueResponseIfStillOwned/);
  assert.match(nativeSource, /closeDedicatedAutomationTarget/);
  assert.match(nativeSource, /page where the user is composing a new task/);
  assert.match(nativeSource, /实际工作只允许在 Chat 页面完成/);
  assert.match(nativeSource, /chatOnlyInstruction/);
  assert.match(nativeSource, /app:\/\/\-\/index\.html/);
  assert.match(nativeSource, /queue_monitor_conversation_drift/);
  assert.match(nativeSource, /fresh_chat_body_pending_timeout/);
  assert.match(nativeSource, /Wait for the dispatch marker instead of pausing every queued/);
  assert.match(nativeSource, /selectBackgroundConversationJS\(conversationId\)/);
  assert.match(nativeSource, /parse a stale page as the active task/);
  assert.match(nativeSource, /任务发送轮次/);
  assert.match(nativeSource, /验收 Chat 标识/);
  assert.match(nativeSource, /dispatchMarker/);
  assert.match(nativeSource, /resolveDispatchedConversationJS/);
  assert.match(nativeSource, /expectedLocalId/);
  assert.match(nativeSource, /local-row-mapping/);
  assert.match(nativeSource, /exact local->durable mapping/);
  assert.match(nativeSource, /a\[href\*=\"\/c\/\"\]/);
  assert.match(nativeSource, /\(\?:c\|work\\\/conversation\)/);
  assert.match(nativeSource, /!observed\.hasPrefix\("local-chatgpt:"\)/);
  assert.match(nativeSource, /portal-local/);
  assert.match(nativeSource, /prewarm-transient-error-retry/);
  assert.match(nativeSource, /new Set\(\['try again', '重试', '再试一次'\]\)/);
  assert.match(nativeSource, /transientErrorRetryCount < 3/);
  assert.match(nativeSource, /hosted-headless-window-fallback-begin/);
  assert.match(nativeSource, /hosted-controller-fallback-begin/);
  assert.match(nativeSource, /unassigned-controller-fallback-begin/);
  assert.match(nativeSource, /mayReuseSerialSharedController/);
  assert.match(nativeSource, /targetId == state\.queueWorkerTargetId/);
  assert.match(nativeSource, /unassigned_controller_fallback=/);
  assert.match(nativeSource, /environment\["CHATGPT_AUTO_CONFIRM_HEADLESS"\] = "1"/);
  assert.match(nativeSource, /general confirmer has already proved that exact renderer is plugin-owned/);
  assert.match(nativeSource, /createSharedControllerQueueWorkerTarget/);
  assert.match(nativeSource, /hosted_controller_unavailable_or_busy/);
  assert.match(nativeSource, /state\.queueWorkerMode = sharedConversationQueueWorkerMode/);
  assert.match(nativeSource,
    /queueAllowsVisibleDedicatedRenderer\(\)[\s\S]*?workerMode == sharedConversationQueueWorkerMode/);
  assert.match(nativeSource, /initialChatReady/);
  assert.match(nativeSource, /Work-to-Chat transition/);
  assert.match(nativeSource, /createHeadlessParallelQueueWorkerTarget\(&state\)/);
  assert.match(nativeSource, /hosted_headless_fallback=/);
  assert.match(nativeSource, /first id absent from the baseline.*is unsafe/);
  assert.doesNotMatch(nativeSource, /source: 'new-sidebar-row'/);
  assert.match(nativeSource, /durable_conversation_id_pending/);
  assert.doesNotMatch(nativeSource, /selectBackgroundConversationJS\(resolvedConversationId\)/);
  assert.match(nativeSource, /navigateHiddenConversation/);
  assert.match(nativeSource, /restoreHiddenConversation/);
  assert.match(nativeSource, /backgroundConversationURL/);
  assert.match(nativeSource, /initialRoute/);
  assert.match(nativeSource, /重新读取共享执行技能/);
  assert.match(nativeSource, /不要重新规划、不要只检查结果、不要中途总结/);
  assert.match(nativeSource, /refreshAutomationTaskDefinitionFromDisk/);
  assert.match(nativeSource, /task-definition-refreshed/);
  assert.match(nativeSource, /action=fresh-project-chat/);
  assert.match(nativeSource, /这是更新后的新目标首轮/);
  assert.match(nativeSource, /不复用旧目标内容/);
  assert.match(nativeSource, /目标：\\n/);
  assert.match(nativeSource, /任务目录：/);
  assert.match(nativeSource, /仓库项目目录尚未登记/);
  assert.match(nativeSource, /目标\/范围、架构、执行任务、验收标准和证据文档/);
  assert.match(nativeSource, /只有整个仓库项目全部完成时才输出末尾唯一的完成证书/);
  assert.doesNotMatch(nativeSource, /第一轮、续作轮和验收轮开始时都必须用 Gmail 按任务 id 只读检查/);
  assert.match(nativeSource, /continuation-backoff/);
  assert.match(nativeSource, /wait_seconds/);
  assert.match(nativeSource, /waiting_for_external_result/);
  assert.match(nativeSource, /waiting_for_network_recovery/);
  assert.match(nativeSource, /queueNetworkRecovery/);
  assert.match(nativeSource, /SCNetworkReachabilityCreateWithName/);
  assert.match(nativeSource, /request failed with status 429/);
  assert.match(nativeSource, /too many requests/);
  assert.match(nativeSource, /network-rate-limit-wait/);
  assert.match(nativeSource, /recoverySignal == nil/);
  assert.match(nativeSource, /next_connector/);
  assert.match(nativeSource, /sharedTaskExecutionSkillPath/);
  assert.match(nativeSource, /实际工作只允许在 Chat 页面完成/);
  assert.match(nativeSource, /the prompt can never trigger a false network outage/);
  assert.match(nativeSource, /chat_start_no_reply/);
  assert.match(nativeSource, /allowBlankConversationReuse: false/);
  assert.doesNotMatch(nativeSource, /allowBlankConversationReuse: !preserveStalledChat/);
  assert.match(nativeSource, /currentDate >= waitingUntil/);
  assert.match(nativeSource, /Confirm it before restoring a task through its exact plugin-owned Chat route/);
  assert.match(nativeSource, /Do not restore the background queue renderer before its current page is read/);
});

test('native runtime stays on the exact plugin Chat target and never takes over the UI', () => {
  const backgroundNativeSource = nativeSource.replace(
    /func activateChatGPTForLogin\(\) \{[\s\S]*?\n\}\n\nfunc waitForActionsLoginTarget/,
    'func waitForActionsLoginTarget',
  ).replace(
    /func unhideDedicatedProcessForPort\([\s\S]*?\) -> Bool \{[\s\S]*?\n\}\n\nfunc dedicatedQueueChatTarget/,
    'func dedicatedQueueChatTarget',
  );
  assert.match(nativeSource, /AXUIElementPerformAction\(candidate\.element, kAXPressAction/);
  assert.match(nativeSource, /AXPress 已发送，等待授权卡消失/);
  assert.match(nativeSource, /reconcilePendingApprovals/);
  assert.match(nativeSource, /"AXVisibleOnly": true/);
  assert.doesNotMatch(nativeSource, /"AXVisibleOnly": false/);
  assert.match(nativeSource, /where application\.isActive/);
  assert.match(nativeSource, /isActuallyVisible\(button, inside: activeWindow\)/);
  assert.match(nativeSource, /axPressVisibleForegroundOnly/);
  assert.match(nativeSource, /axPressNeverTargetsHiddenElements/);
  assert.match(nativeSource, /dismissHistoryOverlay\(covering: candidate\)/);
  assert.doesNotMatch(nativeSource, /CGWarpMouseCursorPosition|postToPid/);
  assert.match(nativeSource, /clickCompactChatGPTLocalNetworkWindowViaQuartz/);
  assert.match(nativeSource, /mouseDown\.post\(tap: \.cghidEventTap\)/);
  assert.match(nativeSource, /application\.activate\(options: \[\.activateIgnoringOtherApps\]\)/);
  assert.doesNotMatch(backgroundNativeSource, /\.activate\s*\(|postToPid|kAXFocusedAttribute/);
  assert.doesNotMatch(nativeSource,
    /navigateChat|scanTargetChats|sweepHiddenChats|sidebarTaskButton|switchApplicationMode/);
  assert.doesNotMatch(nativeSource, /sensitiveTerms|blockedSensitive/);
  assert.match(nativeSource, /Target\.createTarget/);
  assert.match(nativeSource, /Target\.getTargetInfo/);
  assert.match(nativeSource, /browserContextId/);
  assert.match(nativeSource, /\\"background\\":true/);
  assert.match(nativeSource, /invokeInternalApproval/);
  assert.match(nativeSource, /__reactProps\$/);
  assert.match(nativeSource, /"internalActionIsPrimary": true/);
  assert.match(nativeSource, /"operatesHiddenPages": true/);
  assert.match(nativeSource, /loadedApprovalTargets/);
  assert.match(nativeSource, /"scansEveryLoadedRenderer": false/);
  assert.match(nativeSource, /"visibleRendererAccess": isVisible && queueAllowsVisibleDedicatedRenderer\(\)/);
  assert.match(nativeSource, /"operatesVisiblePluginPages": isVisible && queueAllowsVisibleDedicatedRenderer\(\)/);
  assert.match(nativeSource, /Runtime\.evaluate does not activate the app/);
  assert.match(nativeSource, /withWatcherLifecycleLock/);
  assert.match(nativeSource, /idleSystemSleepDisabled/);
  assert.match(nativeSource, /userInitiatedAllowingIdleSystemSleep/);
  assert.match(nativeSource, /flock\(descriptor, LOCK_EX\)/);
});

test('continuation clicks the original conversation and then Continue in new task', async () => {
  const previousConversationId = '6a6b3d26-c654-83e8-8b6a-55ee1eb0719f';
  const nextConversationId = '7b7c4e37-d765-94f9-9c77-66ff2fc072a0';
  const clicks = [];
  let activeConversationId = 'different-chat';
  let overflowOpen = false;
  class FakeEvent {
    constructor(type) { this.type = type; }
  }
  class FakeElement {
    constructor(id, text = '', attributes = {}) {
      this.id = id;
      this.innerText = text;
      this.textContent = text;
      this.attributes = attributes;
      this.disabled = false;
      this.offsetWidth = 120;
      this.offsetHeight = 28;
      this.isConnected = true;
      this.parentElement = null;
    }
    getAttribute(name) { return this.attributes[name] ?? null; }
    hasAttribute(name) { return this.attributes[name] !== undefined; }
    getClientRects() { return this.isConnected ? [{}] : []; }
    getBoundingClientRect() {
      return { left: 0, top: 0, width: this.offsetWidth, height: this.offsetHeight };
    }
    closest() { return this.parentElement; }
    querySelectorAll() { return []; }
    dispatchEvent(event) {
      if (event.type !== 'click') return true;
      clicks.push(this.id);
      if (this.id === 'conversation-row') activeConversationId = previousConversationId;
      if (this.id === 'more-actions') overflowOpen = true;
      if (this.id === 'continue-option') activeConversationId = nextConversationId;
      return true;
    }
  }
  const assistant = new FakeElement('assistant', 'Completed response');
  assistant.attributes['data-message-author-role'] = 'assistant';
  const conversationRow = new FakeElement(
    'conversation-row',
    'Marketplace continuation',
    { href: `/c/${previousConversationId}` },
  );
  const prompt = new FakeElement('prompt');
  const portal = {
    getAttribute(name) {
      return name === 'data-above-composer-conversation-id'
        ? `chatgpt:${activeConversationId}` : null;
    },
  };
  const selectDocument = {
    querySelector(selector) {
      if (selector === '[data-above-composer-conversation-id]') return portal;
      if (selector === '#prompt-textarea') return prompt;
      if (selector === '[contenteditable="true"]') return null;
      return null;
    },
    querySelectorAll(selector) {
      if (selector.includes('[data-message-author-role]')) return [assistant];
      if (selector.startsWith('a[href*=')) return [conversationRow];
      if (selector === '[data-thread-title="true"]') return [];
      return [];
    },
  };
  const renderedSelectScript = renderInterpolatedSwiftScript(
    selectConversationScript,
    previousConversationId,
  );
  const selectResult = await runInNewContext(renderedSelectScript, {
    document: selectDocument,
    PointerEvent: FakeEvent,
    MouseEvent: FakeEvent,
    setTimeout,
  });
  assert.equal(selectResult.ok, true);
  assert.equal(selectResult.clickStrategy, 'direct-link');
  assert.equal(selectResult.conversationId, previousConversationId);

  const moreActions = new FakeElement('more-actions', '', { 'aria-label': 'More actions' });
  const continueOption = new FakeElement(
    'continue-option',
    'Continue in new task',
    { role: 'menuitem' },
  );
  const responseTurn = new FakeElement('response-turn');
  responseTurn.querySelectorAll = () => [moreActions];
  assistant.parentElement = responseTurn;
  assistant.closest = () => responseTurn;
  const main = {
    querySelectorAll() { return [assistant]; },
  };
  const continueDocument = {
    querySelector(selector) {
      if (selector === '[data-above-composer-conversation-id]') return portal;
      if (selector === 'main') return main;
      if (selector.includes('textarea')) return prompt;
      return null;
    },
    querySelectorAll(selector) {
      if (selector.startsWith('button, a')) return [moreActions];
      if (selector.includes('[role="menuitem"]')) return overflowOpen ? [continueOption] : [];
      return [];
    },
  };
  const renderedContinueScript = renderInterpolatedSwiftScript(
    continueInNewTaskScript,
    previousConversationId,
  );
  const continueResult = await runInNewContext(renderedContinueScript, {
    document: continueDocument,
    PointerEvent: FakeEvent,
    MouseEvent: FakeEvent,
    setTimeout,
  });
  assert.equal(continueResult.ok, true);
  assert.equal(continueResult.continuationClicked, true);
  assert.equal(continueResult.continuationLabel, 'continue in new task');
  assert.equal(continueResult.conversationId, nextConversationId);
  assert.deepEqual(clicks, [
    'conversation-row',
    'more-actions',
    'continue-option',
  ]);
});

test('session-scoped approval opens the adjacent menu and selects the conversation option', async () => {
  const clicks = [];
  let menuOpen = false;
  class FakeEvent {
    constructor(type) { this.type = type; }
  }
  class FakeElement {
    constructor(id, text, attributes = {}) {
      this.id = id;
      this.innerText = text;
      this.textContent = text;
      this.attributes = attributes;
      this.disabled = false;
      this.offsetWidth = 80;
      this.offsetHeight = 24;
      this.isConnected = true;
      this.parentElement = null;
    }
    getAttribute(name) { return this.attributes[name] ?? null; }
    getClientRects() { return this.isConnected ? [{}] : []; }
    getBoundingClientRect() {
      return { left: 0, top: 0, width: this.offsetWidth, height: this.offsetHeight };
    }
    querySelectorAll() { return []; }
    dispatchEvent(event) {
      if (event.type !== 'click') return true;
      clicks.push(this.id);
      if (this.id === 'session-trigger') menuOpen = true;
      if (this.id === 'session-option') {
        allow.isConnected = false;
        allow.offsetWidth = 0;
        allow.offsetHeight = 0;
      }
      return true;
    }
  }
  const deny = new FakeElement('deny', 'Deny');
  const allow = new FakeElement('allow', 'Allow');
  const sessionTrigger = new FakeElement(
    'session-trigger',
    '',
    { 'aria-label': 'Allow bhrum2 for this conversation', 'aria-haspopup': 'menu' },
  );
  const sessionOption = new FakeElement(
    'session-option',
    'Allow bhrum2 for this conversation',
    { role: 'menuitem' },
  );
  const card = new FakeElement('card', 'Allow ChatGPT to use bhrum2?');
  card.querySelectorAll = () => [deny, allow, sessionTrigger];
  deny.parentElement = card;
  allow.parentElement = card;
  sessionTrigger.parentElement = card;
  const document = {
    querySelectorAll(selector) {
      if (selector === 'button') return [deny, allow, sessionTrigger];
      if (selector.includes('[role="menuitem"]')) return menuOpen ? [sessionOption] : [];
      return [];
    },
  };
  const result = await runInNewContext(approvalScript, {
    document,
    PointerEvent: FakeEvent,
    MouseEvent: FakeEvent,
    setTimeout,
  });
  assert.equal(result.ok, true);
  assert.equal(result.confirmed, true);
  assert.equal(result.strategy, 'session-scope');
  assert.equal(result.sessionScopeLabel, 'allow bhrum2 for this conversation');
  assert.deepEqual(clicks, ['session-trigger', 'session-option']);
  assert.equal(clicks.includes('allow'), false);
});

test('session-scoped approval falls back to DOM click in an isolated Browser context', async () => {
  const clicks = [];
  let menuOpen = false;
  class FakeElement {
    constructor(id, text, attributes = {}) {
      this.id = id;
      this.innerText = text;
      this.textContent = text;
      this.attributes = attributes;
      this.disabled = false;
      this.offsetWidth = 80;
      this.offsetHeight = 24;
      this.isConnected = true;
      this.parentElement = null;
    }
    getAttribute(name) { return this.attributes[name] ?? null; }
    getClientRects() { return this.isConnected ? [{}] : []; }
    getBoundingClientRect() {
      return { left: this.id === 'session-trigger' ? 80 : 0, top: 0,
        width: 80, height: 24, right: this.id === 'session-trigger' ? 160 : 80,
        bottom: 24 };
    }
    querySelectorAll() { return []; }
    click() {
      clicks.push(this.id);
      if (this.id === 'session-trigger') menuOpen = true;
      if (this.id === 'session-option') {
        allow.isConnected = false;
        allow.offsetWidth = 0;
        allow.offsetHeight = 0;
      }
    }
  }
  const deny = new FakeElement('deny', 'Deny');
  const allow = new FakeElement('allow', 'Allow');
  const sessionTrigger = new FakeElement(
    'session-trigger',
    '',
    { 'aria-label': 'Allow bhrum2 for this conversation', 'aria-haspopup': 'menu' },
  );
  const sessionOption = new FakeElement(
    'session-option',
    'Allow bhrum2 for this conversation',
    { role: 'menuitem' },
  );
  const card = new FakeElement('card', 'Allow ChatGPT to use bhrum2?');
  card.querySelectorAll = () => [deny, allow, sessionTrigger];
  deny.parentElement = card;
  allow.parentElement = card;
  sessionTrigger.parentElement = card;
  const document = {
    querySelectorAll(selector) {
      if (selector === 'button') return [deny, allow, sessionTrigger];
      if (selector.includes('[role="menuitem"]')) return menuOpen ? [sessionOption] : [];
      return [];
    },
  };
  const result = await runInNewContext(approvalScript, {
    document,
    PointerEvent: undefined,
    MouseEvent: undefined,
    Event: undefined,
    setTimeout,
  });
  assert.equal(result.ok, true);
  assert.equal(result.confirmed, true);
  assert.equal(result.strategy, 'session-scope');
  assert.deepEqual(clicks, ['session-trigger', 'session-option']);
});

test('allow-once approval ignores the rendered Enter keyboard hint', async () => {
  const clicks = [];
  class FakeEvent {
    constructor(type) { this.type = type; }
  }
  class FakeElement {
    constructor(id, text) {
      this.id = id;
      this.innerText = text;
      this.textContent = text;
      this.disabled = false;
      this.offsetWidth = 80;
      this.offsetHeight = 24;
      this.isConnected = true;
      this.parentElement = null;
    }
    getAttribute() { return null; }
    getClientRects() { return this.isConnected ? [{}] : []; }
    getBoundingClientRect() {
      return { left: 0, top: 0, width: this.offsetWidth, height: this.offsetHeight };
    }
    querySelectorAll() { return []; }
    dispatchEvent(event) {
      if (event.type !== 'click') return true;
      clicks.push(this.id);
      if (this.id === 'allow-once') {
        this.isConnected = false;
        this.offsetWidth = 0;
        this.offsetHeight = 0;
      }
      return true;
    }
  }
  const deny = new FakeElement('deny', 'Deny\nEscape');
  const allowOnce = new FakeElement('allow-once', 'Allow once\n⏎');
  const card = new FakeElement('card', 'Allow ChatGPT to use bhrum2?');
  card.querySelectorAll = () => [deny, allowOnce];
  deny.parentElement = card;
  allowOnce.parentElement = card;
  const document = { querySelectorAll: selector => selector === 'button' ? [deny, allowOnce] : [] };
  const result = await runInNewContext(approvalScript, {
    document, PointerEvent: FakeEvent, MouseEvent: FakeEvent, setTimeout,
  });
  assert.equal(result.ok, true);
  assert.equal(result.confirmed, true);
  assert.equal(result.strategy, 'single-approval');
  assert.equal(result.label, 'allow once');
  assert.deepEqual(clicks, ['allow-once']);
  assert.match(chatScriptsSource, /\\u21b5\\u23ce/);
});

test('approval re-render with the same request fingerprint is not confirmed as closed', async () => {
  let activeAllow;
  class FakeEvent {
    constructor(type) { this.type = type; }
  }
  class FakeElement {
    constructor(text) {
      this.innerText = text;
      this.textContent = text;
      this.disabled = false;
      this.offsetWidth = 80;
      this.offsetHeight = 24;
      this.isConnected = true;
      this.parentElement = null;
    }
    getAttribute() { return null; }
    getClientRects() { return this.isConnected ? [{}] : []; }
    getBoundingClientRect() { return { left: 0, top: 0, width: 80, height: 24 }; }
    querySelectorAll() { return []; }
    dispatchEvent(event) {
      if (event.type === 'click' && this === activeAllow) {
        this.isConnected = false;
        const replacement = new FakeElement('Allow once');
        replacement.parentElement = card;
        activeAllow = replacement;
      }
      return true;
    }
  }
  const deny = new FakeElement('Deny');
  const card = new FakeElement('Allow ChatGPT to use bhrum2?');
  activeAllow = new FakeElement('Allow once');
  deny.parentElement = card;
  activeAllow.parentElement = card;
  card.querySelectorAll = () => [deny, activeAllow];
  const document = {
    querySelectorAll(selector) {
      return selector === 'button' ? [deny, activeAllow] : [];
    },
  };
  const immediateTimeout = callback => { callback(); return 0; };
  const result = await runInNewContext(approvalScript, {
    document,
    PointerEvent: FakeEvent,
    MouseEvent: FakeEvent,
    setTimeout: immediateTimeout,
  });
  assert.equal(result.ok, false);
  assert.equal(result.confirmed, false);
  assert.equal(result.error, 'approval_click_not_confirmed');
});

test('approval decisions do not inspect or block card contents', () => {
  assert.match(nativeSource, /allRecognizedApprovalsEnabled/);
  assert.match(nativeSource, /自动确认所有 ChatGPT 授权卡/);
  assert.doesNotMatch(nativeSource, /sensitiveTerms|blockedSensitive/);
});

test('legacy sweep command remains compatible without navigating tasks', () => {
  assert.match(nativeSource,
    /case "sweep":[\s\S]*?var result = scan\(&state\)[\s\S]*?"navigationSkipped"/);
});

test('allow-once cards are recognized by their allow and reject button pair', () => {
  assert.match(nativeSource,
    /for anchor in approvalAnchors[\s\S]*?if !verifiedButtons\.isEmpty \{ break \}[\s\S]*?container = parent\(of: node\)/);
  assert.match(nativeSource, /"Reject", "Deny", "拒绝", "不允许"/);
  assert.match(nativeSource,
    /guard buttons\.count == 2,[\s\S]*?return buttons\.filter \{ normalizedAXText\(accessibleString\(\$0\)\)\.isEmpty \}/);
  assert.match(nativeSource,
    /isAllowButton\(title: title, context: context\) \|\|\s*normalizedAXText\(title\)\.isEmpty/);
});

test('relaunch_and_confirm emits a host request and supports self-restarting ChatGPT with CDP port', async () => {
  const result = await call('relaunch_and_confirm', { approveAll: true });
  const request = result.result.structuredContent.hostRequest;
  assert.equal(request.capability, 'desktop.chatgpt-approvals.relaunch-and-confirm');
  assert.equal(request.params.approveAll, true);
  assert.match(nativeSource, /case "relaunch_and_confirm":[\s\S]*?NSWorkspace\.shared\.runningApplications\.filter[\s\S]*?--remote-debugging-port/);
});
