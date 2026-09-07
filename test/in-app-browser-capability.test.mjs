import assert from 'node:assert/strict';
import { mkdtemp, readFile, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import {
  BROWSER_DISPATCH_POLICY,
  BROWSER_CAPABILITY,
  MAX_PARALLEL_BROWSER_JOBS,
  promptForGoal,
  plannerPromptForGoal,
  COMPLETION_CERTIFICATE_INSTRUCTION,
  parseTaskReport,
  parseCompletionCertificate,
  classifyCompletion,
  validateBrowserPolicy,
  isRecoverableBrowserContextError,
  isPageLoadFailureState,
  isPendingAuthorizationState,
  reattachInAppBrowserTab,
  approveAuthorization,
  createInAppBrowserCapabilityHost,
} from '../scripts/in-app-browser-capability-host.mjs';

test('in-app Browser policy is fixed to the authorized Chat surface', () => {
  assert.equal(BROWSER_CAPABILITY, 'browser.in-app.dispatch-and-watch');
  assert.equal(BROWSER_DISPATCH_POLICY.browser, 'iab');
  assert.equal(BROWSER_DISPATCH_POLICY.connector, null);
  assert.equal(BROWSER_DISPATCH_POLICY.model, 'GPT-5.6 Sol');
  assert.equal(BROWSER_DISPATCH_POLICY.reasoning, 'Extra High');
  assert.equal(BROWSER_DISPATCH_POLICY.surface, 'chat');
  assert.equal(BROWSER_DISPATCH_POLICY.goalOnlyDispatch, false);
  assert.equal(BROWSER_DISPATCH_POLICY.maxConcurrentJobs, MAX_PARALLEL_BROWSER_JOBS);
  assert.deepEqual(validateBrowserPolicy({ ...BROWSER_DISPATCH_POLICY }), { ok: true });
  assert.equal(validateBrowserPolicy({ ...BROWSER_DISPATCH_POLICY, connector: 'devspace1' }).ok, false);
  assert.equal(validateBrowserPolicy({ ...BROWSER_DISPATCH_POLICY, previousProgress: 'must not be sent' }).ok, false);
});

test('work prompts stay natural while a fresh planner receives the machine-readable certificate', () => {
  const prompt = promptForGoal('完成 RustDesk 融合');
  assert.match(prompt, /^完成 RustDesk 融合\n\n本轮是工作 Chat/);
  assert.doesNotMatch(prompt, /原始目标：/);
  assert.doesNotMatch(prompt, /内部自行拆解工作/);
  assert.doesNotMatch(prompt, /MAHAYANA_TASK_REPORT_V1/);
  const planner = plannerPromptForGoal('完成 RustDesk 融合', '工作 Chat 已完成代码修改，但还需要 CI。', {
    taskId: 'task-1', appliedRevision: 2, appliedDigest: 'sha256:abc',
  });
  assert.match(planner, /MAHAYANA_TASK_REPORT_CONTRACT_V6/);
  assert.match(planner, /MAHAYANA_TASK_REPORT_V1_BEGIN/);
  assert.match(planner, /"task_id":"task-1"/);
  assert.match(planner, /"applied_task_revision":2/);
  assert.match(planner, /"applied_spec_digest":"sha256:abc"/);
  assert.equal(planner.includes(COMPLETION_CERTIFICATE_INSTRUCTION), true);
  assert.doesNotMatch(prompt, /previousProgress/);
});

test('planner reports can arrange another work Chat without being mistaken for completion', () => {
  const report = parseTaskReport([
    'planner review',
    'MAHAYANA_TASK_REPORT_V1_BEGIN',
    '{"protocol":"mahayana.task-report.v1","status":"incomplete","all_tasks_complete":false,"summary":"CI 尚未完成","completed":["代码已修改"],"remaining":["CI"],"blockers":[],"verification":["diff"],"wait_seconds":0,"wait_reason":"","next_connector":"GitHub","next_task":"在 GitHub Actions 中完成 CI，并回读失败日志。"}',
    'MAHAYANA_TASK_REPORT_V1_END',
  ].join('\n'));
  assert.equal(report.valid, true);
  assert.equal(report.complete, false);
  assert.equal(report.actionable, true);
  assert.equal(report.payload.next_task.includes('GitHub Actions'), true);
});

test('completion parser stops only on the complete certificate shape', () => {
  const valid = [
    'assistant text',
    'MAHAYANA_TASK_REPORT_V1_BEGIN',
    '{"protocol":"mahayana.task-report.v1","status":"complete","all_tasks_complete":true,"summary":"done","completed":["done"],"remaining":[],"blockers":[],"verification":["checked"],"wait_seconds":0,"wait_reason":"","next_connector":"","next_task":""}',
    'MAHAYANA_TASK_REPORT_V1_END',
  ].join('\n');
  assert.equal(parseCompletionCertificate(valid).valid, true);
  assert.equal(parseCompletionCertificate(valid.replace('"remaining":[]', '"remaining":["x"]')).valid, false);
  assert.equal(parseCompletionCertificate(valid.replace('"status":"complete"', '"status":"incomplete"')).valid, false);
  assert.equal(parseCompletionCertificate('没有完成证书').valid, false);
});

test('completion detection requires a valid completion certificate', () => {
  const naturalOnly = classifyCompletion('全部目标已经完成，代码已实现，测试、CI、发布和运行验证均已通过。');
  assert.equal(naturalOnly.valid, false);
  assert.equal(naturalOnly.reason, 'missing-completion-certificate');

  const complete = classifyCompletion([
    '全部目标已经完成，代码已实现，测试、CI、发布和运行验证均已通过。',
    'MAHAYANA_TASK_REPORT_V1_BEGIN',
    '{"protocol":"mahayana.task-report.v1","status":"complete","all_tasks_complete":true,"summary":"done","completed":["done"],"remaining":[],"blockers":[],"verification":["checked"],"wait_seconds":0,"wait_reason":"","next_connector":"","next_task":""}',
    'MAHAYANA_TASK_REPORT_V1_END',
  ].join('\n'));
  assert.equal(complete.valid, true);
  assert.equal(complete.mode, 'certificate');

  const incomplete = classifyCompletion('RustDesk 融合尚未完成，还需要继续实现文件传输和音频，并补充验证。');
  assert.equal(incomplete.valid, false);
  assert.equal(incomplete.reason, 'explicit-incomplete');

  const vague = classifyCompletion('我完成了部分功能，下面是当前总结。');
  assert.equal(vague.valid, false);
});

test('authorization detector recognizes connector cards without a manual trigger', () => {
  assert.equal(isPendingAuthorizationState({
    bodyText: '允许 ChatGPT 使用 GitHub？向 GitHub 仓库创建一个公开可见的拉取请求。',
    controls: [
      { label: '拒绝', disabled: false },
      { label: '允许', disabled: false },
    ],
  }), true);
  assert.equal(isPendingAuthorizationState({
    bodyText: '本次会话需要授权。',
    controls: [{ label: '允许本次会话', disabled: false }],
  }), true);
  assert.equal(isPendingAuthorizationState({
    bodyText: '普通聊天内容里提到 allow。',
    controls: [{ label: '允许', disabled: false }],
  }), false);
  assert.equal(isPendingAuthorizationState({
    bodyText: '允许 ChatGPT 使用 GitHub。',
    controls: [{ label: '允许', disabled: true }],
  }), false);
  assert.equal(isPendingAuthorizationState({
    bodyText: '允许 ChatGPT 使用 GitHub。',
    stopAnswer: true,
    controls: [
      { label: '拒绝', disabled: false },
      { label: '允许', disabled: false },
    ],
  }), true);
});

test('authorization remains detectable while ChatGPT exposes stop-generating', () => {
  assert.equal(isPendingAuthorizationState({
    bodyText: 'ChatGPT 将使用 GitHub 来帮助处理你的请求。',
    stopAnswer: true,
    controls: [
      { label: '停止回答', disabled: false },
      { label: '拒绝', disabled: false },
      { label: '允许', disabled: false },
    ],
  }), true);
});

function fakeTab(id, url) {
  let handoff = false;
  let currentUrl = url;
  return {
    id,
    playwright: {},
    url: async () => currentUrl,
    goto: async value => { currentUrl = value; },
    markHandoff: async () => { handoff = true; },
    get handoff() { return handoff; },
  };
}

test('recoverable Browser context errors are distinguished from page failures', () => {
  assert.equal(isRecoverableBrowserContextError(new Error('node_repl exec context not found')), true);
  assert.equal(isRecoverableBrowserContextError(new Error('tab abc is stale')), true);
  assert.equal(isRecoverableBrowserContextError(new Error('Timed out running CDP command "Runtime.evaluate" for tab 1')), true);
  assert.equal(isRecoverableBrowserContextError(new Error('CDP operation exceeded its deadline before command dispatch')), true);
  assert.equal(isRecoverableBrowserContextError(new Error('可用浏览器数组暂时不可用')), true);
  assert.equal(isRecoverableBrowserContextError(new Error('没有找到 Chat 输入框')), false);
});

test('page-load failures are detected without refreshing normal response errors', () => {
  assert.equal(isPageLoadFailureState({
    bodyText: '页面无法加载，请点击重新加载。',
    controls: [{ label: '重新加载', disabled: false }],
    hasComposer: false,
    hasWorkComposer: false,
    pendingAuthorization: false,
  }), true);
  assert.equal(isPageLoadFailureState({
    bodyText: 'Something went wrong while generating this response.',
    controls: [],
    hasComposer: true,
    hasWorkComposer: false,
    pendingAuthorization: false,
  }), false);
  assert.equal(isPageLoadFailureState({
    bodyText: '普通聊天内容',
    controls: [{ label: '重新加载', disabled: true }],
    hasComposer: false,
    hasWorkComposer: false,
    pendingAuthorization: false,
  }), false);
});

test('renderer crash pages are recognized as recoverable tab failures', () => {
  assert.equal(isPageLoadFailureState({
    url: 'data:text/html;charset=utf-8,This%20page%20crashed',
    title: 'This page crashed',
    bodyText: 'This page crashed chatgpt.com crashed unexpectedly',
    controls: [],
    hasComposer: false,
    hasWorkComposer: false,
    pendingAuthorization: false,
  }), true);
  assert.equal(isPageLoadFailureState({
    url: 'https://chatgpt.com/g/fabushi/c/healthy',
    title: '目标会话',
    bodyText: '用户讨论了页面崩溃这个词，但会话正常。',
    controls: [],
    hasComposer: true,
    hasWorkComposer: false,
    pendingAuthorization: false,
  }), false);
});

test('a restored conversation refreshes itself when the Browser page cannot load', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'chatgpt-auto-confirm-refresh-'));
  const capabilityFile = join(directory, 'capability.json');
  const jobStateFile = join(directory, 'job.json');
  const targetUrl = 'https://chatgpt.com/g/fabushi/c/conversation-refresh';
  await writeFile(jobStateFile, `${JSON.stringify({
    id: 'iab_24681357-1357-4246-8462-135724680246',
    goal: '完成完整目标',
    status: 'waiting_for_browser_host',
    phase: 'waiting',
    attempt: 0,
    startedAt: new Date().toISOString(),
    updatedAt: new Date().toISOString(),
    currentUrl: targetUrl,
    conversationId: 'conversation-refresh',
    responseRunning: false,
    beforeAssistantCount: 0,
    beforeUserCount: 0,
  })}\n`);
  let loaded = false;
  let reloads = 0;
  const healthyState = {
    url: targetUrl,
    title: '目标会话',
    conversationId: 'conversation-refresh',
    assistantCount: 0,
    userCount: 0,
    latestAssistantText: '',
    latestUserText: '',
    bodyText: '目标会话已加载',
    controls: [],
    pendingAuthorization: false,
    stopAnswer: false,
    retry: false,
    hasComposer: true,
    hasWorkComposer: false,
    chatTabSelected: true,
    bodyLowerTail: '目标会话已加载',
  };
  const brokenState = {
    ...healthyState,
    bodyText: '页面无法加载，请点击重新加载。',
    controls: [{ label: '重新加载', disabled: false }],
    hasComposer: false,
  };
  const tab = {
    id: 'refresh',
    playwright: {
      evaluate: async () => loaded ? healthyState : brokenState,
    },
    url: async () => targetUrl,
    reload: async () => { reloads += 1; loaded = true; },
    goto: async () => { loaded = true; },
    markHandoff: async () => {},
  };
  const host = await createInAppBrowserCapabilityHost({
    browser: { tabs: {} },
    tab,
    startUrl: targetUrl,
    capabilityFile,
    jobStateFile,
  });
  try {
    const result = await host.runStep();
    assert.equal(reloads, 1);
    assert.equal(result.status, 'starting');
    assert.equal(result.error, null);
  } finally {
    await host.close();
  }
});

