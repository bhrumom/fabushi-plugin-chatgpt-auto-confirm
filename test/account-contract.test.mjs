import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const native = readFileSync(new URL('../native/AccountManager.swift', import.meta.url), 'utf8');
const main = readFileSync(new URL('../native/main.swift', import.meta.url), 'utf8');
const link = readFileSync(new URL('../scripts/account-login-link.mjs', import.meta.url), 'utf8');
const workflow = readFileSync(new URL('../../../../../.github/workflows/chatgpt-auto-confirm-runner.yml', import.meta.url), 'utf8');

test('account registry is opaque, bounded, and keychain-backed', () => {
  assert.match(native, /maximumAccountCount = 10/);
  assert.match(native, /acct_\[0-9a-f\]\{12\}/);
  assert.match(native, /SecItemAdd/);
  assert.match(native, /SecItemUpdate/);
  assert.match(native, /CHATGPT_AUTO_CONFIRM_KEYCHAIN_DIR/);
  assert.match(native, /fingerprint/);
  assert.doesNotMatch(native, /email/);
  assert.match(main, /case "account_list"/);
  assert.match(main, /case "account_remove"/);
  assert.match(main, /account_in_use/);
  assert.match(main, /accountHiddenSmoke/);
});

test('one-time login link is loopback-only and cannot replay', () => {
  assert.match(link, /randomBytes\(32\)/);
  assert.match(link, /127\.0\.0\.1/);
  assert.match(link, /10 \* 60 \* 1000/);
  assert.match(link, /consumed/);
  assert.match(link, /Date\.now\(\) > expiresAt/);
  assert.match(link, /url\.searchParams\.get\('token'\) !== token/);
  assert.match(link, /detached: true/);
  assert.doesNotMatch(link, /auth\.json|cookies|refresh_token/i);
});

test('runner keeps account id on continuation and uses account-scoped state', () => {
  assert.match(workflow, /previous_run_id="\$GITHUB_RUN_ID"/);
  assert.match(workflow, /-f account_id="\$ACCOUNT_ID"/);
  assert.match(workflow, /chatgpt-auto-confirm-state-\{0\}/);
  assert.match(workflow, /chatgpt-auto-confirm-\$\{\{ inputs\.account_id \}\}/);
});
