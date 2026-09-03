import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import test from 'node:test';
import worker from '../worker/src/index.ts';
import { HOME, RESOURCES } from '../worker/src/content.generated.ts';

const plugin = JSON.parse(readFileSync(new URL('../.codex-plugin/plugin.json', import.meta.url), 'utf8'));
const mcpConfig = JSON.parse(readFileSync(new URL('../.mcp.json', import.meta.url), 'utf8'));
const actionsWorkflow = readFileSync(
  new URL('../../../../../.github/workflows/chatgpt-auto-confirm-runner.yml', import.meta.url),
  'utf8',
);
const restoreSessionScript = readFileSync(
  new URL('../scripts/restore-session-cookies.mjs', import.meta.url),
  'utf8',
);
const dispatchActionsScript = readFileSync(
  new URL('../scripts/dispatch-actions-runner.sh', import.meta.url),
  'utf8',
);
const windowsSyncScript = readFileSync(
  new URL('../scripts/sync-actions-credentials.ps1', import.meta.url),
  'utf8',
);
const liveSessionExporter = readFileSync(
  new URL('../scripts/export-live-chatgpt-session.mjs', import.meta.url),
  'utf8',
);
const credentialBundle = readFileSync(
  new URL('../scripts/credential-bundle.mjs', import.meta.url),
  'utf8',
);
const keepaliveWorkflow = readFileSync(
  new URL('../../../../../.github/workflows/chatgpt-auto-confirm-keepalive.yml', import.meta.url),
  'utf8',
);
const dynamicController = readFileSync(
  new URL('../scripts/run-dynamic-actions-controller.mjs', import.meta.url),
  'utf8',
);
const nativeServer = readFileSync(
  new URL('../server/index.mjs', import.meta.url),
  'utf8',
);
const nativeSource = readFileSync(
  new URL('../native/main.swift', import.meta.url),
  'utf8',
);
const workerSource = readFileSync(
  new URL('../worker/src/index.ts', import.meta.url),
  'utf8',
);
const actionsInbox = JSON.parse(readFileSync(
  new URL('../tasks/actions-inbox.json', import.meta.url),
  'utf8',
));
const rendererRecoverySkill = readFileSync(
  new URL('../skills/recover-actions-chatgpt-renderer/SKILL.md', import.meta.url),
  'utf8',
);
const rendererRecoveryReference = readFileSync(
  new URL('../skills/recover-actions-chatgpt-renderer/references/renderer-diagnostics.md', import.meta.url),
  'utf8',
);
const rendererRecoveryMetadata = readFileSync(
  new URL('../skills/recover-actions-chatgpt-renderer/agents/openai.yaml', import.meta.url),
  'utf8',
);
const syncCredentialSkill = readFileSync(
  new URL('../skills/sync-action-credentials/SKILL.md', import.meta.url),
  'utf8',
);

