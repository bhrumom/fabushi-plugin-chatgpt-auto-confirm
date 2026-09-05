import { ReplyHandoff, handoffAvailable } from './reply-handoff.mjs';
import { createServer } from 'node:http';
import { randomBytes, randomUUID, timingSafeEqual } from 'node:crypto';
import {
  chmod,
  mkdir,
  readFile,
  unlink,
  writeFile,
} from 'node:fs/promises';
import { homedir } from 'node:os';
import { dirname, resolve } from 'node:path';

export const BROWSER_CAPABILITY = 'browser.in-app.dispatch-and-watch';
export const BROWSER_MODEL = 'GPT-5.6 Sol';
export const BROWSER_REASONING = 'Extra High';
export const REPORT_BEGIN = 'MAHAYANA_TASK_REPORT_V1_BEGIN';
export const REPORT_END = 'MAHAYANA_TASK_REPORT_V1_END';

const DEFAULT_CAPABILITY_FILE = resolve(
  homedir(), '.codex', 'browser', 'chatgpt-auto-confirm-capability.json',
);
const DEFAULT_JOB_FILE = resolve(
  homedir(), '.codex', 'browser', 'chatgpt-auto-confirm-job.json',
);
const MAX_GOAL_LENGTH = 10_000;
export const MAX_PARALLEL_BROWSER_JOBS = 2;
const MAX_ATTEMPTS = 10_000;
const DEFAULT_TIMEOUT_SECONDS = 21_600;
const DEFAULT_STAGNATION_SECONDS = 10_800;
const DEFAULT_POLL_INTERVAL_MS = 500;
const configuredBrowserLeaseValue = typeof process === 'undefined'
  ? ''
  : process.env?.CHATGPT_AUTO_CONFIRM_BROWSER_LEASE_MS;
const configuredBrowserLeaseMs = Number(configuredBrowserLeaseValue);
const DEFAULT_BROWSER_LEASE_MS = Number.isFinite(configuredBrowserLeaseMs)
  ? Math.min(6 * 60 * 60 * 1000, Math.max(60_000, configuredBrowserLeaseMs))
  : 6 * 60 * 60 * 1000;
// A scheduled Chat heartbeat has a finite browser-execution budget. Keep its
// slice comfortably below that limit so it can persist and release cleanly;
// the next heartbeat reattaches the same jobs rather than treating the lease
// rotation as a completed or failed task.
export const DEFAULT_BROWSER_HEARTBEAT_SLICE_MS = 18_000;
const DEFAULT_PAGE_REFRESH_COOLDOWN_MS = 5_000;
const PAGE_REFRESH_WINDOW_MS = 60_000;
const MAX_PAGE_REFRESHES_PER_WINDOW = 3;
const BROWSER_DISCOVERY_RETRY_ATTEMPTS = 6;
const BROWSER_DISCOVERY_INITIAL_DELAY_MS = 250;
const BROWSER_DISCOVERY_MAX_DELAY_MS = 4_000;
const BROWSER_HOST_REATTACH_INITIAL_DELAY_MS = 500;
const BROWSER_HOST_REATTACH_MAX_DELAY_MS = 10_000;
const CAPABILITY_TTL_MS = 7 * 24 * 60 * 60 * 1000;
const TERMINAL_JOB_STATUSES = new Set(['completed', 'stopped', 'failed']);
const RECOVERABLE_BROWSER_CONTEXT_PATTERN = /(?:node_repl exec context not found|execution context[^\n]{0,80}(?:destroyed|not found)|(?:browser\s+)?tab(?:\s+id)?[^\n]{0,80}(?:not found|stale|missing|closed|unavailable)|(?:page|target|frame|browser context)[^\n]{0,80}(?:closed|detached|destroyed|unavailable)|not part of (?:the )?current browser|browser[^\n]{0,40}disconnected|\bcdp\b[^\n]{0,120}(?:timed out|timeout|deadline|exceeded|closed|disconnected|dispatch)|(?:timed out|timeout|deadline|exceeded)[^\n]{0,120}\bcdp\b|(?:available\s+browser\s+(?:array|list)|可用浏览器(?:数组|列表))[^\n]{0,80}(?:unavailable|empty|missing|not found|不可用|为空|缺失|找不到))/iu;
const PAGE_LOAD_FAILURE_PATTERN = /(?:无法加载|加载失败|加载出错|页面错误|网络错误|连接错误|空白页面|页面无响应|failed\s+to\s+load|error\s+loading|could\s+not\s+load|network\s+error|connection\s+error|page\s+error|something\s+went\s+wrong)/iu;
const PAGE_CRASH_PATTERN = /(?:this\s+page\s+crashed|crashed\s+unexpectedly|renderer\s+(?:process|crash)|aw\s*,?\s*snap|tab\s+crashed|页面(?:已)?崩溃|网页(?:已)?崩溃|标签页(?:已)?崩溃|渲染(?:进程)?崩溃)/iu;
const CRASH_PAGE_URL_PATTERN = /^(?:data:text\/html|chrome-error:|about:crash|chrome:\/\/crash)/iu;
const OWNED_BROKEN_TAB_URL_PATTERN = /^(?:about:blank|data:text\/html|chrome-error:|about:crash|chrome:\/\/crash)/iu;
const PAGE_REFRESH_CONTROL_PATTERN = /^(?:reload|refresh|try\s+again|重新加载|刷新|再试一次|重新尝试)$/iu;

export const BROWSER_DISPATCH_POLICY = Object.freeze({
  browser: 'iab',
  capability: BROWSER_CAPABILITY,
  connector: null,
  model: BROWSER_MODEL,
  reasoning: BROWSER_REASONING,
  surface: 'chat',
  newChat: true,
  resumeExisting: false,
  goalOnlyDispatch: true,
  approveAll: true,
  timeout: DEFAULT_TIMEOUT_SECONDS,
  stagnationTimeout: DEFAULT_STAGNATION_SECONDS,
  maxRecoveryAttempts: 5,
  autoContinueIncomplete: true,
  maxTaskContinuations: 0,
  continuationMessage: null,
  maxConcurrentJobs: MAX_PARALLEL_BROWSER_JOBS,
  pollIntervalMs: DEFAULT_POLL_INTERVAL_MS,
});

export const COMPLETION_CERTIFICATE_INSTRUCTION = `完成整个目标后，在回复末尾只输出以下完成回执；未完成时不要伪造 complete，继续工作：
MAHAYANA_TASK_REPORT_V1_BEGIN
{"protocol":"mahayana.task-report.v1","status":"complete","all_tasks_complete":true,"summary":"整个目标已完成","completed":["列出已完成项目和发布证据"],"remaining":[],"blockers":[],"verification":["列出可复核的验证证据"],"wait_seconds":0,"wait_reason":"","next_connector":"","next_task":""}
MAHAYANA_TASK_REPORT_V1_END`;

const sleep = milliseconds => new Promise(resolvePromise => {
  setTimeout(resolvePromise, milliseconds);
});

const normalize = value => String(value ?? '').replace(/[\s\u21b5\u23ce]+/gu, ' ').trim();

const normalizeForCompare = value => normalize(value).replace(/\s+/gu, ' ').trim();

const ALLOW_CONTROL_LABELS = new Set([
  'allow', 'allow once', 'allow for this conversation', 'allow for this chat',
  'allow for this session', 'approve', 'approve once', 'confirm', 'confirm once',
  '允许', '允许一次', '允许本次会话', '允许本次聊天', '同意', '同意一次',
  '确认', '确认一次', '完全访问', 'full access',
]);

const REJECT_CONTROL_LABELS = new Set([
  'deny', 'reject', 'cancel', 'deny once', 'reject once',
  '拒绝', '拒绝一次', '不允许', '不允许一次', '取消',
]);

const AUTHORIZATION_HINT_PATTERN = /(?:允许(?:本次会话|本次聊天|在此聊天中)|授权|连接器|请求访问|访问权限|权限(?:请求|要求|确认)|allow\s+chatgpt(?:\s+to\s+use)?|chatgpt\s*(?:将|会)\s*使用|chatgpt\s+(?:wants?|would\s+like|needs?|requests?|is\s+requesting)\s+(?:to\s+)?(?:use|access)|(?:requires?|requesting)\s+(?:your\s+)?(?:permission|approval|access)|permission\s+required|tool\s+access|this\s+(?:conversation|chat|session)|grant(?:ing)?\s+(?:access|permission)|outside\s+this\s+project|向[^\n]{0,80}(?:创建|访问|使用)|GitHub\s*允许)/iu;

function isAllowControlLabel(label) {
  const normalized = normalize(label).toLowerCase();
  return ALLOW_CONTROL_LABELS.has(normalized)
    // Connector cards frequently include the connector or requested scope in
    // the button label (for example, “Allow GitHub access”).  The caller
    // still requires the surrounding authorization-card signal, so accepting
    // these bounded labels does not turn ordinary transcript text into an
    // approval action.
    || /^(?:allow|approve|confirm|grant|允许|同意|确认|授权)(?:\s+(?:once|for\s+this\s+(?:conversation|chat|session)|in\s+this\s+(?:conversation|chat|session)|this\s+(?:conversation|chat|session)|access|permission|本次会话|本次聊天|在此聊天中|一次|访问|权限|chatgpt|github|[\p{L}\p{N}_.:-]{1,48})){0,3}$/iu.test(normalized);
}

function isRejectControlLabel(label) {
  const normalized = normalize(label).toLowerCase();
  return REJECT_CONTROL_LABELS.has(normalized)
    || /^(?:deny|reject|cancel|拒绝|不允许|取消)(?:\s+(?:once|一次))?$/iu.test(normalized);
}

export function isPendingAuthorizationState(state = {}) {
  // ChatGPT can keep its "stop generating" control visible while a connector
  // authorization card is waiting for approval. The card signal is stronger
  // than the response-running signal: suppressing it here leaves the task
  // visibly stuck behind an Allow button forever.
  const controls = Array.isArray(state.controls) ? state.controls : [];
  const activeAllow = controls.filter(control => (
    isAllowControlLabel(control?.label) && !control?.disabled
  ));
  if (activeAllow.length === 0) return false;
  const activeReject = controls.filter(control => (
    isRejectControlLabel(control?.label) && !control?.disabled
  ));
  const bodyText = String(state.bodyText || '');
  return AUTHORIZATION_HINT_PATTERN.test(bodyText) || activeReject.length > 0;
}

const isRecord = value => value !== null && typeof value === 'object' && !Array.isArray(value);

const publicError = error => String(error?.message || error || '未知错误').slice(0, 1000);

function normalizeBrowserCollection(value, source) {
  if (Array.isArray(value)) return value;
  // Browser providers have returned both a bare array and an envelope during
  // handoff. Accept the envelope shape as well so a transient provider change
  // cannot turn a recoverable handoff into a TypeError on `.find()`.
  if (isRecord(value)) {
    for (const key of ['tabs', 'browsers', 'items', 'data']) {
      if (Array.isArray(value[key])) return value[key];
    }
  }
  throw new Error(`内置 Browser ${source} 列表暂时不可用`);
}

async function listBrowserCollectionWithRetry(
  readCollection,
  { source, logger = () => {} } = {},
) {
  let lastError = null;
  for (let attempt = 1; attempt <= BROWSER_DISCOVERY_RETRY_ATTEMPTS; attempt += 1) {
    try {
      const collection = normalizeBrowserCollection(await readCollection(), source);
      if (attempt > 1) {
        logger({ event: 'browser_collection_recovered', source, attempt });
      }
      return collection;
    } catch (error) {
      lastError = error;
      if (attempt < BROWSER_DISCOVERY_RETRY_ATTEMPTS) {
        logger({
          event: 'browser_collection_retry',
          source,
          attempt,
          error: publicError(error),
        });
        const delay = Math.min(
          BROWSER_DISCOVERY_MAX_DELAY_MS,
          BROWSER_DISCOVERY_INITIAL_DELAY_MS * (2 ** (attempt - 1)),
        );
        await sleep(delay);
      }
    }
  }
  throw new Error(`内置 Browser ${source} 列表在自动重试后仍不可用：${publicError(lastError)}`);
}

