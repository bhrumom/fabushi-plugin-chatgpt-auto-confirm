import assert from 'node:assert/strict';
import { mkdtemp, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { ReplyHandoff, digest, handoffAvailable } from '../scripts/reply-handoff.mjs';

async function fixture() {
  let clock = 0;
  const stateFile = join(await mkdtemp(join(tmpdir(), 'reply-handoff-')), 'state.json');
  const sent = [];
  const request = { watchId: 'watch-1', tabId: 'tab-1', threadId: 'task-1',
    conversationUrl: 'https://chatgpt.com/c/conversation-1',
    expectedUserDigest: digest('new request'), baselineAssistantDigest: digest('old reply') };
  const state = { url: request.conversationUrl, latestUserText: 'new request',
    latestAssistantText: 'new reply', stopAnswer: false, pendingAuthorization: false,
    retry: false, hasComposer: true, hasWorkComposer: false };
  const bridge = { independentLifetime: true, idempotentDelivery: true, ownsTask: async () => true,
    send: async event => { sent.push(event); return { accepted: true, eventId: event.eventId }; } };
  const options = { stateFile, readSnapshot: async () => ({ ...state }), bridge, now: () => clock };
  const controller = new ReplyHandoff(options);
  await controller.restore();
  await controller.register(request);
  return { controller, options, request, state, sent, bridge,
    advance: () => { clock += 65_000; } };
}

test('no wake for streaming, authorization, retry, missing state or old replies', async () => {
  for (const patch of [{ stopAnswer: true }, { pendingAuthorization: true }, { retry: true },
    { pageError: true }, { hasComposer: false }, { hasWorkComposer: true },
    { latestUserText: '' }, { latestAssistantText: 'old reply' }, { stopAnswer: undefined }]) {
    const f = await fixture();
    Object.assign(f.state, patch);
    await f.controller.tick(); f.advance(); await f.controller.tick();
    assert.equal(f.sent.length, 0, JSON.stringify(patch));
  }
});

test('stable reply wakes Luna medium once; no reply body persisted or forwarded', async () => {
  const f = await fixture();
  await f.controller.tick();
  assert.equal(f.sent.length, 0);
  f.advance();
  await Promise.all([f.controller.tick(), f.controller.tick()]);
  assert.equal(f.sent.length, 1);
  assert.equal(f.sent[0].model, 'gpt-5.6-luna');
  assert.equal(f.sent[0].thinking, 'medium');
  assert.equal(f.sent[0].threadId, 'task-1');
  assert.ok(!f.sent[0].prompt.includes('new reply'));
  assert.ok(!(await readFile(f.options.stateFile, 'utf8')).includes('new reply'));
  const restored = new ReplyHandoff(f.options);
  await restored.restore();
  await restored.tick();
  assert.equal(f.sent.length, 1);
});

test('changing reply and interrupted settling reset stability', async () => {
  const f = await fixture();
  await f.controller.tick(); f.advance();
  f.state.latestAssistantText = 'revised answer';
  await f.controller.tick();
  assert.equal(f.sent.length, 0);
  f.advance(); f.state.stopAnswer = true; await f.controller.tick();
  f.state.stopAnswer = false; await f.controller.tick();
  assert.equal(f.sent.length, 0);
  f.advance(); await f.controller.tick();
  assert.equal(f.sent.length, 1);
});

test('delivery failure survives restart with same idempotency key', async () => {
  const f = await fixture();
  f.bridge.send = async event => { f.sent.push(event); throw new Error('private-token'); };
  await f.controller.tick(); f.advance(); await f.controller.tick();
  const restored = new ReplyHandoff(f.options);
  await restored.restore(); f.advance(); await restored.tick(); f.advance();
  f.bridge.send = async event => { f.sent.push(event); return { accepted: true, eventId: event.eventId }; };
  await restored.tick();
  assert.equal(f.sent.length, 2);
  assert.equal(f.sent[0].eventId, f.sent[1].eventId);
  assert.equal(restored.status('watch-1').status, 'delivered');
  assert.ok(!(await readFile(f.options.stateFile, 'utf8')).includes('private-token'));
});

test('different conversation, new user turn and cancellation never wake stale tasks', async () => {
  const f = await fixture();
  f.state.url = 'https://chatgpt.com/c/other';
  await f.controller.tick(); f.advance(); await f.controller.tick();
  assert.equal(f.sent.length, 0);
  f.state.url = f.request.conversationUrl; f.state.latestUserText = 'later turn';
  f.advance(); await f.controller.tick();
  assert.equal(f.controller.status('watch-1').status, 'superseded');
  const g = await fixture();
  await g.controller.tick(); await g.controller.cancel('watch-1');
  g.advance(); await g.controller.tick(); assert.equal(g.sent.length, 0);
});

test('registration requires real independent bridge, owned task and immutable watch identity', async () => {
  const f = await fixture();
  assert.equal(handoffAvailable({ send() {} }), false);
  await f.controller.register(f.request);
  await assert.rejects(f.controller.register({ ...f.request, threadId: 'other' }), /identity_conflict/);
  await assert.rejects(f.controller.register({ ...f.request, watchId: 'another' }), /already_watched/);
  f.bridge.ownsTask = async () => false;
  await assert.rejects(f.controller.register({ ...f.request, watchId: 'another', tabId: 'another' }), /not_owned/);
  f.bridge.independentLifetime = false;
  await assert.rejects(f.controller.register(f.request), /bridge_unavailable/);
});

test('real loopback host rejects registration without independent Work bridge', async () => {
  const { createInAppBrowserCapabilityHost } = await import('../scripts/in-app-browser-capability-host.mjs');
  const directory = await mkdtemp(join(tmpdir(), 'handoff-host-'));
  const host = await createInAppBrowserCapabilityHost({ browser: {}, tab: { playwright: {} },
    startUrl: 'https://chatgpt.com/', capabilityFile: join(directory, 'capability.json'),
    jobStateFile: join(directory, 'jobs.json'), localWorkBridge: null });
  try {
    const headers = { authorization: `Bearer ${host.token}`, 'content-type': 'application/json' };
    const unauthorized = await fetch(`${host.baseUrl}/v1/reply-handoff`, { method: 'POST', body: '{}' });
    assert.equal(unauthorized.status, 401);
    const status = await (await fetch(`${host.baseUrl}/v1/capability`, { headers })).json();
    assert.equal(status.replyHandoffAvailable, false);
    const rejected = await fetch(`${host.baseUrl}/v1/reply-handoff`, { headers, method: 'POST',
      body: JSON.stringify({ action: 'register', watchId: 'watch-1' }) });
    assert.equal(rejected.status, 503);
    assert.equal((await rejected.json()).errorCode, 'independent_work_bridge_unavailable');
  } finally { await host.release(); }
});
