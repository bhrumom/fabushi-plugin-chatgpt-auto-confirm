import assert from 'node:assert/strict';
import { mkdtemp, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import {
  LOCAL_WORK_MODEL,
  LOCAL_WORK_THINKING,
  LocalWorkBridge,
  createLocalWorkBridge,
  localWorkBridgeAvailable,
  localWorkBridgeDescriptor,
} from '../scripts/local-work-bridge.mjs';

const eventId = `reply_${'a'.repeat(64)}`;

async function fixture() {
  const stateFile = join(await mkdtemp(join(tmpdir(), 'local-work-bridge-')), 'ledger.json');
  const calls = { probes: 0, enqueues: 0 };
  const bridge = new LocalWorkBridge({
    codexPath: process.execPath,
    stateFile,
    now: () => 1_725_000_000_000,
    probeThread: async (_path, threadId) => {
      calls.probes += 1;
      return threadId === 'thread-1';
    },
    enqueue: async (_path, args) => {
      calls.enqueues += 1;
      assert.deepEqual(args.slice(0, 5), [
        'queue', '--thread', 'thread-1', '--message', `wake ${eventId}`,
      ]);
      assert.ok(args.includes('--model'));
      assert.ok(args.includes(LOCAL_WORK_MODEL));
      assert.ok(args.includes('model_reasoning_effort="medium"'));
      assert.ok(args.includes('--approve-for-me'));
      return { code: 0, signal: null, stdout: '', stderr: '' };
    },
  });
  await bridge.ready;
  return { bridge, stateFile, calls };
}

test('local Work bridge probes ownership and deduplicates an accepted event', async () => {
  const f = await fixture();
  const first = await f.bridge.send({
    eventId, threadId: 'thread-1', model: LOCAL_WORK_MODEL,
    thinking: LOCAL_WORK_THINKING, prompt: `wake ${eventId}`,
  });
  assert.deepEqual(first, { accepted: true, eventId, deduplicated: false });
  const second = await f.bridge.send({
    eventId, threadId: 'thread-1', model: LOCAL_WORK_MODEL,
    thinking: LOCAL_WORK_THINKING, prompt: `wake ${eventId}`,
  });
  assert.deepEqual(second, { accepted: true, eventId, deduplicated: true });
  assert.equal(f.calls.probes, 1);
  assert.equal(f.calls.enqueues, 1);
  const ledger = JSON.parse(await readFile(f.stateFile, 'utf8'));
  assert.equal(ledger.schema, 'chatgpt-auto-confirm.local-work-bridge.v1');
  assert.deepEqual(ledger.events, [{
    eventId, threadId: 'thread-1', status: 'accepted',
    acceptedAt: new Date(1_725_000_000_000).toISOString(), failedAt: null,
  }]);
});

test('bridge rejects an unowned thread and never queues a message', async () => {
  const f = await fixture();
  await assert.rejects(f.bridge.send({
    eventId, threadId: 'thread-2', model: LOCAL_WORK_MODEL,
    thinking: LOCAL_WORK_THINKING, prompt: `wake ${eventId}`,
  }), /work_task_not_owned/);
  assert.equal(f.calls.enqueues, 0);
});

test('bridge rejects reuse of an event id for a different Work thread', async () => {
  const f = await fixture();
  await f.bridge.send({
    eventId, threadId: 'thread-1', model: LOCAL_WORK_MODEL,
    thinking: LOCAL_WORK_THINKING, prompt: `wake ${eventId}`,
  });
  await assert.rejects(f.bridge.send({
    eventId, threadId: 'thread-2', model: LOCAL_WORK_MODEL,
    thinking: LOCAL_WORK_THINKING, prompt: `wake ${eventId}`,
  }), /event_identity_conflict/);
  assert.equal(f.calls.enqueues, 1);
});

test('bridge can be disabled and descriptor is non-secret', () => {
  assert.equal(createLocalWorkBridge({ codexPath: process.execPath, enabled: false }), null);
  assert.equal(localWorkBridgeAvailable({ codexPath: process.execPath, enabled: false }), false);
  const enabled = createLocalWorkBridge({ codexPath: process.execPath, enabled: true });
  assert.equal(enabled.independentLifetime, true);
  assert.equal(enabled.idempotentDelivery, true);
  const descriptor = localWorkBridgeDescriptor({ codexPath: process.execPath, enabled: true });
  assert.deepEqual(descriptor, {
    enabled: true,
    available: true,
    platform: process.platform,
    model: LOCAL_WORK_MODEL,
    thinking: LOCAL_WORK_THINKING,
    transport: 'codex-queue',
  });
  assert.deepEqual(localWorkBridgeDescriptor({ codexPath: process.execPath, enabled: false }), {
    enabled: false,
    available: false,
    platform: process.platform,
    model: LOCAL_WORK_MODEL,
    thinking: LOCAL_WORK_THINKING,
    transport: 'unavailable',
  });
});
