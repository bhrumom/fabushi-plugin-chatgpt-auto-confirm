import ApplicationServices
import Cocoa
import Darwin
import Foundation
import SystemConfiguration

func decide(
  _ candidate: Candidate,
  rules: [ApprovalRule],
  approveAll: Bool,
  isFallback: Bool = true
) -> (String, String, ApprovalRule?) {
  let prefix = isFallback ? "AXPress 兼容回退：" : ""
  let normalized = candidate.promptText.lowercased()
  if approveAll {
    return ("allow", "\(prefix)通用模式：自动确认所有 ChatGPT 授权卡", nil)
  }
  for rule in rules where
    normalized.contains(rule.application.lowercased()) &&
    normalized.contains(rule.action.lowercased()) &&
    normalized.contains(rule.resource.lowercased()) {
    return ("allow", "\(prefix)命中精确允许规则 \(rule.id)", rule)
  }
  return ("noMatch", "未同时匹配应用、动作和资源", nil)
}

func scan(_ state: inout PluginState) -> [String: Any] {
  // Hidden renderers are handled through IPC without route or focus changes.
  // AX is only a compatibility path for a genuinely visible approval card in
  // the active ChatGPT window. It must never press virtualized elements that
  // belong to a conversation the user has already left.
  let ipcResult = scanIPC(&state)
  let ipcCandidates = ipcResult?["candidates"] as? Int ?? 0
  let ipcApproved = ipcResult?["approved"] as? Int ?? 0
  let ipcPending = ipcResult?["pending"] as? Int ?? 0
  let ipcBlocked = ipcResult?["blocked"] as? Int ?? 0
  let ipcUnmatched = ipcResult?["unmatched"] as? Int ?? 0
  let visibleAXEnabled = ProcessInfo.processInfo.environment[
    "CHATGPT_AUTO_CONFIRM_ALLOW_VISIBLE_AX"
  ] == "1"
  if !visibleAXEnabled {
    if let ipcResult { return ipcResult }
    state.lastError = nil
    return [
      "ok": true, "candidates": 0, "approved": 0, "pending": 0,
      "blocked": 0, "unmatched": 0, "backgroundOnly": true,
      "pageChanged": false, "visibleFallbackDisabled": true,
    ]
  }
  guard AXIsProcessTrusted() else {
    if let ipcResult { return ipcResult }
    state.lastError = "accessibility_required"
    return [
      "ok": false,
      "errorCode": "accessibility_required",
      "message": "请在系统设置的隐私与安全性 → 辅助功能中允许此插件；插件不会绕过 macOS 授权。",
    ]
  }
  guard state.approveAll == true || !state.rules.isEmpty else {
    return ["ok": false, "errorCode": "mode_required", "message": "尚未启用通用模式或配置精确允许规则"]
  }
  let found = candidates()
  reconcilePendingApprovals(&state, activeCandidates: found)
  var approved = 0
  var pending = 0
  var blocked = 0
  var unmatched = 0
  for candidate in found {
    if alreadyApproved(candidate, in: state) {
      continue
    }
    let (decision, reason, rule) = decide(
      candidate,
      rules: state.rules,
      approveAll: state.approveAll == true,
      isFallback: true
    )
    var clicked = false
    var activationError: String?
    var auditReason = reason
    if decision == "allow" {
      guard role(of: candidate.element) == kAXButtonRole as String,
            let currentContext = closestApprovalContext(for: candidate.element),
            currentContext == candidate.promptText,
            candidateStillPresent(candidate) else {
        blocked += 1
        activationError = "approval_candidate_changed"
        state.audit.append(AuditEvent(
          at: isoFormatter.string(from: Date()), decision: decision, reason: reason,
          clicked: false, ruleId: rule?.id, buttonTitle: candidate.buttonTitle,
          promptText: approvalAuditPrompt(candidate.promptText), error: activationError
        ))
        continue
      }
      let (actionSent, disappeared, clickError) = performApprovalClick(candidate)
      clicked = actionSent
      activationError = clickError
      if actionSent && disappeared {
        approved += 1
        auditReason = "\(reason)；\(verifiedApprovalMarker)"
      } else if actionSent {
        pending += 1
        auditReason = "\(reason)；\(pendingApprovalMarker)"
      } else {
        blocked += 1
      }
    } else { unmatched += 1 }
    state.audit.append(AuditEvent(
      at: isoFormatter.string(from: Date()), decision: decision, reason: auditReason,
      clicked: clicked, ruleId: rule?.id, buttonTitle: candidate.buttonTitle,
      promptText: approvalAuditPrompt(candidate.promptText), error: activationError
    ))
  }
  if state.audit.count > 100 { state.audit.removeFirst(state.audit.count - 100) }
  state.lastError = nil
  return [
    "ok": true, "candidates": ipcCandidates + found.count,
    "approved": ipcApproved + approved,
    "pending": ipcPending + pending,
    "blocked": ipcBlocked + blocked,
    "unmatched": ipcUnmatched + unmatched,
    "hiddenCandidates": ipcCandidates, "hiddenApproved": ipcApproved,
    "windowCandidates": found.count, "windowApproved": approved,
    "backgroundOnly": true, "pageChanged": false,
  ]
}

