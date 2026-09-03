import Foundation

struct ReplayFailure: Error, CustomStringConvertible {
  let description: String
}

func loadReply(from url: URL) throws -> (finalReason: String, reply: [String: Any]) {
  let data = try Data(contentsOf: url)
  guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
    throw ReplayFailure(description: "invalid json root: \(url.path)")
  }
  guard let result = root["result"] as? [String: Any],
        let reply = result["reply"] as? [String: Any] else {
    throw ReplayFailure(description: "missing result.reply object: \(url.path)")
  }
  let finalReason = root["finalReason"] as? String ?? ""
  return (finalReason, reply)
}

@main
struct QueueTerminalReplay {
  static func main() throws {
    let paths = Array(CommandLine.arguments.dropFirst())
    guard !paths.isEmpty else {
      throw ReplayFailure(description: "usage: queue-terminal-replay <diagnostic.final.json> [...]")
    }

    var failures: [String] = []
    for path in paths {
      let url = URL(fileURLWithPath: path)
      let loaded = try loadReply(from: url)
      let decision = queueReplyTerminalDecision(loaded.reply)
      let explicitlyIncomplete = loaded.reply["explicitlyIncomplete"] as? Bool == true
      let streaming = loaded.reply["streaming"] as? Bool == true
      let pending = loaded.reply["pending"] as? Bool == true
      let stopAvailable = loaded.reply["stopAvailable"] as? Bool == true

      print(
        "\(url.lastPathComponent): finalReason=\(loaded.finalReason) "
          + "streaming=\(streaming) pending=\(pending) stop=\(stopAvailable) "
          + "explicitlyIncomplete=\(explicitlyIncomplete) "
          + "responseIsInFlight=\(decision.responseIsInFlight) "
          + "terminalIncomplete=\(decision.terminalIncomplete) terminal=\(decision.terminal)"
      )

      if loaded.finalReason == "unfinished_reply_missing_continuation_report"
          && !(streaming || pending || stopAvailable) {
        failures.append("\(url.lastPathComponent): historical unfinished continuation lacks the expected active-reply evidence")
      }

      if streaming || pending || stopAvailable {
        if !decision.responseIsInFlight {
          failures.append("\(url.lastPathComponent): active reply was not classified in-flight")
        }
        if decision.terminal {
          failures.append("\(url.lastPathComponent): active reply was incorrectly classified terminal")
        }
      }

      if explicitlyIncomplete && !decision.terminalIncomplete && decision.terminal {
        failures.append("\(url.lastPathComponent): explicitlyIncomplete text incorrectly advanced terminal state")
      }
    }

    if !failures.isEmpty {
      for failure in failures { fputs("FAIL: \(failure)\n", stderr) }
      Foundation.exit(1)
    }
    print("PASS: all replayed diagnostics preserve active Chat state")
  }
}