test('a restored job repairs a lost conversation id from its task-owned tab', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'chatgpt-auto-confirm-repair-target-'));
  const capabilityFile = join(directory, 'capability.json');
  const jobStateFile = join(directory, 'job.json');
  const projectUrl = 'https://chatgpt.com/g/fabushi/project';
  const conversationUrl = 'https://chatgpt.com/g/fabushi/c/conversation-repaired';
  await writeFile(jobStateFile, `${JSON.stringify({
    id: 'iab_24681357-2468-4246-8462-135724680246',
    goal: '继续完整目标',
    status: 'waiting_for_browser_host',
    phase: 'waiting',
    attempt: 1,
    startedAt: new Date().toISOString(),
    updatedAt: new Date().toISOString(),
    currentUrl: projectUrl,
    conversationId: null,
    responseRunning: true,
    beforeAssistantCount: 0,
    beforeUserCount: 0,
  })}\n`);
  let gotoCount = 0;
  const pageState = {
    url: conversationUrl,
    title: '目标会话',
    conversationId: 'conversation-repaired',
    assistantCount: 0,
    userCount: 0,
    latestAssistantText: '',
    latestUserText: '',
    bodyText: '目标会话已加载',
    controls: [],
    pendingAuthorization: false,
    stopAnswer: false,
    retry: false,
    hasComposer: true,
    hasWorkComposer: false,
    chatTabSelected: true,
    bodyLowerTail: '目标会话已加载',
  };
  const tab = {
    id: 'repaired-target-tab',
    playwright: { evaluate: async () => pageState },
    url: async () => conversationUrl,
    goto: async () => { gotoCount += 1; },
    markHandoff: async () => {},
  };
  const host = await createInAppBrowserCapabilityHost({
    browser: { tabs: {} },
    tab,
    startUrl: projectUrl,
    capabilityFile,
    jobStateFile,
  });
  try {
    const result = await host.runStep();
    assert.equal(result.status, 'starting');
    assert.equal(result.currentUrl, conversationUrl);
    assert.equal(result.conversationId, 'conversation-repaired');
    assert.equal(gotoCount, 0);
  } finally {
    await host.close();
  }
});

