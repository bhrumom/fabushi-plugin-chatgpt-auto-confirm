import { spawnSync } from 'node:child_process';
import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

const defaultPort = 9324;
const appRootURL = 'app://-/index.html?initialRoute=%2F';

const sleep = milliseconds =>
  new Promise(resolve => setTimeout(resolve, milliseconds));

const targetURL = target => String(target?.url || '');

const isAppPage = target =>
  target?.type === 'page'
  && target?.webSocketDebuggerUrl
  && targetURL(target).startsWith('app://-/index.html');

const isAvatarOverlay = target => {
  const url = targetURL(target);
  try {
    return url.includes('/avatar-overlay') || decodeURIComponent(url).includes('/avatar-overlay');
  } catch {
    return url.includes('/avatar-overlay');
  }
};

const isNormalAppTarget = target => isAppPage(target) && !isAvatarOverlay(target);

const safeTargetSummary = targets => targets.map(target => ({
  type: target?.type,
  id: String(target?.id || '').slice(0, 48),
  url: targetURL(target).slice(0, 160),
}));

const targetKey = target => `${target?.id || ''}|${target?.webSocketDebuggerUrl || ''}`;

const diagnosticTimestamp = () => new Date().toISOString()
  .replace(/[^0-9]/g, '')
  .slice(0, 17);

const writeDiagnosticEvidence = ({ directory, label, payload }) => {
  if (!directory) return null;
  try {
    mkdirSync(directory, { recursive: true, mode: 0o700 });
    const path = join(directory, `renderer-${label}-${diagnosticTimestamp()}.json`);
    writeFileSync(path, `${JSON.stringify({
      recordedAt: new Date().toISOString(),
      ...payload,
    }, null, 2)}\n`, { mode: 0o600 });
    return path;
  } catch {
    return null;
  }
};

const captureDiagnosticScreenshot = async ({ connection, directory, label }) => {
  if (!connection || !directory) return null;
  try {
    const result = await connection.call('Page.captureScreenshot', {
      format: 'png',
      captureBeyondViewport: true,
      fromSurface: true,
    }, 5_000);
    const encoded = String(result?.data || '');
    if (!encoded) return null;
    mkdirSync(directory, { recursive: true, mode: 0o700 });
    const path = join(directory, `renderer-${label}-${diagnosticTimestamp()}.png`);
    writeFileSync(path, Buffer.from(encoded, 'base64'), { mode: 0o600 });
    return path;
  } catch {
    return null;
  }
};

const approveHeadlessChatGPTLocalNetworkPrompt = ({
  platform = process.platform,
  spawnImpl = spawnSync,
} = {}) => {
  if (platform !== 'darwin') return false;
  const script = `
tell application "System Events"
  repeat with processRef in (application processes whose name is "ChatGPT")
    repeat with windowRef in (windows of processRef)
      try
        set promptTexts to ""
        try
          set promptTexts to (value of static texts of windowRef) as text
        end try
        set dialogRole to ""
        try
          set dialogRole to (subrole of windowRef) as text
        end try
        set compactDialog to false
        try
          set windowSize to size of windowRef
          set windowWidth to item 1 of windowSize
          set windowHeight to item 2 of windowSize
          if (frontmost of processRef) and ¬
             (windowWidth is greater than 180) and (windowWidth is less than 420) and ¬
             (windowHeight is greater than 180) and (windowHeight is less than 360) then
            set compactDialog to true
          end if
        end try
        if (dialogRole is "AXSystemDialog") or compactDialog or ¬
           (promptTexts contains "find devices on local networks") or ¬
           (promptTexts contains "在本地网络上查找设备") or ¬
           (promptTexts contains "在本地網絡上查找設備") then
          if exists (button "Allow" of windowRef) then
            click button "Allow" of windowRef
            return "clicked"
          end if
          if exists (button "允许" of windowRef) then
            click button "允许" of windowRef
            return "clicked"
          end if
          if exists (button "允許" of windowRef) then
            click button "允許" of windowRef
            return "clicked"
          end if
          try
            if compactDialog then
              set windowPosition to position of windowRef
              set clickX to ((item 1 of windowPosition) + (windowWidth * 72 / 100)) as integer
              set clickY to ((item 2 of windowPosition) + (windowHeight * 87 / 100)) as integer
              click at {clickX, clickY}
              return "clicked"
            end if
          end try
          if (dialogRole is "AXSystemDialog") and (frontmost of processRef) then
            return "dialog"
          end if
        end if
      end try
    end repeat
  end repeat
end tell
return "none"
`;
  try {
    const result = spawnImpl('/usr/bin/osascript', ['-e', script], {
      encoding: 'utf8',
      timeout: 1_500,
      stdio: ['ignore', 'pipe', 'ignore'],
    });
    if (result?.status !== 0) return false;
    const output = String(result.stdout || '');
    if (output.includes('clicked')) return true;
    if (!output.includes('dialog')) return false;
    const keyPress = spawnImpl(
      '/usr/bin/osascript',
      ['-e', 'tell application "System Events" to key code 36'],
      { encoding: 'utf8', timeout: 1_000, stdio: ['ignore', 'ignore', 'ignore'] },
    );
    return keyPress?.status === 0;
  } catch {
    return false;
  }
};

