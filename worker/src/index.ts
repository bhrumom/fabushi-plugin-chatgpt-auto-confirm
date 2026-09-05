import { HOME, RESOURCES } from './content.generated.ts';

const EMAIL_WORKFLOW_SUFFIX = '';


const DEFAULT_CHAT_TIMEOUT_SECONDS = 21_600;
const MAX_CHAT_TIMEOUT_SECONDS = 86_400;
const CHAT_STAGNATION_TIMEOUT_SECONDS = 10_800;
const PLUGIN_DISPATCH_BROWSER = 'iab';
const PLUGIN_DISPATCH_CAPABILITY = 'browser.in-app.dispatch-and-watch';
const PLUGIN_DISPATCH_MODEL = 'GPT-5.6 Sol';
const PLUGIN_DISPATCH_REASONING = 'Extra High';
const PLUGIN_MAX_CONCURRENT_BROWSER_JOBS = 2;

const pluginDispatchParams = (goal: string) => ({
  // The plugin accepts only a goal. It deliberately does not accept a prior
  // reply, progress log, or continuation text from the caller.
  message: goal,
  browser: PLUGIN_DISPATCH_BROWSER,
  capability: PLUGIN_DISPATCH_CAPABILITY,
  connector: null,
  model: PLUGIN_DISPATCH_MODEL,
  reasoning: PLUGIN_DISPATCH_REASONING,
  surface: 'chat',
  newChat: true,
  resumeExisting: false,
  goalOnlyDispatch: true,
  approveAll: true,
  timeout: DEFAULT_CHAT_TIMEOUT_SECONDS,
  stagnationTimeout: CHAT_STAGNATION_TIMEOUT_SECONDS,
  maxRecoveryAttempts: 5,
  autoContinueIncomplete: true,
  maxTaskContinuations: 0,
  continuationMessage: null,
  maxConcurrentJobs: PLUGIN_MAX_CONCURRENT_BROWSER_JOBS,
  pollIntervalMs: 500,
});

const taskPromptTemplates = [
  { id: 'implement-and-verify', title: '实现并验证', description: '完成实现并运行相应验证。', promptPrefix: `请在当前 checkout 中完成下面的实现任务，检查现有改动后继续，运行与风险相称的验证，不要覆盖无关改动：\n\n${EMAIL_WORKFLOW_SUFFIX}\n\n` },
  { id: 'diagnose-fix-verify', title: '诊断、修复、验证', description: '定位根因后修复并回归验证。', promptPrefix: `请先用现有代码、日志和测试定位根因，然后修复并完成回归验证；不要只给建议：\n\n${EMAIL_WORKFLOW_SUFFIX}\n\n` },
  { id: 'review-and-fix', title: '审查并修正', description: '审查现有实现，修正真实问题并验证。', promptPrefix: `请审查当前 checkout 中与目标相关的实现，修正发现的真实问题并完成验证：\n\n${EMAIL_WORKFLOW_SUFFIX}\n\n` },
  { id: 'continue-to-complete', title: '持续完成目标', description: '从已有进度继续到全部验收通过。', promptPrefix: `请从当前 checkout 的已有进度继续，不要从头开始；持续工作直到以下目标和验收条件全部满足：\n\n${EMAIL_WORKFLOW_SUFFIX}\n\n` },
].map(template => ({ ...template, promptPrefix: '' }));

const reply = (id: unknown, result: unknown) => Response.json({ jsonrpc: '2.0', id, result });
const error = (id: unknown, code: number, message: string) => Response.json({
  jsonrpc: '2.0', id, error: { code, message },
});
const annotations = (readOnlyHint = false) => ({
  readOnlyHint, destructiveHint: false, openWorldHint: false,
});
const hostResult = (id: unknown, capability: string, params: unknown, approval: 'required' | 'none') =>
  reply(id, {
    content: [{ type: 'text', text: `已向大乘桌面宿主提交 ${capability}。` }],
    structuredContent: {
      handled: true,
      hostRequest: { transport: 'mcp-host-bridge', capability, params, approval },
    },
  });
