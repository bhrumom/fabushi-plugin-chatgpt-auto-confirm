import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const controller = readFileSync(
  new URL('../scripts/run-dynamic-actions-controller.mjs', import.meta.url),
  'utf8',
);
const inbox = JSON.parse(readFileSync(
  new URL('../tasks/actions-inbox.json', import.meta.url),
  'utf8',
));

test('standalone controller polls the main-branch task control file', () => {
  assert.match(controller, /spawnSync\('gh'/);
  assert.match(controller, /repos\/\$\{sourceRepository\}\/contents\/\$\{repositoryPath\}/);
  assert.match(controller, /fetchRepositoryContent\(controlPath, repository\)/);
  assert.match(controller, /CHATGPT_AUTO_CONFIRM_REPOSITORY/);
  assert.match(controller, /tasks\/actions-inbox\.json/);
  assert.match(controller, /task\._specDigest/);
  assert.match(controller, /entry\.sha/);
  assert.match(controller, /createHash\('sha256'\)/);
  assert.match(controller, /pollSeconds \* 1_000/);
  assert.match(controller, /ACTION_DISABLE_TASK_REFRESH: 'true'/);
});

test('goal versions are idempotent and dependencies use desired runtime ids', () => {
  assert.match(controller, /\$\{task\.id\}--v\$\{/);
  assert.match(controller, /native\('queue_cancel'/);
  assert.match(controller, /native\('queue_enqueue'/);
  assert.match(controller, /runtimeIdsByLogicalId/);
  assert.match(controller, /specDigest: task\._specDigest/);
  assert.match(controller, /specSources: task\._specFiles/);
  assert.match(controller, /dependsOn:[\s\S]*runtimeIdsByLogicalId\.get/);
  assert.equal(inbox.schemaVersion, 3);
  assert.equal(inbox.keepAlive, true);
  assert.ok(inbox.maxConcurrent >= 2);
  assert.ok(inbox.tasks.every(task => Number.isInteger(task.goalVersion)));
  assert.ok(inbox.tasks.every(task => Number.isInteger(task.revision)));
  assert.ok(inbox.tasks.every(task => task.specSources === undefined || Array.isArray(task.specSources)));
  assert.ok(inbox.tasks.every(task => task.repository === 'bhrumom/fabushi'));
  assert.ok(inbox.tasks.every(task => task.specRepository === undefined || typeof task.specRepository === 'string'));
  assert.ok(inbox.tasks.every(task => typeof task.codeDirectory === 'string'));
});

test('task updates never cancel the currently running Chat', () => {
  assert.match(controller, /const running = managed\.filter\(isRunning\)/);
  assert.match(controller, /if \(running\.length > 0\) \{[\s\S]*deferred\.push/);
  assert.match(controller, /A task update is never allowed to stop the Chat/);
  assert.doesNotMatch(
    controller,
    /if \(staleVersion && !\['cancelled', 'completed'\]\.includes\(current\.status\)\)/,
  );
});

test('every new Chat is dispatched only after a fresh control read', () => {
  assert.match(controller, /const dispatchFreshRound = async reason =>/);
  assert.match(controller, /native\('queue_pause'\);[\s\S]*const control = fetchControl\(\)/);
  assert.match(controller, /start: false/);
  assert.match(controller, /native\('queue_resume'/);
  assert.match(controller, /resume_until_task_claimed/);
  assert.match(controller, /claimDeadline[\s\S]*native\('queue_pause'\)/);
  assert.match(controller, /wait_for_child_controller/);
  assert.match(controller, /runningEnded[\s\S]*previous_chat_finished/);
  assert.match(controller, /queued_chat_boundary/);
});

test('unchanged tasks continue while changed tasks replace only at the boundary', () => {
  assert.match(controller, /if \(exact\) \{/);
  assert.match(controller, /staleVersion && !isTerminal\(current\)/);
  assert.match(controller, /action: 'resume_until_task_claimed'/);
  assert.match(controller, /queue_pause does not interrupt running Chats/);
});

test('unchanged terminal tasks preserve the child controller recovery budget', () => {
  assert.match(controller, /action: 'preserve_child_recovery_budget'/);
  assert.match(controller, /bypassed maxRuntimeRetries and ACTION_MAX_SAME_FAILURE_RECOVERIES/);
  assert.doesNotMatch(
    controller,
    /if \(exact && \['failed', 'blocked', 'cancelled'\]\.includes\(exact\.status\)\)[\s\S]*?native\('queue_retry'/,
  );
});

test('Work Chat stays natural while a fresh planner Chat owns the report protocol', () => {
  assert.match(controller, /const workDispatchBoundary =/);
  assert.match(controller, /工作 Chat/);
  assert.match(controller, /自然语言工作结果/);
  assert.match(controller, /新的规划\/验收 Chat/);
  assert.match(controller, /只有规划\/验收 Chat 才负责固定回执/);
  assert.match(controller, /next_task 原文交给下一轮新的工作 Chat/);
  assert.doesNotMatch(controller, /MAHAYANA_TASK_REPORT_CONTRACT_V5/);
  assert.doesNotMatch(controller, /MAHAYANA_TASK_REPORT_V1_BEGIN/);
  assert.doesNotMatch(controller, /MAHAYANA_TASK_WAIT_V1/);
  assert.doesNotMatch(controller, /Gmail|项目邮件|立项邮件/);
  assert.match(controller, /小程序会把同一目标发送到新的 Chat/);
});

test('every round names the model, repository, task path, code path, and code-change gate', () => {
  assert.match(controller, /GPT-5\.6 Sol/);
  assert.match(controller, /Extra High/);
  assert.match(controller, /task\.repository \|\| repository/);
  assert.match(controller, /task\.documentDirectory/);
  assert.match(controller, /task\.codeDirectory/);
  assert.match(controller, /必须产生可核验的代码变更/);
});

test('missing task projects are created in the repository and document bodies stay out of prompts', () => {
  assert.match(controller, /task\.documentDirectory/);
  assert.match(controller, /\/tree\/\$\{controlRef\}\/\$\{directory\}/);
  assert.match(controller, /只在消息中提供目录路径和文件夹链接/);
  assert.match(controller, /仓库中尚未登记任务/);
  assert.match(controller, /写入目标\/范围、架构、执行任务、验收标准和证据文档/);
  assert.match(controller, /documentDirectory[\s\S]*\? directoryEntries\(documentDirectory, taskSpecRepository\)[\s\S]*: \[\]/);
  assert.doesNotMatch(controller, /specificationFiles|specificationURLs/);
  assert.doesNotMatch(controller, /documentDirectory_and_codeDirectory_are_required/);
});

test('repository-backed release task is registered with project documents', () => {
  const task = inbox.tasks.find(item => item.id === 'full-platform-release-live-runner-20260831');
  assert.equal(task.connector, 'GitHub');
  assert.equal(task.repository, 'bhrumom/fabushi');
  assert.ok(task.documentDirectory);
  assert.ok(task.specSources.length >= 4);
});