test('the secondary restored job repairs its own delayed conversation URL', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'chatgpt-auto-confirm-secondary-repair-'));
  const capabilityFile = join(directory, 'capability.json');
  const jobStateFile = join(directory, 'jobs.json');
  const now = new Date().toISOString();
  const firstUrl = 'https://chatgpt.com/g/fabushi/c/first-conversation';
  const secondUrl = 'https://chatgpt.com/g/fabushi/c/second-conversation';
  const secondId = 'iab_24681357-8642-4246-8462-135724680246';
  await writeFile(jobStateFile, `${JSON.stringify({
    schema: 'chatgpt-auto-confirm.browser-jobs.v2',
    maxConcurrentJobs: 2,
    jobs: [
      {
        id: 'iab_13572468-1357-4246-8462-246813572468',
        goal: '继续第一项任务',
        status: 'running',
        phase: 'waiting',
        startedAt: now,
        updatedAt: now,
        currentUrl: firstUrl,
        conversationId: 'first-conversation',
      },
      {
        id: secondId,
        goal: '继续第二项任务',
        status: 'waiting_for_browser_host',
        phase: 'waiting',
        startedAt: now,
        updatedAt: now,
        currentUrl: 'https://chatgpt.com/g/fabushi/project',
        conversationId: null,
        tabId: 'secondary-task-tab',
      },
    ],
  })}\n`);
  const pageState = {
    url: secondUrl,
    title: '第二项任务',
    conversationId: 'second-conversation',
    assistantCount: 0,
    userCount: 0,
    latestAssistantText: '',
    latestUserText: '',
    bodyText: '第二项任务会话已加载',
    controls: [],
    pendingAuthorization: false,
    stopAnswer: false,
    retry: false,
    hasComposer: true,
    hasWorkComposer: false,
    chatTabSelected: true,
    bodyLowerTail: '第二项任务会话已加载',
  };
  let gotoCount = 0;
  const secondTab = {
    id: 'secondary-task-tab',
    playwright: { evaluate: async () => pageState },
    url: async () => secondUrl,
    goto: async () => { gotoCount += 1; },
    markHandoff: async () => {},
  };
  const firstTab = fakeTab('first-task-tab', firstUrl);
  const host = await createInAppBrowserCapabilityHost({
    browser: { tabs: { get: async id => {
      assert.equal(id, secondTab.id);
      return secondTab;
    } } },
    tab: firstTab,
    startUrl: firstUrl,
    capabilityFile,
    jobStateFile,
  });
  try {
    const result = await host.runStep({ jobId: secondId });
    assert.equal(result.status, 'starting');
    assert.equal(result.currentUrl, secondUrl);
    assert.equal(result.conversationId, 'second-conversation');
    assert.equal(gotoCount, 0);
  } finally {
    await host.close();
  }
});

test('Browser reattachment rebinds an exact controlled conversation first', async () => {
  const targetUrl = 'https://chatgpt.com/g/fabushi/c/conversation-1';
  const rebound = fakeTab('controlled-1', targetUrl);
  let created = 0;
  const browser = {
    tabs: {
      list: async () => [{ id: 'controlled-1', url: `${targetUrl}?model=sol` }],
      get: async id => {
        assert.equal(id, 'controlled-1');
        return rebound;
      },
      new: async () => { created += 1; return fakeTab('new', 'about:blank'); },
    },
    user: { openTabs: async () => [], claimTab: async () => { throw new Error('unexpected claim'); } },
  };
  const result = await reattachInAppBrowserTab({ browser, targetUrl });
  assert.equal(result.method, 'controlled-tab');
  assert.equal(result.tab, rebound);
  assert.equal(rebound.handoff, true);
  assert.equal(created, 0);
});

test('Browser reattachment prefers the persisted task tab for a project-entry target', async () => {
  const targetUrl = 'https://chatgpt.com/g/fabushi/project';
  const preferred = fakeTab(
    'persisted-release-tab',
    'https://chatgpt.com/g/fabushi/c/release-conversation',
  );
  let listed = false;
  let created = 0;
  const browser = {
    tabs: {
      get: async id => {
        assert.equal(id, preferred.id);
        return preferred;
      },
      list: async () => {
        listed = true;
        return [];
      },
      new: async () => {
        created += 1;
        return fakeTab('unexpected-new-tab', 'about:blank');
      },
    },
  };
  const result = await reattachInAppBrowserTab({
    browser,
    targetUrl,
    preferredTabId: preferred.id,
  });
  assert.equal(result.method, 'preferred-tab');
  assert.equal(result.tab, preferred);
  assert.equal(preferred.handoff, true);
  assert.equal(listed, false);
  assert.equal(created, 0);
});