const pickTarget = (targets, predicate) =>
  targets.find(predicate);

const authenticatedControllerIsReady = state =>
  !state.asksForLogin
  && state.bridge
  && state.readyState === 'complete'
  && state.bodyLength > 50
  && !!(state.currentMode || state.workComposer || state.hasChat || state.hasWork);

const listTargets = async (fetchImpl, port) =>
  fetchImpl(`http://127.0.0.1:${port}/json/list`, {
    signal: AbortSignal.timeout(5_000),
  }).then(response => response.json());

const createAppRootTarget = async ({
  port,
  fetchImpl,
  WebSocketImpl,
  log,
}) => {
  let browserConnection;
  try {
    const version = await fetchImpl(`http://127.0.0.1:${port}/json/version`, {
      signal: AbortSignal.timeout(5_000),
    }).then(response => response.json());
    const browserWebSocketDebuggerUrl = String(version?.webSocketDebuggerUrl || '');
    if (!browserWebSocketDebuggerUrl) {
      throw new Error('CDP browser websocket URL was not exposed');
    }
    browserConnection = await connect({
      id: 'browser',
      type: 'browser',
      url: 'devtools://browser',
      webSocketDebuggerUrl: browserWebSocketDebuggerUrl,
    }, { WebSocketImpl });
    const result = await browserConnection.call('Target.createTarget', {
      url: appRootURL,
      background: false,
    }, 10_000);
    const targetId = String(result.targetId || '');
    if (!targetId) throw new Error('CDP Target.createTarget returned no target id');
    log(`Created ChatGPT app root target ${targetId.slice(0, 48)}`);
    return targetId;
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error);
    log(`CDP app root target creation failed: ${detail}`);
    return null;
  } finally {
    closeConnection(browserConnection);
  }
};

const connect = async (
  target,
  { WebSocketImpl = globalThis.WebSocket } = {},
) => {
  if (!WebSocketImpl) throw new Error('WebSocket is unavailable');
  const socket = new WebSocketImpl(target.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => {
    const cleanup = () => {
      clearTimeout(timer);
      socket.removeEventListener('open', onOpen);
      socket.removeEventListener('error', onError);
    };
    const onOpen = () => {
      cleanup();
      resolve();
    };
    const onError = event => {
      cleanup();
      reject(event);
    };
    const timer = setTimeout(() => {
      cleanup();
      try {
        socket.close();
      } catch {}
      reject(new Error('ChatGPT CDP socket connection timed out'));
    }, 15_000);
    socket.addEventListener('open', onOpen, { once: true });
    socket.addEventListener('error', onError, { once: true });
  });
  let sequence = 0;
  const call = (method, params = {}, timeoutMs = 30_000) => new Promise((resolve, reject) => {
    const id = ++sequence;
    let settled = false;
    const cleanup = () => {
      clearTimeout(timer);
      socket.removeEventListener('message', onMessage);
      socket.removeEventListener('close', onClose);
      socket.removeEventListener('error', onError);
    };
    const finish = (handler, value) => {
      if (settled) return;
      settled = true;
      cleanup();
      handler(value);
    };
    const onMessage = event => {
      let message;
      try {
        message = JSON.parse(String(event.data));
      } catch {
        return;
      }
      if (message.id !== id) return;
      if (message.error) {
        finish(reject, new Error(`${method} failed: ${JSON.stringify(message.error)}`));
      } else {
        finish(resolve, message.result || {});
      }
    };
    const onClose = () => finish(reject, new Error(`${method} failed because the CDP socket closed`));
    const onError = () => finish(reject, new Error(`${method} failed because the CDP socket errored`));
    const timer = setTimeout(() => {
      finish(reject, new Error(`${method} timed out`));
    }, timeoutMs);
    socket.addEventListener('message', onMessage);
    socket.addEventListener('close', onClose, { once: true });
    socket.addEventListener('error', onError, { once: true });
    try {
      socket.send(JSON.stringify({ id, method, params }));
    } catch (error) {
      finish(reject, error instanceof Error ? error : new Error(String(error)));
    }
  });
  return { socket, call, target };
};