const ruleSchema = {
  type: 'object', additionalProperties: false,
  required: ['application', 'action', 'resource'],
  properties: {
    application: { type: 'string', minLength: 1, description: '例如 GitHub' },
    action: { type: 'string', minLength: 1, description: '例如 Enable auto-merge' },
    resource: { type: 'string', minLength: 1, description: '例如 bhrumom/fabushi' },
  },
};
const queuedTaskSchema = {
  type: 'object', additionalProperties: false, required: ['title', 'prompt'],
  properties: {
    id: { type: 'string', pattern: '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$' },
    accountId: { type: 'string', pattern: '^acct_[0-9a-f]{12}$', description: '固定执行此任务的本机账号；不传时使用入队时的默认账号' },
    title: { type: 'string', minLength: 1, maxLength: 160 },
    prompt: { type: 'string', minLength: 1, maxLength: 10000 },
    promptTemplate: { type: 'string', enum: taskPromptTemplates.map(item => item.id), default: 'continue-to-complete' },
    revision: { type: 'integer', minimum: 1, default: 1 },
    specSources: { type: 'array', maxItems: 20, items: { type: 'string', minLength: 1, maxLength: 512 }, default: [] },
    directive: { type: 'string', maxLength: 10000, default: '' },
    applyMode: { type: 'string', enum: ['next_chat', 'interrupt'], default: 'next_chat' },
      source: { type: 'string', maxLength: 160 },
    connector: { type: 'string', minLength: 1, maxLength: 256, default: 'bhrum2', description: '本地工作区选 bhrum2；云端 GitHub/PR/Actions 选 GitHub' },
    dependsOn: { type: 'array', maxItems: 50, items: { type: 'string', pattern: '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$' }, default: [] },
    resourceLocks: { type: 'array', maxItems: 20, items: { type: 'string', minLength: 1, maxLength: 256 }, default: [] },
    priority: { type: 'integer', minimum: -100, maximum: 100, default: 0 },
    timeout: { type: 'integer', minimum: 60, maximum: MAX_CHAT_TIMEOUT_SECONDS, default: DEFAULT_CHAT_TIMEOUT_SECONDS },
    maxTaskContinuations: { type: 'integer', minimum: 0, maximum: 20, default: 0, description: '0 表示按退避策略持续新建分支 Chat 直到任务完成；正数表示显式上限' },
    maxRuntimeRetries: { type: 'integer', minimum: 0, maximum: 5, default: 2 },
  },
};
const tools = [
  { name: 'browser_reply_handoff', description: '注册网页回复结束后唤醒本地 Luna 中等推理任务；只有独立持久宿主和去重通知接口实际就绪才接受注册。注册成功后可结束本地回合，不轮询。', annotations: annotations(), inputSchema: {
    type: 'object', additionalProperties: false, required: ['action', 'watchId'], properties: {
      action: { type: 'string', enum: ['register', 'status', 'cancel'] },
      watchId: { type: 'string', pattern: '^[a-zA-Z0-9_-]{1,128}$' },
      tabId: { type: 'string' }, threadId: { type: 'string' },
      conversationUrl: { type: 'string' },
      expectedUserDigest: { type: 'string', description: '本轮已发送用户消息的 SHA-256，避免把旧回复当作新回复' },
      baselineAssistantDigest: { type: 'string', description: '发送前最后一条 assistant 消息的 SHA-256；不存在时为空字符串的 SHA-256' },
    },
  } },
  { name: 'account_list', description: '列出本机已注册的 ChatGPT 账号（不返回凭证、邮箱或 Cookie）', annotations: annotations(true), inputSchema: {
    type: 'object', additionalProperties: false, properties: {},
  } },
  { name: 'account_add', description: '打开隔离的 ChatGPT 登录窗口，登录后自动保存并验证一个账号', annotations: annotations(), inputSchema: {
    type: 'object', additionalProperties: false, properties: {
      label: { type: 'string', minLength: 1, maxLength: 80, description: '本机显示名称' },
      waitSeconds: { type: 'integer', minimum: 60, maximum: 1800, default: 600 },
      start: { type: 'boolean', default: true, description: '验证成功后是否启动该账号的 smoke Action' },
    },
  } },
  { name: 'account_login_link', description: '生成仅绑定 127.0.0.1、十分钟内一次有效的登录链接', annotations: annotations(), inputSchema: {
    type: 'object', additionalProperties: false, properties: {
      label: { type: 'string', maxLength: 80 },
    },
  } },
  { name: 'account_switch', description: '切换默认账号；已入队或运行中的任务不会改变', annotations: annotations(), inputSchema: {
    type: 'object', additionalProperties: false, required: ['accountId'], properties: {
      accountId: { type: 'string', pattern: '^acct_[0-9a-f]{12}$' },
    },
  } },
  { name: 'account_rename', description: '修改本机账号名称', annotations: annotations(), inputSchema: {
    type: 'object', additionalProperties: false, required: ['accountId', 'label'], properties: {
      accountId: { type: 'string', pattern: '^acct_[0-9a-f]{12}$' },
      label: { type: 'string', minLength: 1, maxLength: 80 },
    },
  } },
  { name: 'account_status', description: '检查账号本机凭证、云端最近验证和默认状态', annotations: annotations(true), inputSchema: {
    type: 'object', additionalProperties: false, properties: {
      accountId: { type: 'string', pattern: '^acct_[0-9a-f]{12}$' },
    },
  } },
  { name: 'account_sync', description: '从指定账号的隔离 ChatGPT renderer 导出最新 Cookie、保存凭证并启动 smoke Action', annotations: annotations(), inputSchema: {
    type: 'object', additionalProperties: false, properties: {
      accountId: { type: 'string', pattern: '^acct_[0-9a-f]{12}$' },
      waitSeconds: { type: 'integer', minimum: 30, maximum: 1800, default: 600 },
      start: { type: 'boolean', default: true },
    },
  } },
  { name: 'account_remove', description: '删除账号及本机凭据；运行中的任务会拒绝删除', annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false }, inputSchema: {
    type: 'object', additionalProperties: false, required: ['accountId'], properties: {
      accountId: { type: 'string', pattern: '^acct_[0-9a-f]{12}$' },
      confirm: { type: 'boolean', description: '必须显式确认删除' },
    },
  } },
  { name: 'login_and_sync_actions', description: 'Open the ChatGPT desktop app when needed, validate its signed-in app:// renderer and local Codex auth, then export the live renderer session over CDP and sync both credentials to GitHub Secrets.', annotations: {
    readOnlyHint: false, destructiveHint: false, openWorldHint: true,
  }, inputSchema: {
    type: 'object', additionalProperties: false, properties: {
      waitSeconds: { type: 'integer', minimum: 30, maximum: 1800, default: 600 },
      start: { type: 'boolean', default: true },
      accountId: { type: 'string', pattern: '^acct_[0-9a-f]{12}$' },
    },
  } },
  { name: 'sync_actions_credentials', description: 'Export the live authenticated app:// renderer session from an already-open ChatGPT desktop instance over CDP, validate local Codex auth, then upload both credentials to GitHub Secrets.', annotations: {
    readOnlyHint: false, destructiveHint: false, openWorldHint: true,
  }, inputSchema: {
    type: 'object', additionalProperties: false, properties: {
      waitSeconds: { type: 'integer', minimum: 30, maximum: 1800, default: 600 },
      start: { type: 'boolean', default: false, description: 'After syncing, optionally start the GitHub Actions runner.' },
      accountId: { type: 'string', pattern: '^acct_[0-9a-f]{12}$' },
    },
  } },
  { name: 'home', description: '加载插件首页', annotations: annotations(true), inputSchema: {
    type: 'object', additionalProperties: false, properties: {
      surface: { type: 'string' }, locale: { type: 'string' }, cursor: { type: 'string' },
      limit: { type: 'integer', minimum: 1, maximum: 10 },
    },
  } },
  { name: 'start', description: '启动 ChatGPT 后台已加载授权卡的全部自动确认', annotations: annotations(), inputSchema: {
    type: 'object', additionalProperties: false, properties: {
      rules: { type: 'array', minItems: 1, maxItems: 20, items: ruleSchema },
      approveAll: { type: 'boolean', description: '自动确认 ChatGPT 已加载的所有已识别授权卡' },
      chatTitles: { type: 'array', maxItems: 20, description: '兼容字段；严格后台模式不会切换任务', items: { type: 'string', minLength: 1, maxLength: 256 } },
      chatUrls: { type: 'array', maxItems: 20, description: '后台跟踪的 ChatGPT 对话地址；页面卸载后会用同一登录会话在隐藏目标中继续操作', items: { type: 'string', pattern: '^https://chatgpt\\.com/(?:$|c/)' } },
      intervalMs: { type: 'integer', minimum: 400, maximum: 5000, default: 750 },
    },
  } },
  { name: 'stop', description: '停止自动确认监听', annotations: annotations(), inputSchema: {
    type: 'object', additionalProperties: false, properties: {},
  } },
  { name: 'status', description: '读取监听、权限和规则状态', annotations: annotations(true), inputSchema: {
    type: 'object', additionalProperties: false, properties: {},
  } },
  { name: 'scan_once', description: '立即后台扫描并确认已加载的所有已识别授权卡', annotations: annotations(), inputSchema: {
    type: 'object', additionalProperties: false, properties: {},
  } },
  { name: 'relaunch_and_confirm', description: '让小程序自行重启 ChatGPT.app 开启调试通道并立刻确认授权卡', annotations: annotations(), inputSchema: {
    type: 'object', additionalProperties: false, properties: {
      approveAll: { type: 'boolean', description: '自动确认 ChatGPT 已加载的所有已识别授权卡' },
    },
  } },
  { name: 'audit_log', description: '读取仅保存在本机的最近审计记录', annotations: annotations(true), inputSchema: {
    type: 'object', additionalProperties: false, properties: {
      limit: { type: 'integer', minimum: 1, maximum: 100, default: 20 },
    },
  } },
  { name: 'diagnose', description: '只读检查 ChatGPT 已加载的辅助功能结构', annotations: annotations(true), inputSchema: {
    type: 'object', additionalProperties: false, properties: {},
  } },
  { name: 'dispatch_goal', description: '由插件通过受授权的内置 Browser 派发一个一次性完整目标：每个目标都有独立后台标签页；最多两个目标可同时持续推进。只发送 goal，固定选择聊天页、GPT-5.6 Sol 和极高，自动批准授权卡（优先会话范围，不可用时直接允许）；只有完整完成回执和验证证据才停止，未完成或回执缺失时自动续作', annotations: annotations(), inputSchema: {
    type: 'object', additionalProperties: false, required: ['goal'], properties: {
      goal: { type: 'string', minLength: 1, maxLength: 10000, description: '只填写原始目标；不要传入历史进度、上一轮回复或续作文本' },
    },
  } },
  { name: 'browser_capability_status', description: '只读查看受授权的内置 Browser capability、宿主健康、两个隔离标签页中的任务状态和重新附着要求', annotations: annotations(true), inputSchema: {
    type: 'object', additionalProperties: false, properties: {},
  } },
  { name: 'browser_job_status', description: '只读查看内置 Browser 派发任务的实时状态', annotations: annotations(true), inputSchema: {
    type: 'object', additionalProperties: false, required: ['jobId'], properties: {
      jobId: { type: 'string', pattern: '^iab_[A-Za-z0-9-]{20,100}$' },
    },
  } },
  { name: 'browser_watch', description: '启动或恢复插件持久 Browser 监督器；同时轮询最多两个隔离标签页。浏览器列表短暂为空、标签页失效或执行租约结束时自动重试/重新附着各自任务，不重复派发或携带历史进度；受时限的定时监督会收到可等待的短租约参数，以便保存状态后自动在下一轮续租', annotations: annotations(), inputSchema: {
    type: 'object', additionalProperties: false, properties: {},
  } },
  { name: 'browser_stop', description: '停止一个由内置 Browser 派发的长期任务', annotations: annotations(), inputSchema: {
    type: 'object', additionalProperties: false, required: ['jobId'], properties: {
      jobId: { type: 'string', pattern: '^iab_[A-Za-z0-9-]{20,100}$' },
    },
  } },
  { name: 'send_and_watch', description: '在指定 Chat 页面发送目标并等待回复；长期目标优先使用 dispatch_goal 的内置 Browser capability', annotations: annotations(), inputSchema: {
    type: 'object', additionalProperties: false, properties: {
      message: { type: 'string', minLength: 1, maxLength: 10000, description: '只填写原始目标；插件会追加固定的完成回执模板' },
      connector: { type: 'string', description: '要从 ChatGPT Apps 菜单选择的 MCP connector 名称（如 devspace1）' },
      conversationId: { type: 'string', pattern: '^[A-Za-z0-9-]{8,128}$', description: '只读恢复监视时要绑定的 Chat 会话 ID；任何实际发送都会忽略旧会话并新建 Chat' },
      chatUrl: { type: 'string', pattern: '^https://chatgpt\\.com/(?:$|c/)', description: '精确操作的 ChatGPT 对话地址；界面隐藏后仍会在后台挂载' },
      newChat: { type: 'boolean', default: true, description: '在隐藏 ChatGPT.app 实例中点击「新聊天」并选中 Chat，再选择 connector 并发送' },
      timeout: { type: 'integer', minimum: 10, maximum: MAX_CHAT_TIMEOUT_SECONDS, default: DEFAULT_CHAT_TIMEOUT_SECONDS, description: '等待最终回复的最大秒数；必须长于 3 小时无进展阈值' },
      accountId: { type: 'string', pattern: '^acct_[0-9a-f]{12}$', description: '固定此隐藏 Chat 使用的账号' },
      stagnationTimeout: { type: 'integer', minimum: 60, maximum: CHAT_STAGNATION_TIMEOUT_SECONDS, default: CHAT_STAGNATION_TIMEOUT_SECONDS, description: '页面连续无新内容多少秒后直接开启新 Chat；旧 Chat 保持运行，默认 3 小时' },
      maxRecoveryAttempts: { type: 'integer', minimum: 0, maximum: 5, default: 5, description: '页面无进展后在新 Chat 自动发送续作指令的最大次数；超过后截图并报错' },
      autoContinueIncomplete: { type: 'boolean', default: true, description: '回复明确未完成、阻塞、模糊或提前结束时，自动在全新 Chat 续作同一目标' },
      maxTaskContinuations: { type: 'integer', minimum: 0, maximum: 20, default: 0, description: '0 表示持续续作直到完成；正数表示显式上限' },
      continuationMessage: { type: 'string', maxLength: 4000, description: '兼容旧调用但不会使用；续作只发送原始目标和固定完成回执模板' },
      resumeExisting: { type: 'boolean', default: false, description: '仅继续监视已发送的当前 Chat，不重复发送指令' },
      approveAll: { type: 'boolean', description: '自动确认所有授权卡片（默认 true）' },
      pollIntervalMs: { type: 'integer', minimum: 200, maximum: 5000, default: 500, description: '轮询回复的间隔毫秒数' },
    },
    required: ['message'],
  } },
  { name: 'add_connector', description: '在当前 ChatGPT 对话的 Apps 菜单中选择指定的 MCP connector', annotations: annotations(), inputSchema: {
    type: 'object', additionalProperties: false, properties: {
      connector: { type: 'string', minLength: 1, maxLength: 256, description: 'connector 名称（如 devspace1）' },
      conversationId: { type: 'string', pattern: '^[A-Za-z0-9-]{8,128}$', description: '要绑定的 ChatGPT 桌面端 Chat 会话 ID' },
      chatUrl: { type: 'string', pattern: '^https://chatgpt\\.com/(?:$|c/)', description: '精确操作的 ChatGPT 对话地址' },
    },
    required: ['connector'],
  } },
  { name: 'get_reply', description: '获取 ChatGPT 当前最新的 assistant 回复内容和流式状态', annotations: annotations(true), inputSchema: {
    type: 'object', additionalProperties: false, properties: {
      conversationId: { type: 'string', pattern: '^[A-Za-z0-9-]{8,128}$' },
      chatUrl: { type: 'string', pattern: '^https://chatgpt\\.com/(?:$|c/)' },
    },
  } },
  { name: 'chat_status', description: '获取当前 ChatGPT 聊天界面状态（输入框、流式回复、对话标题、connector 列表）', annotations: annotations(true), inputSchema: {
    type: 'object', additionalProperties: false, properties: {
      conversationId: { type: 'string', pattern: '^[A-Za-z0-9-]{8,128}$' },
      chatUrl: { type: 'string', pattern: '^https://chatgpt\\.com/(?:$|c/)' },
    },
  } },
  { name: 'prompt_templates', description: '读取内置任务提示词和最终总结协议', annotations: annotations(true), inputSchema: {
    type: 'object', additionalProperties: false, properties: {},
  } },
  { name: 'enqueue_tasks', description: '把一个或多个任务加入本地持久队列；同一已登录 ChatGPT 实例会为无依赖、无资源锁冲突的任务创建相互隔离的隐藏 Chat 并行执行，最大并发数为 4', annotations: annotations(), inputSchema: {
    type: 'object', additionalProperties: false, required: ['tasks'], properties: {
      tasks: { type: 'array', minItems: 1, maxItems: 50, items: queuedTaskSchema },
      maxConcurrent: { type: 'integer', minimum: 1, maximum: 4, default: 2 },
      reviewGate: { type: 'boolean', default: true },
      start: { type: 'boolean', default: true },
      accountId: { type: 'string', pattern: '^acct_[0-9a-f]{12}$', description: '本次入队的默认账号；每个任务会保存固定账号 id' },
    },
  } },
  { name: 'start_queue', description: '启动或恢复队列；工作和自动验收都在专用实例的 Chat 页面完成，Worker 只返回队列状态', annotations: annotations(), inputSchema: {
    type: 'object', additionalProperties: false, properties: {
      maxConcurrent: { type: 'integer', minimum: 1, maximum: 4 },
      waitForReview: { type: 'boolean', default: true },
      waitTimeout: { type: 'integer', minimum: 1, maximum: 7200, default: 3600 },
    },
  } },
  { name: 'queue_status', description: '读取任务队列、专用 ChatGPT worker 状态、网络恢复等待、验收 Chat 和待处理结果', annotations: annotations(true), inputSchema: {
    type: 'object', additionalProperties: false, properties: {},
  } },
  { name: 'update_task', description: '不停止长期 Action，更新已有任务的 revision、提示词和规范快照；运行中的 Chat 完成本轮后，新 Chat 自动读取最新修订', annotations: annotations(), inputSchema: {
    type: 'object', additionalProperties: false, required: ['taskId', 'revision'], properties: {
      taskId: { type: 'string', pattern: '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$' },
      revision: { type: 'integer', minimum: 1 },
      expectedRevision: { type: 'integer', minimum: 1 },
      title: { type: 'string', minLength: 1, maxLength: 160 },
      prompt: { type: 'string', minLength: 1, maxLength: 10000 },
      directive: { type: 'string', maxLength: 10000 },
      specSources: { type: 'array', maxItems: 20, items: { type: 'string', minLength: 1, maxLength: 512 }, default: [] },
      specSnapshot: { type: 'string', maxLength: 120000 },
      specDigest: { type: 'string', maxLength: 80 },
      applyMode: { type: 'string', enum: ['next_chat', 'interrupt'], default: 'next_chat' },
      source: { type: 'string', maxLength: 160 },
    },
  } },
  { name: 'start_actions_runner', description: '把当前队列的最小续作状态和 ChatGPT 登录凭证安全刷新到 GitHub Secrets，并启动最长六小时的 GitHub Actions 持续运行器；未完成时 Action 自动启动下一轮', annotations: {
    readOnlyHint: false, destructiveHint: false, openWorldHint: true,
  }, inputSchema: {
    type: 'object', additionalProperties: false, properties: {
      accountId: { type: 'string', pattern: '^acct_[0-9a-f]{12}$' },
    },
  } },
  { name: 'wait_for_review', description: '等待队列出现待验收、阻塞或失败任务', annotations: annotations(true), inputSchema: {
    type: 'object', additionalProperties: false, properties: {
      timeout: { type: 'integer', minimum: 1, maximum: 7200, default: 3600 },
    },
  } },
  { name: 'review_task', description: '提交验收；通过后自动释放后续任务，未通过则带意见重新排队', annotations: annotations(), inputSchema: {
    type: 'object', additionalProperties: false, required: ['taskId', 'accepted'], properties: {
      taskId: { type: 'string', pattern: '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$' },
      accepted: { type: 'boolean' },
      feedback: { type: 'string', maxLength: 4000, default: '' },
    },
  } },
  { name: 'pause_queue', description: '暂停启动新任务，运行中的 worker 继续保存进度', annotations: annotations(), inputSchema: {
    type: 'object', additionalProperties: false, properties: {},
  } },
  { name: 'resume_queue', description: '从本地持久状态恢复队列和仍存活的 worker', annotations: annotations(), inputSchema: {
    type: 'object', additionalProperties: false, properties: {},
  } },
  { name: 'retry_task', description: '保留任务和工作区进度，必要时切换 GitHub/bhrum2 connector 后立即新建 Chat 从中断处续作', annotations: annotations(), inputSchema: {
    type: 'object', additionalProperties: false, required: ['taskId'], properties: {
      taskId: { type: 'string', pattern: '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$' },
      feedback: { type: 'string', maxLength: 4000, default: '' },
      connector: { type: 'string', minLength: 1, maxLength: 256, description: '可选：GitHub 用于云端仓库/PR/Actions；bhrum2 用于本地工作区' },
    },
  } },
  { name: 'cancel_task', description: '取消排队中或运行中的任务', annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false }, inputSchema: {
    type: 'object', additionalProperties: false, required: ['taskId'], properties: {
      taskId: { type: 'string', pattern: '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$' },
    },
  } },
];

