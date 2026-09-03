#!/usr/bin/env node
import crypto from 'node:crypto';
import http from 'node:http';
import { spawn } from 'node:child_process';

const args = process.argv.slice(2);
const value = name => {
  const index = args.indexOf(name);
  return index >= 0 ? args[index + 1] : '';
};
const runtime = value('--runtime');
const label = String(value('--label') || '');
if (!runtime) throw new Error('runtime is required');

const token = crypto.randomBytes(32).toString('hex');
const expiresAt = Date.now() + 10 * 60 * 1000;
let consumed = false;

const html = () => `<!doctype html><meta charset="utf-8"><title>ChatGPT 账号登录</title>
<meta name="viewport" content="width=device-width,initial-scale=1"><main style="font:16px system-ui;max-width:32rem;margin:4rem auto;padding:1rem">
<h1>添加 ChatGPT 账号</h1><p>确认后会在本机打开隔离登录窗口。凭据不会出现在此页面或链接中。</p>
<form method="post" action="/start?token=${token}"><button type="submit">确认并打开登录</button></form><p>此链接十分钟内有效且只能使用一次。</p></main>`;

const server = http.createServer((request, response) => {
  const url = new URL(request.url || '/', 'http://127.0.0.1');
  if (url.pathname !== '/') {
    if (url.pathname === '/start' && request.method === 'POST') {
      if (url.searchParams.get('token') !== token || consumed || Date.now() > expiresAt) {
        response.writeHead(410, { 'content-type': 'text/plain; charset=utf-8' });
        response.end('链接已过期或已使用');
        return;
      }
      consumed = true;
      const child = spawn(runtime, ['account_add', JSON.stringify({ label, start: true })], {
        detached: true,
        stdio: 'ignore',
        env: process.env,
      });
      child.unref();
      response.writeHead(202, { 'content-type': 'text/html; charset=utf-8' });
      response.end('<p>已启动隔离登录窗口，可以关闭此页面。</p>');
      setTimeout(() => server.close(), 1_000);
      return;
    }
    response.writeHead(404); response.end('Not found'); return;
  }
  if (request.method !== 'GET' || url.searchParams.get('token') !== token) { response.writeHead(404); response.end(); return; }
  response.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' });
  response.end(html());
});

server.listen(0, '127.0.0.1', () => {
  const address = server.address();
  const port = typeof address === 'object' && address ? address.port : 0;
  process.stdout.write(`${JSON.stringify({ ok: true, url: `http://127.0.0.1:${port}/?token=${token}`, expiresAt, oneTime: true })}\n`);
});
setTimeout(() => server.close(), Math.max(1, expiresAt - Date.now()));