const closeConnection = connection => {
  try {
    connection?.socket?.close();
  } catch {}
};

const optionalCall = async (
  call,
  method,
  params = {},
  timeoutMs = 5_000,
  log = message => process.stderr.write(`${message}\n`),
) => {
  try {
    await call(method, params, timeoutMs);
    return true;
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error);
    log(`Optional CDP command ${method} failed: ${detail}`);
    return false;
  }
};

const findTarget = async ({
  port,
  timeoutMs,
  label,
  fetchImpl,
  sleepImpl,
  nowImpl,
  allowAvatarOverlay = true,
  avatarOverlayFallbackMs = 10_000,
  beforeProbeImpl = () => {},
}) => {
  const deadline = nowImpl() + timeoutMs;
  const avatarOverlayFallbackDeadline = nowImpl() + Math.min(
    avatarOverlayFallbackMs,
    timeoutMs,
  );
  let lastTargets = [];
  let avatarOverlayTarget;
  let lastError = '';
  while (nowImpl() < deadline) {
    await beforeProbeImpl();
    try {
      lastTargets = await listTargets(fetchImpl, port);
      const target = pickTarget(lastTargets, isNormalAppTarget);
      if (target) return target;
      avatarOverlayTarget = pickTarget(lastTargets, targetItem =>
        isAppPage(targetItem) && isAvatarOverlay(targetItem),
      ) || avatarOverlayTarget;
      if (
        allowAvatarOverlay
        && avatarOverlayTarget
        && nowImpl() >= avatarOverlayFallbackDeadline
      ) {
        return avatarOverlayTarget;
      }
    } catch (error) {
      lastError = error instanceof Error ? error.message : String(error);
    }
    await sleepImpl(1_000);
  }
  if (allowAvatarOverlay && avatarOverlayTarget) return avatarOverlayTarget;
  throw new Error(`${label} was not exposed (${JSON.stringify({
    lastError,
    targets: safeTargetSummary(lastTargets),
  })})`);
};