test('home contract', () => {
  assert.equal(HOME.schema, 'mahayana.miniapp.home.v1');
  assert.equal(HOME.app.id, 'chatgpt-auto-confirm');
  assert.equal(HOME.app.version, plugin.version);
  assert.ok(Buffer.byteLength(JSON.stringify(HOME)) <= 32768);
  assert.ok(HOME.feed.items.length <= 10);
  assert.deepEqual(HOME.quickReplies.map(item => item.action.name), [
    'account_list', 'account_add', 'account_login_link', 'account_status',
    'sync_actions_credentials', 'login_and_sync_actions', 'queue_status', 'start_actions_runner',
    'prompt_templates', 'wait_for_review',
  ]);
  assert.equal(HOME.quickReplies.some(item => item.action.name === 'web_login_and_sync_actions'), false);
  assert.equal(HOME.quickReplies.some(item => item.action.name === 'account_list'), true);
});
test('renderer recovery skill is packaged with the miniapp', () => {
  assert.equal(plugin.skills, './skills');
  assert.match(rendererRecoverySkill, /name: recover-actions-chatgpt-renderer/);
  assert.match(rendererRecoverySkill, /verify_chatgpt_login/);
  assert.match(rendererRecoverySkill, /window\.open/);
  assert.match(rendererRecoverySkill, /clicked=true/);
  assert.match(rendererRecoverySkill, /parallel_queue_smoke/);
  assert.match(rendererRecoveryReference, /headless-existing-window-ready/);
  assert.match(rendererRecoveryReference, /needs_login/);
  assert.match(rendererRecoveryMetadata, /display_name:/);
  assert.match(rendererRecoveryMetadata, /\$recover-actions-chatgpt-renderer/);
});
test('article bodies stay lazy', () => assert.ok(Object.keys(RESOURCES).length >= 1));
test('continuous Actions runner preserves secrets and chains incomplete sessions', () => {
  assert.match(actionsWorkflow, /runs-on: macos-15/);
  assert.match(actionsWorkflow, /timeout-minutes: 355/);
  assert.match(actionsWorkflow, /CHATGPT_CODEX_AUTH_B64/);
  assert.match(actionsWorkflow, /CHATGPT_SESSION_COOKIES_B64/);
  assert.match(syncCredentialSkill, /Codex 凭证与 ChatGPT Session.*独立且都必需/);
  assert.match(syncCredentialSkill, /Work → Chat/);
  assert.match(syncCredentialSkill, /不得把 Work usage 页面当作 Chat 页面/);
  assert.match(actionsWorkflow, /restore-session-cookies\.mjs/);
  assert.match(actionsWorkflow, /CHATGPT_SESSION_MODE=restore-and-verify/);
  assert.match(actionsWorkflow, /Verify authenticated ChatGPT session/);
  assert.match(actionsWorkflow, /verify_chatgpt_login/);
  assert.match(
    actionsWorkflow,
    /Verify authenticated ChatGPT session\r?\n\s+if: \$\{\{ inputs\.cancel_task_id == '' \}\}\r?\n\s+id: auth_verify\r?\n\s+timeout-minutes: 6/,
  );
  assert.match(actionsWorkflow, /CHATGPT_AUTO_CONFIRM_STATE: \$\{\{ steps\.paths\.outputs\.state_path \}\}/);
  assert.match(actionsWorkflow, /CHATGPT_AUTO_CONFIRM_QUEUE_STATE: \$\{\{ steps\.paths\.outputs\.state_path \}\}/);
  assert.match(actionsWorkflow, /CHATGPT_AUTO_CONFIRM_BACKGROUND_PORT: \$\{\{ env\.CHATGPT_CDP_PORT \}\}/);
  assert.match(actionsWorkflow, /CHATGPT_AUTO_CONFIRM_PROFILE_PATH: \$\{\{ steps\.paths\.outputs\.profile_dir \}\}/);
  assert.match(actionsWorkflow, /AUTHENTICATION_VERIFIED/);
  assert.match(actionsWorkflow, /no continuation was dispatched/);
  assert.match(actionsWorkflow, /for attempt in 1 2/);
  assert.match(actionsWorkflow, /Authenticated Chat shell attempt/);
  assert.match(actionsWorkflow, /restarting the app before retrying/);
  assert.match(actionsWorkflow, /pkill -f "user-data-dir=\$PROFILE_DIR"/);
  assert.match(actionsWorkflow, /SingletonLock/);
  assert.match(actionsWorkflow, /detach_mount\(\)/);
  assert.match(actionsWorkflow, /for attempt in 1 2 3 4 5/);
  assert.match(actionsWorkflow, /hdiutil detach "\$mount_dir"/);
  assert.match(actionsWorkflow, /hdiutil detach "\$mount_dir" -force/);
  assert.doesNotMatch(actionsWorkflow, /hdiutil detach "\$mount_dir" .* -wait/);
  assert.match(actionsWorkflow, /hdiutil info/);
  assert.match(actionsWorkflow, /trap cleanup_mount EXIT/);
  assert.match(restoreSessionScript, /mode === 'restore'/);
  assert.match(restoreSessionScript, /process\.exit\(0\)/);
  assert.match(restoreSessionScript, /Page\.reload/);
  assert.match(restoreSessionScript, /Page\.navigate/);
  assert.match(restoreSessionScript, /json\/version/);
  assert.match(restoreSessionScript, /Target\.createTarget/);
  assert.match(restoreSessionScript, /Created ChatGPT app root target/);
  assert.match(restoreSessionScript, /avatar-overlay/);
  assert.match(restoreSessionScript, /approveHeadlessChatGPTLocalNetworkPrompt/);
  assert.match(restoreSessionScript, /find devices on local networks/);
  assert.match(restoreSessionScript, /AXSystemDialog/);
  assert.match(restoreSessionScript, /key code 36/);
  assert.match(restoreSessionScript, /nativePromptImpl/);
  assert.match(restoreSessionScript, /initialRoute=%2F/);
  assert.match(restoreSessionScript, /Optional CDP command/);
  assert.match(restoreSessionScript, /authenticatedControllerIsReady/);
  assert.match(restoreSessionScript, /!state\.asksForLogin/);
  assert.match(
    restoreSessionScript,
    /state\.currentMode\s*\|\|\s*state\.workComposer\s*\|\|\s*state\.hasChat\s*\|\|\s*state\.hasWork/,
  );
  assert.doesNotMatch(restoreSessionScript, /call\([^\n]*['"]Page\.setWebLifecycleState['"]/);
  assert.doesNotMatch(actionsWorkflow, /pkill -x ChatGPT/);
  assert.match(actionsWorkflow, /Launch authenticated desktop shell/);
  assert.match(
    actionsWorkflow,
    /Launch authenticated desktop shell\r?\n\s+if: \$\{\{ inputs\.cancel_task_id == '' \}\}\r?\n\s+timeout-minutes: 6/,
  );
  assert.doesNotMatch(actionsWorkflow, /login_status=\$\(/);
  assert.match(actionsWorkflow, /Build native queue runtime/);
  assert.match(actionsWorkflow, /native-auth-verify\.log/);
  assert.match(actionsWorkflow, /native-auth-targets\.json/);
  assert.match(actionsWorkflow, /Native ChatGPT authentication verification failed/);
  assert.match(actionsWorkflow, /CHATGPT_AUTO_CONFIRM_STATE_KEY/);
  assert.doesNotMatch(actionsWorkflow, /CHATGPT_AUTO_CONFIRM_INITIAL_STATE_B64/);
  assert.match(actionsWorkflow, /\{"automationTasks":\[\]\}/);
  assert.match(actionsWorkflow, /queue-state\.enc/);
  assert.match(actionsWorkflow, /previous_run_id="\$GITHUB_RUN_ID"/);
  assert.match(actionsWorkflow, /parallel_queue_smoke/);
  assert.match(actionsWorkflow, /cancel_task_id/);
  assert.match(actionsWorkflow, /Cancel persisted task without launching Chat/);
  assert.match(actionsWorkflow, /cancel-persisted-task\.mjs/);
  assert.match(actionsWorkflow, /Persisted task cancellation completed/);
  assert.match(actionsWorkflow, /inputs\.cancel_task_id == ''/);
  assert.match(actionsWorkflow, /chatgpt-auto-confirm-parallel-smoke/);
  assert.match(actionsWorkflow, /verify-parallel-actions-queue\.mjs/);
  assert.match(actionsWorkflow, /parallel-queue-evidence\.json/);
  assert.match(actionsWorkflow, /task-queue\/watcher-trace\.log/);
  assert.doesNotMatch(actionsWorkflow, /CHATGPT_AUTO_CONFIRM_TASK_INBOX_B64/);
  assert.doesNotMatch(actionsWorkflow, /CHATGPT_AUTO_CONFIRM_TASK_INBOX_FILE/);
  assert.match(actionsWorkflow, /CHATGPT_AUTO_CONFIRM_TASK_CONTROL_PATH/);
  assert.match(actionsWorkflow, /tasks\/actions-inbox\.json/);
  assert.doesNotMatch(actionsWorkflow, /import-actions-task-inbox\.mjs/);
  assert.match(actionsWorkflow, /status" != "incomplete"/);
  assert.match(actionsWorkflow, /VERIFICATION_ONLY/);
  assert.match(actionsWorkflow, /no continuation was dispatched/);
  assert.match(actionsWorkflow, /--ref "\$GITHUB_REF_NAME"/);
  assert.match(actionsWorkflow, /jq '\{status, reason, counts, tasks\}'/);
  assert.doesNotMatch(actionsWorkflow, /pull_request:/);
  assert.doesNotMatch(actionsWorkflow, /push:/);
  assert.match(actionsWorkflow, /account_id:/);
  assert.match(actionsWorkflow, /chatgpt-auto-confirm-credentials-/);
  assert.match(actionsWorkflow, /aes-256-gcm/);
  assert.match(actionsWorkflow, /retention-days: 30/);
  assert.match(actionsWorkflow, /restore_latest_credentials/);
  assert.match(keepaliveWorkflow, /cron: '17 \*\/6 \* \* \*'/);
  assert.match(keepaliveWorkflow, /CHATGPT_AUTO_CONFIRM_ACCOUNT_IDS_JSON/);
  assert.match(keepaliveWorkflow, /smoke_only=true/);
});
test('login sync uploads both credential forms without printing values', () => {
  assert.match(dispatchActionsScript, /CHATGPT_SESSION_COOKIES_PATH/);
  assert.match(dispatchActionsScript, /CHATGPT_CODEX_AUTH_B64/);
  assert.match(dispatchActionsScript, /CHATGPT_SESSION_COOKIES_B64/);
  assert.doesNotMatch(dispatchActionsScript, /CHATGPT_AUTO_CONFIRM_INITIAL_STATE_B64|export-action-state/);
  assert.match(dispatchActionsScript, /CHATGPT_AUTO_CONFIRM_DISPATCH/);
  assert.doesNotMatch(dispatchActionsScript, /echo .*CHATGPT_(CODEX_AUTH|SESSION_COOKIES)_B64/);
  assert.match(dispatchActionsScript, /CHATGPT_ACCOUNT_ID/);
  assert.match(dispatchActionsScript, /deployment-branch-policies/);
  assert.match(credentialBundle, /aes-256-gcm/);
  assert.match(credentialBundle, /credential bundle account mismatch/);
  assert.match(dynamicController, /status === 'failed'/);
  assert.match(dynamicController, /await handleFinishedChild\(\)[\s\S]*if \(!child\)/);
});
test('Windows credential sync keeps secrets out of logs and supports optional dispatch', () => {
  assert.equal(existsSync(new URL('../scripts/extract-windows-chatgpt-cookies.py', import.meta.url)), false);
  assert.equal(existsSync(new URL('../scripts/extract-macos-chatgpt-cookies.py', import.meta.url)), false);
  assert.match(nativeServer, /sync-actions-credentials\.ps1/);
  assert.match(nativeServer, /process\.platform !== 'win32'/);
  assert.match(windowsSyncScript, /CHATGPT_CODEX_AUTH_B64/);
  assert.match(windowsSyncScript, /CHATGPT_SESSION_COOKIES_B64/);
  assert.doesNotMatch(windowsSyncScript, /CHATGPT_AUTO_CONFIRM_INITIAL_STATE_B64|export-action-state/);
  assert.match(windowsSyncScript, /\$Start/);
  assert.match(windowsSyncScript, /ConvertTo-Json -Compress/);
  assert.doesNotMatch(windowsSyncScript, /Write-Host .*encoded/);
  assert.doesNotMatch(windowsSyncScript, /Write-Output .*encoded/);
  assert.match(windowsSyncScript, /shell:AppsFolder/);
  assert.match(windowsSyncScript, /OpenAI\.Codex_2p2nqsd0c76g0!App/);
  assert.match(windowsSyncScript, /export-live-chatgpt-session\.mjs/);
  assert.match(windowsSyncScript, /Get-LiveRendererCookieSummary/);
  assert.match(windowsSyncScript, /CHATGPT_CDP_PORT/);
  assert.doesNotMatch(windowsSyncScript, /remote-debugging-port/);
  assert.doesNotMatch(windowsSyncScript, /load-extension/);
  assert.doesNotMatch(windowsSyncScript, /chatgpt-cookie-capture-extension/);
  assert.doesNotMatch(windowsSyncScript, /auth\.openai\.com\/oauth/);
  assert.match(windowsSyncScript, /WaitSeconds/);
  assert.match(windowsSyncScript, /\[switch\]\$DesktopLogin/);
  assert.doesNotMatch(windowsSyncScript, /\$OpenLogin|\$WebLogin/);
  assert.match(liveSessionExporter, /Network\.getAllCookies/);
  assert.match(liveSessionExporter, /Runtime\.evaluate/);
  assert.match(liveSessionExporter, /app:\/\/-\/index\.html/);
  assert.match(liveSessionExporter, /electronBridge/);
  assert.match(liveSessionExporter, /live-desktop-renderer/);
  assert.doesNotMatch(liveSessionExporter, /api\/auth\/session|https:\/\/chatgpt\.com/);
  assert.doesNotMatch(liveSessionExporter, /sqlite|Safe Storage|win32crypt|Cryptodome/i);
});
test('worker exposes the interactive login sync command', async () => {
  const response = await worker.fetch(new Request('https://example.test/mcp', {
    method: 'POST', body: JSON.stringify({ jsonrpc: '2.0', id: 9, method: 'tools/list' }),
  }));
  const tools = (await response.json()).result.tools;
  const dispatchGoal = tools.find(item => item.name === 'dispatch_goal');
  assert.ok(dispatchGoal);
  assert.deepEqual(dispatchGoal.inputSchema.required, ['goal']);
  assert.equal(dispatchGoal.inputSchema.properties.goal.maxLength, 10000);
  assert.deepEqual(mcpConfig.mcpServers['chatgpt-auto-confirm-local'], {
    type: 'stdio',
    command: 'node',
    args: ['--experimental-strip-types', './server/index.mjs'],
    cwd: '.',
  });
  assert.match(nativeServer, /\['send_and_watch', 'send_and_watch'\]/);
  assert.match(nativeServer, /tool === 'dispatch_goal'/);
  assert.match(workerSource, /PLUGIN_DISPATCH_BROWSER = 'iab'/);
  assert.match(workerSource, /PLUGIN_DISPATCH_CAPABILITY = 'browser\.in-app\.dispatch-and-watch'/);
  assert.match(workerSource, /PLUGIN_DISPATCH_MODEL = 'GPT-5\.6 Sol'/);
  assert.match(workerSource, /PLUGIN_DISPATCH_REASONING = 'Extra High'/);
  assert.match(nativeServer, /browser\.in-app\.dispatch-and-watch/);
  assert.match(nativeServer, /browserCapabilityFile/);
  const tool = tools.find(item => item.name === 'login_and_sync_actions');
  assert.ok(tool);
  assert.equal(tool.inputSchema.properties.start.default, true);
  assert.equal(tool.inputSchema.properties.waitSeconds.default, 600);
  assert.match(nativeServer, /\['login_and_sync_actions', 'login_and_sync_actions'\]/);
  assert.match(nativeServer, /'cancel_task', 'sync_actions_credentials', 'login_and_sync_actions'/);
  const credentialTool = tools.find(item => item.name === 'sync_actions_credentials');
  assert.ok(credentialTool);
  assert.equal(credentialTool.inputSchema.properties.start.default, false);
  assert.equal(credentialTool.inputSchema.properties.waitSeconds.default, 600);
  assert.match(workerSource, /actions-runner-credential-sync/);
  assert.match(nativeServer, /\['sync_actions_credentials', 'sync_actions_credentials'\]/);
  assert.match(nativeSource, /case "sync_actions_credentials"/);
  assert.match(nativeSource, /CDPClient\.allCookies/);
  assert.match(nativeSource, /authenticationDeadline/);
  assert.match(nativeSource, /actionsDesktopTarget\(\)/);
  assert.match(nativeSource, /if actionsDesktopTarget\(\) != nil \{ return \}/);
  assert.match(nativeSource, /application\.forceTerminate\(\)/);
  assert.match(nativeSource, /--remote-debugging-port=\\\(CDPClient\.port\(\)\)/);
  assert.match(nativeSource, /actionsDesktopState/);
  assert.match(nativeSource, /func actionsControllerShellIsReady/);
  assert.match(nativeSource, /case "verify_chatgpt_login":[\s\S]*createQueueWorkerTarget\(&queueState, reuseExisting: true\)/);
  assert.match(nativeSource, /chatgpt_hidden_chat_unavailable/);
  assert.match(nativeSource, /try saveState\(queueState\)/);
  assert.match(nativeSource, /electronBridge/);
  assert.match(nativeSource, /actionsLoginPorts/);
  assert.match(nativeSource, /ports\.append\(9324\)/);
  assert.doesNotMatch(nativeSource, /createActionsWebLoginTarget|actionsWebSessionMatchesCodex/);
  assert.doesNotMatch(nativeSource, /actionsWebLoginState|api\/auth\/session/);
  assert.match(nativeSource, /syncLiveActionsCredentials/);
  assert.match(nativeSource, /openDesktopIfNeeded: Bool = false/);
  assert.match(nativeSource, /startRunner: startRunner,\s+openDesktopIfNeeded: false/);
  assert.match(nativeSource, /startRunner: startRunner,\s+openDesktopIfNeeded: true/);
  assert.match(nativeSource, /credentialSource": "live-desktop-renderer"/);
  assert.doesNotMatch(nativeSource, /credentialSource": "local-files"/);
  assert.doesNotMatch(nativeSource, /extractVerifiedMacOS|macOSCookieExtractor/);
  assert.doesNotMatch(nativeSource, /webSessionIdentifiers/);
  assert.match(nativeSource, /!url\.contains\("avatar-overlay"\)/);
  assert.match(nativeServer, /-DesktopLogin/);
  assert.match(nativeServer, /-WaitSeconds/);
  const webTool = tools.find(item => item.name === 'web_login_and_sync_actions');
  assert.equal(webTool, undefined);
  assert.doesNotMatch(workerSource, /web_login_and_sync_actions|actions-runner-web-login-sync/);
  assert.doesNotMatch(nativeServer, /web_login_and_sync_actions|-OpenLogin|-WebLogin/);
  assert.match(windowsSyncScript, /OpenAI\.Codex_2p2nqsd0c76g0!App/);
  assert.match(windowsSyncScript, /credentialSource/);
});
// test('continuous Actions inbox contains independent work for real parallel dispatch', () => {
//   assert.ok(actionsInbox.maxConcurrent >= 2);
//   assert.ok(actionsInbox.tasks.length >= 2);
//   const firstLocks = new Set(actionsInbox.tasks[0].resourceLocks || []);
//   const secondLocks = new Set(actionsInbox.tasks[1].resourceLocks || []);
//   assert.equal([...firstLocks].some(lock => secondLocks.has(lock)), false);
// });
test('JSON-RPC errors use the top-level error member', async () => {
  const response = await worker.fetch(new Request('https://example.test/mcp', {
    method: 'POST', body: JSON.stringify({ jsonrpc: '2.0', id: 7, method: 'unknown' }),
  }));
  assert.deepEqual((await response.json()).error, { code: -32601, message: 'Method not found' });
});

test('task prompt templates expose the strict report protocol', async () => {
  const response = await worker.fetch(new Request('https://example.test/mcp', {
    method: 'POST', body: JSON.stringify({
      jsonrpc: '2.0', id: 8, method: 'tools/call',
      params: { name: 'prompt_templates', arguments: {} },
    }),
  }));
  const payload = await response.json();
  assert.equal(payload.result.structuredContent.templates.length, 4);
  const templateText = payload.result.structuredContent.templates
    .map(template => template.promptPrefix).join('\n');
  assert.equal(templateText, '');
  assert.equal(payload.result.structuredContent.reportProtocol.protocol, 'mahayana.task-report.v1');
  assert.deepEqual(payload.result.structuredContent.reportProtocol.fields, [
    'task_id', 'applied_task_revision', 'applied_spec_digest',
    'status', 'all_tasks_complete', 'summary', 'completed', 'remaining', 'blockers', 'verification',
    'wait_seconds', 'wait_reason', 'next_connector', 'next_task',
  ]);
});
