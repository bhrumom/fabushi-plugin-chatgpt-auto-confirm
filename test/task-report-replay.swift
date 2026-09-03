import Foundation

struct TaskReportReplayFailure: Error, CustomStringConvertible {
  let description: String
}

@main
struct TaskReportReplay {
  static func main() throws {
    let paths = Array(CommandLine.arguments.dropFirst())
    guard !paths.isEmpty else {
      throw TaskReportReplayFailure(description: "usage: task-report-replay <diagnostic.final.json> [...]")
    }

    var failures: [String] = []
    for path in paths {
      let url = URL(fileURLWithPath: path)
      let data = try Data(contentsOf: url)
      guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let result = root["result"] as? [String: Any],
            let reply = result["reply"] as? [String: Any],
            let content = reply["content"] as? String else {
        failures.append("\(url.lastPathComponent): missing result.reply.content")
        continue
      }

      guard let report = parseTaskReport(content) else {
        failures.append("\(url.lastPathComponent): production parser rejected visible task report")
        continue
      }
      let status = report["status"] as? String ?? ""
      let taskId = report["task_id"] as? String ?? ""
      let digest = report["applied_spec_digest"] as? String
      let hasBegin = content.contains("MAHAYANA_TASK_REPORT_V1_BEGIN")
      let hasEnd = content.contains("MAHAYANA_TASK_REPORT_V1_END")
      let digestDisplay = digest.map { "'\($0)'" } ?? "nil"
      print(
        "\(url.lastPathComponent): begin=\(hasBegin) end=\(hasEnd) "
          + "taskId=\(taskId) status=\(status) digest=\(digestDisplay)"
      )

      if !hasBegin || !hasEnd {
        failures.append("\(url.lastPathComponent): report markers are incomplete")
      }
      if status != "complete" {
        failures.append("\(url.lastPathComponent): expected complete, got \(status)")
      }
      if taskId != "streaming-terminal-regression-004" {
        failures.append("\(url.lastPathComponent): unexpected task_id \(taskId)")
      }
      if digest != "" {
        failures.append("\(url.lastPathComponent): expected empty digest from no-spec task")
      }
    }

    if !failures.isEmpty {
      for failure in failures {
        fputs("FAIL: \(failure)\n", stderr)
      }
      Foundation.exit(1)
    }
    print("PASS: real final diagnostic is accepted as a complete task report")
  }
}