test('Browser reattachment discards a persisted renderer-crash tab before opening a live tab', async () => {
  const targetUrl = 'https://chatgpt.com/g/fabushi/c/recover-after-crash';
  let closed = false;
  let created = 0;
  const broken = {
    id: 'persisted-crash-tab',
    playwright: {},
    url: async () => 'data:text/html;charset=utf-8,This%20page%20crashed',
    close: async () => { closed = true; },
    markHandoff: async () => {},
  };
  const live = {
    id: 'fresh-live-tab',
    playwright: {},
    goto: async value => { live.currentUrl = value; },
    url: async () => live.currentUrl,
    markHandoff: async () => {},
    currentUrl: 'about:blank',
  };
  const browser = {
    tabs: {
      get: async id => {
        assert.equal(id, broken.id);
        return broken;
      },
      list: async () => [],
      new: async () => { created += 1; return live; },
    },
  };
  const result = await reattachInAppBrowserTab({
    browser,
    targetUrl,
    preferredTabId: broken.id,
  });
  assert.equal(result.method, 'new-tab');
  assert.equal(result.tab, live);
  assert.equal(closed, true);
  assert.equal(created, 1);
  assert.equal(result.url, targetUrl);
});

test('Browser reattachment does not let a persisted tab cross project ownership', async () => {
  const targetUrl = 'https://chatgpt.com/g/fabushi/project';
  const foreign = fakeTab(
    'persisted-foreign-tab',
    'https://chatgpt.com/g/another-project/c/foreign-conversation',
  );
  const replacement = fakeTab('replacement-tab', targetUrl);
  let created = 0;
  const browser = {
    tabs: {
      get: async id => {
        if (id === foreign.id) return foreign;
        if (id === replacement.id) return replacement;
        throw new Error(`unexpected tab ${id}`);
      },
      list: async () => [],
      new: async () => {
        created += 1;
        return replacement;
      },
    },
  };
  const result = await reattachInAppBrowserTab({
    browser,
    targetUrl,
    preferredTabId: foreign.id,
  });
  assert.equal(result.method, 'new-tab');
  assert.equal(result.tab, replacement);
  assert.equal(created, 1);
  assert.equal(foreign.handoff, false);
});

test('Browser reattachment does not steal a persisted tab on an unrelated external page', async () => {
  const targetUrl = 'https://chatgpt.com/g/fabushi/project';
  const foreign = fakeTab('persisted-external-tab', 'https://example.com/account');
  const replacement = fakeTab('replacement-external-tab', targetUrl);
  const browser = {
    tabs: {
      get: async id => id === foreign.id ? foreign : replacement,
      list: async () => [],
      new: async () => replacement,
    },
  };
  const result = await reattachInAppBrowserTab({
    browser,
    targetUrl,
    preferredTabId: foreign.id,
  });
  assert.equal(result.method, 'new-tab');
  assert.equal(result.tab, replacement);
  assert.equal(foreign.handoff, false);
});

test('Browser reattachment retries a transient missing collection and accepts an envelope', async () => {
  const targetUrl = 'https://chatgpt.com/g/fabushi/c/conversation-transient-list';
  const rebound = fakeTab('controlled-transient', targetUrl);
  let listCalls = 0;
  const events = [];
  const browser = {
    tabs: {
      list: async () => {
        listCalls += 1;
        if (listCalls < 3) return undefined;
        return { tabs: [{ id: 'controlled-transient', url: targetUrl }] };
      },
      get: async id => {
        assert.equal(id, 'controlled-transient');
        return rebound;
      },
      new: async () => { throw new Error('should not create a duplicate tab'); },
    },
  };
  const result = await reattachInAppBrowserTab({
    browser,
    targetUrl,
    logger: event => events.push(event),
  });
  assert.equal(result.method, 'controlled-tab');
  assert.equal(result.tab, rebound);
  assert.equal(listCalls, 3);
  assert.ok(events.some(event => event.event === 'browser_collection_retry'));
  assert.ok(events.some(event => event.event === 'browser_collection_recovered'));
});

test('Browser reattachment claims an exact released conversation before opening a new tab', async () => {
  const targetUrl = 'https://chatgpt.com/g/fabushi/c/conversation-2';
  const claimed = fakeTab('claimed-2', targetUrl);
  let created = 0;
  const openTab = { id: 'claim-handle', providerTabId: 'provider-2', url: targetUrl, title: '目标会话' };
  const browser = {
    tabs: {
      list: async () => [],
      get: async () => { throw new Error('unexpected get'); },
      new: async () => { created += 1; return fakeTab('new', 'about:blank'); },
    },
    user: {
      openTabs: async () => [openTab],
      claimTab: async value => {
        assert.equal(value, openTab);
        return claimed;
      },
    },
  };
  const result = await reattachInAppBrowserTab({ browser, targetUrl });
  assert.equal(result.method, 'claimed-user-tab');
  assert.equal(result.tab, claimed);
  assert.equal(claimed.handoff, true);
  assert.equal(created, 0);
});

test('Browser reattachment creates and preserves a target tab only as the final fallback', async () => {
  const targetUrl = 'https://chatgpt.com/g/fabushi/c/conversation-3';
  const created = fakeTab('new-3', 'https://chatgpt.com/');
  const browser = {
    tabs: {
      list: async () => [],
      get: async () => { throw new Error('unexpected get'); },
      new: async () => created,
    },
    user: { openTabs: async () => [], claimTab: async () => { throw new Error('unexpected claim'); } },
  };
  const result = await reattachInAppBrowserTab({ browser, targetUrl });
  assert.equal(result.method, 'new-tab');
  assert.equal(await created.url(), targetUrl);
  assert.equal(created.handoff, true);
});

function emptyLocator() {
  return {
    count: async () => 0,
    nth: () => emptyLocator(),
    all: async () => [],
    press: async () => {},
  };
}

test('authorization falls back to the direct Allow button when no session scope is available', async () => {
  let allowClicks = 0;
  const allow = {
    count: async () => 1,
    nth: () => allow,
    isVisible: async () => true,
    isEnabled: async () => true,
    click: async () => { allowClicks += 1; },
  };
  const tab = {
    playwright: {
      evaluate: async () => ({ pendingAuthorization: allowClicks === 0, stopAnswer: true }),
      getByRole: (role, options = {}) => (
        role === 'button' && options.name === 'Allow' ? allow : emptyLocator()
      ),
      getByText: () => emptyLocator(),
      locator: () => emptyLocator(),
    },
  };
  const result = await approveAuthorization(tab);
  assert.deepEqual(result, { ok: true, found: true, method: 'direct-allow-fallback' });
  assert.equal(allowClicks, 1);
});

