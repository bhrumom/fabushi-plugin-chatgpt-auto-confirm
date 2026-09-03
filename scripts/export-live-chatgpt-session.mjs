import { chmod, mkdir, readFile, rename, unlink, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';

const argumentsMap = new Map();
for (let index = 2; index < process.argv.length; index += 2) {
  argumentsMap.set(process.argv[index], process.argv[index + 1]);
}

const outputPath = argumentsMap.get('--output');
const authPath = argumentsMap.get('--auth');
const port = Number(argumentsMap.get('--port') || process.env.CHATGPT_CDP_PORT || 9324);

class ExportError extends Error {}

const decodeBase64Url = value => {
  const normalized = value.replaceAll('-', '+').replaceAll('_', '/');
  return Buffer.from(normalized.padEnd(Math.ceil(normalized.length / 4) * 4, '='), 'base64');
};

const codexIdentifiers = async path => {
  const auth = JSON.parse(await readFile(path, 'utf8'));
  const tokens = auth.tokens || {};
  const accountId = String(tokens.account_id || '');
  const tokenParts = String(tokens.id_token || '').split('.');
  if (!accountId || tokenParts.length < 2) throw new ExportError('Codex auth bundle is incomplete');
  const payload = JSON.parse(decodeBase64Url(tokenParts[1]).toString('utf8'));
  const claims = payload['https://api.openai.com/auth'] || {};
  const identifiers = new Set([
    accountId,
    String(claims.chatgpt_account_id || ''),
    String(claims.chatgpt_user_id || ''),
  ].filter(Boolean));
  if (!identifiers.size) throw new ExportError('Codex auth bundle has no ChatGPT identity');
  return identifiers;
};

const listTargets = async () => {
  const response = await fetch(`http://127.0.0.1:${port}/json/list`, {
    signal: AbortSignal.timeout(5_000),
  });
  if (!response.ok) throw new ExportError('ChatGPT CDP target list is unavailable');
  return response.json();
};

const connect = async websocketUrl => {
  const socket = new WebSocket(websocketUrl);
  await new Promise((resolvePromise, reject) => {
    const timer = setTimeout(() => reject(new ExportError('ChatGPT CDP connection timed out')), 10_000);
    socket.addEventListener('open', () => {
      clearTimeout(timer);
      resolvePromise();
    }, { once: true });
    socket.addEventListener('error', () => {
      clearTimeout(timer);
      reject(new ExportError('ChatGPT CDP connection failed'));
    }, { once: true });
  });
  let sequence = 0;
  const call = (method, params = {}) => new Promise((resolvePromise, reject) => {
    const id = ++sequence;
    const timer = setTimeout(() => {
      socket.removeEventListener('message', onMessage);
      reject(new ExportError(`ChatGPT CDP command timed out: ${method}`));
    }, 15_000);
    const onMessage = event => {
      const message = JSON.parse(String(event.data));
      if (message.id !== id) return;
      clearTimeout(timer);
      socket.removeEventListener('message', onMessage);
      if (message.error) reject(new ExportError(`ChatGPT CDP command failed: ${method}`));
      else resolvePromise(message.result || {});
    };
    socket.addEventListener('message', onMessage);
    socket.send(JSON.stringify({ id, method, params }));
  });
  return { socket, call };
};

const normalizeCookies = cookies => cookies.flatMap(cookie => {
  const domain = String(cookie.domain || '');
  const lowerDomain = domain.toLowerCase().replace(/^\./, '');
  const allowedDomain = lowerDomain === 'chatgpt.com'
    || lowerDomain.endsWith('.chatgpt.com')
    || lowerDomain === 'openai.com'
    || lowerDomain.endsWith('.openai.com');
  if (!allowedDomain) return [];
  if (!cookie.name || !cookie.value) return [];
  const normalized = {
    name: String(cookie.name),
    value: String(cookie.value),
    domain,
    path: String(cookie.path || '/'),
    secure: cookie.secure !== false,
    httpOnly: cookie.httpOnly === true,
  };
  if (cookie.sameSite && cookie.sameSite !== 'None') normalized.sameSite = cookie.sameSite;
  if (Number(cookie.expires) > 0) normalized.expires = Number(cookie.expires);
  return [normalized];
});

const exportSession = async () => {
  if (!outputPath || !authPath || !Number.isInteger(port) || port < 1 || port > 65535) {
    throw new ExportError('Required arguments are invalid');
  }
  await codexIdentifiers(resolve(authPath));
  const targets = await listTargets();
  const candidates = targets.filter(item => item.type === 'page'
    && item.webSocketDebuggerUrl
    && String(item.url || '').startsWith('app://-/index.html')
    && !String(item.url || '').includes('/avatar-overlay'));
  if (!candidates.length) throw new ExportError('No live ChatGPT desktop app renderer is exposed over CDP');

  const authenticationExpression = `(() => {
    const normalize = value => (value || '').replace(/\\s+/g, ' ').trim();
    const bodyText = normalize(document.body?.innerText).slice(0, 12000);
    const controls = [...document.querySelectorAll('button,[role="button"],[role="tab"],[aria-label]')];
    const labels = controls.map(element => normalize([
      element.innerText, element.textContent, element.getAttribute('aria-label'),
      element.getAttribute('title')
    ].filter(Boolean).join(' ')));
    const exact = label => labels.some(value => value.toLowerCase() === label);
    const hasChat = exact('chat') || exact('聊天');
    const hasWork = exact('work') || exact('工作');
    const currentMode = labels.find(value => /current mode|当前模式|目前模式/i.test(value)) || '';
    const asksForLogin = /(^|\\n)(log in|sign up|登录|登入|註冊|注册)(\\n|$)/i.test(bodyText);
    const workComposer = !!document.querySelector('[data-codex-composer="true"]');
    const authenticated = location.protocol === 'app:' && !!window.electronBridge
      && !asksForLogin && document.readyState === 'complete' && bodyText.length > 50
      && !!(currentMode || workComposer || hasChat || hasWork);
    return {authenticated};
  })()`;
  let selectedConnection;
  for (const candidate of candidates) {
    let connection;
    try {
      connection = await connect(candidate.webSocketDebuggerUrl);
      const evaluation = await connection.call('Runtime.evaluate', {
        expression: authenticationExpression,
        returnByValue: true,
      });
      if (evaluation.result?.value?.authenticated === true) {
        selectedConnection = connection;
        break;
      }
    } catch {
      // Try the next renderer: ChatGPT may expose an overlay or a stale page
      // before its authenticated primary page finishes mounting.
    }
    connection?.socket.close();
  }
  if (!selectedConnection) throw new ExportError('ChatGPT desktop app renderer is not authenticated');
  const { socket, call } = selectedConnection;
  try {
    await call('Network.enable');
    const cookieResult = await call('Network.getAllCookies');
    const cookies = normalizeCookies(Array.isArray(cookieResult.cookies) ? cookieResult.cookies : []);
    if (!cookies.length) throw new ExportError('No ChatGPT session cookies were returned by the live renderer');
    const resolvedOutput = resolve(outputPath);
    const temporaryOutput = `${resolvedOutput}.${process.pid}.${Date.now()}.tmp`;
    await mkdir(dirname(resolvedOutput), { recursive: true });
    try {
      await writeFile(temporaryOutput, JSON.stringify({ cookies }), { mode: 0o600 });
      await chmod(temporaryOutput, 0o600).catch(() => {});
      await rename(temporaryOutput, resolvedOutput);
    } finally {
      await unlink(temporaryOutput).catch(() => {});
    }
    return { ok: true, cookieCount: cookies.length, credentialSource: 'live-desktop-renderer', accountVerified: true };
  } finally {
    socket.close();
  }
};

try {
  process.stdout.write(`${JSON.stringify(await exportSession())}\n`);
} catch (error) {
  process.stdout.write(`${JSON.stringify({
    ok: false,
    errorCode: 'live_chatgpt_session_export_failed',
    message: error instanceof ExportError ? error.message : 'Live ChatGPT renderer export failed',
  })}\n`);
  process.exitCode = 1;
}
