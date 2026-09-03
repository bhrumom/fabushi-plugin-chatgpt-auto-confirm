import Foundation

func parseTaskWait(_ content: String) -> [String: Any]? {
  guard let marker = content.range(of: "MAHAYANA_TASK_WAIT_V1", options: .backwards) else {
    return nil
  }
  let suffix = content[marker.upperBound...]
    .trimmingCharacters(in: .whitespacesAndNewlines)
  guard let opening = suffix.firstIndex(of: "{"),
        let closing = suffix[opening...].firstIndex(of: "}") else { return nil }
  let raw = String(suffix[opening...closing])
  guard let data = raw.data(using: .utf8),
        let wait = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let taskId = wait["task_id"] as? String,
        !taskId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        let waitSeconds = wait["wait_seconds"] as? Int,
        (60...604_800).contains(waitSeconds),
        let reason = wait["reason"] as? String,
        !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
    return nil
  }
  return wait
}

func parseTaskReport(_ content: String) -> [String: Any]? {
  guard let start = content.range(of: "MAHAYANA_TASK_REPORT_V1_BEGIN", options: .backwards),
        let end = content.range(of: "MAHAYANA_TASK_REPORT_V1_END", range: start.upperBound..<content.endIndex),
        start.upperBound <= end.lowerBound else { return nil }
  var raw = String(content[start.upperBound..<end.lowerBound])
    .trimmingCharacters(in: .whitespacesAndNewlines)
  if raw.hasPrefix("```json") { raw.removeFirst(7) }
  else if raw.hasPrefix("```") { raw.removeFirst(3) }
  if raw.hasSuffix("```") { raw.removeLast(3) }
  raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
  guard let data = raw.data(using: .utf8),
        let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        report["protocol"] as? String == "mahayana.task-report.v1",
        let taskId = report["task_id"] as? String,
        !taskId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        let appliedRevision = report["applied_task_revision"] as? Int,
        appliedRevision >= 1,
        report["applied_spec_digest"] is String,
        let status = report["status"] as? String,
        ["complete", "incomplete", "blocked"].contains(status),
        let allTasksComplete = report["all_tasks_complete"] as? Bool,
        report["summary"] is String,
        let completed = report["completed"] as? [String],
        let remaining = report["remaining"] as? [String],
        let blockers = report["blockers"] as? [String],
        report["verification"] is [String],
        let nextTask = report["next_task"] as? String,
        completed.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
        remaining.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
        blockers.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
    return nil
  }
  let waitSeconds = report["wait_seconds"] as? Int ?? 0
  guard (0...604_800).contains(waitSeconds) else { return nil }
  if status == "complete" {
    guard allTasksComplete, remaining.isEmpty, blockers.isEmpty, waitSeconds == 0,
          nextTask.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
  } else {
    guard !allTasksComplete,
          !nextTask.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
  }
  return report
}