const recoverAppRootConnection = async ({
  connection,
  port,
  fetchImpl,
  WebSocketImpl,
  sleepImpl,
  nowImpl,
  timeoutMs,
  label,
  log,
  createRootTargetImpl,
  beforeProbeImpl = () => {},
  diagnosticsDir,
}) => {
  const deadline = nowImpl() + timeoutMs;
  let active = connection;
  let lastTargets = [];
  let lastError = '';
  let navigationAttempts = 0;
  let rootTargetCreationAttempts = 0;
  let lastNavigationAt = 0;

  const recordEvidence = async (label, extra = {}, screenshotConnection = active) => {
    const screenshotPath = await captureDiagnosticScreenshot({
      connection: screenshotConnection,
      directory: diagnosticsDir,
      label,
    });
    const evidencePath = writeDiagnosticEvidence({
      directory: diagnosticsDir,
      label,
      payload: {
        phase: label,
        label,
        targets: safeTargetSummary(lastTargets),
        navigationAttempts,
        rootTargetCreationAttempts,
        lastError,
        screenshotPath,
        ...extra,
      },
    });
    if (diagnosticsDir) {
      log(`Renderer diagnostic ${label}: ${JSON.stringify({
        screenshotPath: screenshotPath || null,
        evidencePath: evidencePath || null,
        targetCount: lastTargets.length,
        navigationAttempts,
        rootTargetCreationAttempts,
        lastError: lastError || null,
      })}`);
    }
    return { screenshotPath, evidencePath };
  };

  const createRootTargetIfNeeded = async () => {
    if (rootTargetCreationAttempts >= 2 || typeof createRootTargetImpl !== 'function') return;
    rootTargetCreationAttempts += 1;
    await createRootTargetImpl({ port, fetchImpl, WebSocketImpl, log });
  };

  // A navigation can replace the renderer while leaving the old DevTools
  // socket open. Always release that socket before selecting the replacement.
  if (active) {
    let currentURL = '';
    try {
      const evaluation = await active.call('Runtime.evaluate', {
        expression: 'location.href',
        returnByValue: true,
      }, 5_000);
      currentURL = String(evaluation.result?.value || '');
    } catch (error) {
      lastError = error instanceof Error ? error.message : String(error);
    }
    if (isAvatarOverlay({ url: currentURL })) {
      await recordEvidence('before-overlay-navigation', { currentURL });
      const navigated = await optionalCall(
        active.call,
        'Page.navigate',
        { url: appRootURL },
        10_000,
        log,
      );
      navigationAttempts += 1;
      lastNavigationAt = nowImpl();
      closeConnection(active);
      active = null;
      if (!navigated) await createRootTargetIfNeeded();
    } else if (lastError) {
      // A failed Runtime.evaluate can mean the renderer was replaced while
      // Chromium kept the old target record. Force a fresh WebSocket attach.
      closeConnection(active);
      active = null;
    }
  }

  while (nowImpl() < deadline) {
    await beforeProbeImpl();
    try {
      lastTargets = await listTargets(fetchImpl, port);
      const normalTarget = pickTarget(lastTargets, isNormalAppTarget);
      if (normalTarget) {
        await recordEvidence('normal-renderer-ready', {
          targetId: String(normalTarget.id || '').slice(0, 48),
          targetURL: targetURL(normalTarget),
        }, active);
        if (active && targetKey(active.target) === targetKey(normalTarget)) {
          return active;
        }
        closeConnection(active);
        return await connect(normalTarget, { WebSocketImpl });
      }

      const overlayTarget = pickTarget(lastTargets, targetItem =>
        isAppPage(targetItem) && isAvatarOverlay(targetItem),
      );
      if (overlayTarget) {
        if (!active || targetKey(active.target) !== targetKey(overlayTarget)) {
          closeConnection(active);
          active = await connect(overlayTarget, { WebSocketImpl });
        }
        if (navigationAttempts < 2) {
          await recordEvidence('before-overlay-retry-navigation', {
            targetId: String(overlayTarget.id || '').slice(0, 48),
            targetURL: targetURL(overlayTarget),
          });
          const navigated = await optionalCall(
            active.call,
            'Page.navigate',
            { url: appRootURL },
            10_000,
            log,
          );
          navigationAttempts += 1;
          lastNavigationAt = nowImpl();
          closeConnection(active);
          active = null;
          if (!navigated) await createRootTargetIfNeeded();
        }
      } else if (
        navigationAttempts > 0
        && nowImpl() - lastNavigationAt >= 2_000
      ) {
        // A renderer can disappear after Page.navigate has acknowledged the
        // request. Create a fresh normal app target through the browser CDP
        // endpoint instead of waiting for the retired overlay to reappear.
        await createRootTargetIfNeeded();
      } else if (rootTargetCreationAttempts < 2) {
        // Page.navigate can retire the only renderer before the caller gets
        // here. In that state there is no overlay and no navigation attempt
        // left to trigger the old fallback, so actively ask the browser CDP
        // endpoint for a fresh authenticated app root instead of polling an
        // empty target list until the timeout.
        await recordEvidence('empty-target-list-before-root-retry', {
          reason: 'no_normal_or_overlay_target',
        }, null);
        await createRootTargetIfNeeded();
      }
    } catch (error) {
      lastError = error instanceof Error ? error.message : String(error);
      closeConnection(active);
      active = null;
    }
    await sleepImpl(1_000);
  }

  closeConnection(active);
  await recordEvidence('renderer-recovery-timeout', {
    reason: 'reconnect_deadline_exhausted',
  }, active);
  throw new Error(`${label} was not ready (${JSON.stringify({
    lastError,
    navigationAttempts,
    targets: safeTargetSummary(lastTargets),
  })})`);
};

const activate = async (call, log) => {
  // New ChatGPT desktop builds can leave Page.setWebLifecycleState unanswered.
  // Focus hints improve hosted rendering but must never abort cookie bootstrap.
  await optionalCall(call, 'Emulation.setFocusEmulationEnabled', { enabled: true }, 5_000, log);
  await optionalCall(call, 'Emulation.setIdleOverride', {
    isUserActive: true,
    isScreenUnlocked: true,
  }, 5_000, log);
};

