import { readFileSync, writeFileSync } from 'node:fs';

const statePath = process.env.CHATGPT_AUTO_CONFIRM_QUEUE_STATE;
const resultPath = process.env.ACTION_RESULT_PATH;
const requestedTaskId = String(process.env.CHATGPT_AUTO_CONFIRM_CANCEL_TASK_ID || '').trim();

if (!statePath) throw new Error('CHATGPT_AUTO_CONFIRM_QUEUE_STATE is required');
if (!resultPath) throw new Error('ACTION_RESULT_PATH is required');
if (!requestedTaskId || requestedTaskId.length > 240 || /[\r\n]/.test(requestedTaskId)) {
  throw new Error('CHATGPT_AUTO_CONFIRM_CANCEL_TASK_ID must be a nonempty task id');
}

const state = JSON.parse(readFileSync(statePath, 'utf8'));
const tasks = Array.isArray(state.automationTasks) ? state.automationTasks : [];
const matches = task => task?.id === requestedTaskId
  || String(task?.id || '').startsWith(`${requestedTaskId}--v`);
const cancelledTaskIds = tasks.filter(matches).map(task => task.id);

state.automationTasks = tasks.filter(task => !matches(task));
state.queueEnabled = false;
state.queuePaused = true;
state.queueWatcherPid = null;
state.queueWorkerPort = null;
state.queueWorkerTargetId = null;
state.queueWorkerProfilePath = null;
state.queueWorkerMode = null;
writeFileSync(statePath, `${JSON.stringify(state)}\n`, { mode: 0o600 });

const result = {
  status: 'complete',
  reason: cancelledTaskIds.length > 0 ? 'persisted_task_cancelled' : 'persisted_task_already_absent',
  requestedTaskId,
  cancelledTaskIds,
  remainingTaskIds: state.automationTasks.map(task => task.id),
};
writeFileSync(resultPath, `${JSON.stringify(result)}\n`, { mode: 0o600 });
process.stdout.write(`PERSISTED_TASK_CANCELLATION ${JSON.stringify(result)}\n`);