func watcherIsAlive(_ pid: Int32?) -> Bool {
  guard let pid, pid > 1 else { return false }
  return kill(pid, 0) == 0
}

func beginWatcherActivity(
  preventIdleSystemSleep: Bool,
  reason: String
) -> NSObjectProtocol {
  // Locking the screen must not put the queue watcher into App Nap. The queue
  // additionally prevents idle system sleep while work is running; the general
  // approval watcher allows normal sleep and resumes after wake.
  let options: ProcessInfo.ActivityOptions = preventIdleSystemSleep
    ? [.userInitiated, .latencyCritical, .idleSystemSleepDisabled]
    : [.userInitiatedAllowingIdleSystemSleep]
  return ProcessInfo.processInfo.beginActivity(options: options, reason: reason)
}

func parseStartPayload() throws -> ([ApprovalRule], Int, [String], [String], Bool) {
  guard CommandLine.arguments.count >= 3,
        let data = CommandLine.arguments[2].data(using: .utf8),
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
    throw NSError(domain: "chatgpt-auto-confirm", code: 1,
                  userInfo: [NSLocalizedDescriptionKey: "启动参数必须是 JSON 对象"])
  }
  let approveAll = object["approveAll"] as? Bool ?? true
  let rawRules = object["rules"] as? [[String: Any]] ?? []
  guard rawRules.count <= 20, approveAll || !rawRules.isEmpty else {
    throw NSError(domain: "chatgpt-auto-confirm", code: 1,
                  userInfo: [NSLocalizedDescriptionKey: "请启用 approveAll 或提供 1-20 条精确规则"])
  }
  var identities = Set<String>()
  let rules = try rawRules.enumerated().map { index, raw -> ApprovalRule in
    let application = (raw["application"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let action = (raw["action"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let resource = (raw["resource"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard [application, action, resource].allSatisfy({ !$0.isEmpty && $0 != "*" && $0 != ".*" && $0.count <= 256 }) else {
      throw NSError(domain: "chatgpt-auto-confirm", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "规则字段必须是精确文本"])
    }
    let identity = [application, action, resource].map { $0.lowercased() }.joined(separator: "\0")
    guard identities.insert(identity).inserted else {
      throw NSError(domain: "chatgpt-auto-confirm", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "规则不能重复"])
    }
    return ApprovalRule(
      id: (raw["id"] as? String) ?? "rule-\(index + 1)",
      application: application, action: action, resource: resource
    )
  }
  let interval = min(5_000, max(400, object["intervalMs"] as? Int ?? 750))
  let chatTitles = (object["chatTitles"] as? [String] ?? []).map {
    $0.trimmingCharacters(in: .whitespacesAndNewlines)
  }
  guard chatTitles.count <= 20,
        chatTitles.allSatisfy({ !$0.isEmpty && $0.count <= 256 }) else {
    throw NSError(domain: "chatgpt-auto-confirm", code: 4,
                  userInfo: [NSLocalizedDescriptionKey: "chatTitles 必须是最多 20 个精确任务标题"])
  }
  let rawChatURLs = object["chatUrls"] as? [String] ?? []
  let chatURLs = rawChatURLs.compactMap(normalizedChatURL)
  guard rawChatURLs.count <= 20, chatURLs.count == rawChatURLs.count else {
    throw NSError(domain: "chatgpt-auto-confirm", code: 5,
                  userInfo: [NSLocalizedDescriptionKey: "chatUrls 必须是最多 20 个 https://chatgpt.com/c/... 地址"])
  }
  return (rules, interval, chatTitles, chatURLs, approveAll)
}

func statusPayload(_ state: PluginState) -> [String: Any] {
  let rulePayload = state.rules.map {
    ["id": $0.id, "application": $0.application, "action": $0.action, "resource": $0.resource]
  }
  let approvalTargets = loadedApprovalTargets(state)
  let approvalPorts = Array(Set(approvalTargets.map(\.port))).sorted()
  return [
    "ok": true,
    "running": state.enabled && watcherIsAlive(state.watcherPid),
    "enabled": state.enabled,
    "approveAll": state.approveAll == true,
    "accessibilityGranted": AXIsProcessTrusted(),
    "applicationRunning": !runningChatGptApplications().isEmpty,
    "rules": rulePayload,
    "chatTitles": state.chatTitles ?? [],
    "trackedChatURLs": state.trackedChatURLs ?? [],
    "hiddenTargetCount": approvalTargets.count,
    "loadedRendererCount": approvalTargets.count,
    "scannedPorts": approvalPorts,
    "backgroundChat": [
      "port": state.backgroundAppPort as Any,
      "targetId": state.backgroundChatTargetId as Any,
      "profilePath": state.backgroundProfilePath as Any,
      "conversationId": state.backgroundConversationId as Any,
      "connected": state.backgroundAppPort.map {
        !CDPClient.fetchTargets(portOverride: $0).isEmpty
      } ?? false,
      "surface": "chat",
      "workerUsed": false,
    ],
    "intervalMs": state.intervalMs,
    "auditCount": state.audit.count,
    "lastError": state.lastError as Any,
    "backgroundOnly": true,
    "ipc": [
      "cdp": CDPClient.checkStatus(),
      "unix": UnixIPCClient.checkStatus(),
      "primaryPath": "CDP WebSocket & Unix IPC 主路径",
      "fallbackPath": "AXPress 兼容回退",
    ],
    "safety": [
      "requiresApplicationActionAndResource": state.approveAll != true,
      "allRecognizedApprovalsEnabled": state.approveAll == true,
      "sensitiveActionsAlwaysBlocked": false,
      "dataLeavesDevice": false,
      "usesOnlyAccessibilityPress": false,
      "movesMouse": false,
      "activatesApplication": false,
      "navigatesTasks": false,
      "dismissesCoveringHistoryOverlay": true,
      "ipcIsPrimaryPath": true,
      "internalActionIsPrimary": true,
      "operatesHiddenPages": true,
      "scansEveryLoadedRenderer": false,
      "visibleRendererAccess": false,
      "requiresPriorTracking": false,
      "changesVisiblePage": false,
      "axPressIsFallback": ProcessInfo.processInfo.environment[
        "CHATGPT_AUTO_CONFIRM_ALLOW_VISIBLE_AX"
      ] == "1",
      "axPressVisibleForegroundOnly": true,
      "axPressNeverTargetsHiddenElements": true,
    ],
  ]
}

func diagnosticPayload() -> [String: Any] {
  let applications = runningChatGptApplications().map { application -> [String: Any] in
    let root = AXUIElementCreateApplication(application.processIdentifier)
    let buttons = descendants(of: root, matchingRole: kAXButtonRole as String)
    let elements = allDescendants(of: root)
    let menuItems = elements.compactMap { element -> [String: Any]? in
      guard role(of: element) == kAXMenuItemRole as String else { return nil }
      let text = accessibleString(element).trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { return nil }
      return ["text": text, "actions": actionNames(of: element)]
    }
    let actionable = elements.compactMap { element -> [String: Any]? in
      let actions = actionNames(of: element)
      guard actions.contains(kAXPressAction as String) else { return nil }
      let elementRole = role(of: element)
      guard elementRole != kAXMenuItemRole as String &&
              elementRole != kAXMenuBarItemRole as String else { return nil }
      let text = accessibleString(element).trimmingCharacters(in: .whitespacesAndNewlines)
      let nested = text.isEmpty ? textContent(of: element, limit: 60) : text
      guard !nested.isEmpty else { return nil }
      return ["role": elementRole, "text": String(nested.prefix(300)), "actions": actions]
    }
    let matchedNodes = elements.compactMap { element -> [String: Any]? in
      let strings = diagnosticStrings(element)
      let rawValues = [
        kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXValueAttribute,
      ].map { stringAttribute(element, $0 as CFString) }
      guard rawValues.contains(where: {
        $0.contains("GitHub Actions 修复跟踪") || $0.contains("修复允许按钮识别") ||
          $0.contains("修复并跟踪 GitHub Actions") || $0.contains("GitHub连接DevSpace")
      }) else { return nil }
      var ancestry: [[String: Any]] = []
      var current: AXUIElement? = element
      for _ in 0..<14 {
        guard let node = current else { break }
        ancestry.append([
          "role": role(of: node), "strings": diagnosticStrings(node),
          "nestedText": String(textContent(of: node, limit: 100).prefix(500)),
          "actions": actionNames(of: node),
        ])
        current = parent(of: node)
      }
      return ["strings": strings, "ancestry": ancestry]
    }
    let allText = textContent(of: root, limit: 8_000)
    let relevantLines = allText.split(separator: "\n")
      .map(String.init)
      .filter { line in
        let normalized = line.lowercased()
        return normalized.contains("github") || normalized.contains("chatgpt") ||
          normalized.contains("allow") || normalized.contains("reject") ||
          normalized.contains("auto-merge") || normalized.contains("自动合并") ||
          normalized.contains("允许") || normalized.contains("拒绝")
      }
      .prefix(100)
    return [
      "bundleIdentifier": application.bundleIdentifier ?? "",
      "localizedName": application.localizedName ?? "",
      "processIdentifier": application.processIdentifier,
      "buttonCount": buttons.count,
      "buttonTitles": buttons.prefix(100).map(accessibleString),
      "menuItems": Array(menuItems.prefix(300)),
      "actionable": Array(actionable.prefix(200)),
      "matchedNodes": matchedNodes,
      "relevantText": Array(relevantLines),
    ]
  }
  return [
    "ok": true,
    "accessibilityGranted": AXIsProcessTrusted(),
    "applications": applications,
    "ipc": [
      "cdp": CDPClient.checkStatus(),
      "unix": UnixIPCClient.checkStatus(),
    ],
  ]
}

func startWatcher(_ state: inout PluginState) throws {
  if watcherIsAlive(state.watcherPid), let pid = state.watcherPid { kill(pid, SIGTERM) }
  let process = Process()
  process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
  process.arguments = ["watch"]
  process.standardInput = FileHandle.nullDevice
  process.standardOutput = FileHandle.nullDevice
  process.standardError = FileHandle.nullDevice
  try process.run()
  state.watcherPid = process.processIdentifier
}

func withWatcherLifecycleLock<T>(_ body: () throws -> T) throws -> T {
  let directory = stateURL().deletingLastPathComponent()
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let lockURL = directory.appendingPathComponent("watcher.lock")
  let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
  guard descriptor >= 0 else {
    throw NSError(
      domain: "chatgpt-auto-confirm",
      code: 6,
      userInfo: [NSLocalizedDescriptionKey: "无法创建授权 watcher 生命周期锁"]
    )
  }
  defer {
    _ = flock(descriptor, LOCK_UN)
    close(descriptor)
  }
  guard flock(descriptor, LOCK_EX) == 0 else {
    throw NSError(
      domain: "chatgpt-auto-confirm",
      code: 7,
      userInfo: [NSLocalizedDescriptionKey: "无法获取授权 watcher 生命周期锁"]
    )
  }
  return try body()
}