const sessionStateExpression = `(() => {
  const normalize = value => (value || '').replace(/\\s+/g, ' ').trim();
  const visible = element => !!(element && (
    element.offsetWidth || element.offsetHeight || element.getClientRects().length
  ));
  const bodyText = normalize(document.body?.innerText).slice(0, 12000);
  const controls = [...document.querySelectorAll(
    'button, [role="button"], [role="tab"], [aria-label]'
  )].filter(visible);
  // Keep label sources independent. Electron controls frequently expose the
  // same visible label through innerText and textContent; concatenating them
  // turns "Chat" into "Chat Chat" and breaks exact control detection.
  const labels = controls.flatMap(element => [
    element.innerText,
    element.textContent,
    element.getAttribute('aria-label'),
    element.getAttribute('title')
  ]).map(normalize).filter(Boolean);
  const exact = label => labels.some(value => value.toLowerCase() === label);
  const hasChat = exact('chat') || exact('聊天');
  const hasWork = exact('work') || exact('工作');
  const currentMode = labels.find(value =>
    /current mode|当前模式|目前模式/i.test(value)
  ) || '';
  const asksForLogin = /(^|\\n)(log in|sign up|登录|登入|註冊|注册)(\\n|$)/i.test(bodyText);
  const workComposer = !!document.querySelector('[data-codex-composer="true"]');
  return {
    hasChat,
    hasWork,
    currentMode: currentMode.slice(0, 160),
    asksForLogin,
    workComposer,
    bodyLength: bodyText.length,
    url: location.href,
    bridge: !!window.electronBridge,
    visibility: document.visibilityState,
    readyState: document.readyState
  };
})()`;

