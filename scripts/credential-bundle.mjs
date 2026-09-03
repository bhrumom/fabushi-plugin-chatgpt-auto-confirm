#!/usr/bin/env node
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';

const VERSION = 1;

function fail(message) {
  throw new Error(message);
}

function valueAfter(args, name, required = true) {
  const index = args.indexOf(name);
  if (index < 0) {
    if (required) fail(`missing ${name}`);
    return undefined;
  }
  const value = args[index + 1];
  if (!value || value.startsWith('--')) fail(`missing value for ${name}`);
  return value;
}

function stateKeyBytes(raw) {
  if (!raw) fail('state key is empty');
  const trimmed = raw.trim();
  let decoded;
  if (/^[0-9a-f]{64}$/i.test(trimmed)) decoded = Buffer.from(trimmed, 'hex');
  else {
    try { decoded = Buffer.from(trimmed, 'base64'); } catch { decoded = null; }
  }
  if (!decoded || decoded.length < 32) fail('state key must contain at least 256 bits');
  return decoded;
}

function keyFor(stateKey) {
  return crypto.createHash('sha256')
    .update('chatgpt-auto-confirm credential bundle v1\0')
    .update(stateKeyBytes(stateKey))
    .digest();
}

function aadFor(accountId) {
  if (!/^acct_[0-9a-f]{12}$/.test(accountId)) fail('invalid account id');
  return Buffer.from(JSON.stringify({ version: VERSION, accountId }), 'utf8');
}

async function writePrivate(file, data) {
  await fs.mkdir(path.dirname(file), { recursive: true });
  await fs.writeFile(file, data, { mode: 0o600 });
  await fs.chmod(file, 0o600);
}

export async function packCredentialBundle({ accountId, stateKey, authPath, cookiesPath, outputPath }) {
  const auth = await fs.readFile(authPath);
  const cookies = await fs.readFile(cookiesPath);
  if (!auth.length || !cookies.length) fail('credential files are empty');
  const payload = Buffer.from(JSON.stringify({
    auth: auth.toString('base64'),
    cookies: cookies.toString('base64'),
  }), 'utf8');
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', keyFor(stateKey), iv);
  const aad = aadFor(accountId);
  cipher.setAAD(aad);
  const ciphertext = Buffer.concat([cipher.update(payload), cipher.final()]);
  const envelope = {
    version: VERSION,
    accountId,
    algorithm: 'aes-256-gcm',
    createdAt: new Date().toISOString(),
    iv: iv.toString('base64'),
    tag: cipher.getAuthTag().toString('base64'),
    ciphertext: ciphertext.toString('base64'),
  };
  await writePrivate(outputPath, `${JSON.stringify(envelope)}\n`);
  return { ok: true, accountId, outputPath, algorithm: envelope.algorithm };
}

export async function unpackCredentialBundle({ accountId, stateKey, inputPath, authOutput, cookiesOutput }) {
  const envelope = JSON.parse(await fs.readFile(inputPath, 'utf8'));
  if (envelope?.version !== VERSION || envelope?.algorithm !== 'aes-256-gcm') fail('unsupported credential bundle');
  if (envelope.accountId !== accountId) fail('credential bundle account mismatch');
  const iv = Buffer.from(String(envelope.iv || ''), 'base64');
  const tag = Buffer.from(String(envelope.tag || ''), 'base64');
  const ciphertext = Buffer.from(String(envelope.ciphertext || ''), 'base64');
  if (iv.length !== 12 || tag.length !== 16 || !ciphertext.length) fail('credential bundle is incomplete');
  const decipher = crypto.createDecipheriv('aes-256-gcm', keyFor(stateKey), iv);
  decipher.setAAD(aadFor(accountId));
  decipher.setAuthTag(tag);
  let raw;
  try { raw = Buffer.concat([decipher.update(ciphertext), decipher.final()]); }
  catch { fail('credential bundle authentication failed'); }
  const payload = JSON.parse(raw.toString('utf8'));
  const auth = Buffer.from(String(payload.auth || ''), 'base64');
  const cookies = Buffer.from(String(payload.cookies || ''), 'base64');
  if (!auth.length || !cookies.length) fail('credential bundle payload is empty');
  await writePrivate(authOutput, auth);
  await writePrivate(cookiesOutput, cookies);
  return { ok: true, accountId, authOutput, cookiesOutput };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const args = process.argv.slice(2);
  try {
    const command = args.shift();
    const stateKey = valueAfter(args, '--state-key');
    const accountId = valueAfter(args, '--account-id');
    let result;
    if (command === 'pack') {
      result = await packCredentialBundle({
        accountId, stateKey,
        authPath: valueAfter(args, '--auth'),
        cookiesPath: valueAfter(args, '--cookies'),
        outputPath: valueAfter(args, '--output'),
      });
    } else if (command === 'unpack') {
      result = await unpackCredentialBundle({
        accountId, stateKey,
        inputPath: valueAfter(args, '--input'),
        authOutput: valueAfter(args, '--auth-output'),
        cookiesOutput: valueAfter(args, '--cookies-output'),
      });
    } else fail('usage: pack|unpack');
    process.stdout.write(`${JSON.stringify(result)}\n`);
  } catch (error) {
    process.stderr.write(`${String(error?.message || error)}\n`);
    process.exitCode = 1;
  }
}
