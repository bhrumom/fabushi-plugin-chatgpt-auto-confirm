import { spawn, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const runtime = process.env.CHATGPT_AUTO_CONFIRM_NATIVE ||
  fileURLToPath(new URL('../runtime/macos/chatgpt-auto-confirm', import.meta.url));
const controller = fileURLToPath(new URL('./run-actions-controller.mjs', import.meta.url));
const resultPath = process.env.ACTION_RESULT_PATH || 'action-result.json';
const repository = process.env.GITHUB_REPOSITORY || 'bhrumom/fabushi';
const controlPath = process.env.CHATGPT_AUTO_CONFIRM_TASK_CONTROL_PATH ||
  '.agents/plugins/plugins/chatgpt-auto-confirm/tasks/actions-inbox.json';
const controlRef = process.env.CHATGPT_AUTO_CONFIRM_TASK_CONTROL_REF || 'main';
const pollSeconds = Math.max(15, Number(
  process.env.CHATGPT_AUTO_CONFIRM_TASK_CONTROL_POLL_SECONDS || 30,
));
const boundaryRetrySeconds = Math.max(2, Number(
  process.env.CHATGPT_AUTO_CONFIRM_TASK_BOUNDARY_RETRY_SECONDS || 5,
));
const taskClaimSeconds = Math.min(180, Math.max(5, Number(
  process.env.CHATGPT_AUTO_CONFIRM_TASK_CLAIM_SECONDS || 60,
)));
const sessionSeconds = Math.min(
  20_700,
  Math.max(300, Number(process.env.ACTION_SESSION_SECONDS || 20_100)),
);
const deadline = Date.now() + sessionSeconds * 1_000;

const native = (command, params = undefined) => {
  const args = [command];
  if (params !== undefined) args.push(JSON.stringify(params));
  const result = spawnSync(runtime, args, {
    encoding: 'utf8',
    env: process.env,
    timeout: 120_000,
    maxBuffer: 10 * 1024 * 1024,
  });
  const line = result.stdout.trim().split(/\r?\n/).at(-1);
  if (!line) throw new Error(`${command} returned no JSON: ${result.stderr}`);
  const payload = JSON.parse(line);
  if (result.status !== 0 || payload.ok === false) {
    throw new Error(`${command} failed: ${payload.errorCode || payload.message || result.stderr}`);
  }
  return payload;
};

const fetchRepositoryContent = repositoryPath => {
  const result = spawnSync('gh', [
    'api', '--method', 'GET',
    `repos/${repository}/contents/${repositoryPath}`,
    '-f', `ref=${controlRef}`,
  ], {
    encoding: 'utf8',
    env: process.env,
    timeout: 60_000,
    maxBuffer: 10 * 1024 * 1024,
  });
  if (result.status !== 0) {
    throw new Error(`repository content fetch failed for ${repositoryPath}: ${result.stderr || result.stdout}`);
  }
  return JSON.parse(result.stdout);
};

const fetchControl = () => {
  const envelope = fetchRepositoryContent(controlPath);
  const raw = Buffer.from(String(envelope.content || '').replace(/\s+/g, ''), 'base64')
    .toString('utf8');
  const control = JSON.parse(raw);
  const directoryCache = new Map();
  const directoryEntries = directory => {
    if (!directoryCache.has(directory)) {
      const entries = fetchRepositoryContent(directory);
      if (!Array.isArray(entries)) throw new Error(`task document path is not a directory: ${directory}`);
      directoryCache.set(directory, entries.filter(entry => entry?.type === 'file'));
    }
    return directoryCache.get(directory);
  };
  control.tasks = (Array.isArray(control.tasks) ? control.tasks : []).map(task => {
    const documentDirectory = normalizedDirectory(task.documentDirectory);
    const sources = Array.isArray(task.specSources) && task.specSources.length > 0
      ? task.specSources.map(source => String(source || '').replace(/^\/+/, ''))
      : documentDirectory
        ? directoryEntries(documentDirectory).map(entry => entry.path)
        : [];
    const files = sources.map(source => {
      const directory = path.posix.dirname(source);
      const entry = directoryEntries(directory).find(candidate => candidate.path === source);
      if (!entry?.sha) throw new Error(`task specification source is missing: ${source}`);
      return { path: source, sha: entry.sha };
    });
    const digestInput = JSON.stringify({
      id: task.id,
      revision: Math.max(1, Number(task.revision || task.goalVersion || 1)),
      title: task.title,
      prompt: task.prompt,
      directive: task.directive || '',
      files,
    });
    return {
      ...task,
      _specFiles: files.map(file => file.path),
      _specDigest: `sha256:${createHash('sha256').update(digestInput).digest('hex')}`,
    };
  });
  control._blobSha = envelope.sha;
  control._source = envelope.html_url ||
    `https://github.com/${repository}/blob/${controlRef}/${controlPath}`;
  return control;
};

const reportContract = task => {
  const taskId = JSON.stringify(runtimeId(task));
  const revision = taskRevision(task);
  const digest = JSON.stringify(task._specDigest || '');
  return `
MAHAYANA_TASK_REPORT_CONTRACT_V5
下面是唯一允许的完成证书。只有整个仓库项目、全部验收、测试、发布和证据都完成时才输出；未完成、等待、阻塞或本轮提前结束时不要输出任何报告或“下一步”模板，小程序会把同一目标发送到新的 Chat：
MAHAYANA_TASK_REPORT_V1_BEGIN
{"protocol":"mahayana.task-report.v1","task_id":${taskId},"applied_task_revision":${revision},"applied_spec_digest":${digest},"status":"complete","all_tasks_complete":true,"summary":"整个项目已完成","completed":["已完成的项目、发布和验收证据"],"remaining":[],"blockers":[],"verification":["可复核的完整验收证据"],"wait_seconds":0,"wait_reason":"","next_connector":"","next_task":""}
MAHAYANA_TASK_REPORT_V1_END
`;
};

const normalizedDirectory = value => String(value || '')
  .trim()
  .replace(/^\/+|\/+$/g, '');

const taskDocumentBlock = task => {
  const directory = normalizedDirectory(task.documentDirectory);
  if (!directory) {
    return [
      `仓库中尚未登记任务 ${task.id} 的项目目录。先按稳定任务 id 和标题查找匹配项目。`,
      `如果找不到，创建 .agents/plugins/plugins/chatgpt-auto-confirm/tasks/${task.id}，写入目标/范围、架构、执行任务、验收标准和证据文档，并把文件登记到仓库任务控制项。`,
      '共享执行技能：.agents/plugins/plugins/chatgpt-auto-confirm/skills/actions-first-task-queue/SKILL.md。每轮重新读取技能和仓库项目文档。',
    ].join('\n');
  }
  const directoryURL = `https://github.com/${repository}/tree/${controlRef}/${directory}`;
  const additionalURLs = Array.isArray(task.documentURLs)
    ? task.documentURLs.map(value => String(value || '').trim()).filter(Boolean)
    : [];
  const links = [directoryURL, ...additionalURLs];
  return [
    '任务文档目录（开始工作前必须打开并阅读目录中的全部相关文档）：',
    `- 仓库目录：${directory}`,
    ...links.map(value => `- 文件夹链接：${value}`),
    '只在消息中提供目录路径和文件夹链接，不在提示词中复制文档正文。',
    '目录中可以包含 PRD、技术设计、架构说明、UI/UX、接口契约、验收标准和其他任务资料。',
    '当前 goalVersion 对应的目录资料优先于旧 Chat 中的任务描述。',
    `当前规范摘要：${task._specDigest || 'unavailable'}。`,
    `规范文件：${(task._specFiles || []).join('、') || directory}`,
    `共享执行技能：.agents/plugins/plugins/chatgpt-auto-confirm/skills/actions-first-task-queue/SKILL.md。每轮重新读取技能和任务目录全部文件。`,
  ].join('\n');
};

const taskRevision = task => Math.max(1, Number(task.revision || task.goalVersion || 1));
const runtimeId = task =>
  `${task.id}--v${taskRevision(task)}--s${String(task._specDigest || '').replace('sha256:', '').slice(0, 12)}`;
const logicalPrefix = task => `${task.id}--v`;
const managedBy = (current, task) =>
  current.id === task.id || current.id.startsWith(logicalPrefix(task));
const isRunning = task => task.status === 'running';
const isTerminal = task => ['completed', 'cancelled'].includes(task.status);

const taskPrompt = (control, task) => [
  `动态任务控制版本：${control.revision || control._blobSha}。`,
  `逻辑任务：${task.id}；目标版本：${taskRevision(task)}；规范摘要：${task._specDigest}。`,
  `本轮发送前必须重新确认模型 GPT-5.6 Sol、推理强度 Extra High；第一轮、续作和验收轮都相同。`,
  `本轮必须使用 GitHub 连接器读取和修改仓库 ${task.repository || repository}（https://github.com/${task.repository || repository}）。`,
  normalizedDirectory(task.documentDirectory)
    ? `任务文件在仓库路径 ${normalizedDirectory(task.documentDirectory)}；代码修改位置在仓库路径 ${normalizedDirectory(task.codeDirectory || '.')}。先读已配置的任务文件和现有代码，再直接实现。`
    : `仓库中尚未登记本任务的项目文件；先按任务 id 查找，找不到就创建专用项目目录、完整立项文档并登记到任务控制项。代码修改位置在仓库路径 ${normalizedDirectory(task.codeDirectory || '.')}。`,
  `除非正在等待已启动的外部作业或确有人工卡点，本轮必须产生可核验的代码变更并运行相应测试；只阅读、检查、规划、发邮件或汇报结果都不算工作，不得因此结束。`,
  task.prompt,
  taskDocumentBlock(task),
  reportContract(task),
].filter(Boolean).join('\n\n');

let activeControl = null;
let lastBlobSha = '';

const reconcileControl = control => {
  activeControl = control;
  const queue = native('queue_status');
  const existing = Array.isArray(queue.tasks) ? queue.tasks : [];
  const desiredTasks = Array.isArray(control.tasks) ? control.tasks : [];
  const runtimeIdsByLogicalId = new Map(
    desiredTasks.filter(task => task?.id).map(task => [task.id, runtimeId(task)]),
  );
  const cancelled = [];
  const enqueued = [];
  const requeued = [];
  const deferred = [];

  for (const task of desiredTasks) {
    if (!task?.id || !task?.title || !task?.prompt || !task?.repository ||
        !normalizedDirectory(task.codeDirectory)) {
      process.stderr.write(
        `TASK_CONTROL_INVALID_TASK ${JSON.stringify({
          id: task?.id || null,
          reason: 'id_title_prompt_repository_and_codeDirectory_are_required',
        })}\n`,
      );
      continue;
    }

    const desiredId = runtimeId(task);
    const managed = existing.filter(current => managedBy(current, task));
    const exact = managed.find(current => current.id === desiredId);
    const running = managed.filter(isRunning);

    // A task update is never allowed to stop the Chat that is currently
    // working. The new goal is held until that Chat reaches a round boundary.
    if (running.length > 0) {
      deferred.push({
        logicalTaskId: task.id,
        desiredId,
        runningIds: running.map(current => current.id),
      });
      continue;
    }

    for (const current of managed) {
      const staleVersion = current.id !== desiredId;
      if (staleVersion && !isTerminal(current)) {
        try {
          native('queue_cancel', { taskId: current.id });
          cancelled.push(current.id);
        } catch (error) {
          process.stderr.write(`TASK_CONTROL_CANCEL_WARNING ${current.id} ${error.message}\n`);
        }
      }
    }

    if (exact) {
      // The per-session controller owns recovery budgets for an unchanged
      // runtime id. Requeueing failed/blocked tasks here on every five-second
      // boundary bypassed maxRuntimeRetries and ACTION_MAX_SAME_FAILURE_RECOVERIES,
      // so one broken hidden renderer could be resurrected indefinitely while
      // the outer Actions job remained in_progress. A changed revision/digest
      // gets a new runtime id and is still enqueued below; an unchanged
      // terminal task is left for the child controller to retry finitely or
      // yield encrypted state to the next run.
      if (['failed', 'blocked', 'cancelled'].includes(exact.status)) {
        deferred.push({
          logicalTaskId: task.id,
          desiredId,
          terminalStatus: exact.status,
          action: 'preserve_child_recovery_budget',
        });
      }
      continue;
    }

    native('queue_enqueue', {
      tasks: [{
        ...task,
        id: desiredId,
        revision: taskRevision(task),
        specDigest: task._specDigest,
        specSources: task._specFiles,
        dependsOn: (Array.isArray(task.dependsOn) ? task.dependsOn : [])
          .map(dependency => runtimeIdsByLogicalId.get(dependency) || dependency),
        prompt: taskPrompt(control, task),
      }],
      // Dispatch is opened explicitly only after the latest control file has
      // been read at the next Chat boundary.
      start: false,
      maxConcurrent: Math.min(4, Math.max(1, Number(control.maxConcurrent || 2))),
      reviewGate: control.reviewGate ?? false,
    });
    enqueued.push(desiredId);
  }

  if (control.authoritative === true) {
    for (const current of existing) {
      const managed = desiredTasks.some(task => managedBy(current, task));
      if (managed || isTerminal(current)) continue;
      if (isRunning(current)) {
        deferred.push({
          logicalTaskId: null,
          desiredId: null,
          runningIds: [current.id],
          removal: true,
        });
        continue;
      }
      try {
        native('queue_cancel', { taskId: current.id });
        cancelled.push(current.id);
      } catch (error) {
        process.stderr.write(`TASK_CONTROL_CANCEL_WARNING ${current.id} ${error.message}\n`);
      }
    }
  }

  const changed = control._blobSha !== lastBlobSha;
  lastBlobSha = control._blobSha;
  const result = {
    changed,
    revision: control.revision || control._blobSha,
    source: control._source,
    enqueued,
    requeued,
    cancelled,
    deferred,
    keepAlive: control.keepAlive === true,
  };
  process.stdout.write(`TASK_CONTROL_SYNC ${JSON.stringify(result)}\n`);
  return result;
};

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

const dispatchFreshRound = async reason => {
  // queue_pause does not interrupt running Chats. It only closes the gate that
  // creates another Chat, which gives us a deterministic update boundary.
  native('queue_pause');
  const control = fetchControl();
  const sync = reconcileControl(control);
  const queue = native('queue_status');
  const tasks = Array.isArray(queue.tasks) ? queue.tasks : [];
  const queued = tasks.filter(task => task.status === 'queued');
  const runningCount = tasks.filter(isRunning).length;
  const maxConcurrent = Math.min(4, Math.max(1, Number(
    control.maxConcurrent || queue.maxConcurrent || 2,
  )));

  if (queued.length > 0 && runningCount < maxConcurrent) {
  if (!child || child.exitCode !== null) {
    process.stdout.write(`TASK_CHAT_BOUNDARY_DEFERRED ${JSON.stringify({
      reason,
      revision: sync.revision,
      queuedIds: queued.map(task => task.id),
      action: 'wait_for_child_controller',
    })}
`);
    return sync;
  }
  process.stdout.write(`TASK_CHAT_BOUNDARY ${JSON.stringify({
    reason,
    revision: sync.revision,
    queuedIds: queued.map(task => task.id),
    runningCount,
    maxConcurrent,
    action: 'resume_until_task_claimed',
    claimTimeoutSeconds: taskClaimSeconds,
  })}
`);
  native('queue_resume', {
    maxConcurrent,
    reviewGate: control.reviewGate ?? false,
  });
  const queuedIds = new Set(queued.map(task => task.id));
  const claimDeadline = Date.now() + taskClaimSeconds * 1_000;
  let claimedIds = [];
  while (Date.now() < claimDeadline && child?.exitCode === null) {
    await sleep(1_000);
    const current = native('queue_status');
    const currentTasks = Array.isArray(current.tasks) ? current.tasks : [];
    claimedIds = currentTasks
      .filter(task => queuedIds.has(task.id) && task.status !== 'queued')
      .map(task => task.id);
    if (claimedIds.length > 0) break;
  }
  native('queue_pause');
  process.stdout.write(`TASK_CHAT_CLAIM ${JSON.stringify({
    reason,
    queuedIds: [...queuedIds],
    claimedIds,
    claimed: claimedIds.length > 0,
    childExitCode: child?.exitCode ?? null,
  })}
`);
}
  return sync;
};

const writeIncomplete = reason => {
  let queue = {};
  try { queue = native('queue_status'); } catch {}
  const result = {
    status: 'incomplete',
    reason,
    finishedAt: new Date().toISOString(),
    counts: queue.counts || {},
    tasks: queue.tasks || [],
    taskControl: activeControl ? {
      revision: activeControl.revision || activeControl._blobSha,
      source: activeControl._source,
      keepAlive: activeControl.keepAlive === true,
    } : null,
  };
  writeFileSync(resultPath, `${JSON.stringify(result)}\n`);
  process.stdout.write(`ACTION_RESULT ${JSON.stringify(result)}\n`);
};

let child = null;
let stopping = false;
const stopChild = () => {
  if (child && child.exitCode === null) child.kill('SIGTERM');
};
const handleFinishedChild = async () => {
  if (!child || child.exitCode === null) return false;
  const exitCode = child.exitCode;
  let status = '';
  let reason = '';
  try {
    const result = JSON.parse(readFileSync(resultPath, 'utf8'));
    status = result.status || '';
    reason = result.reason || '';
  } catch {}
  if (status === 'failed') process.exit(exitCode || 1);
  if (reason === 'recoverable_task_retry_budget_exhausted') {
    process.stdout.write(`TASK_CONTROLLER_STOP ${JSON.stringify({ status, reason })}\n`);
    process.exit(0);
  }
  if (activeControl?.keepAlive !== true) {
    process.exit(exitCode || (status === 'complete' ? 0 : 1));
  }
  child = null;
  await sleep(Math.min(5_000, pollSeconds * 1_000));
  return true;
};
process.on('SIGTERM', () => { stopping = true; stopChild(); });
process.on('SIGINT', () => { stopping = true; stopChild(); });

try {
  await dispatchFreshRound('startup');
} catch (error) {
  process.stderr.write(`TASK_CONTROL_INITIAL_WARNING ${error.message}\n`);
}

let nextControlPollAt = Date.now() + pollSeconds * 1_000;
let nextBoundaryRetryAt = Date.now();
let previousRunningIds = new Set();
while (!stopping && Date.now() < deadline) {
  // Consume the terminal result before considering a replacement child. The
  // previous order could overwrite a just-finished failed child at the top of
  // the loop, causing a deterministic failure to restart until the six-hour
  // hosted deadline.
  if (await handleFinishedChild()) continue;
  if (!child) {
    const remainingSeconds = Math.max(300, Math.ceil((deadline - Date.now()) / 1_000));
    child = spawn(process.execPath, [controller], {
      env: {
        ...process.env,
        ACTION_SESSION_SECONDS: String(Math.min(remainingSeconds, 20_100)),
        // The outer dynamic controller owns versioned task reconciliation.
        // Disable the legacy child refresher so it neither targets the
        // logical id nor tries to inline a specification larger than 60 KB.
        ACTION_DISABLE_TASK_REFRESH: 'true',
      },
      stdio: ['ignore', 'inherit', 'inherit'],
    });
  }

  let queue = null;
  try { queue = native('queue_status'); }
  catch (error) { process.stderr.write(`TASK_QUEUE_STATUS_WARNING ${error.message}\n`); }
  const tasks = Array.isArray(queue?.tasks) ? queue.tasks : [];
  const runningIds = new Set(tasks.filter(isRunning).map(task => task.id));
  const runningEnded = [...previousRunningIds].some(id => !runningIds.has(id));
  const hasQueued = tasks.some(task => task.status === 'queued');
  const controlPollDue = Date.now() >= nextControlPollAt;
  const boundaryRetryDue = hasQueued && Date.now() >= nextBoundaryRetryAt;

  if (runningEnded || controlPollDue || boundaryRetryDue) {
    const reason = runningEnded
      ? 'previous_chat_finished'
      : controlPollDue
        ? 'periodic_control_refresh'
        : 'queued_chat_boundary';
    try { await dispatchFreshRound(reason); }
    catch (error) { process.stderr.write(`TASK_CONTROL_SYNC_WARNING ${error.message}\n`); }
    if (controlPollDue) nextControlPollAt = Date.now() + pollSeconds * 1_000;
    nextBoundaryRetryAt = Date.now() + boundaryRetrySeconds * 1_000;
    try {
      queue = native('queue_status');
      previousRunningIds = new Set(
        (Array.isArray(queue.tasks) ? queue.tasks : [])
          .filter(isRunning)
          .map(task => task.id),
      );
    } catch {
      previousRunningIds = runningIds;
    }
  } else {
    previousRunningIds = runningIds;
  }

  if (await handleFinishedChild()) continue;
  await sleep(1_000);
}

stopChild();
writeIncomplete(stopping ? 'dynamic_controller_interrupted' : 'hosted_runner_session_deadline');