export async function restoreSession({
  port = Number(process.env.CHATGPT_CDP_PORT || defaultPort),
  mode = process.env.CHATGPT_SESSION_MODE || 'restore-and-verify',
  headless = process.env.CHATGPT_AUTO_CONFIRM_HEADLESS === '1',
  nativePromptImpl,
  encoded = process.env.CHATGPT_SESSION_COOKIES_B64,
  fetchImpl = globalThis.fetch,
  WebSocketImpl = globalThis.WebSocket,
  sleepImpl = sleep,
  nowImpl = () => Date.now(),
  targetTimeoutMs = 120_000,
  reconnectTimeoutMs = 120_000,
  verificationTimeoutMs = 120_000,
  createRootTargetImpl,
  log = message => process.stderr.write(`${message}\n`),
  diagnosticsDir = process.env.CHATGPT_AUTO_CONFIRM_DIAGNOSTICS_DIR || '',
} = {}) {
  if (!['seed', 'restore', 'verify', 'restore-and-verify'].includes(mode)) {
    throw new Error(`Unsupported CHATGPT_SESSION_MODE: ${mode}`);
  }
  if (typeof fetchImpl !== 'function') throw new Error('fetch is unavailable');

  let payload = { cookies: [] };
  if (mode !== 'verify') {
    if (!encoded) {
      throw new Error(
        'CHATGPT_SESSION_COOKIES_B64 is required because Codex auth alone only restores Work access',
      );
    }
    payload = JSON.parse(Buffer.from(encoded, 'base64').toString('utf8'));
    if (!Array.isArray(payload.cookies) || payload.cookies.length === 0) {
      throw new Error('The ChatGPT session cookie secret is empty');
    }
  }

  let connection;
  const rootTargetCreator = createRootTargetImpl || createAppRootTarget;
  const beforeProbeImpl = headless
    ? async () => {
      const approved = typeof nativePromptImpl === 'function'
        ? nativePromptImpl()
        : approveHeadlessChatGPTLocalNetworkPrompt();
      if (approved) {
        log('Headless ChatGPT native local-network prompt approved');
      }
    }
    : undefined;
  try {
    const target = await findTarget({
      port,
      timeoutMs: targetTimeoutMs,
      label: 'ChatGPT app shell',
      fetchImpl,
      sleepImpl,
      nowImpl,
      beforeProbeImpl,
    });
    connection = await connect(target, { WebSocketImpl });

    if (mode !== 'verify') {
      await connection.call('Network.setCookies', { cookies: payload.cookies });
      const result = await connection.call('Network.getAllCookies');
      const restored = (result.cookies || []).filter(cookie =>
        /(^|\.)((chatgpt|openai)\.com)$/i.test(cookie.domain || ''),
      ).length;
      if (restored === 0) {
        throw new Error('ChatGPT session cookies were not persisted');
      }
      if (mode === 'seed') {
        return `Seeded ${restored} ChatGPT session cookies`;
      }
    }

    connection = await recoverAppRootConnection({
      connection,
      port,
      fetchImpl,
      WebSocketImpl,
      sleepImpl,
      nowImpl,
      timeoutMs: reconnectTimeoutMs,
      label: 'ChatGPT app shell after bootstrap',
      log,
      createRootTargetImpl: rootTargetCreator,
      beforeProbeImpl,
      diagnosticsDir,
    });

    if (mode === 'restore' || mode === 'restore-and-verify') {
      // Hosted macOS runs have no user-facing window. In that environment a
      // Chromium Page.reload can tear down the only Electron renderer before
      // it answers the CDP command, leaving /json/list empty for the whole
      // recovery window. Navigating to the app root exercises the same cookie
      // bootstrap while keeping the renderer lifecycle recoverable. The local
      // desktop path retains the stronger cache-busting reload behavior.
      let bootstrapActionSucceeded;
      if (headless) {
        bootstrapActionSucceeded = await optionalCall(
          connection.call,
          'Page.navigate',
          { url: appRootURL },
          10_000,
          log,
        );
      } else {
        // Page.reload can replace the renderer. Re-discover the target after
        // the command instead of issuing Runtime calls through the stale socket.
        bootstrapActionSucceeded = await optionalCall(
          connection.call,
          'Page.reload',
          { ignoreCache: true },
          10_000,
          log,
        );
      }
      if (!bootstrapActionSucceeded) {
        // Some Electron builds retire the only renderer when navigation or
        // reload times out. Create a replacement root page before polling the
        // now-empty target list so the recovery does not wait out its entire
        // timeout with no renderer to attach to.
        await rootTargetCreator({ port, fetchImpl, WebSocketImpl, log });
      }
      closeConnection(connection);
      connection = await recoverAppRootConnection({
        connection: null,
        port,
        fetchImpl,
        WebSocketImpl,
        sleepImpl,
        nowImpl,
        timeoutMs: reconnectTimeoutMs,
        label: 'ChatGPT app shell after reload',
        log,
        createRootTargetImpl: rootTargetCreator,
        beforeProbeImpl,
        diagnosticsDir,
      });
      await activate(connection.call, log);
    }

    // Bootstrap mode intentionally stops here. The native queue owns the
    // authoritative hidden-Chat authentication check.
    if (mode === 'restore') {
      return `Restored ${payload.cookies.length} ChatGPT session cookies and requested renderer reload`;
    }

    const verificationDeadline = nowImpl() + verificationTimeoutMs;
    let lastState = {};
    while (nowImpl() < verificationDeadline) {
      await sleepImpl(2_000);
      try {
        const evaluation = await connection.call('Runtime.evaluate', {
          expression: sessionStateExpression,
          returnByValue: true,
        }, 15_000);
        lastState = evaluation.result?.value || {};
        if (isAvatarOverlay({ url: lastState.url })) {
          connection = await recoverAppRootConnection({
            connection,
            port,
            fetchImpl,
            WebSocketImpl,
            sleepImpl,
            nowImpl,
            timeoutMs: reconnectTimeoutMs,
            label: 'ChatGPT app shell during verification',
            log,
            createRootTargetImpl: rootTargetCreator,
            beforeProbeImpl,
            diagnosticsDir,
          });
          continue;
        }
        if (authenticatedControllerIsReady(lastState)) {
          return `Verified authenticated desktop shell (${JSON.stringify(lastState)})`;
        }
      } catch (error) {
        lastState = {
          cdpError: error instanceof Error ? error.message : String(error),
        };
        closeConnection(connection);
        connection = null;
        try {
          connection = await recoverAppRootConnection({
            connection,
            port,
            fetchImpl,
            WebSocketImpl,
            sleepImpl,
            nowImpl,
            timeoutMs: reconnectTimeoutMs,
            label: 'ChatGPT app shell after CDP failure',
            log,
            createRootTargetImpl: rootTargetCreator,
            beforeProbeImpl,
            diagnosticsDir,
          });
        } catch (recoveryError) {
          lastState.recoveryError = recoveryError instanceof Error
            ? recoveryError.message
            : String(recoveryError);
        }
      }
    }
    throw new Error(
      `Authenticated desktop shell was not verified (${JSON.stringify(lastState)})`,
    );
  } finally {
    closeConnection(connection);
  }
}

const isMainModule = process.argv[1]
  && import.meta.url === pathToFileURL(process.argv[1]).href;

if (isMainModule) {
  const output = await restoreSession();
  process.stdout.write(`${output}\n`);
  // Electron does not always complete the DevTools WebSocket close handshake
  // on hosted macOS, so terminate cleanly after the one-shot bootstrap.
  process.exit(0);
}