test('authorization closes an unusable scope menu and directly approves the card', async () => {
  let arrowClicks = 0;
  let allowClicks = 0;
  let escapePresses = 0;
  const allow = {
    count: async () => 1,
    nth: () => allow,
    isVisible: async () => true,
    isEnabled: async () => true,
    click: async () => { allowClicks += 1; },
    evaluate: async () => ({
      label: 'Allow', ariaHasPopup: null, ariaExpanded: null, dataState: null,
      rect: { left: 10, right: 90, top: 10, bottom: 40 }, disabled: false,
    }),
  };
  const arrow = {
    isVisible: async () => true,
    isEnabled: async () => true,
    click: async () => { arrowClicks += 1; },
    evaluate: async () => ({
      label: 'More options', ariaHasPopup: 'menu', ariaExpanded: 'false', dataState: 'closed',
      rect: { left: 91, right: 110, top: 10, bottom: 40 }, disabled: false,
    }),
  };
  const tab = {
    playwright: {
      evaluate: async () => ({ pendingAuthorization: allowClicks === 0 }),
      getByRole: (role, options = {}) => (
        role === 'button' && options.name === 'Allow' ? allow : emptyLocator()
      ),
      getByText: () => emptyLocator(),
      locator: selector => {
        if (selector === 'button, [role="button"]') {
          return { ...emptyLocator(), all: async () => [allow, arrow] };
        }
        if (selector === 'body') {
          return { ...emptyLocator(), press: async key => {
            assert.equal(key, 'Escape');
            escapePresses += 1;
          } };
        }
        return emptyLocator();
      },
    },
  };
  const result = await approveAuthorization(tab);
  assert.deepEqual(result, { ok: true, found: true, method: 'arrow-then-direct-allow-fallback' });
  assert.equal(arrowClicks, 1);
  assert.equal(escapePresses, 1);
  assert.equal(allowClicks, 1);
});

test('authorization treats a card that disappears during scope selection as resolved', async () => {
  let arrowClicks = 0;
  let escapePresses = 0;
  let reads = 0;
  const allow = {
    isVisible: async () => true,
    isEnabled: async () => true,
    evaluate: async () => ({
      label: 'Allow', ariaHasPopup: null, ariaExpanded: null, dataState: null,
      rect: { left: 10, right: 90, top: 10, bottom: 40 }, disabled: false,
    }),
  };
  const arrow = {
    isVisible: async () => true,
    isEnabled: async () => true,
    click: async () => { arrowClicks += 1; },
    evaluate: async () => ({
      label: 'More options', ariaHasPopup: 'menu', ariaExpanded: 'false', dataState: 'closed',
      rect: { left: 91, right: 110, top: 10, bottom: 40 }, disabled: false,
    }),
  };
  const tab = {
    playwright: {
      evaluate: async () => {
        reads += 1;
        return reads === 1
          ? { pendingAuthorization: true, stopAnswer: false }
          : { pendingAuthorization: false, stopAnswer: true };
      },
      getByRole: () => emptyLocator(),
      getByText: () => emptyLocator(),
      locator: selector => {
        if (selector === 'button, [role="button"]') {
          return { ...emptyLocator(), all: async () => [allow, arrow] };
        }
        if (selector === 'body') {
          return { ...emptyLocator(), press: async key => {
            assert.equal(key, 'Escape');
            escapePresses += 1;
          } };
        }
        return emptyLocator();
      },
    },
  };
  const result = await approveAuthorization(tab);
  assert.deepEqual(result, {
    ok: true,
    found: true,
    method: 'authorization-settled-during-scope-selection',
  });
  assert.equal(arrowClicks, 1);
  assert.equal(escapePresses, 1);
  assert.equal(reads, 2);
});

test('a persisted job automatically retries the same step after its tab binding is replaced', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'chatgpt-auto-confirm-reattach-'));
  const capabilityFile = join(directory, 'capability.json');
  const jobStateFile = join(directory, 'job.json');
  const targetUrl = 'https://chatgpt.com/g/fabushi/c/conversation-4';
  const job = {
    id: 'iab_12345678-1234-4234-8234-123456789012',
    goal: '完成完整目标',
    status: 'waiting_for_browser_host',
    phase: 'waiting',
    attempt: 0,
    startedAt: new Date().toISOString(),
    updatedAt: new Date().toISOString(),
    currentUrl: targetUrl,
    conversationId: 'conversation-4',
    responseRunning: false,
    beforeAssistantCount: 0,
    beforeUserCount: 0,
  };
  await writeFile(jobStateFile, `${JSON.stringify(job)}\n`);
  const staleTab = {
    id: 'stale',
    playwright: { evaluate: async () => { throw new Error('node_repl exec context not found'); } },
  };
  const pageState = {
    url: targetUrl,
    title: '目标会话',
    conversationId: 'conversation-4',
    assistantCount: 0,
    userCount: 0,
    latestAssistantText: '',
    latestUserText: '',
    bodyText: '',
    controls: [],
    allowButtonCount: 0,
    pendingAuthorization: false,
    stopAnswer: false,
    retry: false,
    hasComposer: true,
    hasWorkComposer: false,
    chatTabSelected: true,
    bodyLowerTail: '',
  };
  const healthyTab = {
    id: 'healthy',
    playwright: { evaluate: async () => pageState },
    goto: async value => { pageState.url = value; },
    markHandoff: async () => {},
    url: async () => pageState.url,
  };
  let recoveries = 0;
  const host = await createInAppBrowserCapabilityHost({
    browser: { tabs: {} },
    tab: staleTab,
    startUrl: targetUrl,
    capabilityFile,
    jobStateFile,
    recoverTab: async ({ targetUrl: requestedTarget }) => {
      recoveries += 1;
      assert.equal(requestedTarget, targetUrl);
      return { tab: healthyTab, method: 'controlled-tab', url: targetUrl };
    },
  });
  try {
    const result = await host.runStep();
    assert.equal(recoveries, 1);
    assert.equal(result.status, 'starting');
    assert.equal(result.reattachCount, 1);
    assert.equal(result.lastReattachMethod, 'controlled-tab');
    assert.equal(result.lastReattachError, null);
    assert.equal(result.error, null);
  } finally {
    await host.close();
  }
});

