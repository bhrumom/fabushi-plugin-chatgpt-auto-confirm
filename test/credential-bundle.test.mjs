import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { packCredentialBundle, unpackCredentialBundle } from '../scripts/credential-bundle.mjs';

test('credential bundles encrypt, authenticate, and bind account id', async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'chatgpt-credential-bundle-'));
  const authPath = path.join(root, 'auth.json');
  const cookiesPath = path.join(root, 'cookies.json');
  const bundlePath = path.join(root, 'bundle.json');
  const authOut = path.join(root, 'out-auth.json');
  const cookiesOut = path.join(root, 'out-cookies.json');
  const key = Buffer.alloc(32, 7).toString('base64');
  await fs.writeFile(authPath, '{"tokens":{"account_id":"opaque"}}');
  await fs.writeFile(cookiesPath, '{"cookies":[{"name":"session","value":"redacted-in-test"}]}');
  await packCredentialBundle({ accountId: 'acct_0123456789ab', stateKey: key, authPath, cookiesPath, outputPath: bundlePath });
  const envelope = JSON.parse(await fs.readFile(bundlePath, 'utf8'));
  assert.equal(envelope.accountId, 'acct_0123456789ab');
  assert.equal(envelope.algorithm, 'aes-256-gcm');
  assert.equal(envelope.ciphertext.includes('redacted-in-test'), false);
  await unpackCredentialBundle({ accountId: 'acct_0123456789ab', stateKey: key, inputPath: bundlePath, authOutput: authOut, cookiesOutput: cookiesOut });
  assert.equal(await fs.readFile(authOut, 'utf8'), await fs.readFile(authPath, 'utf8'));
  await assert.rejects(
    unpackCredentialBundle({ accountId: 'acct_abcdef012345', stateKey: key, inputPath: bundlePath, authOutput: path.join(root, 'bad-auth'), cookiesOutput: path.join(root, 'bad-cookies') }),
    /account mismatch/,
  );
  envelope.tag = Buffer.alloc(16).toString('base64');
  await fs.writeFile(bundlePath, JSON.stringify(envelope));
  await assert.rejects(
    unpackCredentialBundle({ accountId: 'acct_0123456789ab', stateKey: key, inputPath: bundlePath, authOutput: path.join(root, 'tamper-auth'), cookiesOutput: path.join(root, 'tamper-cookies') }),
    /authentication failed/,
  );
});