export function isRecoverableBrowserContextError(error) {
  return RECOVERABLE_BROWSER_CONTEXT_PATTERN.test(publicError(error));
}

function isResumableBrowserFailure(job) {
  if (!isRecord(job) || job.status !== 'failed' || job.stopRequested === true) return false;
  if (job.phase === 'terminal') return false;
  const outcome = String(job.lastOutcome?.kind || '');
  return outcome !== 'complete' && outcome !== 'stopped';
}

export function isPageLoadFailureState(state = {}) {
  const bodyText = String(state.bodyText || '');
  const title = String(state.title || '');
  const url = String(state.url || '');
  const controls = Array.isArray(state.controls) ? state.controls : [];
  const hasRefreshControl = controls.some(control => (
    PAGE_REFRESH_CONTROL_PATTERN.test(normalize(control?.label)) && !control?.disabled
  ));
  const hasLoadErrorText = PAGE_LOAD_FAILURE_PATTERN.test(bodyText);
  const hasCrashDocument = PAGE_CRASH_PATTERN.test(`${title}\n${bodyText}`);
  const hasCrashUrl = CRASH_PAGE_URL_PATTERN.test(url);
  const missingComposer = state.hasComposer !== true
    && state.hasWorkComposer !== true
    && state.pendingAuthorization !== true;
  return hasRefreshControl
    || (hasLoadErrorText && missingComposer)
    || ((hasCrashUrl || hasCrashDocument) && missingComposer);
}

function canonicalChatUrl(value) {
  try {
    const url = new URL(String(value || ''));
    if (url.protocol !== 'https:' || url.hostname !== 'chatgpt.com') return '';
    return `${url.origin}${url.pathname.replace(/\/$/u, '') || '/'}`;
  } catch {
    return '';
  }
}

function sameChatTarget(left, right) {
  const canonicalLeft = canonicalChatUrl(left);
  const canonicalRight = canonicalChatUrl(right);
  if (!canonicalLeft || !canonicalRight) return false;
  if (canonicalLeft === canonicalRight) return true;
  const leftConversation = canonicalLeft.match(/\/c\/([^/]+)$/u)?.[1];
  const rightConversation = canonicalRight.match(/\/c\/([^/]+)$/u)?.[1];
  return !!leftConversation && leftConversation === rightConversation;
}

function chatProjectId(value) {
  try {
    const url = new URL(String(value || ''));
    if (url.protocol !== 'https:' || url.hostname !== 'chatgpt.com') return '';
    return url.pathname.match(/^\/g\/([^/]+)/u)?.[1] || '';
  } catch {
    return '';
  }
}

function sameChatProject(left, right) {
  const leftProject = chatProjectId(left);
  const rightProject = chatProjectId(right);
  return !!leftProject && !!rightProject && leftProject === rightProject;
}

function isReusableBrowserJobUrl(job, currentUrl, targetUrl) {
  if (!canonicalChatUrl(currentUrl)) return false;
  const targetConversation = canonicalChatUrl(targetUrl).match(/\/c\/([^/]+)$/u)?.[1] || '';
  // Once a response is deemed incomplete, the job reuses its own project tab
  // to start a fresh Chat.  Requiring the old conversation URL in that phase
  // would unnecessarily open another tab and could disturb the other job.
  if ((job.phase || 'accepted') === 'accepted' || !targetConversation) {
    return sameChatProject(currentUrl, targetUrl);
  }
  return sameChatTarget(currentUrl, targetUrl);
}

function browserTabFailureReason(currentUrl) {
  const url = String(currentUrl || '');
  if (CRASH_PAGE_URL_PATTERN.test(url)) return '检测到内置 Browser 崩溃页面';
  if (!canonicalChatUrl(url)) return '标签页已离开 ChatGPT 或显示故障页面';
  return '标签页不再属于该任务的受控会话';
}

export function promptForGoal(goal) {
  const value = String(goal ?? '').trim();
  if (!value || value.length > MAX_GOAL_LENGTH) {
    throw new Error('goal 必须是 1-10000 字符的非空目标文本');
  }
  return `${value}\n\n${COMPLETION_CERTIFICATE_INSTRUCTION}`;
}

export function validateBrowserPolicy(policy) {
  if (!isRecord(policy)) return { ok: false, message: '缺少内置 Browser 授权策略' };
  const mismatches = Object.entries(BROWSER_DISPATCH_POLICY)
    .filter(([key, expected]) => policy[key] !== expected)
    .map(([key, expected]) => `${key}=${JSON.stringify(expected)}`);
  if (Object.hasOwn(policy, 'previousProgress') || Object.hasOwn(policy, 'continuation')) {
    mismatches.push('禁止传入历史进度或续作文本');
  }
  return mismatches.length > 0
    ? { ok: false, message: `Browser 派发策略不符合固定安全策略：${mismatches.join(', ')}` }
    : { ok: true };
}

export function parseCompletionCertificate(text) {
  const source = String(text ?? '');
  const beginIndex = source.lastIndexOf(REPORT_BEGIN);
  const endIndex = beginIndex === -1 ? -1 : source.indexOf(REPORT_END, beginIndex + REPORT_BEGIN.length);
  if (beginIndex === -1 || endIndex === -1) {
    return { valid: false, reason: 'missing-completion-certificate', payload: null };
  }
  const raw = source.slice(beginIndex + REPORT_BEGIN.length, endIndex).trim();
  let payload;
  try {
    payload = JSON.parse(raw);
  } catch {
    return { valid: false, reason: 'completion-certificate-json-invalid', payload: null };
  }
  const valid = isRecord(payload)
    && payload.protocol === 'mahayana.task-report.v1'
    && payload.status === 'complete'
    && payload.all_tasks_complete === true
    && typeof payload.summary === 'string' && payload.summary.trim().length > 0
    && Array.isArray(payload.completed) && payload.completed.length > 0
    && Array.isArray(payload.remaining) && payload.remaining.length === 0
    && Array.isArray(payload.blockers) && payload.blockers.length === 0
    && Array.isArray(payload.verification) && payload.verification.length > 0
    && payload.wait_seconds === 0
    && payload.wait_reason === ''
    && typeof payload.next_connector === 'string'
    && payload.next_task === '';
  return {
    valid,
    reason: valid ? 'complete' : 'completion-certificate-fields-invalid',
    payload: valid ? payload : null,
  };
}

const NATURAL_INCOMPLETE_PATTERN = /(?:尚未(?:完成|实现|通过|验证)|(?:未|没有|尚无|还没).{0,16}(?:完成|实现|通过|验证)|仍(?:需|要|在).{0,16}(?:继续|完成|处理|验证)|还需要|仍需|阻塞|无法.{0,24}(?:完成|验证|实现)|不能.{0,24}(?:声称|报告|返回).{0,12}(?:完成|complete)|not\s+yet|incomplete|still\s+(?:in progress|needs?|has?\s+to)|blocked|pending|remaining|todo|next\s+step)/iu;
export function classifyCompletion(text) {
  const source = String(text ?? '').trim();
  const certificate = parseCompletionCertificate(source);
  if (certificate.valid) return { valid: true, mode: 'certificate', certificate };
  if (!source) return { valid: false, mode: 'none', reason: 'empty-final-reply', certificate };
  if (NATURAL_INCOMPLETE_PATTERN.test(source)) {
    return { valid: false, mode: 'natural', reason: 'explicit-incomplete', certificate };
  }
  return {
    valid: false,
    mode: 'natural',
    reason: certificate.reason === 'completion-certificate-fields-invalid'
      ? 'invalid-completion-certificate' : 'missing-completion-certificate',
    certificate,
  };
}

function conversationIdFromState(state) {
  const raw = String(state?.conversationId || '').trim();
  return raw.startsWith('chatgpt:') ? raw.slice('chatgpt:'.length) : raw;
}

