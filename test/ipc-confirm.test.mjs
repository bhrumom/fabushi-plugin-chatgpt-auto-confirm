import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import crypto from 'node:crypto';
import { mkdtempSync, rmSync } from 'node:fs';
import http from 'node:http';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';

const execFileAsync = promisify(execFile);

function sendTextFrame(socket, text) {
  const payload = Buffer.from(text, 'utf8');
  const len = payload.length;
  let header;
  if (len <= 125) {
    header = Buffer.alloc(2);
    header[0] = 0x81;
    header[1] = len;
  } else if (len <= 65535) {
    header = Buffer.alloc(4);
    header[0] = 0x81;
    header[1] = 126;
    header.writeUInt16BE(len, 2);
  } else {
    header = Buffer.alloc(10);
    header[0] = 0x81;
    header[1] = 127;
    header.writeBigUInt64BE(BigInt(len), 2);
  }
  socket.write(Buffer.concat([header, payload]));
}

test('CDP WebSocket & Unix IPC primary path integration test', async t => {
  if (process.platform !== 'darwin') {
    t.skip('Native runtime is macOS-only');
    return;
  }

  const tmpDir = mkdtempSync(path.join(os.tmpdir(), 'chatgpt-ipc-test-'));
  const socketPath = path.join(tmpDir, 'ipc.sock');
  const statePath = path.join(tmpDir, 'state.json');
  const nativeBinary = fileURLToPath(new URL('../runtime/macos/chatgpt-auto-confirm', import.meta.url));

  // 1. Start Mock Unix Socket Server (AF_UNIX)
  let unixInitReceived = false;
  const unixServer = net.createServer(socket => {
    let buffer = Buffer.alloc(0);
    socket.on('data', chunk => {
      buffer = Buffer.concat([buffer, chunk]);
      while (buffer.length >= 4) {
        const len = buffer.readUInt32LE(0);
        if (buffer.length < 4 + len) break;
        const jsonBytes = buffer.slice(4, 4 + len);
        buffer = buffer.slice(4 + len);
        let req;
        try {
          req = JSON.parse(jsonBytes.toString('utf8'));
        } catch (e) {
          continue;
        }
        if (req.method === 'initialize') {
          unixInitReceived = true;
          const resp = {
            jsonrpc: '2.0',
            id: req.id ?? 1,
            result: {
              protocolVersion: '2025-06-18',
              serverInfo: { name: 'mock-chatgpt-unix-ipc', version: '2.0.0' },
              capabilities: {}
            }
          };
          const respPayload = Buffer.from(JSON.stringify(resp), 'utf8');
          const header = Buffer.alloc(4);
          header.writeUInt32LE(respPayload.length, 0);
          socket.write(Buffer.concat([header, respPayload]));
        }
      }
    });
  });

  await new Promise(resolve => unixServer.listen(socketPath, resolve));
  t.after(() => {
    unixServer.close();
    rmSync(tmpDir, { recursive: true, force: true });
  });

  // 2. Start Mock CDP HTTP & WebSocket Server (AF_INET)
  let cdpPort = 0;
  let evaluateExpressionReceived = null;
  const evaluatedTargets = new Set();
  const httpServer = http.createServer((req, res) => {
    if (req.url === '/json') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify([
        {
          id: 'page-101',
          type: 'page',
          title: 'ChatGPT - Tool Approval Mock',
          url: 'https://chatgpt.com/c/test-session-101',
          webSocketDebuggerUrl: `ws://127.0.0.1:${cdpPort}/devtools/page/101`
        },
        {
          id: 'page-202',
          type: 'page',
          title: 'ChatGPT - Hidden Tool Approval Mock',
          url: 'https://chatgpt.com/c/test-session-202',
          webSocketDebuggerUrl: `ws://127.0.0.1:${cdpPort}/devtools/page/202`
        }
      ]));
    } else {
      res.writeHead(404);
      res.end();
    }
  });

  httpServer.on('upgrade', (req, socket, head) => {
    if (req.url === '/devtools/page/101' || req.url === '/devtools/page/202') {
      evaluatedTargets.add(req.url);
      const key = req.headers['sec-websocket-key'];
      const acceptKey = crypto.createHash('sha1').update(key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
      socket.write(
        'HTTP/1.1 101 Switching Protocols\r\n' +
        'Upgrade: websocket\r\n' +
        'Connection: Upgrade\r\n' +
        `Sec-WebSocket-Accept: ${acceptKey}\r\n\r\n`
      );

      let buffer = Buffer.alloc(0);
      socket.on('data', chunk => {
        buffer = Buffer.concat([buffer, chunk]);
        while (buffer.length >= 2) {
          const opcode = buffer[0] & 0x0f;
          if (opcode === 0x08) {
            socket.end();
            return;
          }
          let payloadLen = buffer[1] & 0x7f;
          let offset = 2;
          if (payloadLen === 126) {
            if (buffer.length < 4) break;
            payloadLen = buffer.readUInt16BE(2);
            offset += 2;
          } else if (payloadLen === 127) {
            if (buffer.length < 10) break;
            payloadLen = Number(buffer.readBigUInt64BE(2));
            offset += 8;
          }
          const isMasked = (buffer[1] & 0x80) !== 0;
          let maskKey = null;
          if (isMasked) {
            if (buffer.length < offset + 4) break;
            maskKey = buffer.slice(offset, offset + 4);
            offset += 4;
          }
          if (buffer.length < offset + payloadLen) break;
          const payload = buffer.slice(offset, offset + payloadLen);
          buffer = buffer.slice(offset + payloadLen);
          if (isMasked && maskKey) {
            for (let i = 0; i < payload.length; i++) {
              payload[i] ^= maskKey[i % 4];
            }
          }
          const text = payload.toString('utf8');
          let msg;
          try {
            msg = JSON.parse(text);
          } catch (e) {
            continue;
          }
          if (msg.method === 'Runtime.evaluate') {
            evaluateExpressionReceived = msg.params?.expression;
            const expression = msg.params?.expression ?? '';
            const value = expression.includes('alreadySelected')
              ? {
                  ok: true,
                  alreadySelected: true,
                  selectedLabel: 'chat-surface-validated',
                }
              : expression.includes('userMessageCount')
              ? {
                  ok: true,
                  content: '',
                  streaming: true,
                  done: false,
                  pending: true,
                  charCount: 0,
                  messageCount: 3,
                  userMessageCount: 4,
                }
              : expression.includes('hasInput')
                ? {
                    ok: true,
                    hasInput: true,
                    streaming: true,
                    title: 'ChatGPT',
                    connectors: ['devspace1'],
                    messageCount: { user: 4, assistant: 3 },
                    url: 'https://chatgpt.com/c/test-session-101',
                  }
                : {
                    candidates: 1,
                    approved: 1,
                    pending: 0,
                    blocked: 0,
                    unmatched: 0,
                    audits: [
                      {
                        buttonTitle: 'Allow once',
                        decision: 'allow',
                        reason: 'IPC 主路径：通用模式：已通过进程间通信自动确认 (allow_once/target_message_id)',
                        clicked: true,
                        ruleId: null,
                        promptText: 'Allow ChatGPT to use [approval details redacted] #c9e1f2a'
                      }
                    ]
                  };
            const mockEvalResponse = {
              id: msg.id,
              result: {
                result: {
                  type: 'object',
                  value,
                }
              }
            };
            sendTextFrame(socket, JSON.stringify(mockEvalResponse));
          }
        }
      });
    } else {
      socket.destroy();
    }
  });

  await new Promise(resolve => httpServer.listen(0, '127.0.0.1', resolve));
  cdpPort = httpServer.address().port;
  t.after(() => httpServer.close());

  const env = {
    ...process.env,
    CHATGPT_AUTO_CONFIRM_STATE: statePath,
    CHATGPT_AUTO_CONFIRM_UNIX_IPC: socketPath,
    CHATGPT_AUTO_CONFIRM_CDP_PORT: String(cdpPort),
    CHATGPT_AUTO_CONFIRM_CDP_HOST: '127.0.0.1',
    CHATGPT_AUTO_CONFIRM_BACKGROUND_PORT: String(cdpPort),
    CHATGPT_AUTO_CONFIRM_ALLOW_TEST_WEB_TARGET: '1',
    CHATGPT_AUTO_CONFIRM_DISABLE_AX: '1'
  };

  // 3. Test status command via Native Binary
  const { stdout: statusStdout } = await execFileAsync(nativeBinary, ['status'], { env });
  const statusRes = JSON.parse(statusStdout);
  assert.equal(statusRes.ok, true);
  assert.equal(statusRes.ipc.unix.available, true);
  assert.equal(statusRes.ipc.unix.connected, true);
  assert.equal(statusRes.ipc.unix.initialized, true);
  assert.equal(statusRes.ipc.unix.protocol, 'UInt32_LE_JSON');
  assert.equal(statusRes.ipc.cdp.available, true);
  assert.equal(statusRes.ipc.cdp.connected, true);
  assert.equal(statusRes.ipc.cdp.pageTargetCount, 2);
  assert.equal(statusRes.loadedRendererCount, 0);
  assert.equal(statusRes.safety.scansEveryLoadedRenderer, false);
  assert.equal(statusRes.safety.visibleRendererAccess, false);
  assert.equal(statusRes.ipc.primaryPath, 'CDP WebSocket & Unix IPC 主路径');
  assert.equal(statusRes.safety.ipcIsPrimaryPath, true);
  assert.equal(statusRes.safety.axPressIsFallback, false);
  assert.equal(statusRes.safety.axPressVisibleForegroundOnly, true);
  assert.equal(statusRes.safety.axPressNeverTargetsHiddenElements, true);
  assert.equal(unixInitReceived, true);

  const { stdout: chatStatusStdout } = await execFileAsync(
    nativeBinary,
    ['chat_status'],
    { env }
  );
  const chatStatusRes = JSON.parse(chatStatusStdout);
  assert.equal(chatStatusRes.ok, true);
  assert.equal(chatStatusRes.streaming, true);
  assert.deepEqual(chatStatusRes.connectors, ['devspace1']);

  const { stdout: replyStdout } = await execFileAsync(
    nativeBinary,
    ['get_reply'],
    { env }
  );
  const replyRes = JSON.parse(replyStdout);
  assert.equal(replyRes.ok, true);
  assert.equal(replyRes.pending, true);
  assert.equal(replyRes.streaming, true);
  assert.equal(replyRes.content, '');
  assert.equal(replyRes.userMessageCount, 4);

  // 4. A scan without an exact plugin-owned hidden target must not evaluate
  // either loaded renderer, even when both are valid ChatGPT pages.
  const evaluatedBeforeScan = [...evaluatedTargets].sort();
  const { stdout: scanStdout } = await execFileAsync(
    nativeBinary,
    ['scan', JSON.stringify({ approveAll: true })],
    { env }
  );
  const scanRes = JSON.parse(scanStdout);
  assert.equal(scanRes.ok, true);
  assert.equal(scanRes.candidates, 0);
  assert.equal(scanRes.approved, 0);
  assert.equal(scanRes.visibleFallbackDisabled, true);
  assert.equal(scanRes.pageChanged, false);
  assert.deepEqual([...evaluatedTargets].sort(), evaluatedBeforeScan);
  assert.ok(evaluateExpressionReceived);

  // 5. No authorization audit is emitted when no owned hidden renderer exists.
  const { stdout: auditStdout } = await execFileAsync(nativeBinary, ['audit', '10'], { env });
  const auditRes = JSON.parse(auditStdout);
  assert.equal(auditRes.ok, true);
  assert.equal(auditRes.events.length, 0);

});