test('a crashed bound tab is reloaded in place before the queue creates another tab', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'chatgpt-auto-confirm-crashed-tab-'));
  const capabilityFile = join(directory, 'capability.json');
  const jobStateFile = join(directory, 'job.json');
  const targetUrl = 'https://chatgpt.com/g/fabushi/c/conversation-crashed';
  await writeFile(jobStateFile, `${JSON.stringify({
    id: 'iab_44444444-5555-4666-8777-888888888888',
    goal: '完成完整目标',
    status: 'waiting_for_browser_host',
    phase: 'waiting',
    attempt: 1,
    startedAt: new Date().toISOString(),
    updatedAt: new Date().toISOString(),
    currentUrl: targetUrl,
    conversationId: 'conversation-crashed',
    responseRunning: false,
    beforeAssistantCount: 0,
    beforeUserCount: 0,
  })}\n`);
  let currentUrl = 'data:text/html;charset=utf-8,This%20page%20crashed';
  let gotoCount = 0;
  const healthyState = {
    url: targetUrl,
    title: '目标会话',
    conversationId: 'conversation-crashed',
    assistantCount: 0,
    userCount: 0,
    latestAssistantText: '',
    latestUserText: '',
    bodyText: '目标会话已加载',
    controls: [],
    pendingAuthorization: false,
    stopAnswer: false,
    retry: false,
    hasComposer: true,
    hasWorkComposer: false,
    chatTabSelected: true,
    bodyLowerTail: '目标会话已加载',
  };
  const tab = {
    id: 'crashed-bound-tab',
    playwright: { evaluate: async () => ({ ...healthyState, url: currentUrl }) },
    url: async () => currentUrl,
    goto: async value => { gotoCount += 1; currentUrl = value; },
    markHandoff: async () => {},
  };
  let fallbackRecoveries = 0;
  const host = await createInAppBrowserCapabilityHost({
    browser: { tabs: {} },
    tab,
    startUrl: targetUrl,
    capabilityFile,
    jobStateFile,
    recoverTab: async () => {
      fallbackRecoveries += 1;
      throw new Error('不应在原标签页重载成功时走外部恢复');
    },
  });
  try {
    const result = await host.runStep();
    assert.equal(result.status, 'starting');
    assert.equal(result.lastReattachMethod, 'reloaded-broken-tab');
    assert.equal(result.reattachCount, 1);
    assert.equal(gotoCount, 1);
    assert.equal(fallbackRecoveries, 0);
    assert.equal(result.lastTabFailure, null);
  } finally {
    await host.close();
  }
});

test('a closed bound tab is detected and reattached to the same conversation', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'chatgpt-auto-confirm-closed-tab-'));
  const capabilityFile = join(directory, 'capability.json');
  const jobStateFile = join(directory, 'job.json');
  const targetUrl = 'https://chatgpt.com/g/fabushi/c/conversation-closed';
  await writeFile(jobStateFile, `${JSON.stringify({
    id: 'iab_55555555-6666-4777-8888-999999999999',
    goal: '完成完整目标',
    status: 'waiting_for_browser_host',
    phase: 'waiting',
    attempt: 1,
    startedAt: new Date().toISOString(),
    updatedAt: new Date().toISOString(),
    currentUrl: targetUrl,
    conversationId: 'conversation-closed',
    responseRunning: false,
  })}\n`);
  const closedTab = {
    id: 'closed-bound-tab',
    playwright: { evaluate: async () => { throw new Error('tab closed'); } },
    url: async () => { throw new Error('tab closed'); },
  };
  const pageState = {
    url: targetUrl,
    title: '目标会话',
    conversationId: 'conversation-closed',
    assistantCount: 0,
    userCount: 0,
    latestAssistantText: '',
    latestUserText: '',
    bodyText: '目标会话已加载',
    controls: [],
    pendingAuthorization: false,
    stopAnswer: false,
    retry: false,
    hasComposer: true,
    hasWorkComposer: false,
    chatTabSelected: true,
    bodyLowerTail: '目标会话已加载',
  };
  const healthyTab = {
    id: 'reattached-closed-tab',
    playwright: { evaluate: async () => pageState },
    url: async () => targetUrl,
    markHandoff: async () => {},
  };
  let recoveries = 0;
  const host = await createInAppBrowserCapabilityHost({
    browser: { tabs: {} },
    tab: closedTab,
    startUrl: targetUrl,
    capabilityFile,
    jobStateFile,
    recoverTab: async ({ targetUrl: requestedTarget }) => {
      recoveries += 1;
      assert.equal(requestedTarget, targetUrl);
      return { tab: healthyTab, method: 'new-tab', url: targetUrl };
    },
  });
  try {
    const result = await host.runStep();
    assert.equal(result.status, 'starting');
    assert.equal(result.lastReattachMethod, 'new-tab');
    assert.equal(result.reattachCount, 1);
    assert.equal(recoveries, 1);
    assert.match(result.lastTabFailure, /控制句柄失效/);
  } finally {
    await host.close();
  }
});

test('a persisted Browser-host failure is revived instead of treated as a terminal task failure', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'chatgpt-auto-confirm-revive-timeout-'));
  const capabilityFile = join(directory, 'capability.json');
  const jobStateFile = join(directory, 'job.json');
  const now = new Date().toISOString();
  await writeFile(jobStateFile, `${JSON.stringify({
    id: 'iab_33333333-4444-4555-8666-777777777777',
    goal: '完成完整目标',
    status: 'failed',
    phase: 'waiting',
    attempt: 2,
    startedAt: now,
    updatedAt: now,
    currentUrl: 'https://chatgpt.com/g/fabushi/c/conversation-timeout',
    conversationId: 'conversation-timeout',
    error: '没有找到 Chat 输入框',
  })}\n`);
  const host = await createInAppBrowserCapabilityHost({
    browser: { tabs: {} },
    tab: { id: 'revived-timeout', playwright: {} },
    startUrl: 'https://chatgpt.com/g/fabushi/project',
    capabilityFile,
    jobStateFile,
  });
  try {
    assert.equal(host.activeJob.status, 'waiting_for_browser_host');
    assert.match(host.activeJob.error, /自动恢复同一任务/);
    assert.equal(host.activeJob.id, 'iab_33333333-4444-4555-8666-777777777777');
  } finally {
    await host.close();
  }
});