export default {
  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname !== '/mcp') return new Response('Not found', { status: 404 });
    if (request.method === 'DELETE') return new Response(null, { status: 204 });
    if (request.method !== 'POST') return new Response('Method not allowed', { status: 405 });
    const rpc = await request.json() as any;
    if (rpc.method === 'notifications/initialized') return new Response(null, { status: 202 });
    if (rpc.method === 'initialize') return reply(rpc.id, {
      protocolVersion: '2025-06-18', capabilities: { tools: {}, resources: {} },
      serverInfo: { name: 'chatgpt-auto-confirm', version: '0.1.0' },
    });
    if (rpc.method === 'tools/list') return reply(rpc.id, { tools });
    if (rpc.method === 'tools/call' && rpc.params?.name === 'home') return reply(rpc.id, {
      content: [{ type: 'text', text: HOME.welcome?.markdown ?? '' }], structuredContent: HOME,
    });
    if (rpc.method === 'tools/call') {
      const name = String(rpc.params?.name ?? '');
      const args = rpc.params?.arguments ?? {};
      if (name === 'start') {
        const rules = Array.isArray(args.rules) ? args.rules : [];
        if ((!args.approveAll && rules.length < 1) || rules.length > 20 || rules.some((rule: any) => {
          const parts = [rule?.application, rule?.action, rule?.resource]
            .map(value => String(value ?? '').trim());
          return parts.some(value => !value || value === '*' || value === '.*' || value.length > 256);
        })) {
          return error(rpc.id, -32602, '请启用 approveAll 或提供 1-20 条 application/action/resource 精确规则');
        }
        return hostResult(rpc.id, 'desktop.chatgpt-approvals.start', {
          rules, approveAll: args.approveAll === true,
          chatTitles: Array.isArray(args.chatTitles) ? args.chatTitles : [],
          chatUrls: Array.isArray(args.chatUrls) ? args.chatUrls : [],
          intervalMs: args.intervalMs ?? 750,
        }, 'required');
      }
      if (name === 'stop') return hostResult(
        rpc.id, 'desktop.chatgpt-approvals.stop', {}, 'required');
      if (name === 'status') return hostResult(
        rpc.id, 'desktop.chatgpt-approvals.status', {}, 'none');
      if (name === 'scan_once') return hostResult(
        rpc.id, 'desktop.chatgpt-approvals.scan-once', {}, 'required');
      if (name === 'relaunch_and_confirm') return hostResult(
        rpc.id, 'desktop.chatgpt-approvals.relaunch-and-confirm', { approveAll: args.approveAll === true }, 'required');
      if (name === 'audit_log') return hostResult(
        rpc.id, 'desktop.chatgpt-approvals.audit', { limit: args.limit ?? 20 }, 'none');
      if (name === 'diagnose') return hostResult(
        rpc.id, 'desktop.chatgpt-approvals.diagnose', {}, 'none');
      if (name === 'browser_reply_handoff') return reply(rpc.id, {
        isError: true, content: [{ type: 'text', text: '此功能需要本地插件和独立 Work 通知宿主，云端不能模拟注册成功。' }],
        structuredContent: { ok: false, errorCode: 'local_work_bridge_required' },
      });
      if (name === 'dispatch_goal') {
        const goal = String(args.goal ?? '').trim();
        if (!goal || goal.length > 10000) {
          return error(rpc.id, -32602, 'goal 必须是 1-10000 字符的非空目标文本');
        }
        return hostResult(
          rpc.id,
          PLUGIN_DISPATCH_CAPABILITY,
          pluginDispatchParams(goal),
          'required',
        );
      }
      if (name === 'browser_capability_status') return hostResult(
        rpc.id, 'browser.in-app.capability-status', {}, 'none');
      if (name === 'browser_job_status') return hostResult(
        rpc.id, 'browser.in-app.job-status', { jobId: String(args.jobId || '') }, 'none');
      if (name === 'browser_watch') return hostResult(
        rpc.id, 'browser.in-app.watch', {}, 'none');
      if (name === 'browser_stop') return hostResult(
        rpc.id, 'browser.in-app.stop', { jobId: String(args.jobId || '') }, 'required');
      if (name === 'send_and_watch') {
        const msg = String(args.message ?? '').trim();
        if (!msg || msg.length > 10000) {
          return error(rpc.id, -32602, 'message 必须是 1-10000 字符的非空文本');
        }
        const resumeExisting = args.resumeExisting === true;
        return hostResult(rpc.id, 'desktop.chatgpt-approvals.send-and-watch', {
          message: msg,
          accountId: args.accountId || null,
          connector: args.connector || null,
          conversationId: resumeExisting ? (args.conversationId || null) : null,
          chatUrl: resumeExisting ? (args.chatUrl || null) : null,
          newChat: !resumeExisting,
          timeout: Math.min(MAX_CHAT_TIMEOUT_SECONDS, Math.max(10, args.timeout ?? DEFAULT_CHAT_TIMEOUT_SECONDS)),
          stagnationTimeout: Math.min(CHAT_STAGNATION_TIMEOUT_SECONDS, Math.max(60, args.stagnationTimeout ?? CHAT_STAGNATION_TIMEOUT_SECONDS)),
          maxRecoveryAttempts: Math.min(5, Math.max(0, args.maxRecoveryAttempts ?? 5)),
          autoContinueIncomplete: args.autoContinueIncomplete !== false,
          maxTaskContinuations: Math.min(20, Math.max(0, args.maxTaskContinuations ?? 0)),
          originalGoal: msg,
          goalOnlyDispatch: true,
          continuationMessage: null,
          resumeExisting,
          approveAll: args.approveAll !== false,
          pollIntervalMs: Math.min(5000, Math.max(200, args.pollIntervalMs ?? 500)),
        }, 'required');
      }
      if (name === 'add_connector') {
        const connector = String(args.connector ?? '').trim();
        if (!connector || connector.length > 256) {
          return error(rpc.id, -32602, 'connector 必须是 1-256 字符的名称');
        }
        return hostResult(rpc.id, 'desktop.chatgpt-approvals.add-connector', {
          connector, conversationId: args.conversationId || null, chatUrl: args.chatUrl || null,
        }, 'required');
      }
      if (name === 'get_reply') return hostResult(
        rpc.id, 'desktop.chatgpt-approvals.get-reply', {
          conversationId: args.conversationId || null, chatUrl: args.chatUrl || null,
        }, 'none');
      if (name === 'chat_status') return hostResult(
        rpc.id, 'desktop.chatgpt-approvals.chat-status', {
          conversationId: args.conversationId || null, chatUrl: args.chatUrl || null,
        }, 'none');
      if (name === 'prompt_templates') return reply(rpc.id, {
        content: [{ type: 'text', text: '已加载内置任务提示词。' }],
        structuredContent: {
          templates: taskPromptTemplates,
          reportProtocol: {
            protocol: 'mahayana.task-report.v1',
            markers: ['MAHAYANA_TASK_REPORT_V1_BEGIN', 'MAHAYANA_TASK_REPORT_V1_END'],
            statuses: ['complete', 'incomplete', 'blocked'],
            completion: 'the queue stops only for status=complete, all_tasks_complete=true, remaining=[], blockers=[], wait_seconds=0, next_task=""',
            fields: ['task_id', 'applied_task_revision', 'applied_spec_digest', 'status', 'all_tasks_complete', 'summary', 'completed', 'remaining', 'blockers', 'verification', 'wait_seconds', 'wait_reason', 'next_connector', 'next_task'],
          },
        },
      });
      if (name === 'enqueue_tasks') {
        const tasks = Array.isArray(args.tasks) ? args.tasks : [];
        if (tasks.length < 1 || tasks.length > 50) return error(rpc.id, -32602, 'tasks 必须包含 1-50 个任务');
        return hostResult(rpc.id, 'desktop.chatgpt-approvals.queue-enqueue', {
          tasks,
          accountId: args.accountId || null,
          maxConcurrent: Math.min(4, Math.max(1, args.maxConcurrent ?? 2)),
          reviewGate: args.reviewGate !== false,
          start: args.start !== false,
        }, 'required');
      }
      if (name === 'start_queue') return hostResult(
        rpc.id, 'desktop.chatgpt-approvals.queue-start', {
          maxConcurrent: args.maxConcurrent || null,
          waitForReview: args.waitForReview !== false,
          waitTimeout: Math.min(7200, Math.max(1, args.waitTimeout ?? 3600)),
        }, 'required');
      if (name === 'queue_status') return hostResult(
        rpc.id, 'desktop.chatgpt-approvals.queue-status', {}, 'none');
      if (name === 'update_task') return hostResult(
        rpc.id, 'desktop.chatgpt-approvals.queue-update', {
          taskId: String(args.taskId || ''),
          revision: Math.max(1, Number(args.revision || 1)),
          expectedRevision: args.expectedRevision == null ? null : Math.max(1, Number(args.expectedRevision)),
          title: args.title ? String(args.title).slice(0, 160) : null,
          prompt: args.prompt ? String(args.prompt).slice(0, 10000) : null,
          directive: args.directive ? String(args.directive).slice(0, 10000) : null,
          specSources: Array.isArray(args.specSources) ? args.specSources.slice(0, 20) : [],
          specSnapshot: args.specSnapshot ? String(args.specSnapshot).slice(0, 120000) : null,
          specDigest: args.specDigest ? String(args.specDigest).slice(0, 80) : null,
          applyMode: ['next_chat', 'interrupt'].includes(args.applyMode) ? args.applyMode : 'next_chat',
          source: args.source ? String(args.source).slice(0, 160) : 'operator',
        }, 'required');
      if (name === 'start_actions_runner') return hostResult(
        rpc.id, 'desktop.chatgpt-approvals.actions-runner-start', {
          accountId: args.accountId || null,
        }, 'required');
      if (['account_list', 'account_add', 'account_login_link', 'account_switch', 'account_rename', 'account_status', 'account_sync', 'account_remove'].includes(name)) {
        const accountParams: Record<string, unknown> = { ...args };
        if (name === 'account_remove' && args.confirm !== true) {
          return error(rpc.id, -32602, '删除账号必须显式传入 confirm=true');
        }
        return hostResult(rpc.id, `desktop.chatgpt-approvals.${name.replaceAll('_', '-')}`, accountParams, name === 'account_list' || name === 'account_status' ? 'none' : 'required');
      }
      if (name === 'login_and_sync_actions') return hostResult(
        rpc.id, 'desktop.chatgpt-approvals.actions-runner-login-sync', {
          waitSeconds: Math.min(1800, Math.max(30, Number(args.waitSeconds ?? 600))),
          start: args.start !== false,
          accountId: args.accountId || null,
        }, 'required');
      if (name === 'sync_actions_credentials') return hostResult(
        rpc.id, 'desktop.chatgpt-approvals.actions-runner-credential-sync', {
          start: args.start === true,
          accountId: args.accountId || null,
        }, 'required');
      if (name === 'wait_for_review') return hostResult(
        rpc.id, 'desktop.chatgpt-approvals.queue-wait-review', {
          timeout: Math.min(7200, Math.max(1, args.timeout ?? 3600)),
        }, 'none');
      if (name === 'review_task') return hostResult(
        rpc.id, 'desktop.chatgpt-approvals.queue-review', {
          taskId: String(args.taskId || ''),
          accepted: args.accepted === true,
          feedback: String(args.feedback || '').slice(0, 4000),
        }, 'required');
      if (name === 'pause_queue') return hostResult(
        rpc.id, 'desktop.chatgpt-approvals.queue-pause', {}, 'required');
      if (name === 'resume_queue') return hostResult(
        rpc.id, 'desktop.chatgpt-approvals.queue-resume', {}, 'required');
      if (name === 'retry_task') return hostResult(
        rpc.id, 'desktop.chatgpt-approvals.queue-retry', {
          taskId: String(args.taskId || ''),
          feedback: String(args.feedback || '').slice(0, 4000),
          connector: args.connector ? String(args.connector).slice(0, 256) : null,
        }, 'required');
      if (name === 'cancel_task') return hostResult(
        rpc.id, 'desktop.chatgpt-approvals.queue-cancel', {
          taskId: String(args.taskId || ''),
        }, 'required');
    }
    if (rpc.method === 'resources/list') return reply(rpc.id, { resources: Object.keys(RESOURCES).map(uri => ({
      uri, name: uri.split('/').at(-1), mimeType: 'text/markdown',
    })) });
    if (rpc.method === 'resources/read') {
      const text = RESOURCES[String(rpc.params?.uri ?? '')];
      if (text === undefined) return error(rpc.id, -32002, 'Resource not found');
      return reply(rpc.id, { contents: [{ uri: rpc.params.uri, mimeType: 'text/markdown', text }] });
    }
    return error(rpc.id ?? null, -32601, 'Method not found');
  },
};
