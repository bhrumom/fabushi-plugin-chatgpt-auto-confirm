import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const pluginRoot = fileURLToPath(new URL('..', import.meta.url));
const chatScriptsPath = join(pluginRoot, 'native', 'ChatScripts.swift');
const taskReportParserPath = join(pluginRoot, 'native', 'TaskReportParsing.swift');
const queueTerminalDecisionPath = join(pluginRoot, 'native', 'QueueTerminalDecision.swift');
const chatScriptsSource = readFileSync(chatScriptsPath, 'utf8');

function rawSwiftScript(functionName) {
  const escapedName = functionName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const match = chatScriptsSource.match(
    new RegExp(`func ${escapedName}\\(\\) -> String \\{\\n  #\"\"\"([\\s\\S]*?)\"\"\"#\\n\\}`),
  );
  assert.ok(match, `missing raw Swift script ${functionName}`);
  return match[1];
}

test('queue monitor JavaScript remains syntactically valid on the current Chat surface', () => {
  const chatStatus = rawSwiftScript('chatStatusJS');
  const getReply = rawSwiftScript('getReplyJS');

  assert.doesNotThrow(() => new Function(`return ${chatStatus};`));
  assert.doesNotThrow(() => new Function(`return ${getReply};`));

  assert.match(getReply, /显示更多/);
  assert.match(getReply, /回复优秀/);
  assert.match(getReply, /回复不佳/);
});

test('active Chat replies can never become terminal from incomplete text alone', () => {
  const directory = mkdtempSync(join(tmpdir(), 'chatgpt-auto-confirm-terminal-decision-'));
  const driverPath = join(directory, 'main.swift');
  const binaryPath = join(directory, 'queue-terminal-decision-test');
  try {
    writeFileSync(driverPath, `import Foundation

let activeReply: [String: Any] = [
  "streaming": true,
  "pending": true,
  "stopAvailable": true,
  "explicitlyIncomplete": true,
  "terminalIncomplete": false,
  "done": false,
  "completionCandidate": false,
]
let active = queueReplyTerminalDecision(activeReply)
guard active.responseIsInFlight else { exit(1) }
guard !active.terminalIncomplete else { exit(2) }
guard !active.terminal else { exit(3) }

let textOnlyReply: [String: Any] = [
  "streaming": false,
  "pending": false,
  "stopAvailable": false,
  "explicitlyIncomplete": true,
  "terminalIncomplete": false,
  "done": false,
  "completionCandidate": false,
]
let textOnly = queueReplyTerminalDecision(textOnlyReply)
guard !textOnly.responseIsInFlight else { exit(4) }
guard !textOnly.terminal else { exit(5) }

let finishedIncompleteReply: [String: Any] = [
  "streaming": false,
  "pending": false,
  "stopAvailable": false,
  "explicitlyIncomplete": true,
  "terminalIncomplete": true,
  "done": false,
  "completionCandidate": false,
  "responseActionsComplete": true,
  "responseActionTurnBoundToLast": true,
  "awaitingAssistant": false,
]
let finishedIncomplete = queueReplyTerminalDecision(finishedIncompleteReply)
guard !finishedIncomplete.responseIsInFlight else { exit(6) }
guard finishedIncomplete.terminalIncomplete else { exit(7) }
guard finishedIncomplete.terminal else { exit(8) }

let stalePreviousTurnActions: [String: Any] = [
  "streaming": false,
  "pending": false,
  "stopAvailable": false,
  "terminalIncomplete": true,
  "done": true,
  "completionCandidate": true,
  "responseActionsComplete": true,
  "responseActionTurnBoundToLast": false,
  "awaitingAssistant": true,
]
let staleActions = queueReplyTerminalDecision(stalePreviousTurnActions)
guard !staleActions.responseIsInFlight else { exit(9) }
guard !staleActions.terminalEvidence else { exit(10) }
guard !staleActions.terminal else { exit(11) }
print("terminal-decision-guarded")
`);
    execFileSync('xcrun', ['swiftc', queueTerminalDecisionPath, driverPath, '-o', binaryPath], {
      stdio: 'pipe',
    });
    const output = execFileSync(binaryPath, { encoding: 'utf8' }).trim();
    assert.equal(output, 'terminal-decision-guarded');
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test('production task report parser accepts an empty digest for a no-spec task', () => {
  const directory = mkdtempSync(join(tmpdir(), 'chatgpt-auto-confirm-report-parser-'));
  const driverPath = join(directory, 'main.swift');
  const binaryPath = join(directory, 'task-report-parser-test');
  try {
    writeFileSync(driverPath, `import Foundation

let content = #\"\"\"
visible final answer
MAHAYANA_TASK_REPORT_V1_BEGIN
{"protocol":"mahayana.task-report.v1","task_id":"no-spec-task","applied_task_revision":1,"applied_spec_digest":"","status":"complete","all_tasks_complete":true,"summary":"done","completed":["done"],"remaining":[],"blockers":[],"verification":["checked"],"wait_seconds":0,"wait_reason":"","next_connector":"","next_task":""}
MAHAYANA_TASK_REPORT_V1_END
\"\"\"#

guard let report = parseTaskReport(content) else {
  fputs("parser rejected no-spec complete report\\n", stderr)
  exit(1)
}
guard report["status"] as? String == "complete" else { exit(2) }
guard report["applied_spec_digest"] as? String == "" else { exit(3) }

let partial = #"""
MAHAYANA_TASK_REPORT_V1_BEGIN
{"protocol":"mahayana.task-report.v1","task_id":"no-spec-task","applied_task_revision":1,"applied_spec_digest":"","status":"incomplete","all_tasks_complete":false,"summary":"one item done","completed":["one item"],"remaining":["rest"],"blockers":[],"verification":["checked"],"wait_seconds":0,"wait_reason":"","next_connector":"","next_task":"continue rest"}
MAHAYANA_TASK_REPORT_V1_END
"""#
guard parseTaskReport(partial)?["status"] as? String == "incomplete" else { exit(4) }

let falseComplete = content.replacingOccurrences(
  of: #""all_tasks_complete":true"#,
  with: #""all_tasks_complete":false"#
)
guard parseTaskReport(falseComplete) == nil else { exit(5) }

let missingFlag = content.replacingOccurrences(
  of: #","all_tasks_complete":true"#,
  with: ""
)
guard parseTaskReport(missingFlag) == nil else { exit(6) }
print("unified-report-contract-accepted")
`);
    execFileSync('xcrun', ['swiftc', taskReportParserPath, driverPath, '-o', binaryPath], {
      stdio: 'pipe',
    });
    const output = execFileSync(binaryPath, { encoding: 'utf8' }).trim();
    assert.equal(output, 'unified-report-contract-accepted');
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});