test('two Browser goals keep isolated tabs while one pump advances both jobs', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'chatgpt-auto-confirm-parallel-jobs-'));
  const capabilityFile = join(directory, 'capability.json');
  const jobStateFile = join(directory, 'job.json');
  const now = new Date().toISOString();
  const existingUrl = 'https://chatgpt.com/g/fabushi/c/existing-parallel-goal';
  await writeFile(jobStateFile, `${JSON.stringify({
    id: 'iab_10101010-2020-4030-8040-505050505050',
    goal: '继续已有发布目标',
    status: 'running',
    phase: 'waiting',
    attempt: 1,
    startedAt: now,
    updatedAt: now,
    currentUrl: existingUrl,
    conversationId: 'existing-parallel-goal',
  })}\n`);
  const existingTab = fakeTab('existing-parallel-tab', existingUrl);
  const createdTabs = [];
  const browser = {
    tabs: {
      new: async () => {
        const tab = fakeTab(`parallel-tab-${createdTabs.length + 1}`, 'about:blank');
        createdTabs.push(tab);
        return tab;
      },
    },
  };
  const host = await createInAppBrowserCapabilityHost({
    browser,
    tab: existingTab,
    startUrl: existingUrl,
    capabilityFile,
    jobStateFile,
  });
  const request = async (pathname, body) => {
    const response = await fetch(`${host.baseUrl}${pathname}`, {
      method: body === undefined ? 'GET' : 'POST',
      headers: {
        authorization: `Bearer ${host.token}`,
        ...(body === undefined ? {} : { 'content-type': 'application/json' }),
      },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    return { status: response.status, body: await response.json() };
  };
  try {
    const dispatched = await request('/v1/chat/dispatch', {
      goal: '在独立标签页推进 RustDesk 融合目标',
      policy: BROWSER_DISPATCH_POLICY,
    });
    assert.equal(dispatched.status, 202);
    assert.equal(dispatched.body.accepted, true);
    assert.equal(dispatched.body.jobs.length, MAX_PARALLEL_BROWSER_JOBS);
    assert.equal(createdTabs.length, 1);
    assert.equal(dispatched.body.job.tabId, 'parallel-tab-1');
    assert.notEqual(dispatched.body.job.tabId, existingTab.id);

    const capacity = await request('/v1/chat/dispatch', {
      goal: '不应覆盖前两个目标的第三个任务',
      policy: BROWSER_DISPATCH_POLICY,
    });
    assert.equal(capacity.status, 409);
    assert.equal(capacity.body.errorCode, 'browser_job_capacity_reached');

    const status = await request('/v1/capability');
    assert.equal(status.status, 200);
    assert.equal(status.body.jobs.length, MAX_PARALLEL_BROWSER_JOBS);
    assert.equal(status.body.activeJobs.length, MAX_PARALLEL_BROWSER_JOBS);

    const stepped = [];
    host.policy.pollIntervalMs = 1;
    host.runStep = async ({ jobId } = {}) => {
      const job = host.jobs.get(jobId);
      stepped.push(job.id);
      job.status = 'completed';
      job.phase = 'terminal';
      host.activeJob = job;
      return { ...job };
    };
    const result = await host.runPump({ leaseTimeoutMs: 200 });
    assert.equal(result.status, 'completed');
    assert.deepEqual(new Set(stepped), new Set([
      'iab_10101010-2020-4030-8040-505050505050',
      dispatched.body.job.id,
    ]));

    const persisted = JSON.parse(await readFile(jobStateFile, 'utf8'));
    assert.equal(persisted.schema, 'chatgpt-auto-confirm.browser-jobs.v2');
    assert.equal(persisted.jobs.length, MAX_PARALLEL_BROWSER_JOBS);
  } finally {
    await host.close();
  }
});

test('the long-lived pump and HTTP-style supervisor ticks share one step lock', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'chatgpt-auto-confirm-single-flight-'));
  const capabilityFile = join(directory, 'capability.json');
  const jobStateFile = join(directory, 'job.json');
  const targetUrl = 'https://chatgpt.com/g/fabushi/c/conversation-single-flight';
  const now = new Date().toISOString();
  await writeFile(jobStateFile, `${JSON.stringify({
    id: 'iab_87654321-4321-4234-8234-210987654321',
    goal: '完成完整目标',
    status: 'running',
    phase: 'waiting',
    attempt: 1,
    startedAt: now,
    updatedAt: now,
    currentUrl: targetUrl,
    conversationId: 'conversation-single-flight',
    responseRunning: false,
    beforeAssistantCount: 0,
    beforeUserCount: 0,
    stableSamples: 0,
    lastFingerprint: '',
    lastProgressAt: Date.now(),
  })}\n`);
  const pageState = {
    url: targetUrl,
    title: '目标会话',
    conversationId: 'conversation-single-flight',
    assistantCount: 0,
    userCount: 0,
    latestAssistantText: '',
    latestUserText: '',
    bodyText: '',
    controls: [],
    allowButtonCount: 0,
    pendingAuthorization: false,
    stopAnswer: false,
    retry: false,
    hasComposer: true,
    hasWorkComposer: false,
    chatTabSelected: true,
    bodyLowerTail: '',
  };
  let activeEvaluations = 0;
  let maximumConcurrentEvaluations = 0;
  const tab = {
    id: 'single-flight',
    playwright: {
      evaluate: async () => {
        activeEvaluations += 1;
        maximumConcurrentEvaluations = Math.max(maximumConcurrentEvaluations, activeEvaluations);
        await new Promise(resolvePromise => setTimeout(resolvePromise, 60));
        activeEvaluations -= 1;
        return pageState;
      },
    },
  };
  const host = await createInAppBrowserCapabilityHost({
    browser: { tabs: {} },
    tab,
    startUrl: targetUrl,
    capabilityFile,
    jobStateFile,
  });
  try {
    const pump = host.runPump();
    await new Promise(resolvePromise => setTimeout(resolvePromise, 10));
    const concurrentTick = await host.runStep();
    assert.equal(concurrentTick.id, 'iab_87654321-4321-4234-8234-210987654321');
    host.pumpStopRequested = true;
    await pump;
    assert.equal(maximumConcurrentEvaluations, 1);
  } finally {
    await host.close();
  }
});

test('runUntilTerminal returns when its active job is already terminal', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'chatgpt-auto-confirm-terminal-pump-'));
  const capabilityFile = join(directory, 'capability.json');
  const jobStateFile = join(directory, 'job.json');
  const now = new Date().toISOString();
  const terminalJob = {
    id: 'iab_11111111-2222-4333-8444-555555555555',
    goal: '完成完整目标',
    status: 'completed',
    phase: 'terminal',
    attempt: 1,
    startedAt: now,
    updatedAt: now,
  };
  const tab = { id: 'terminal', playwright: {} };
  const host = await createInAppBrowserCapabilityHost({
    browser: { tabs: {} },
    tab,
    startUrl: 'https://chatgpt.com/g/fabushi/project',
    capabilityFile,
    jobStateFile,
  });
  try {
    host.activeJob = terminalJob;
    const result = await Promise.race([
      host.runUntilTerminal(),
      new Promise((_, reject) => setTimeout(() => reject(new Error('runUntilTerminal did not return')), 200)),
    ]);
    assert.equal(result.status, 'completed');
    assert.equal(host.pumpActive, false);
  } finally {
    await host.close();
  }
});

