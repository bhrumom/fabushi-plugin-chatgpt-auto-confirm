import assert from 'node:assert/strict';
import test from 'node:test';
import { restoreSession } from '../scripts/restore-session-cookies.mjs';

const encodedCookies = Buffer.from(JSON.stringify({
  cookies: [{ name: 'session', value: 'redacted', domain: '.chatgpt.com' }],
})).toString('base64');

const appTarget = (id, url) => ({
  id,
  type: 'page',
  url,
  webSocketDebuggerUrl: `ws://${id}`,
});

class FakeCDPServer {
  constructor({
    initialURL,
    loginPrompt = false,
    replaceOnAuthFailure = false,
    stuckOverlay = false,
    navigationFailure = false,
    rootTargetFailures = 0,
    controllerReady = true,
  }) {
    this.targets = [appTarget('initial', initialURL)];
    this.loginPrompt = loginPrompt;
    this.replaceOnAuthFailure = replaceOnAuthFailure;
    this.stuckOverlay = stuckOverlay;
    this.navigationFailure = navigationFailure;
    this.rootTargetFailures = rootTargetFailures;
    this.controllerReady = controllerReady;
    this.failAuthEvaluation = replaceOnAuthFailure;
    this.connections = [];
    this.closedSockets = 0;
    this.navigations = 0;
    this.reloads = 0;
    this.rootTargetCreations = 0;
    this.clock = 0;
  }

  fetch = async () => ({
    json: async () => this.targets.map(target => ({ ...target })),
  });

  targetForSocket(socket) {
    return this.targets.find(target => target.webSocketDebuggerUrl === socket.url)
      || this.connections.find(item => item.socket === socket)?.target;
  }

  replaceTarget(id, url) {
    this.targets = [appTarget(id, url)];
  }

  createRootTarget = async () => {
    this.rootTargetCreations += 1;
    if (this.rootTargetCreations <= this.rootTargetFailures) {
      this.targets = [];
      return null;
    }
    this.replaceTarget('after-root-create', 'app://-/index.html?initialRoute=%2F');
    return 'after-root-create';
  };

  handle(socket, method) {
    const target = this.targetForSocket(socket);
    if (method === 'Runtime.evaluate') {
      const isLocationProbe = String(socket.lastExpression || '').trim() === 'location.href';
      if (this.failAuthEvaluation && !isLocationProbe) {
        this.failAuthEvaluation = false;
        if (this.replaceOnAuthFailure) {
          this.replaceTarget('after-cdp-failure', 'app://-/index.html?initialRoute=%2F');
        }
        return { error: { message: 'renderer replaced during evaluation' } };
      }
      if (isLocationProbe) {
        return { result: { result: { value: target?.url || '' } } };
      }
      const bodyLength = this.loginPrompt ? 80 : 120;
      return {
        result: {
          result: {
            value: {
              asksForLogin: this.loginPrompt,
              bridge: true,
              bodyLength,
              readyState: 'complete',
              url: target?.url || '',
              visibility: 'visible',
              hasChat: this.controllerReady,
              hasWork: false,
              currentMode: '',
              workComposer: false,
            },
          },
        },
      };
    }
    if (method === 'Network.getAllCookies') {
      return { result: { cookies: [{ domain: '.chatgpt.com' }] } };
    }
    if (method === 'Page.navigate') {
      this.navigations += 1;
      if (this.navigationFailure) {
        this.targets = [];
        return { error: { message: 'renderer replaced during navigation' } };
      }
      if (!this.stuckOverlay) {
        this.replaceTarget('after-navigation', 'app://-/index.html?initialRoute=%2F');
      }
      return { result: { frameId: 'frame' } };
    }
    if (method === 'Page.reload') {
      this.reloads += 1;
      this.replaceTarget('after-reload', 'app://-/index.html?initialRoute=%2F');
      return { result: {} };
    }
    return { result: {} };
  }

  webSocketClass() {
    const server = this;
    return class FakeWebSocket {
      constructor(url) {
        this.url = url;
        this.listeners = new Map();
        this.closed = false;
        const target = server.targets.find(item => item.webSocketDebuggerUrl === url);
        server.connections.push({ socket: this, target });
        queueMicrotask(() => this.emit('open', {}));
      }

      addEventListener(name, listener) {
        const listeners = this.listeners.get(name) || new Set();
        listeners.add(listener);
        this.listeners.set(name, listeners);
      }

      removeEventListener(name, listener) {
        this.listeners.get(name)?.delete(listener);
      }

      emit(name, event) {
        for (const listener of this.listeners.get(name) || []) listener(event);
      }

      send(raw) {
        const message = JSON.parse(raw);
        this.lastExpression = message.params?.expression || '';
        const response = server.handle(this, message.method);
        if (!response) return;
        queueMicrotask(() => this.emit('message', {
          data: JSON.stringify({ id: message.id, ...response }),
        }));
      }

      close() {
        if (this.closed) return;
        this.closed = true;
        server.closedSockets += 1;
        queueMicrotask(() => this.emit('close', {}));
      }
    };
  }