function conversationIdFromUrl(value) {
  return canonicalChatUrl(value).match(/\/c\/([^/?#]+)$/u)?.[1] || '';
}

function projectNewChatUrl(url) {
  try {
    const parsed = new URL(url);
    const match = parsed.pathname.match(/^\/g\/([^/]+)(?:\/project|\/c\/[^/]+)?/u);
    if (match) return `${parsed.origin}/g/${match[1]}/project`;
  } catch {
    // Fall through to the stable ChatGPT entry point.
  }
  return 'https://chatgpt.com/';
}

async function readPageState(tab) {
  const state = await tab.playwright.evaluate(() => {
    const visible = element => !!(element && (
      element.offsetWidth || element.offsetHeight || element.getClientRects().length
    ));
    const label = element => (element?.innerText
      || element?.getAttribute('aria-label')
      || element?.getAttribute('title')
      || '').replace(/[\s\u21b5\u23ce]+/gu, ' ').trim();
    const main = document.querySelector('main') || document;
    const assistantNodes = [...main.querySelectorAll(
      '[data-message-author-role="assistant"], [data-local-conversation-final-assistant], '
        + '[data-content-search-unit-key$=":assistant"], '
        + '[data-conversation-screenshot-content].agent-turn',
    )].filter(visible);
    const userNodes = [...main.querySelectorAll(
      '[data-message-author-role="user"], [data-user-message-bubble], [data-content-search-unit-key$=":user"]',
    )].filter(visible);
    const controls = [...document.querySelectorAll('button, [role="button"]')]
      .filter(visible)
      .map(element => ({
        label: label(element),
        disabled: !!element.disabled || element.getAttribute('aria-disabled') === 'true',
        ariaHasPopup: element.getAttribute('aria-haspopup'),
        ariaExpanded: element.getAttribute('aria-expanded'),
      }));
    const bodyText = document.body?.innerText || '';
    const bodyLower = bodyText.toLowerCase();
    const stopAnswer = controls.some(control => /停止回答|停止生成|stop generating|stop responding|stop answering/iu.test(control.label));
    const retry = controls.some(control => /重试|retry|重新生成|regenerate/iu.test(control.label));
    const conversationMarker = document.querySelector('[data-above-composer-conversation-id]')
      ?.getAttribute('data-above-composer-conversation-id') || '';
    const urlMatch = window.location.href.match(/\/c\/([^/?#]+)/u);
    const assistantText = assistantNodes.map(node => node.innerText || node.textContent || '').at(-1) || '';
    return {
      url: window.location.href || '',
      title: document.title || '',
      conversationId: conversationMarker || urlMatch?.[1] || '',
      assistantCount: assistantNodes.length,
      userCount: userNodes.length,
      latestAssistantText: assistantText.slice(-200_000),
      latestUserText: (userNodes.at(-1)?.innerText || userNodes.at(-1)?.textContent || '').slice(-20_000),
      bodyText: bodyText.slice(-200_000),
      controls,
      stopAnswer,
      retry,
      hasComposer: !!document.querySelector('textarea[name="prompt-textarea"], [contenteditable="true"][role="textbox"]'),
      hasWorkComposer: !!document.querySelector('[data-codex-composer="true"]'),
      chatTabSelected: [...document.querySelectorAll('[role="tab"]')].some(tab => (
        (tab.innerText || tab.textContent || '').trim() === '聊天'
        && tab.getAttribute('aria-selected') === 'true'
      )),
      bodyLowerTail: bodyLower.slice(-5000),
    };
  });
  const allowButtonCount = Array.isArray(state.controls)
    ? state.controls.filter(control => isAllowControlLabel(control?.label)).length : 0;
  const pendingAuthorization = typeof state.pendingAuthorization === 'boolean'
    ? state.pendingAuthorization : isPendingAuthorizationState(state);
  return {
    ...state,
    allowButtonCount,
    pendingAuthorization,
  };
}

async function verifyReattachedTab(tab) {
  if (!tab?.playwright) throw new Error('重新附着的内置 Browser 标签页不可控');
  const url = await tab.url();
  if (!canonicalChatUrl(url)) throw new Error('重新附着的标签页不是 ChatGPT 页面');
  try { await tab.markHandoff(); } catch { /* the current run may already own the handoff */ }
  return url;
}

/**
 * Replace a stale Tab binding without replacing the authorized in-app Browser.
 * Prefer an already controlled exact target, then an exact user-owned tab,
 * and create a new background tab only when neither exists.
 */
export async function reattachInAppBrowserTab({
  browser,
  targetUrl,
  preferredTabId = null,
  fallbackUrl = 'https://chatgpt.com/',
  logger = () => {},
} = {}) {
  if (!browser?.tabs) throw new Error('缺少可重新附着的内置 Browser');
  const destination = canonicalChatUrl(targetUrl) || canonicalChatUrl(fallbackUrl);
  if (!destination) throw new Error('没有可恢复的 ChatGPT 目标 URL');
  const failures = [];

  // The persisted tab id is the strongest ownership signal. Reuse it before
  // scanning URLs so a project-entry URL cannot accidentally create a third
  // tab when another parallel job is already in the same project.
  if (preferredTabId && browser.tabs.get) {
    try {
      const tab = await browser.tabs.get(preferredTabId);
      const url = typeof tab.url === 'function' ? await tab.url() : '';
      const targetConversation = destination.match(/\/c\/([^/]+)$/u)?.[1] || '';
      const targetMatches = canonicalChatUrl(url)
        ? (targetConversation ? sameChatTarget(url, destination) : sameChatProject(url, destination))
        // A persisted owned tab may be a renderer crash page. It is handled
        // below as a stale recovery hint rather than a usable Browser handle.
        : OWNED_BROKEN_TAB_URL_PATTERN.test(url);
      if (targetMatches && !OWNED_BROKEN_TAB_URL_PATTERN.test(url)) {
        if (!tab?.playwright) throw new Error('首选任务标签页不可控');
        try { await tab.markHandoff(); } catch { /* current run may own the handoff */ }
        logger({ event: 'browser_tab_reattached', method: 'preferred-tab', tabId: preferredTabId, url });
        return { tab, method: 'preferred-tab', url };
      }
      if (targetMatches && OWNED_BROKEN_TAB_URL_PATTERN.test(url)) {
        // A renderer-crash document can keep goto/reload pending forever in
        // some in-app Browser hosts. Do not bind the new trusted host to
        // that dead handle: discard the agent-owned tab and let the normal
        // exact-conversation/new-tab recovery path select a live tab. This
        // keeps recovery automatic and prevents the supervisor from
        // blocking until the enclosing Browser execution times out.
        try { await tab.close?.(); } catch { /* the crashed tab may be gone */ }
        logger({
          event: 'browser_broken_preferred_tab_discarded',
          method: 'preferred-tab-crash-fallback',
          tabId: preferredTabId,
          url,
        });
      }
    } catch (error) {
      failures.push(`preferred-tab: ${publicError(error)}`);
    }
  }

  try {
    const controlledTabs = await listBrowserCollectionWithRetry(
      () => browser.tabs.list(),
      { source: '受控标签页', logger },
    );
    const targetConversation = destination.match(/\/c\/([^/]+)$/u)?.[1] || '';
    const match = controlledTabs.find(candidate => (
      targetConversation
        ? sameChatTarget(candidate.url, destination)
        : sameChatProject(candidate.url, destination)
    ));
    if (match?.id) {
      const tab = await browser.tabs.get(match.id);
      const url = await verifyReattachedTab(tab);
      logger({ event: 'browser_tab_reattached', method: 'controlled-tab', tabId: match.id, url });
      return { tab, method: 'controlled-tab', url };
    }
  } catch (error) {
    failures.push(`controlled-tab: ${publicError(error)}`);
  }

  try {
    if (browser.user?.openTabs && browser.user?.claimTab) {
      const userTabs = await listBrowserCollectionWithRetry(
        () => browser.user.openTabs(),
        { source: '用户标签页', logger },
      );
      const targetConversation = destination.match(/\/c\/([^/]+)$/u)?.[1] || '';
      const match = userTabs.find(candidate => (
        targetConversation
          ? sameChatTarget(candidate.url, destination)
          : sameChatProject(candidate.url, destination)
      ));
      if (match) {
        const tab = await browser.user.claimTab(match);
        const url = await verifyReattachedTab(tab);
        logger({ event: 'browser_tab_reattached', method: 'claimed-user-tab', tabId: tab.id, url });
        return { tab, method: 'claimed-user-tab', url };
      }
    }
  } catch (error) {
    failures.push(`claimed-user-tab: ${publicError(error)}`);
  }

  try {
    const tab = await browser.tabs.new();
    await tab.goto(destination);
    const url = await verifyReattachedTab(tab);
    logger({ event: 'browser_tab_reattached', method: 'new-tab', tabId: tab.id, url });
    return { tab, method: 'new-tab', url };
  } catch (error) {
    failures.push(`new-tab: ${publicError(error)}`);
  }

  throw new Error(`内置 Browser 自动重新附着失败：${failures.join(' | ')}`);
}

async function visibleLocator(locators) {
  for (const locator of locators) {
    let count = 0;
    try { count = await locator.count(); } catch { continue; }
    for (let index = 0; index < count; index += 1) {
      const candidate = locator.nth(index);
      try {
        if (await candidate.isVisible() && await candidate.isEnabled()) return candidate;
      } catch {
        // The React tree may replace the element between attempts.
      }
    }
  }
  return null;
}

async function clickSessionScope(tab) {
  const names = [
    '允许本次会话', '允许本次聊天', '允许在此聊天中', '允许在本次会话中',
    'Allow for this conversation', 'Allow for this chat', 'Allow for this session',
    'Allow in this conversation', 'Allow in this chat',
  ];
  const locators = [];
  for (const name of names) {
    locators.push(tab.playwright.getByRole('menuitem', { name, exact: true }));
    locators.push(tab.playwright.getByRole('menuitemradio', { name, exact: true }));
    locators.push(tab.playwright.getByRole('button', { name, exact: true }));
    locators.push(tab.playwright.getByText(name, { exact: true }));
  }
  const target = await visibleLocator(locators);
  if (target) {
    await target.click();
    return true;
  }
  // Connector-specific labels include the connector name, e.g. “Allow
  // GitHub for this conversation”. Search only inside the open menu so a
  // generic card-level Allow button can never be mistaken for this choice.
  const menuItems = tab.playwright.locator(
    '[role="menu"] [role="menuitem"], [role="menu"] [role="menuitemradio"], '
      + '[role="menu"] [role="option"], [role="menu"] button, '
      + '[role="listbox"] [role="option"], [role="listbox"] [role="menuitem"]',
  );
  const scopedPattern = /(?:允许|allow)[^\n]{0,120}(?:本次会话|本次聊天|在此聊天中|在本次会话中|this conversation|this chat|this session)/iu;
  let count = 0;
  try { count = await menuItems.count(); } catch { return false; }
  for (let index = 0; index < count; index += 1) {
    const candidate = menuItems.nth(index);
    try {
      if (!(await candidate.isVisible()) || !(await candidate.isEnabled())) continue;
      const label = await candidate.evaluate(element => (
        element.innerText || element.textContent || element.getAttribute('aria-label') || ''
      ).replace(/[\s\u21b5\u23ce]+/gu, ' ').trim());
      if (!scopedPattern.test(label)) continue;
      await candidate.click();
      return true;
    } catch {
      // The menu may be replaced after an option is selected.
    }
  }
  return false;
}

export async function clickDirectAllow(tab) {
  const names = [
    'Allow', 'Allow once', 'Approve', 'Approve once', 'Confirm', 'Confirm once',
    'Allow access', 'Grant access', 'Allow permission', '允许', '允许一次',
    '允许本次会话', '允许本次聊天', '允许访问', '授权访问', '同意', '同意一次',
    '确认', '确认一次', '完全访问', 'Full access',
  ];
  const locators = [];
  for (const name of names) {
    locators.push(tab.playwright.getByRole('button', { name, exact: true }));
  }
  const target = await visibleLocator(locators);
  if (target) {
    await target.click();
    return true;
  }
  // An authorization button can be localized as “Allow <connector> access”.
  // The exact role lookup above intentionally covers common labels first;
  // this bounded fallback handles connector-specific labels without relying on
  // a brittle list of connector names.
  const controls = tab.playwright.locator('button, [role="button"]');
  let count = 0;
  try { count = await controls.count(); } catch { return false; }
  for (let index = 0; index < count; index += 1) {
    const candidate = controls.nth(index);
    try {
      if (!(await candidate.isVisible()) || !(await candidate.isEnabled())) continue;
      const info = await candidate.evaluate(element => ({
        label: (element.innerText || element.textContent || element.getAttribute('aria-label') || '')
          .replace(/[\s\u21b5\u23ce]+/gu, ' ').trim(),
        ariaHasPopup: element.getAttribute('aria-haspopup'),
      }));
      if (!isAllowControlLabel(info.label)) continue;
      // A split-button menu trigger is handled by authorizationArrow so that
      // its session-scoped choice is preferred over a broad permission.
      if (info.ariaHasPopup === 'menu' || info.ariaHasPopup === 'listbox') continue;
      await candidate.click();
      return true;
    } catch {
      // React may replace a control while the card is being rendered.
    }
  }
  return false;
}

async function waitForAuthorizationSettlement(tab, {
  timeoutMs = 1_500,
  pollIntervalMs = 150,
} = {}) {
  const deadline = Date.now() + timeoutMs;
  let lastState = null;
  while (Date.now() <= deadline) {
    lastState = await readPageState(tab);
    if (lastState.stopAnswer === true || lastState.pendingAuthorization !== true) return lastState;
    if (Date.now() >= deadline) break;
    await sleep(pollIntervalMs);
  }
  return null;
}

async function confirmedAuthorizationResult(tab, method) {
  const settled = await waitForAuthorizationSettlement(tab);
  return settled
    ? { ok: true, found: true, method }
    : null;
}

async function authorizationArrow(tab) {
  const allControls = await tab.playwright.locator('button, [role="button"]').all();
  const allowControls = [];
  const controls = [];
  for (const control of allControls) {
    try {
      if (!(await control.isVisible()) || !(await control.isEnabled())) continue;
      const info = await control.evaluate(element => {
        const rect = element.getBoundingClientRect();
        return {
          label: (element.innerText || element.getAttribute('aria-label') || element.getAttribute('title') || '')
            .replace(/[\s\u21b5\u23ce]+/gu, ' ').trim(),
          ariaHasPopup: element.getAttribute('aria-haspopup'),
          ariaExpanded: element.getAttribute('aria-expanded'),
          dataState: element.getAttribute('data-state'),
          rect: { left: rect.left, right: rect.right, top: rect.top, bottom: rect.bottom },
          disabled: !!element.disabled,
        };
      });
      const lower = info.label.toLowerCase();
      const isAllow = isAllowControlLabel(lower);
      if (isAllow) allowControls.push({ locator: control, info });
      controls.push({ locator: control, info });
    } catch {
      // Ignore detached controls.
    }
  }
  const allow = allowControls[0];
  if (!allow) return null;
  const isTrigger = item => item.info.ariaHasPopup === 'menu'
    || item.info.ariaHasPopup === 'listbox'
    || item.info.ariaExpanded !== null
    || item.info.dataState !== null
    || /menu|dropdown|chevron|caret|arrow|下拉|箭头|更多|选项/iu.test(item.info.label);
  const adjacent = controls
    .filter(item => item.locator !== allow.locator && isTrigger(item))
    .map(item => {
      const a = allow.info.rect;
      const b = item.info.rect;
      const verticalOverlap = Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top);
      const horizontalGap = Math.max(a.left - b.right, b.left - a.right, 0);
      const distance = Math.abs((a.left + a.right) - (b.left + b.right))
        + Math.abs((a.top + a.bottom) - (b.top + b.bottom));
      return { ...item, score: (verticalOverlap > 0 && horizontalGap <= 16 ? 10_000 : 0) - distance };
    })
    .sort((left, right) => right.score - left.score);
  return adjacent[0]?.locator || null;
}

export async function approveAuthorization(tab) {
  const state = await readPageState(tab);
  const pendingAuthorization = state.pendingAuthorization === true
    || (state.pendingAuthorization === undefined && isPendingAuthorizationState(state));
  // Do not suppress a visible authorization card merely because the Chat page
  // also exposes a stop-generating control (see isPendingAuthorizationState).
  if (!pendingAuthorization) return { ok: true, found: false };
  if (await clickSessionScope(tab)) {
    const confirmed = await confirmedAuthorizationResult(tab, 'session-scope-visible');
    if (confirmed) return confirmed;
    return {
      ok: false,
      found: true,
      errorCode: 'authorization_session_scope_not_confirmed',
      message: '已点击“允许本次会话”，但授权卡仍未消失；插件将自动重试。',
    };
  }
  const arrow = await authorizationArrow(tab);
  if (!arrow) {
    if (await clickDirectAllow(tab)) {
      const confirmed = await confirmedAuthorizationResult(tab, 'direct-allow-fallback');
      if (confirmed) return confirmed;
      // Some split controls expose their menu only after the main Allow
      // surface is pressed. Try the now-visible session-scoped option before
      // reporting the card as still pending.
      if (await clickSessionScope(tab)) {
        const sessionConfirmed = await confirmedAuthorizationResult(tab, 'direct-allow-then-session-scope');
        if (sessionConfirmed) return sessionConfirmed;
      }
      return {
        ok: false,
        found: true,
        errorCode: 'authorization_action_not_confirmed',
        message: '已尝试允许授权，但授权卡仍在显示；插件将自动重试。',
      };
    }
    return {
      ok: false,
      found: true,
      errorCode: 'authorization_allow_control_not_found',
      message: '检测到授权卡，但没有找到可点击的会话范围或直接允许控件。',
    };
  }
  await arrow.click();
  await sleep(250);
  if (await clickSessionScope(tab)) {
    const confirmed = await confirmedAuthorizationResult(tab, 'arrow-then-session-scope');
    if (confirmed) return confirmed;
    return {
      ok: false,
      found: true,
      errorCode: 'authorization_session_scope_not_confirmed',
      message: '已点击“允许本次会话”，但授权卡仍未消失；插件将自动重试。',
    };
  }
  {
    try { await tab.playwright.locator('body').press('Escape'); } catch { /* menu already closed */ }
    await sleep(100);
    if (await clickDirectAllow(tab)) {
      const confirmed = await confirmedAuthorizationResult(tab, 'arrow-then-direct-allow-fallback');
      if (confirmed) return confirmed;
    }
    // A connector card can disappear while its scope menu is closing. Re-read
    // the live page before reporting a failure; otherwise a completed approval
    // race would leave the persisted queue unnecessarily waiting for a card
    // that no longer exists.
    const settled = await readPageState(tab);
    if (settled.stopAnswer === true || settled.pendingAuthorization !== true) {
      return { ok: true, found: true, method: 'authorization-settled-during-scope-selection' };
    }
    return {
      ok: false,
      found: true,
      errorCode: 'authorization_session_option_not_found',
      message: '已打开授权范围菜单，但既没有找到“允许本次会话”，也没有找到直接允许控件。',
    };
  }
}

async function ensureModelAndReasoning(tab) {
  const modelButton = await visibleLocator([
    tab.playwright.getByRole('button', { name: '极高', exact: true }),
    tab.playwright.getByRole('button', { name: '思考强度', exact: true }),
  ]);
  if (!modelButton) throw new Error('当前聊天页没有找到思考强度/模型选择器');
  const solLocator = tab.playwright.getByRole('menuitemradio', {
    name: BROWSER_MODEL, exact: true,
  });
  const modelAlreadyOpen = !!await visibleLocator([solLocator]);
  if (!modelAlreadyOpen) {
    await modelButton.click();
    await sleep(250);
  }
  const sol = await visibleLocator([solLocator]);
  if (!sol) throw new Error('模型选择器没有提供 GPT-5.6 Sol');
  if (await sol.getAttribute('aria-checked') !== 'true') await sol.click();
  // The in-app Browser's accessibility tree can lag while the model menu is
  // re-rendering; the stable DOM role is more reliable than getByRole here.
  const slider = tab.playwright.locator('[role="slider"]');
  let visibleSlider = await visibleLocator([slider]);
  if (!visibleSlider) {
    const reopenedModelButton = await visibleLocator([
      tab.playwright.getByRole('button', { name: '极高', exact: true }),
      tab.playwright.getByRole('button', { name: '思考强度', exact: true }),
    ]);
    if (reopenedModelButton) {
      await reopenedModelButton.click();
      await sleep(250);
      visibleSlider = await visibleLocator([slider]);
    }
  }
  if (!visibleSlider) throw new Error('模型选择器没有提供思考强度滑块');
  const maximum = await visibleSlider.getAttribute('aria-valuemax');
  if (await visibleSlider.getAttribute('aria-valuenow') !== maximum) {
    await visibleSlider.press('End');
  }
  const checked = await sol.getAttribute('aria-checked');
  const value = await visibleSlider.getAttribute('aria-valuenow');
  if (checked !== 'true' || value !== maximum) {
    throw new Error(`模型或思考强度验证失败：modelChecked=${checked}, reasoning=${value}/${maximum}`);
  }
  try { await tab.playwright.locator('body').press('Escape'); } catch { /* already closed */ }
  return { model: BROWSER_MODEL, reasoning: BROWSER_REASONING, verified: true };
}

function canRefreshBrowserPage(host) {
  const now = Date.now();
  if (!host.pageRefreshWindowStartedAt
      || now - host.pageRefreshWindowStartedAt >= PAGE_REFRESH_WINDOW_MS) {
    host.pageRefreshWindowStartedAt = now;
    host.pageRefreshCount = 0;
  }
  if (now - Number(host.lastPageRefreshAt || 0) < DEFAULT_PAGE_REFRESH_COOLDOWN_MS) return false;
  if (Number(host.pageRefreshCount || 0) >= MAX_PAGE_REFRESHES_PER_WINDOW) {
    throw new Error('Browser 页面连续加载失败，自动刷新次数已达安全上限');
  }
  host.pageRefreshCount = Number(host.pageRefreshCount || 0) + 1;
  host.lastPageRefreshAt = now;
  return true;
}

async function refreshBrowserPage(tab, fallbackUrl, host) {
  if (!canRefreshBrowserPage(host)) return readPageState(tab);
  let currentUrl = '';
  try { currentUrl = await tab.url(); } catch { /* use the stable project URL below */ }
  if (canonicalChatUrl(currentUrl)) await tab.reload();
  else await tab.goto(fallbackUrl);
  await sleep(1_200);
  const state = await readPageState(tab);
  if (!isPageLoadFailureState(state)) {
    host.pageRefreshCount = 0;
    host.pageRefreshWindowStartedAt = Date.now();
  }
  return state;
}

async function ensureChatPage(tab, newChatUrl, host) {
  let state = await readPageState(tab);
  if (!state.url.includes('/g/') || state.hasWorkComposer) {
    await tab.goto(newChatUrl);
    await sleep(1200);
  }
  let lastError = null;
  let loadCheckFailures = 0;
  const deadline = Date.now() + 30_000;
  while (Date.now() < deadline) {
    try {
      state = await readPageState(tab);
      if (isPageLoadFailureState(state)) {
        state = await refreshBrowserPage(tab, newChatUrl, host);
        loadCheckFailures = 0;
        continue;
      }
      if (!state.url.includes('/g/') || state.hasWorkComposer) {
        await tab.goto(newChatUrl);
        await sleep(900);
        lastError = new Error('当前页面仍在加载 Chat 页面');
      } else {
        const chatTab = tab.playwright.getByRole('tab', { name: '聊天', exact: true });
        if (await chatTab.count() > 0 && await chatTab.first().getAttribute('aria-selected') !== 'true') {
          await chatTab.first().click();
          await sleep(250);
        }
        await ensureModelAndReasoning(tab);
        state = await readPageState(tab);
        if (isPageLoadFailureState(state)) {
          state = await refreshBrowserPage(tab, newChatUrl, host);
          loadCheckFailures = 0;
          continue;
        }
        if (state.hasComposer && !state.hasWorkComposer) return state;
        lastError = new Error('当前页面不是可发送消息的 Chat 页面');
      }
    } catch (error) {
      lastError = error;
      if (isRecoverableBrowserContextError(error)) throw error;
      loadCheckFailures += 1;
      if (loadCheckFailures >= 3) {
        state = await refreshBrowserPage(tab, newChatUrl, host);
        loadCheckFailures = 0;
      }
    }
    await sleep(400);
  }
  throw lastError || new Error('当前页面不是可发送消息的 Chat 页面');
}

async function sendGoal(tab, prompt) {
  const before = await readPageState(tab);
  const textarea = tab.playwright.locator('textarea[name="prompt-textarea"]');
  const composer = await visibleLocator([
    textarea,
    tab.playwright.getByRole('textbox', { name: 'fabushi中的新聊天', exact: true }),
    tab.playwright.getByRole('textbox', { name: 'ChatGPT', exact: true }),
  ]);
  if (!composer) throw new Error('没有找到 Chat 输入框');
  await composer.fill(prompt);
  const sendButton = await visibleLocator([
    tab.playwright.getByTestId('send-button'),
    tab.playwright.getByRole('button', { name: '发送提示', exact: true }),
    tab.playwright.getByRole('button', { name: 'Send message', exact: true }),
  ]);
  if (!sendButton) throw new Error('没有找到 Chat 发送按钮');
  await sendButton.click();
  const deadline = Date.now() + 45_000;
  while (Date.now() < deadline) {
    const state = await readPageState(tab);
    const rendered = normalizeForCompare(state.latestUserText);
    const expected = normalizeForCompare(prompt);
    // ChatGPT renders links as visible text (for example, dropping https://),
    // so confirmation must compare the canonicalized message as well as the
    // exact text.
    const canonical = value => value
      .replace(/https?:\/\/(?:www\.)?[^/\s]+\/?/giu, '')
      .replace(/\s+/gu, ' ')
      .trim();
    const sent = state.userCount > before.userCount
      && (rendered.includes(expected)
        || canonical(rendered).includes(canonical(expected)));
    if (sent) {
      try { await tab.markHandoff(); } catch { /* the host may already own the handoff */ }
      return { ok: true, before, state };
    }
    await sleep(350);
  }
  return { ok: false, before, state: await readPageState(tab), errorCode: 'message_send_not_confirmed' };
}

async function waitForResponse(tab, job, before, policy) {
  const deadline = Date.now() + Number(policy.timeout || DEFAULT_TIMEOUT_SECONDS) * 1000;
  const stagnationDeadline = Number(policy.stagnationTimeout || DEFAULT_STAGNATION_SECONDS) * 1000;
  const pollInterval = Math.min(5000, Math.max(200, Number(policy.pollIntervalMs || DEFAULT_POLL_INTERVAL_MS)));
  const initialAssistantCount = before.assistantCount;
  const initialUserCount = before.userCount;
  let sawResponse = false;
  let stableSamples = 0;
  let lastFingerprint = '';
  let lastProgressAt = Date.now();
  let authorizationAttempts = 0;
  let latestState = before;
  while (Date.now() < deadline) {
    if (job.stopRequested) return { kind: 'stopped', state: latestState };
    latestState = await readPageState(tab);
    job.currentUrl = latestState.url;
    job.conversationId = conversationIdFromState(latestState);
    job.latestReply = latestState.latestAssistantText.slice(-4000);
    job.responseRunning = latestState.stopAnswer;
    if (latestState.pendingAuthorization) {
      job.status = 'waiting_for_authorization';
      const approval = await approveAuthorization(tab);
      if (!approval.ok) {
        authorizationAttempts += 1;
        job.authorization = approval;
        if (authorizationAttempts >= 5) return { kind: 'blocked', state: latestState, approval };
      } else if (approval.found) {
        job.authorization = approval;
        job.status = 'running';
        lastProgressAt = Date.now();
      }
    }
    const responseCountChanged = latestState.assistantCount > initialAssistantCount;
    const userMessageConfirmed = latestState.userCount > initialUserCount
      && latestState.latestUserText.length > 0;
    if (responseCountChanged || (latestState.url.includes('/c/') && userMessageConfirmed)) {
      sawResponse = sawResponse || responseCountChanged;
    }
    const fingerprint = `${latestState.assistantCount}:${latestState.latestAssistantText.length}:${latestState.latestAssistantText.slice(-240)}`;
    if (fingerprint !== lastFingerprint) {
      lastFingerprint = fingerprint;
      lastProgressAt = Date.now();
      stableSamples = 0;
    } else {
      stableSamples += 1;
    }
    if (!latestState.stopAnswer && sawResponse && stableSamples >= 3) {
      const completion = classifyCompletion(latestState.latestAssistantText || latestState.bodyText);
      if (completion.valid) return { kind: 'complete', state: latestState, completion };
      return { kind: 'incomplete', state: latestState, completion };
    }
    if (Date.now() - lastProgressAt >= stagnationDeadline) {
      return { kind: 'stagnated', state: latestState };
    }
    job.status = latestState.stopAnswer ? 'running' : (sawResponse ? 'settling' : 'starting');
    job.updatedAt = new Date().toISOString();
    await sleep(pollInterval);
  }
  return { kind: 'timed-out', state: latestState };
}

function hostJobs(host) {
  if (!(host.jobs instanceof Map)) host.jobs = new Map();
  if (host.activeJob?.id && !host.jobs.has(host.activeJob.id)) {
    host.jobs.set(host.activeJob.id, host.activeJob);
  }
  return [...host.jobs.values()];
}

function registerJob(host, job) {
  if (!job?.id) return job;
  if (!(host.jobs instanceof Map)) host.jobs = new Map();
  host.jobs.set(job.id, job);
  return job;
}

function jobForId(host, jobId) {
  if (!jobId) return null;
  return hostJobs(host).find(job => job.id === jobId) || null;
}

function activeBrowserJobs(host) {
  return hostJobs(host).filter(job => !TERMINAL_JOB_STATUSES.has(job.status));
}

function publicJobs(host) {
  return hostJobs(host).map(publicJob);
}

function persistedJob(job) {
  return {
    id: job.id,
    goal: job.goal,
    status: job.status,
    phase: job.phase || 'accepted',
    attempt: job.attempt || 0,
    startedAt: job.startedAt,
    updatedAt: job.updatedAt,
    currentUrl: job.currentUrl || null,
    conversationId: job.conversationId || null,
    tabId: job.tab?.id || job.tabId || null,
    responseRunning: job.responseRunning === true,
    authorization: job.authorization || null,
    latestReply: job.latestReply || '',
    lastOutcome: job.lastOutcome || null,
    error: job.error || null,
    beforeAssistantCount: job.beforeAssistantCount || 0,
    beforeUserCount: job.beforeUserCount || 0,
    stableSamples: job.stableSamples || 0,
    lastFingerprint: job.lastFingerprint || '',
    lastProgressAt: job.lastProgressAt || Date.now(),
    reattachCount: job.reattachCount || 0,
    lastReattachedAt: job.lastReattachedAt || null,
    lastReattachMethod: job.lastReattachMethod || null,
    lastReattachError: job.lastReattachError || null,
    lastTabFailure: job.lastTabFailure || null,
    lastTabFailureAt: job.lastTabFailureAt || null,
  };
}

async function persistJob(host, job = host.activeJob) {
  if (!job) return;
  registerJob(host, job);
  job.updatedAt = new Date().toISOString();
  const jobs = hostJobs(host).map(persistedJob);
  // Keep the established single-job file shape so an already installed
  // predecessor can recover it. The moment a second task exists, record an
  // explicit collection so each task can keep its own tab binding.
  const persisted = jobs.length === 1
    ? jobs[0]
    : {
      schema: 'chatgpt-auto-confirm.browser-jobs.v2',
      maxConcurrentJobs: MAX_PARALLEL_BROWSER_JOBS,
      jobs,
    };
  await mkdir(dirname(host.jobStateFile), { recursive: true });
  await writeFile(host.jobStateFile, `${JSON.stringify(persisted)}\n`, { encoding: 'utf8', mode: 0o600 });
  await chmod(host.jobStateFile, 0o600);
}

function restorePersistedJob(saved) {
  const recoverableFailure = isResumableBrowserFailure(saved);
  if (!isRecord(saved) || !saved.id || !saved.goal
      || (TERMINAL_JOB_STATUSES.has(saved.status) && !recoverableFailure)) return null;
  return {
    ...saved,
    status: recoverableFailure ? 'waiting_for_browser_host' : (saved.status || 'accepted'),
    phase: saved.phase || 'accepted',
    error: recoverableFailure ? '内置 Browser/CDP 暂时不可用，插件将自动恢复同一任务。' : saved.error,
    stopRequested: false,
    restoredFromDisk: true,
  };
}

async function restoreJobs(jobStateFile) {
  try {
    const saved = JSON.parse(await readFile(jobStateFile, 'utf8'));
    const rawJobs = Array.isArray(saved?.jobs) ? saved.jobs : [saved];
    return rawJobs.map(restorePersistedJob).filter(Boolean);
  } catch {
    return [];
  }
}

async function repairRestoredBrowserJobConversation(host, job, tab = host.tab) {
  if (!job || job.phase !== 'waiting'
      || conversationIdFromState(job)
      || conversationIdFromUrl(job.currentUrl)) return;
  let boundTabUrl = '';
  try {
    if (typeof tab?.url === 'function') boundTabUrl = await tab.url();
  } catch {
    return;
  }
  const boundConversationId = conversationIdFromUrl(boundTabUrl);
  const savedTarget = job.currentUrl || host.newChatUrl;
  if (!boundConversationId || !sameChatProject(boundTabUrl, savedTarget)) return;
  job.currentUrl = canonicalChatUrl(boundTabUrl);
  job.conversationId = boundConversationId;
}

async function prepareRestoredBrowserJob(host, job) {
  await repairRestoredBrowserJobConversation(host, job);
  if (!job.restoredFromDisk || job.restorePrepared || job.phase !== 'waiting') return;
  const target = String(job.currentUrl || '').trim();
  if (target.startsWith('https://chatgpt.com/')) {
    let state = await readPageState(host.tab);
    if (state.url !== target) {
      await host.tab.goto(target);
      await sleep(900);
    }
    state = await readPageState(host.tab);
    if (isPageLoadFailureState(state)) {
      state = await refreshBrowserPage(host.tab, target, host);
    }
    if (isPageLoadFailureState(state)) {
      throw new Error('Browser 页面刷新后仍无法加载当前会话');
    }
  }
  job.restorePrepared = true;
  job.error = null;
  if (job.status === 'waiting_for_browser_host') job.status = 'running';
}

function browserRecoveryTarget(host, job) {
  const resumeCurrentConversation = (job.phase || 'accepted') === 'waiting'
    && canonicalChatUrl(job.currentUrl);
  return resumeCurrentConversation || host.newChatUrl;
}

async function bindBrowserJobTab(host, job, tab, {
  method = 'existing-tab',
  url = null,
} = {}) {
  if (!tab?.playwright) throw new Error('内置 Browser 任务标签页不可控');
  job.tab = tab;
  job.tabId = tab.id || job.tabId || null;
  if (url) job.currentUrl = url;
  try { await tab.markHandoff(); } catch { /* the trusted host already owns this tab */ }
  host.tab = tab;
  host.lastBrowserActivityAt = new Date().toISOString();
  if (method !== 'existing-tab') {
    job.lastReattachedAt = host.lastBrowserActivityAt;
    job.lastReattachMethod = method;
    job.lastReattachError = null;
  }
  return tab;
}

async function reviveBrokenBrowserJobTab(host, job, tab, targetUrl) {
  let currentUrl = '';
  try {
    currentUrl = typeof tab.url === 'function' ? await tab.url() : '';
  } catch (error) {
    job.lastTabFailure = `标签页状态读取失败：${publicError(error)}`;
    job.lastTabFailureAt = new Date().toISOString();
  }
  // A healthy ChatGPT URL that belongs to another job must never be
  // overwritten. Only the clearly broken/non-ChatGPT page is safe to revive
  // in place; otherwise the exact-conversation recovery path below selects or
  // creates an isolated tab.
  if (canonicalChatUrl(currentUrl)) return null;
  const destination = canonicalChatUrl(targetUrl) || host.newChatUrl;
  if (!destination || typeof tab.goto !== 'function') return null;
  try {
    await tab.goto(destination);
    await sleep(900);
    currentUrl = typeof tab.url === 'function' ? await tab.url() : destination;
    if (!isReusableBrowserJobUrl(job, currentUrl, destination)) return null;
    await bindBrowserJobTab(host, job, tab, {
      method: 'reloaded-broken-tab',
      url: currentUrl,
    });
    job.reattachCount = Number(job.reattachCount || 0) + 1;
    job.lastTabFailure = null;
    job.lastTabFailureAt = null;
    job.lastReattachError = null;
    job.error = null;
    job.status = 'running';
    await persistJob(host, job);
    host.logger({
      event: 'browser_tab_recovered_in_place',
      tabId: tab.id || null,
      url: currentUrl,
    });
    return tab;
  } catch (error) {
    job.lastTabFailure = `标签页重载失败：${publicError(error)}`;
    job.lastTabFailureAt = new Date().toISOString();
    return null;
  }
}

async function forgetBrokenBrowserJobTab(job, tab, reason) {
  job.lastTabFailure = reason;
  job.lastTabFailureAt = new Date().toISOString();
  // Closing is best effort. The in-app Browser may already have discarded a
  // crashed renderer, and its short-lived Tab handle may not expose close().
  // Never close a healthy ChatGPT tab here because it may belong to the other
  // parallel job.
  if (typeof tab?.close === 'function') {
    try { await tab.close(); } catch { /* the crashed tab is already gone */ }
  }
  job.tab = null;
  job.tabId = null;
}

async function createBrowserJobTab(host, job) {
  if (!host.browser?.tabs?.new) throw new Error('内置 Browser 不支持创建任务标签页');
  const tab = await host.browser.tabs.new();
  await tab.goto(host.newChatUrl);
  const url = typeof tab.url === 'function' ? await tab.url() : host.newChatUrl;
  await bindBrowserJobTab(host, job, tab, { method: 'new-parallel-tab', url });
  return tab;
}

async function ensureBrowserJobTab(host, job) {
  if (job.tab?.playwright) {
    const target = browserRecoveryTarget(host, job);
    // Older Browser adapters did not expose url() on an already-bound Tab.
    // Keep that binding and let the normal page-state probe below validate it;
    // requiring a URL accessor here would turn a healthy legacy handle into a
    // false crash and starve the parallel pump.
    if (typeof job.tab.url !== 'function') return bindBrowserJobTab(host, job, job.tab);
    let currentUrl = '';
    try {
      currentUrl = typeof job.tab.url === 'function' ? await job.tab.url() : '';
      if (isReusableBrowserJobUrl(job, currentUrl, target)) {
        return bindBrowserJobTab(host, job, job.tab, { url: currentUrl });
      }
      const revived = await reviveBrokenBrowserJobTab(host, job, job.tab, target);
      if (revived) return revived;
      const reason = browserTabFailureReason(currentUrl);
      if (!canonicalChatUrl(currentUrl)) await forgetBrokenBrowserJobTab(job, job.tab, reason);
      else {
        job.lastTabFailure = reason;
        job.lastTabFailureAt = new Date().toISOString();
        job.tab = null;
        job.tabId = null;
      }
    } catch (error) {
      await forgetBrokenBrowserJobTab(job, job.tab, `标签页控制句柄失效：${publicError(error)}`);
    }
  }
  if (job.tabId && host.browser?.tabs?.get) {
    try {
      const tab = await host.browser.tabs.get(job.tabId);
      const target = browserRecoveryTarget(host, job);
      const currentUrl = typeof tab.url === 'function' ? await tab.url() : target;
      if (isReusableBrowserJobUrl(job, currentUrl, target)) {
        return bindBrowserJobTab(host, job, tab, { method: 'controlled-tab', url: currentUrl });
      }
      const revived = await reviveBrokenBrowserJobTab(host, job, tab, target);
      if (revived) return revived;
      if (!canonicalChatUrl(currentUrl)) await forgetBrokenBrowserJobTab(job, tab, browserTabFailureReason(currentUrl));
      else {
        job.lastTabFailure = browserTabFailureReason(currentUrl);
        job.lastTabFailureAt = new Date().toISOString();
        job.tabId = null;
      }
    } catch {
      // The saved tab id is only an optimization. The normal recovery path
      // below finds the exact conversation or creates an isolated new tab.
      job.tabId = null;
    }
  }
  if ((job.phase || 'accepted') === 'accepted') return createBrowserJobTab(host, job);
  await recoverBrowserHostTab(host, job);
  return job.tab;
}

async function recoverBrowserHostTab(host, job) {
  const targetUrl = browserRecoveryTarget(host, job);
  const recovery = await host.recoverTab({
    browser: host.browser,
    targetUrl,
    preferredTabId: job.tabId || null,
    fallbackUrl: host.newChatUrl,
    logger: host.logger,
  });
  await bindBrowserJobTab(host, job, recovery.tab, {
    method: recovery.method,
    url: recovery.url,
  });
  job.reattachCount = Number(job.reattachCount || 0) + 1;
  job.restorePrepared = true;
  job.error = null;
  job.status = 'running';
  host.pageRefreshCount = 0;
  host.pageRefreshWindowStartedAt = Date.now();
  host.lastPageRefreshAt = 0;
  await persistJob(host, job);
  return recovery;
}

function nextBrowserJob(host, requestedJobId = '') {
  if (requestedJobId) {
    const requested = jobForId(host, requestedJobId);
    if (!requested) return null;
    const pendingIndex = host.pendingJobs.findIndex(job => job.id === requested.id);
    if (pendingIndex >= 0) host.pendingJobs.splice(pendingIndex, 1);
    return requested;
  }
  while (host.pendingJobs.length > 0) {
    const pending = host.pendingJobs.shift();
    const job = jobForId(host, pending?.id);
    if (job && !TERMINAL_JOB_STATUSES.has(job.status)) return job;
  }
  const runnable = activeBrowserJobs(host);
  if (runnable.length === 0) return null;
  const index = Number(host.roundRobinCursor || 0) % runnable.length;
  host.roundRobinCursor = (index + 1) % runnable.length;
  return runnable[index];
}

function readyForLeaseDrain(job) {
  if (!job || TERMINAL_JOB_STATUSES.has(job.status)) return false;
  // A response can finish in the same polling slice in which the Browser
  // lease expires. Drain the already-decided handoff (or an accepted job that
  // has not started yet) once before yielding the host, so a finished Chat is
  // followed by its fresh Chat in the same trusted Browser execution.
  return job.status === 'handoff_to_fresh_chat'
    || (job.phase === 'accepted' && job.responseRunning !== true);
}

async function runBrowserStep(host, { jobId = '', allowReattach = true } = {}) {
  const job = nextBrowserJob(host, jobId);
  if (!job) return null;
  registerJob(host, job);
  host.activeJob = job;
  if (TERMINAL_JOB_STATUSES.has(job.status)) return publicJob(job);
  if (job.stopRequested || job.status === 'stopped') {
    job.status = 'stopped';
    await persistJob(host, job);
    return publicJob(job);
  }
  try {
    await ensureBrowserJobTab(host, job);
    await prepareRestoredBrowserJob(host, job);
    // A successful step supersedes a stale host-disconnect diagnostic that
    // was persisted before a new Browser host was attached.
    job.error = null;
    host.lastBrowserActivityAt = new Date().toISOString();
    if ((job.phase || 'accepted') === 'accepted') {
      let state = await readPageState(host.tab);
      if ((job.attempt || 0) > 0 || state.url.includes('/c/')) {
        await host.tab.goto(host.newChatUrl);
        await sleep(900);
        state = await readPageState(host.tab);
      }
      if (isPageLoadFailureState(state)) {
        state = await refreshBrowserPage(host.tab, host.newChatUrl, host);
      }
      if (isPageLoadFailureState(state)) {
        throw new Error('Browser 页面刷新后仍无法加载新会话');
      }
      if (state.pendingAuthorization) {
        job.status = 'waiting_for_authorization';
        const approval = await approveAuthorization(host.tab);
        job.authorization = approval;
        if (!approval.ok) {
          await persistJob(host, job);
          return publicJob(job);
        }
        state = await readPageState(host.tab);
      }
      state = await ensureChatPage(host.tab, host.newChatUrl, host);
      if (state.pendingAuthorization) {
        job.status = 'waiting_for_authorization';
        const approval = await approveAuthorization(host.tab);
        job.authorization = approval;
        if (!approval.ok) {
          await persistJob(host, job);
          return publicJob(job);
        }
        state = await readPageState(host.tab);
      }
      const sent = await sendGoal(host.tab, promptForGoal(job.goal));
      if (!sent.ok) throw new Error(sent.errorCode || 'message_send_not_confirmed');
      job.phase = 'waiting';
      job.status = 'running';
      job.beforeAssistantCount = sent.before.assistantCount;
      job.beforeUserCount = sent.before.userCount;
      job.currentUrl = sent.state.url;
      job.conversationId = conversationIdFromState(sent.state);
      job.responseRunning = true;
      job.lastProgressAt = Date.now();
      job.stableSamples = 0;
      job.lastFingerprint = '';
      await persistJob(host, job);
      return publicJob(job);
    }

    let state = await readPageState(host.tab);
    if (isPageLoadFailureState(state)) {
      state = await refreshBrowserPage(host.tab, browserRecoveryTarget(host, job), host);
    }
    if (isPageLoadFailureState(state)) {
      throw new Error('Browser 页面刷新后仍无法加载当前会话');
    }
    job.currentUrl = state.url;
    job.conversationId = conversationIdFromState(state);
    job.latestReply = state.latestAssistantText.slice(-4000);
    job.responseRunning = state.stopAnswer;
    if (state.pendingAuthorization) {
      job.status = 'waiting_for_authorization';
      const approval = await approveAuthorization(host.tab);
      job.authorization = approval;
      if (approval.ok) job.status = 'running';
      await persistJob(host, job);
      return publicJob(job);
    }
    // A prior Browser host may have persisted an authorization diagnostic
    // before the card was dismissed by a replacement host. Do not expose that
    // stale failure after the page is healthy and the card is gone.
    job.authorization = null;
    const responseStarted = state.assistantCount > Number(job.beforeAssistantCount || 0);
    const fingerprint = `${state.assistantCount}:${state.latestAssistantText.length}:${state.latestAssistantText.slice(-240)}`;
    if (fingerprint !== job.lastFingerprint) {
      job.lastFingerprint = fingerprint;
      job.stableSamples = 0;
      job.lastProgressAt = Date.now();
    } else {
      job.stableSamples = Number(job.stableSamples || 0) + 1;
    }
    if (!state.stopAnswer && responseStarted && job.stableSamples >= 3) {
      const completion = classifyCompletion(state.latestAssistantText || state.bodyText);
      if (completion.valid) {
        job.status = 'completed';
        job.phase = 'terminal';
        job.lastOutcome = {
          kind: 'complete', mode: completion.mode, conversationId: conversationIdFromState(state),
        };
        if (completion.certificate?.payload) job.certificate = completion.certificate.payload;
      } else {
        job.status = 'handoff_to_fresh_chat';
        job.phase = 'accepted';
        job.attempt = Number(job.attempt || 0) + 1;
        job.lastOutcome = {
          kind: 'incomplete', reason: completion.reason, conversationId: conversationIdFromState(state),
        };
        job.beforeAssistantCount = 0;
        job.beforeUserCount = 0;
        job.stableSamples = 0;
        job.lastFingerprint = '';
      }
    } else if (Date.now() - Number(job.lastProgressAt || Date.now()) >= DEFAULT_STAGNATION_SECONDS * 1000) {
      job.status = 'handoff_to_fresh_chat';
      job.phase = 'accepted';
      job.attempt = Number(job.attempt || 0) + 1;
      job.lastOutcome = { kind: 'stagnated', conversationId: conversationIdFromState(state) };
    } else {
      job.status = state.stopAnswer ? 'running' : (responseStarted ? 'settling' : 'starting');
    }
    await persistJob(host, job);
    return publicJob(job);
  } catch (error) {
    const message = publicError(error);
    // Every exception here originates from the Browser automation layer, not
    // from the delegated project itself. Preserve the task and recover the
    // host instead of turning an incidental UI/CDP failure into a terminal
    // release failure. Only an explicit user stop may terminate it here.
    const recoverableHostFailure = !job.stopRequested;
    if (recoverableHostFailure && allowReattach) {
      job.status = 'reattaching_browser_host';
      job.error = '内置 Browser 标签页绑定失效，插件正在自动重新附着同一任务。';
      await persistJob(host, job);
      try {
        await recoverBrowserHostTab(host, job);
        return await runBrowserStep(host, { jobId: job.id, allowReattach: false });
      } catch (recoveryError) {
        job.status = 'waiting_for_browser_host';
        job.lastReattachError = publicError(recoveryError);
        job.error = '内置 Browser 执行租约已结束；需要启动插件长期宿主泵，随后会自动恢复同一任务和会话。';
      }
    } else if (recoverableHostFailure) {
      job.status = 'waiting_for_browser_host';
      job.lastReattachError = message;
      job.error = '内置 Browser 自动重新附着后的操作仍不可用；插件将轮换宿主并继续同一任务。';
    } else {
      job.status = job.stopRequested ? 'stopped' : 'failed';
      job.error = message;
    }
    await persistJob(host, job);
    return publicJob(job);
  }
}

function publicJob(job) {
  if (!job) return null;
  return {
    id: job.id,
    goal: job.goal,
    status: job.status,
    attempt: job.attempt,
    startedAt: job.startedAt,
    updatedAt: job.updatedAt,
    currentUrl: job.currentUrl || null,
    conversationId: job.conversationId || null,
    tabId: job.tab?.id || job.tabId || null,
    responseRunning: job.responseRunning === true,
    authorization: job.authorization || null,
    latestReply: job.latestReply || '',
    lastOutcome: job.lastOutcome || null,
    error: job.error || null,
    reattachCount: job.reattachCount || 0,
    lastReattachedAt: job.lastReattachedAt || null,
    lastReattachMethod: job.lastReattachMethod || null,
    lastReattachError: job.lastReattachError || null,
    lastTabFailure: job.lastTabFailure || null,
    lastTabFailureAt: job.lastTabFailureAt || null,
  };
}

async function runJob(host, job) {
  job.status = 'running';
  job.updatedAt = new Date().toISOString();
  const newChatUrl = host.newChatUrl;
  try {
    for (let attempt = 1; attempt <= MAX_ATTEMPTS; attempt += 1) {
      if (job.stopRequested) {
        job.status = 'stopped';
        break;
      }
      job.attempt = attempt;
      job.authorization = null;
      job.updatedAt = new Date().toISOString();
      let state = await readPageState(host.tab);
      const mustCreateFreshChat = attempt > 1 || state.url.includes('/c/');
      if (mustCreateFreshChat) {
        await host.tab.goto(newChatUrl);
        await sleep(1200);
      }
      state = await ensureChatPage(host.tab, newChatUrl, host);
      job.currentUrl = state.url;
      job.conversationId = conversationIdFromState(state);
      const prompt = promptForGoal(job.goal);
      const sent = await sendGoal(host.tab, prompt);
      if (!sent.ok) throw new Error(sent.errorCode || 'message_send_not_confirmed');
      job.currentUrl = sent.state.url;
      job.conversationId = conversationIdFromState(sent.state);
      job.status = 'running';
      job.updatedAt = new Date().toISOString();
      const outcome = await waitForResponse(host.tab, job, sent.before, host.policy);
      job.lastOutcome = { kind: outcome.kind, conversationId: conversationIdFromState(outcome.state) };
      job.updatedAt = new Date().toISOString();
      if (outcome.kind === 'complete') {
        job.status = 'completed';
        if (outcome.completion?.certificate?.payload) {
          job.certificate = outcome.completion.certificate.payload;
        }
        break;
      }
      if (outcome.kind === 'stopped') {
        job.status = 'stopped';
        break;
      }
      if (outcome.kind === 'blocked') {
        job.status = 'waiting_for_authorization';
        job.error = outcome.approval?.message || '等待“允许本次会话”授权';
        break;
      }
      if (outcome.kind === 'incomplete' || outcome.kind === 'stagnated' || outcome.kind === 'timed-out') {
        job.status = 'handoff_to_fresh_chat';
        continue;
      }
      throw new Error(`未处理的 Chat 结果：${outcome.kind}`);
    }
    if (job.status === 'handoff_to_fresh_chat') {
      job.status = 'failed';
      job.error = '达到安全的最大新 Chat 续作次数';
    }
  } catch (error) {
    job.status = job.stopRequested ? 'stopped' : 'failed';
    job.error = publicError(error);
  } finally {
    job.updatedAt = new Date().toISOString();
    if (host.activeJob?.id === job.id && TERMINAL_JOB_STATUSES.has(job.status)) {
      host.activeJob = job;
    }
  }
}

function safeEqual(left, right) {
  const leftBuffer = Buffer.from(String(left || ''));
  const rightBuffer = Buffer.from(String(right || ''));
  return leftBuffer.length > 0 && leftBuffer.length === rightBuffer.length
    && timingSafeEqual(leftBuffer, rightBuffer);
}

function json(res, status, payload) {
  const body = JSON.stringify(payload);
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
    'content-length': Buffer.byteLength(body),
  });
  res.end(body);
}

async function requestBody(req) {
  const chunks = [];
  let size = 0;
  for await (const chunk of req) {
    size += chunk.length;
    if (size > 1_000_000) throw new Error('请求体过大');
    chunks.push(chunk);
  }
  if (chunks.length === 0) return {};
  return JSON.parse(Buffer.concat(chunks).toString('utf8'));
}

async function capabilityStatus(host) {
  const jobs = publicJobs(host);
  const activeJobs = jobs.filter(job => !TERMINAL_JOB_STATUSES.has(job.status));
  const reattachRequired = activeJobs.some(job => job.status === 'waiting_for_browser_host');
  return {
    ok: true,
    capability: BROWSER_CAPABILITY,
    browser: 'iab',
    replyHandoffAvailable: handoffAvailable(host.localWorkBridge),
    model: BROWSER_MODEL,
    reasoning: BROWSER_REASONING,
    surface: 'chat',
    authorizationScope: 'conversation-only',
    localOnly: true,
    hostHealth: reattachRequired ? 'reattach_required' : 'attached',
    reattachRequired,
    pumpActive: host.pumpActive,
    lastBrowserActivityAt: host.lastBrowserActivityAt,
    activeJob: publicJob(host.activeJob),
    jobs,
    activeJobs,
    maxConcurrentJobs: MAX_PARALLEL_BROWSER_JOBS,
    newChatUrl: host.newChatUrl,
    expiresAt: host.expiresAt,
  };
}

export async function createInAppBrowserCapabilityHost({
  browser,
  tab,
  startUrl,
  policy = BROWSER_DISPATCH_POLICY,
  capabilityFile = DEFAULT_CAPABILITY_FILE,
  jobStateFile = DEFAULT_JOB_FILE,
  logger = () => {},
  recoverTab = reattachInAppBrowserTab,
  localWorkBridge = null,
} = {}) {
  if (!browser || !tab?.playwright) throw new Error('需要已授权的内置 Browser 和可控标签页');
  const policyCheck = validateBrowserPolicy(policy);
  if (!policyCheck.ok) throw new Error(policyCheck.message);
  const token = randomBytes(32).toString('base64url');
  const resolvedCapabilityFile = resolve(capabilityFile);
  const initialUrl = startUrl || await tab.playwright.evaluate(() => window.location.href);
  const host = {
    browser,
    tab,
    localWorkBridge,
    logger,
    recoverTab,
    policy: { ...BROWSER_DISPATCH_POLICY },
    newChatUrl: projectNewChatUrl(initialUrl),
    token,
    expiresAt: Date.now() + CAPABILITY_TTL_MS,
    capabilityFile: resolvedCapabilityFile,
    jobStateFile: resolve(jobStateFile),
    activeJob: null,
    jobs: new Map(),
    pendingJobs: [],
    jobWaiters: [],
    pumpActive: false,
    pumpStopRequested: false,
    stepActive: false,
    roundRobinCursor: 0,
    lastBrowserActivityAt: new Date().toISOString(),
    pageRefreshCount: 0,
    pageRefreshWindowStartedAt: Date.now(),
    lastPageRefreshAt: 0,
  };
  host.replyHandoff = new ReplyHandoff({
    stateFile: `${host.jobStateFile}.reply-handoff.json`,
    bridge: localWorkBridge,
    readSnapshot: async watch => {
      // Never navigate/recreate a tab or read another conversation on its behalf.
      const watchedTab = await browser.tabs.get(watch.tabId);
      const state = await readPageState(watchedTab);
      return { ...state, pageError: isPageLoadFailureState(state) };
    },
  });
  await host.replyHandoff.restore();
  const restoredJobs = await restoreJobs(host.jobStateFile);
  for (const job of restoredJobs) registerJob(host, job);
  host.activeJob = restoredJobs[0] || null;
  // A legacy single-job state did not persist a tab identifier. Preserve the
  // supplied controlled tab for that oldest job; every additional restored
  // job reattaches only to its own saved conversation or a new background tab.
  if (host.activeJob) {
    host.activeJob.tab = tab;
    host.activeJob.tabId = tab.id || host.activeJob.tabId || null;
    // A short-lived host can persist the project entry while the actual
    // conversation tab remains alive (for example during a lease rotation).
    // Recover the conversation identity before restored-job preflight.
    await repairRestoredBrowserJobConversation(host, host.activeJob, tab);
  }
  host.runStep = async ({ jobId = '' } = {}) => {
    if (host.stepActive) return publicJob(jobId ? jobForId(host, jobId) : host.activeJob);
    host.stepActive = true;
    try {
      return await runBrowserStep(host, { jobId });
    } finally {
      host.stepActive = false;
    }
  };
  host.runPump = async ({ idleTimeoutMs = 0, leaseTimeoutMs = 0 } = {}) => {
    if (host.pumpActive) throw new Error('内置 Browser capability 泵已在运行');
    host.pumpActive = true;
    const leaseDeadline = leaseTimeoutMs > 0 ? Date.now() + leaseTimeoutMs : Number.POSITIVE_INFINITY;
    const leaseDrainedJobs = new Set();
    try {
      while (!host.pumpStopRequested) {
        const runningJobs = activeBrowserJobs(host);
        if (runningJobs.length === 0 && hostJobs(host).length > 0) break;
        if (Date.now() >= leaseDeadline) {
          const readyJobs = runningJobs.filter(job => (
            !leaseDrainedJobs.has(job.id) && readyForLeaseDrain(job)
          ));
          if (readyJobs.length > 0) {
            for (const job of readyJobs) {
              leaseDrainedJobs.add(job.id);
              await host.runStep({ jobId: job.id });
            }
            continue;
          }
          for (const job of runningJobs) {
            job.status = 'waiting_for_browser_host';
            job.error = '内置 Browser 宿主已在执行租约到期前主动轮换；下一轮会自动重新附着同一任务。';
          }
          if (runningJobs.length > 0) await persistJob(host, runningJobs.at(-1));
          break;
        }
        let job = nextBrowserJob(host);
        if (!job) {
          job = await new Promise(resolvePromise => {
            let timer;
            const resolveJob = nextJob => {
              if (timer) clearTimeout(timer);
              resolvePromise(nextJob);
            };
            host.jobWaiters.push(resolveJob);
            const leaseRemainingMs = Number.isFinite(leaseDeadline)
              ? Math.max(1, leaseDeadline - Date.now()) : 0;
            const waitTimeoutMs = idleTimeoutMs > 0 && leaseRemainingMs > 0
              ? Math.min(idleTimeoutMs, leaseRemainingMs)
              : (idleTimeoutMs > 0 ? idleTimeoutMs : leaseRemainingMs);
            if (waitTimeoutMs > 0) timer = setTimeout(() => {
              const index = host.jobWaiters.indexOf(resolveJob);
              if (index >= 0) host.jobWaiters.splice(index, 1);
              resolvePromise(null);
            }, waitTimeoutMs);
          });
        }
        if (!job) {
          if (Date.now() >= leaseDeadline || idleTimeoutMs > 0) break;
          continue;
        }
        // Route every pump tick through the same single-flight guard used by
        // HTTP supervisor ticks. The long-lived Browser lease and the plugin
        // supervisor can legitimately poll at the same time, but only one of
        // them may advance the persisted job.
        await host.runStep({ jobId: job.id });
        const pollIntervalMs = Number(host.policy.pollIntervalMs || DEFAULT_POLL_INTERVAL_MS);
        const remainingMs = Number.isFinite(leaseDeadline)
          ? Math.max(0, leaseDeadline - Date.now()) : pollIntervalMs;
        await sleep(Math.min(pollIntervalMs, remainingMs));
      }
    } finally {
      host.pumpActive = false;
    }
    return publicJob(host.activeJob);
  };
  // Keep the trusted Browser execution lease alive until this persisted job
  // reaches a terminal state. A lease rotation is an internal recovery event,
  // not a reason to return control to the caller: rebind the same job and keep
  // pumping. Callers should await this method instead of creating the host and
  // letting the Browser execution turn end. A recurring supervisor with a
  // hard execution limit may opt into a persisted, bounded slice instead.
  host.runUntilTerminal = async ({
    leaseTimeoutMs = DEFAULT_BROWSER_LEASE_MS,
    returnOnLeaseExpiry = false,
  } = {}) => {
    const reattachFailures = new Map();
    try {
      while (!host.pumpStopRequested) {
        const result = await host.runPump({
          idleTimeoutMs: 0,
          leaseTimeoutMs,
        });
        const remainingJobs = activeBrowserJobs(host);
        if (!result || remainingJobs.length === 0 || host.pumpStopRequested) return result;
        const jobsNeedingReattach = remainingJobs.filter(job => (
          job.status === 'waiting_for_browser_host' || job.status === 'reattaching_browser_host'
        ));
        // A scheduler can call this method in bounded, awaited Browser turns.
        // The state has already been persisted by runPump, so deliberately
        // yield before the host execution itself is forcibly reclaimed. The
        // next scheduled slice reattaches every affected job independently.
        if (returnOnLeaseExpiry && jobsNeedingReattach.length > 0) {
          return {
            ...publicJob(host.activeJob),
            reattachRequired: true,
            leaseSliceComplete: true,
          };
        }
        for (const job of jobsNeedingReattach) {
          try {
            await recoverBrowserHostTab(host, job);
            reattachFailures.delete(job.id);
          } catch (error) {
            const failures = Number(reattachFailures.get(job.id) || 0) + 1;
            reattachFailures.set(job.id, failures);
            job.status = 'waiting_for_browser_host';
            job.lastReattachError = publicError(error);
            job.error = '内置 Browser 暂时不可用，插件会继续自动重试并保留同一任务。';
            await persistJob(host, job);
            const delay = Math.min(
              BROWSER_HOST_REATTACH_MAX_DELAY_MS,
              BROWSER_HOST_REATTACH_INITIAL_DELAY_MS * (2 ** Math.min(failures - 1, 6)),
            );
            await sleep(delay);
          }
        }
      }
      return publicJob(host.activeJob);
    } finally {
      await host.release();
    }
  };
  const server = createServer((req, res) => {
    void (async () => {
      const requestUrl = new URL(req.url || '/', 'http://127.0.0.1');
      const suppliedToken = String(req.headers.authorization || '').replace(/^Bearer\s+/iu, '');
      if (!safeEqual(suppliedToken, host.token)) {
        json(res, 401, { ok: false, errorCode: 'browser_capability_unauthorized' });
        return;
      }
      if (Date.now() >= host.expiresAt) {
        json(res, 410, { ok: false, errorCode: 'browser_capability_expired' });
        return;
      }
      if (req.method === 'GET' && requestUrl.pathname === '/v1/capability') {
        json(res, 200, await capabilityStatus(host));
        return;
      }
      if (requestUrl.pathname === '/v1/reply-handoff' && req.method === 'POST') {
        if (!handoffAvailable(localWorkBridge)) {
          json(res, 503, { ok: false, errorCode: 'independent_work_bridge_unavailable',
            message: '宿主未提供跨模型回合持续运行、绑定本地 Work 并去重确认的通知接口。不能交还等待。' });
          return;
        }
        const body = await requestBody(req);
        let result;
        if (body.action === 'register') {
          if (activeBrowserJobs(host).some(job => job.tabId === body.tabId)) {
            json(res, 409, { ok: false, errorCode: 'tab_owned_by_goal_dispatcher' });
            return;
          }
          result = await host.replyHandoff.register(body);
        } else if (body.action === 'cancel') result = await host.replyHandoff.cancel(body.watchId);
        else if (body.action === 'status') result = host.replyHandoff.status(body.watchId);
        else throw new Error('invalid_handoff_action');
        json(res, 200, { ok: true, ...result });
        return;
      }
      const jobMatch = requestUrl.pathname.match(/^\/v1\/chat\/jobs\/([^/]+)(\/stop)?$/u);
      if (req.method === 'GET' && jobMatch) {
        const job = jobForId(host, jobMatch[1]);
        if (!job) {
          json(res, 404, { ok: false, errorCode: 'browser_job_not_found' });
          return;
        }
        json(res, 200, { ok: true, job: publicJob(job) });
        return;
      }
      if (req.method === 'POST' && requestUrl.pathname === '/v1/chat/dispatch') {
        const body = await requestBody(req);
        const goal = String(body.goal ?? '').trim();
        if (!goal || goal.length > MAX_GOAL_LENGTH) {
          json(res, 400, { ok: false, errorCode: 'invalid_goal', message: 'goal 必须是 1-10000 字符的非空目标文本' });
          return;
        }
        const bodyPolicy = body.policy;
        const bodyPolicyCheck = validateBrowserPolicy(bodyPolicy);
        if (!bodyPolicyCheck.ok) {
          json(res, 400, { ok: false, errorCode: 'browser_policy_rejected', message: bodyPolicyCheck.message });
          return;
        }
        const existing = activeBrowserJobs(host).find(job => job.goal === goal);
        if (existing) {
          json(res, 200, { ok: true, accepted: false, alreadyRunning: true, job: publicJob(existing) });
          return;
        }
        if (activeBrowserJobs(host).length >= MAX_PARALLEL_BROWSER_JOBS) {
          json(res, 409, {
            ok: false,
            errorCode: 'browser_job_capacity_reached',
            message: `内置 Browser 最多同时运行 ${MAX_PARALLEL_BROWSER_JOBS} 个隔离任务。`,
            jobs: publicJobs(host),
          });
          return;
        }
        const job = {
          id: `iab_${randomUUID()}`,
          goal,
          status: 'accepted',
          attempt: 0,
          startedAt: new Date().toISOString(),
          updatedAt: new Date().toISOString(),
          stopRequested: false,
          currentUrl: host.newChatUrl,
          conversationId: null,
          latestReply: '',
          responseRunning: false,
          authorization: null,
          lastOutcome: null,
          error: null,
          reattachCount: 0,
          lastReattachedAt: null,
          lastReattachMethod: null,
          lastReattachError: null,
        };
        await createBrowserJobTab(host, job);
        registerJob(host, job);
        host.activeJob = job;
        host.pendingJobs.push(job);
        await persistJob(host, job);
        host.jobWaiters.shift()?.(job);
        json(res, 202, {
          ok: true,
          accepted: true,
          capability: BROWSER_CAPABILITY,
          job: publicJob(job),
          jobs: publicJobs(host),
          maxConcurrentJobs: MAX_PARALLEL_BROWSER_JOBS,
        });
        return;
      }
      if (req.method === 'POST' && requestUrl.pathname === '/v1/chat/step') {
        const body = await requestBody(req);
        const requestedJobId = String(body.jobId || '').trim();
        if (requestedJobId && !jobForId(host, requestedJobId)) {
          json(res, 404, { ok: false, errorCode: 'browser_job_not_found' });
          return;
        }
        const job = await host.runStep({ jobId: requestedJobId });
        json(res, 200, { ok: true, job });
        return;
      }
      if (req.method === 'POST' && jobMatch && jobMatch[2] === '/stop') {
        const job = jobForId(host, jobMatch[1]);
        if (!job) {
          json(res, 404, { ok: false, errorCode: 'browser_job_not_found' });
          return;
        }
        job.stopRequested = true;
        job.status = 'stopped';
        job.responseRunning = false;
        job.error = job.error || '已由用户停止内置 Browser 任务';
        job.lastOutcome = { kind: 'stopped', reason: 'operator' };
        await persistJob(host, job);
        json(res, 200, { ok: true, job: publicJob(job), jobs: publicJobs(host) });
        return;
      }
      json(res, 404, { ok: false, errorCode: 'browser_capability_route_not_found' });
    })().catch(error => {
      if (!res.headersSent) json(res, 500, { ok: false, errorCode: 'browser_capability_internal_error', message: publicError(error) });
      else res.destroy();
    });
  });
  await new Promise((resolvePromise, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', () => resolvePromise());
  });
  const address = server.address();
  if (!address || typeof address === 'string') throw new Error('内置 Browser capability 没有获得本地端口');
  const baseUrl = `http://127.0.0.1:${address.port}`;
  const descriptor = {
    schema: 'chatgpt-auto-confirm.browser-capability.v1',
    capability: BROWSER_CAPABILITY,
    browser: 'iab',
    baseUrl,
    token,
    expiresAt: host.expiresAt,
  };
  await mkdir(dirname(resolvedCapabilityFile), { recursive: true });
  await writeFile(resolvedCapabilityFile, `${JSON.stringify(descriptor)}\n`, { encoding: 'utf8', mode: 0o600 });
  await chmod(resolvedCapabilityFile, 0o600);
  host.baseUrl = baseUrl;
  host.descriptor = { ...descriptor, token: undefined };
  host.server = server;
  let released = false;
  let handoffTimer;
  // A process callback polls; the model is never invoked for unchanged state.
  // The independent lifetime declaration is supplied only by a trusted host.
  const handoffTick = async () => {
    if (released || Date.now() >= host.expiresAt) return;
    try { await host.replyHandoff.tick(); }
    catch { host.logger({ event: 'handoff_state_unavailable' }); }
    if (!released) handoffTimer = setTimeout(handoffTick, 1000);
  };
  if (handoffAvailable(localWorkBridge)) handoffTimer = setTimeout(handoffTick, 1000);
  host.release = async () => {
    if (released) return;
    released = true;
    clearTimeout(handoffTimer);
    await host.replyHandoff.tail;
    host.pumpStopRequested = true;
    for (const waiter of host.jobWaiters.splice(0)) waiter(null);
    await new Promise(resolvePromise => server.close(() => resolvePromise()));
    try {
      const current = JSON.parse(await readFile(resolvedCapabilityFile, 'utf8'));
      if (current.token === token) await unlink(resolvedCapabilityFile);
    } catch {
      // The capability file may already have been replaced or removed.
    }
  };
  host.close = async () => {
    const runningJobs = activeBrowserJobs(host);
    for (const job of runningJobs) {
      job.stopRequested = true;
      job.status = 'stopped';
      job.responseRunning = false;
      job.lastOutcome = { kind: 'stopped', reason: 'host_closed' };
    }
    if (runningJobs.length > 0) await persistJob(host, runningJobs.at(-1));
    await host.release();
  };
  return host;
}

/**
 * Bootstrap a fresh trusted Browser execution lease without requiring the
 * caller to retain or guess a previous tab id. The returned host must be kept
 * alive with `await host.runUntilTerminal()`; a scheduler with a hard runtime
 * limit may await a returned bounded slice using `returnOnLeaseExpiry`.
 */
export async function attachPersistentInAppBrowserCapabilityHost({
  browser,
  startUrl,
  preferredTabId = null,
  policy = BROWSER_DISPATCH_POLICY,
  capabilityFile = DEFAULT_CAPABILITY_FILE,
  jobStateFile = DEFAULT_JOB_FILE,
  logger = () => {},
  recoverTab = reattachInAppBrowserTab,
  localWorkBridge = null,
} = {}) {
  const recovery = await recoverTab({
    browser,
    targetUrl: startUrl,
    preferredTabId,
    fallbackUrl: projectNewChatUrl(startUrl),
    logger,
  });
  const host = await createInAppBrowserCapabilityHost({
    browser,
    tab: recovery.tab,
    startUrl: recovery.url || startUrl,
    policy,
    capabilityFile,
    jobStateFile,
    logger,
    recoverTab,
    localWorkBridge,
  });
  host.bootstrapReattachMethod = recovery.method;
  return host;
}