test('runUntilTerminal automatically reattaches the same job after a lease rotation', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'chatgpt-auto-confirm-auto-reattach-'));
  const capabilityFile = join(directory, 'capability.json');
  const jobStateFile = join(directory, 'job.json');
  const now = new Date().toISOString();
  const activeJob = {
    id: 'iab_22222222-3333-4444-8555-666666666666',
    goal: '完成完整目标',
    status: 'running',
    phase: 'waiting',
    attempt: 1,
    startedAt: now,
    updatedAt: now,
  };
  let runSteps = 0;
  let recoveries = 0;
  const host = await createInAppBrowserCapabilityHost({
    browser: { tabs: {} },
    tab: { id: 'auto-reattach', playwright: {} },
    startUrl: 'https://chatgpt.com/g/fabushi/project',
    capabilityFile,
    jobStateFile,
    recoverTab: async () => {
      recoveries += 1;
      return { tab: { id: `rotated-${recoveries}`, playwright: {} }, method: 'controlled-tab', url: 'https://chatgpt.com/g/fabushi/project' };
    },
  });
  try {
    host.activeJob = activeJob;
    host.policy.pollIntervalMs = 5;
    host.runStep = async () => {
      runSteps += 1;
      host.activeJob.status = runSteps === 1 ? 'running' : 'completed';
      if (runSteps === 1) await new Promise(resolvePromise => setTimeout(resolvePromise, 40));
      return { ...host.activeJob };
    };
    const result = await host.runUntilTerminal({ leaseTimeoutMs: 25 });
    assert.equal(result.status, 'completed');
    assert.equal(recoveries, 1);
    assert.equal(result.reattachCount, 1);
  } finally {
    await host.close();
  }
});

test('a scheduled Browser slice yields persisted recovery state before its execution context expires', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'chatgpt-auto-confirm-scheduled-slice-'));
  const capabilityFile = join(directory, 'capability.json');
  const jobStateFile = join(directory, 'job.json');
  const now = new Date().toISOString();
  const activeJob = {
    id: 'iab_77777777-3333-4444-8555-666666666666',
    goal: '持续推进完整目标',
    status: 'running',
    phase: 'waiting',
    attempt: 1,
    startedAt: now,
    updatedAt: now,
  };
  let runSteps = 0;
  let recoveries = 0;
  const host = await createInAppBrowserCapabilityHost({
    browser: { tabs: {} },
    tab: { id: 'scheduled-slice', playwright: {} },
    startUrl: 'https://chatgpt.com/g/fabushi/project',
    capabilityFile,
    jobStateFile,
    recoverTab: async () => {
      recoveries += 1;
      return { tab: { id: `unexpected-${recoveries}`, playwright: {} }, method: 'controlled-tab' };
    },
  });
  try {
    host.activeJob = activeJob;
    host.policy.pollIntervalMs = 5;
    host.runStep = async () => {
      runSteps += 1;
      host.activeJob.status = 'running';
      return { ...host.activeJob };
    };
    const result = await host.runUntilTerminal({
      leaseTimeoutMs: 25,
      returnOnLeaseExpiry: true,
    });
    assert.equal(result.leaseSliceComplete, true);
    assert.equal(result.reattachRequired, true);
    assert.ok(runSteps > 0);
    assert.equal(recoveries, 0);
    assert.equal(host.activeJob.status, 'waiting_for_browser_host');
    const saved = JSON.parse(await readFile(jobStateFile, 'utf8'));
    assert.equal(saved.status, 'waiting_for_browser_host');
  } finally {
    await host.close();
  }
});

test('lease rotation drains a decided fresh-chat handoff before yielding', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'chatgpt-auto-confirm-lease-drain-'));
  const capabilityFile = join(directory, 'capability.json');
  const jobStateFile = join(directory, 'job.json');
  const now = new Date().toISOString();
  const jobId = 'iab_88888888-3333-4444-8555-666666666666';
  const activeJob = {
    id: jobId,
    goal: '在新 Chat 继续完整目标',
    status: 'handoff_to_fresh_chat',
    phase: 'accepted',
    attempt: 2,
    startedAt: now,
    updatedAt: now,
    currentUrl: 'https://chatgpt.com/g/fabushi/c/finished-chat',
    conversationId: 'finished-chat',
    responseRunning: false,
  };
  await writeFile(jobStateFile, `${JSON.stringify(activeJob)}\n`);
  const host = await createInAppBrowserCapabilityHost({
    browser: { tabs: {} },
    tab: { id: 'lease-drain', playwright: {} },
    startUrl: 'https://chatgpt.com/g/fabushi/project',
    capabilityFile,
    jobStateFile,
  });
  let steps = 0;
  try {
    host.policy.pollIntervalMs = 5;
    host.runStep = async ({ jobId: requestedJobId } = {}) => {
      steps += 1;
      assert.equal(requestedJobId, jobId);
      const job = host.jobs.get(requestedJobId);
      job.status = 'running';
      job.phase = 'waiting';
      job.responseRunning = true;
      job.currentUrl = 'https://chatgpt.com/g/fabushi/c/fresh-chat';
      job.conversationId = 'fresh-chat';
      return { ...job };
    };
    await new Promise(resolvePromise => setTimeout(resolvePromise, 5));
    await host.runPump({ leaseTimeoutMs: 1 });
    assert.equal(steps, 1);
    const saved = JSON.parse(await readFile(jobStateFile, 'utf8'));
    assert.equal(saved.status, 'waiting_for_browser_host');
    assert.equal(saved.phase, 'waiting');
    assert.equal(saved.currentUrl, 'https://chatgpt.com/g/fabushi/c/fresh-chat');
    assert.equal(saved.conversationId, 'fresh-chat');
  } finally {
    await host.close();
  }
});

test('a Browser lease rotates into recoverable reattachment before its execution expires', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'chatgpt-auto-confirm-lease-rotation-'));
  const capabilityFile = join(directory, 'capability.json');
  const jobStateFile = join(directory, 'job.json');
  const now = new Date().toISOString();
  const activeJob = {
    id: 'iab_99999999-8888-4777-8666-555555555555',
    goal: '完成完整目标',
    status: 'running',
    phase: 'waiting',
    attempt: 1,
    startedAt: now,
    updatedAt: now,
  };
  const host = await createInAppBrowserCapabilityHost({
    browser: { tabs: {} },
    tab: { id: 'lease-rotation', playwright: {} },
    startUrl: 'https://chatgpt.com/g/fabushi/project',
    capabilityFile,
    jobStateFile,
  });
  try {
    host.activeJob = activeJob;
    host.policy.pollIntervalMs = 5;
    host.runStep = async () => ({ ...activeJob });
    const result = await host.runPump({ leaseTimeoutMs: 25 });
    assert.equal(result.status, 'waiting_for_browser_host');
    assert.match(result.error, /主动轮换/);
    const saved = JSON.parse(await (await import('node:fs/promises')).readFile(jobStateFile, 'utf8'));
    assert.equal(saved.id, activeJob.id);
    assert.equal(saved.status, 'waiting_for_browser_host');
  } finally {
    await host.close();
  }
});