  sleep = async milliseconds => {
    this.clock += milliseconds;
  };

  now = () => this.clock;
}

const run = (server, options = {}) => restoreSession({
  mode: 'restore-and-verify',
  encoded: encodedCookies,
  fetchImpl: server.fetch,
  WebSocketImpl: server.webSocketClass(),
  sleepImpl: server.sleep,
  nowImpl: server.now,
  targetTimeoutMs: 20_000,
  reconnectTimeoutMs: 20_000,
  verificationTimeoutMs: 20_000,
  createRootTargetImpl: options.createRootTargetImpl || server.createRootTarget,
  log: () => {},
  ...options,
});

test('reconnects to the replacement renderer after avatar-overlay navigation and reload', async () => {
  const server = new FakeCDPServer({
    initialURL: 'app://-/index.html?initialRoute=%2Favatar-overlay',
  });

  const output = await run(server);
  assert.match(output, /^Verified authenticated desktop shell/);
  assert.equal(server.navigations, 1);
  assert.equal(server.reloads, 1);
  assert.ok(server.closedSockets >= 2);
  assert.ok(server.connections.some(item => item.target?.id === 'after-navigation'));
  assert.ok(server.connections.some(item => item.target?.id === 'after-reload'));
});

test('uses root navigation instead of reload for a headless desktop shell', async () => {
  const server = new FakeCDPServer({
    initialURL: 'app://-/index.html?initialRoute=%2F',
  });
  let nativePromptProbes = 0;

  const output = await run(server, {
    headless: true,
    nativePromptImpl: () => { nativePromptProbes += 1; },
  });
  assert.match(output, /^Verified authenticated desktop shell/);
  assert.equal(server.reloads, 0);
  assert.equal(server.navigations, 1);
  assert.ok(nativePromptProbes > 0);
  assert.ok(server.connections.some(item => item.target?.id === 'after-navigation'));
});

test('creates a fresh root target when overlay navigation retires the renderer', async () => {
  const server = new FakeCDPServer({
    initialURL: 'app://-/index.html?initialRoute=%2Favatar-overlay',
    navigationFailure: true,
    rootTargetFailures: 1,
  });

  const output = await run(server, { headless: true });
  assert.match(output, /^Verified authenticated desktop shell/);
  assert.ok(server.rootTargetCreations >= 2);
  assert.ok(server.connections.some(item => item.target?.id === 'after-root-create'));
});

test('recovers when the active renderer fails during Runtime.evaluate', async () => {
  const server = new FakeCDPServer({
    initialURL: 'app://-/index.html?initialRoute=%2F',
    replaceOnAuthFailure: true,
  });

  const output = await run(server);

  assert.match(output, /^Verified authenticated desktop shell/);
  assert.ok(server.connections.some(item => item.target?.id === 'after-cdp-failure'));
});


test('does not accept a non-login placeholder shell without controller controls', async () => {
  const server = new FakeCDPServer({
    initialURL: 'app://-/index.html?initialRoute=%2F',
    controllerReady: false,
  });

  await assert.rejects(
    run(server, { verificationTimeoutMs: 4_000 }),
    /Authenticated desktop shell was not verified/,
  );
});

test('does not accept a real login prompt as an authenticated shell', async () => {
  const server = new FakeCDPServer({
    initialURL: 'app://-/index.html?initialRoute=%2F',
    loginPrompt: true,
  });

  await assert.rejects(
    run(server, { verificationTimeoutMs: 4_000 }),
    /Authenticated desktop shell was not verified/,
  );
});

test('times out with redacted target diagnostics when overlay recovery is stuck', async () => {
  const server = new FakeCDPServer({
    initialURL: 'app://-/index.html?initialRoute=%2Favatar-overlay',
    stuckOverlay: true,
  });

  await assert.rejects(
    run(server, { targetTimeoutMs: 12_000, reconnectTimeoutMs: 4_000 }),
    error => {
      assert.match(error.message, /ChatGPT app shell after bootstrap was not ready/);
      assert.match(error.message, /avatar-overlay/);
      assert.doesNotMatch(error.message, /ws:\/\//);
      return true;
    },
  );
});
