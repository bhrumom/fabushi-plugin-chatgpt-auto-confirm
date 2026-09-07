import ApplicationServices
import Cocoa
import CryptoKit
import Darwin
import Foundation
import SystemConfiguration

func queueDirectoryURL() -> URL {
  queueStateURL().deletingLastPathComponent().appendingPathComponent("task-queue", isDirectory: true)
}

let currentQueueRuntimeRevision = "mahayana.task-queue.v115"
let defaultMaxTaskContinuations = 6
let minimumAutomaticContinuationDelaySeconds = 30
let repeatedIncompleteReportCircuitThreshold = 3
let automaticApprovalWindowSeconds: TimeInterval = 120
let maxAutomaticApprovalsPerWindow = 8
let retainedApprovalFingerprintCount = 100

func prunedAutomaticApprovalTimestamps(
  _ values: [String]?,
  now: Date = Date()
) -> [String] {
  (values ?? []).filter { value in
    guard let date = isoFormatter.date(from: value) else { return false }
    return now.timeIntervalSince(date) <= automaticApprovalWindowSeconds
  }
}

func approvalFingerprint(_ detection: [String: Any]?) -> String? {
  guard let value = detection?["cardFingerprint"] as? String else { return nil }
  let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
  return normalized.isEmpty ? nil : String(normalized.prefix(96))
}

func recordHandledApprovalFingerprint(
  _ fingerprint: String,
  fingerprints: inout [String]?,
  fingerprintAttempts: inout [String: Int]?,
  timestamps: inout [String]?,
  lastFingerprint: inout String?,
  lastApprovedAt: inout String?,
  now: Date = Date()
) {
  var handled = fingerprints ?? []
  handled.removeAll { $0 == fingerprint }
  handled.append(fingerprint)
  fingerprints = Array(handled.suffix(retainedApprovalFingerprintCount))
  var attempts = fingerprintAttempts ?? [:]
  attempts[fingerprint] = (attempts[fingerprint] ?? 0) + 1
  attempts = attempts.filter { handled.contains($0.key) }
  fingerprintAttempts = attempts
  var recent = prunedAutomaticApprovalTimestamps(timestamps, now: now)
  let timestamp = isoFormatter.string(from: now)
  recent.append(timestamp)
  timestamps = recent
  lastFingerprint = fingerprint
  lastApprovedAt = timestamp
}

func queueStateURL() -> URL {
  if let override = ProcessInfo.processInfo.environment["CHATGPT_AUTO_CONFIRM_QUEUE_STATE"],
     !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
    return URL(fileURLWithPath: override)
  }
  return stateURL().deletingLastPathComponent().appendingPathComponent("queue-state.json")
}

func queueTraceURL() -> URL {
  queueDirectoryURL().appendingPathComponent("watcher-trace.log")
}

let retainedConversationDiagnosticCount = 5

func queueConversationDiagnosticsDirectoryURL() -> URL {
  queueStateURL().deletingLastPathComponent()
    .appendingPathComponent("diagnostics", isDirectory: true)
}

func queueConversationDiagnosticBaseName(_ task: AutomationTask) -> String {
  let reviewing = task.reviewStatus == "running"
  let rawConversation = reviewing ? task.reviewConversationId : task.conversationId
  let conversation = (rawConversation ?? "conversation-pending")
    .replacingOccurrences(
      of: "[^A-Za-z0-9_-]+",
      with: "-",
      options: .regularExpression
    )
  let kind = reviewing ? "review" : "work"
  return "\(task.id)-attempt-\(task.attempts)-review-\(task.reviewRound)-\(kind)-\(conversation.prefix(80))"
}

func writeQueueConversationDiagnostic(
  _ task: AutomationTask,
  finalReason: String? = nil
) {
  guard let rawResult = task.lastResultJSON,
        let resultData = rawResult.data(using: .utf8),
        let result = try? JSONSerialization.jsonObject(with: resultData) else { return }
  let directory = queueConversationDiagnosticsDirectoryURL()
  try? FileManager.default.createDirectory(
    at: directory,
    withIntermediateDirectories: true
  )
  let baseName = queueConversationDiagnosticBaseName(task)
  let liveURL = directory.appendingPathComponent("\(baseName).live.json")
  let finalURL = directory.appendingPathComponent("\(baseName).final.json")
  let payload: [String: Any] = [
    "recordedAt": isoFormatter.string(from: Date()),
    "taskId": task.id,
    "attempts": task.attempts,
    "reviewRound": task.reviewRound,
    "conversationId": task.conversationId ?? NSNull(),
    "reviewConversationId": task.reviewConversationId ?? NSNull(),
    "status": finalReason == nil ? "live" : "final",
    "finalReason": finalReason ?? NSNull(),
    "result": result,
  ]
  guard let data = try? JSONSerialization.data(
    withJSONObject: payload,
    options: [.prettyPrinted, .sortedKeys]
  ) else { return }
  let targetURL = finalReason == nil ? liveURL : finalURL
  do {
    try data.write(to: targetURL, options: .atomic)
    try? FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: targetURL.path
    )
    if finalReason != nil {
      try? FileManager.default.removeItem(at: liveURL)
      pruneQueueConversationDiagnostics(taskId: task.id)
    }
  } catch {
    queueTrace(
      "task=\(task.id) stage=diagnostic-write-failed error=\(error.localizedDescription)"
    )
  }
}

func pruneQueueConversationDiagnostics(taskId: String) {
  let directory = queueConversationDiagnosticsDirectoryURL()
  guard let urls = try? FileManager.default.contentsOfDirectory(
    at: directory,
    includingPropertiesForKeys: [.contentModificationDateKey],
    options: [.skipsHiddenFiles]
  ) else { return }
  let prefix = "\(taskId)-"
  let finalized = urls.filter {
    $0.lastPathComponent.hasPrefix(prefix)
      && $0.lastPathComponent.hasSuffix(".final.json")
  }.sorted {
    let lhs = (try? $0.resourceValues(
      forKeys: [.contentModificationDateKey]
    ).contentModificationDate) ?? .distantPast
    let rhs = (try? $1.resourceValues(
      forKeys: [.contentModificationDateKey]
    ).contentModificationDate) ?? .distantPast
    return lhs > rhs
  }
  for staleURL in finalized.dropFirst(retainedConversationDiagnosticCount) {
    try? FileManager.default.removeItem(at: staleURL)
  }
}

func queueTrace(_ message: String) {
  let url = queueTraceURL()
  try? FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  if !FileManager.default.fileExists(atPath: url.path) {
    _ = FileManager.default.createFile(atPath: url.path, contents: nil)
  }
  guard let handle = try? FileHandle(forWritingTo: url) else { return }
  defer { try? handle.close() }
  if ((try? handle.seekToEnd()) ?? 0) > 262_144 {
    try? handle.truncate(atOffset: 0)
    try? handle.seek(toOffset: 0)
  }
  let timestamp = isoFormatter.string(from: Date())
  handle.write(Data("[\(timestamp)] \(message)\n".utf8))
}

func queueTraceTail() -> [String] {
  guard let data = try? Data(contentsOf: queueTraceURL()),
        let text = String(data: data.suffix(16_384), encoding: .utf8) else { return [] }
  return Array(text.split(separator: "\n").suffix(40)).map(String.init)
}

func loadQueueState() -> PluginState {
  guard let data = try? Data(contentsOf: queueStateURL()),
        var state = try? decoder.decode(PluginState.self, from: data) else {
    return PluginState()
  }
  // Zero explicitly means continue until complete. Short-round backoff and
  // rate-limit recovery prevent the old rapid-fire behavior without turning a
  // long healthy task into a terminal failure at an arbitrary Chat count.
  if state.queueRuntimeRevision != currentQueueRuntimeRevision,
     var tasks = state.automationTasks {
    for index in tasks.indices where tasks[index].maxTaskContinuations < 0
        || tasks[index].maxTaskContinuations == 8 {
      tasks[index].maxTaskContinuations = defaultMaxTaskContinuations
    }
    state.automationTasks = tasks
  }
  return state
}

func saveQueueState(_ state: PluginState) throws {
  try writePluginState(state, to: queueStateURL())
}

func withQueueStateLock<T>(
  _ body: (inout PluginState) throws -> T
) throws -> T {
  let directory = queueStateURL().deletingLastPathComponent()
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let lockURL = directory.appendingPathComponent("queue.lock")
  let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
  guard descriptor >= 0 else {
    throw NSError(
      domain: "chatgpt-auto-confirm",
      code: 20,
      userInfo: [NSLocalizedDescriptionKey: "无法创建任务队列状态锁"]
    )
  }
  defer {
    _ = flock(descriptor, LOCK_UN)
    close(descriptor)
  }
  guard flock(descriptor, LOCK_EX) == 0 else {
    throw NSError(
      domain: "chatgpt-auto-confirm",
      code: 21,
      userInfo: [NSLocalizedDescriptionKey: "无法获取任务队列状态锁"]
    )
  }
  var state = loadQueueState()
  let result = try body(&state)
  try saveQueueState(state)
  return result
}

func writePluginState(_ state: PluginState, to url: URL) throws {
  try FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  try encoder.encode(state).write(to: url, options: .atomic)
}

func normalizedTaskId(_ rawValue: String?) -> String? {
  guard let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
        !value.isEmpty,
        value.range(
          of: "^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$",
          options: .regularExpression
        ) != nil else { return nil }
  return value
}

func normalizedConnector(_ rawValue: String?) -> String? {
  guard let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
        !value.isEmpty,
        value.count <= 256,
        !value.contains("\n"),
        !value.contains("\r") else { return nil }
  return value
}

struct QueueNetworkProbe {
  let reachable: Bool
  let detail: String
}

func queueNetworkProbe() -> QueueNetworkProbe {
  guard let reachability = SCNetworkReachabilityCreateWithName(nil, "api.github.com") else {
    return QueueNetworkProbe(
      reachable: true,
      detail: "无法创建 GitHub 路由预检；按实际请求结果判断网络状态"
    )
  }
  var flags = SCNetworkReachabilityFlags()
  guard SCNetworkReachabilityGetFlags(reachability, &flags) else {
    return QueueNetworkProbe(
      reachable: true,
      detail: "无法读取 GitHub 路由预检；按实际请求结果判断网络状态"
    )
  }
  let isReachable = flags.contains(.reachable)
  let needsConnection = flags.contains(.connectionRequired)
  let canConnectAutomatically = flags.contains(.connectionOnDemand)
    || flags.contains(.connectionOnTraffic)
  let online = isReachable && (!needsConnection || canConnectAutomatically)
  // SCNetworkReachability is deprecated on current macOS and can report
  // false negatives on ephemeral GitHub-hosted runners. A negative preflight
  // must not leave every task queued forever. Start the task and let the
  // existing networkRecoverySignal path handle an actual request failure.
  return QueueNetworkProbe(
    reachable: true,
    detail: online
      ? "GitHub 网络路由可达"
      : "GitHub 路由预检不确定（flags=\(flags.rawValue)）；按实际请求结果判断"
  )
}

func networkRecoverySignal(_ value: String) -> String? {
  let text = value.lowercased()
  let markers = [
    "network is unreachable", "network unreachable", "err_internet_disconnected",
    "internet disconnected", "could not resolve host", "dns lookup failed",
    "connection reset", "connection refused", "connection timed out",
    "upstream 502", "http 502", "http 503", "http 504",
    "request failed with status 429", "http 429", "too many requests",
    "devspace_tool_timeout", "网络断开", "网络不可用", "无法解析主机",
    "连接被重置", "连接超时", "上游 502", "上游 503", "上游 504",
    "请求过于频繁"
  ]
  guard let marker = markers.first(where: { text.contains($0) }) else { return nil }
  return marker
}

func isRequestRateLimitSignal(_ value: String) -> Bool {
  let text = value.lowercased()
  return text.contains("request failed with status 429")
    || text.contains("http 429")
    || text.contains("too many requests")
    || text.contains("请求过于频繁")
}

func queueNetworkRecovery(
  _ task: inout AutomationTask,
  state: inout PluginState,
  reason: String
) {
  if isRequestRateLimitSignal(reason) {
    let currentDate = Date()
    let now = isoFormatter.string(from: currentDate)
    let delay = 1_800
    queueContinuation(&task, report: nil, reason: "rate_limit_recovery")
    state.queuePaused = false
    state.queueNetworkStatus = "rate_limited"
    state.queueNetworkLastError = String(reason.prefix(240))
    state.queueNetworkWaitUntil = isoFormatter.string(
      from: currentDate.addingTimeInterval(Double(delay))
    )
    task.status = "waiting"
    task.waitingUntil = state.queueNetworkWaitUntil
    task.waitReason = "ChatGPT 请求限流；退避约 \(delay) 秒后自动恢复"
    task.lastError = "waiting_for_rate_limit_recovery"
    task.updatedAt = now
    task.finishedAt = nil
    queueTrace(
      "task=\(task.id) stage=network-rate-limit-wait delay=\(delay)s reason=\(reason)"
    )
    return
  }
  // Use the regular continuation reset so the next operation is always a
  // fresh Chat, then defer only that continuation while connectivity recovers.
  queueContinuation(&task, report: nil, reason: "network_recovery")
  guard task.status == "queued" else { return }
  let failureCount = min(6, (state.queueNetworkFailureCount ?? 0) + 1)
  let delay = min(300, 30 * (1 << min(3, failureCount - 1)))
  let dueDate = Date().addingTimeInterval(Double(delay))
  let compactReason = String(reason.prefix(240))
  state.queueNetworkFailureCount = failureCount
  state.queueNetworkStatus = "waiting_for_recovery"
  state.queueNetworkLastError = compactReason
  state.queueNetworkWaitUntil = isoFormatter.string(from: dueDate)
  task.status = "waiting"
  task.waitingUntil = state.queueNetworkWaitUntil
  task.waitReason = "网络/上游连接恢复：\(compactReason)；将在约 \(delay) 秒后重新探测"
  task.reviewFeedback = "小程序检测到网络、DNS 或上游连接异常（\(compactReason)）。不要重复当前失败请求；等待小程序恢复连接后在新 Chat 中检查同一 checkout 的落盘结果，再继续未完成步骤。"
  task.lastError = "waiting_for_network_recovery"
  task.updatedAt = isoFormatter.string(from: Date())
}

func taskPromptPrefix(_ template: String) -> String {
  switch template {
  case "implement-and-verify":
    return "请在当前 checkout 中完成下面的实现任务，检查现有改动后继续，运行与风险相称的验证，不要覆盖无关改动："
  case "diagnose-fix-verify":
    return "请先用现有代码、日志和测试定位根因，然后修复并完成回归验证；不要只给建议："
  case "review-and-fix":
    return "请审查当前 checkout 中与目标相关的实现，修正发现的真实问题并完成验证："
  default:
    return "请从当前 checkout 的已有进度继续，不要从头开始；持续工作直到以下目标和验收条件全部满足："
  }
}

func chatOnlyInstruction(_ value: String) -> String {
  value
    .split(separator: "\n", omittingEmptySubsequences: false)
    .map(String.init)
    .filter { line in
      let normalized = line.lowercased()
      return !normalized.contains("worker")
        && !normalized.contains("work/worker")
        && !normalized.contains("work 模式")
        && !normalized.contains("work mode")
        && !normalized.contains("转交 work")
        && !normalized.contains("continue in work")
    }
    .joined(separator: "\n")
    .trimmingCharacters(in: .whitespacesAndNewlines)
}

func taskSpecSourceList(_ task: AutomationTask) -> String {
  guard let sources = task.specSources, !sources.isEmpty else {
    return "（无外部规范文件）"
  }
  return sources.map { "- \($0)" }.joined(separator: "\n")
}

let sharedTaskExecutionSkillPath =
  "skills/actions-first-task-queue/SKILL.md"

func taskDocumentDirectory(_ task: AutomationTask) -> String {
  guard let first = task.specSources?.first,
        !first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
    return "tasks/\(task.id)"
  }
  return (first as NSString).deletingLastPathComponent
}

func taskDefinitionSHA256(_ value: String) -> String {
  let digest = SHA256.hash(data: Data(value.utf8))
  return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
}

/// The miniapp owns task-update detection. Before every queue iteration it
/// re-reads the control entry and all declared task files from the checkout.
@discardableResult
func refreshAutomationTaskDefinitionFromDisk(_ task: inout AutomationTask) -> Bool {
  guard let workspace = task.workspaceRoot?.trimmingCharacters(in: .whitespacesAndNewlines),
        !workspace.isEmpty else { return false }
  let workspaceURL = URL(fileURLWithPath: workspace).standardizedFileURL
  let relativeControl = task.taskControlPath?.trimmingCharacters(in: .whitespacesAndNewlines)
  let controlPath = (relativeControl?.isEmpty == false)
    ? relativeControl!
    : "tasks/actions-inbox.json"
  let controlURL = URL(fileURLWithPath: controlPath, relativeTo: workspaceURL).standardizedFileURL
  guard controlURL.path.hasPrefix(workspaceURL.path + "/"),
        let data = try? Data(contentsOf: controlURL),
        let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let entries = root["tasks"] as? [[String: Any]],
        let entry = entries.first(where: { ($0["id"] as? String) == task.id }) else {
    return false
  }
  // The email-thread record is runtime progress, not task specification. It
  // must never trigger a new goal merely because a Chat replied to the thread.
  let sources = (entry["specSources"] as? [String] ?? task.specSources ?? [])
    .filter { URL(fileURLWithPath: $0).lastPathComponent != ".mahayana-project-email.json" }
  var sections: [String] = []
  for source in sources {
    let url = URL(fileURLWithPath: source, relativeTo: workspaceURL).standardizedFileURL
    guard url.path.hasPrefix(workspaceURL.path + "/"),
          let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
    sections.append("## \(source)\n\(text.trimmingCharacters(in: .whitespacesAndNewlines))")
  }
  let snapshot = sections.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
  let digest = snapshot.isEmpty ? nil : taskDefinitionSHA256(snapshot)
  let incomingPrompt = entry["prompt"] as? String ?? task.prompt
  let incomingTitle = entry["title"] as? String ?? task.title
  let incomingDirective = (entry["directive"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
  let incomingConnector = entry["connector"] as? String ?? task.connector
  let incomingRepository = entry["repository"] as? String ?? task.repository
  let incomingCodeDirectory = entry["codeDirectory"] as? String ?? task.codeDirectory
  if incomingConnector != task.connector {
    task.connector = incomingConnector
    task.updatedAt = isoFormatter.string(from: Date())
    queueTrace("task=\(task.id) stage=task-connector-refreshed connector=\(incomingConnector)")
  }
  let previousRevision = max(1, task.currentRevision ?? 1)
  let declaredRevision = max(1, entry["revision"] as? Int ?? previousRevision)
  let changed = declaredRevision > previousRevision
    || incomingPrompt != task.prompt
    || incomingTitle != task.title
    || incomingDirective != task.pendingDirective
    || incomingRepository != task.repository
    || incomingCodeDirectory != task.codeDirectory
    || sources != (task.specSources ?? [])
    || digest != task.specDigest
  guard changed else { return false }

  let effectiveRevision = declaredRevision > previousRevision
    ? declaredRevision
    : previousRevision + 1
  task.originalPrompt = task.originalPrompt ?? task.prompt
  task.prompt = incomingPrompt
  task.title = incomingTitle
  task.currentRevision = effectiveRevision
  task.pendingRevision = effectiveRevision
  task.specSources = sources
  task.specSnapshot = snapshot
  task.specDigest = digest
  task.pendingDirective = incomingDirective
  task.repository = incomingRepository
  task.codeDirectory = incomingCodeDirectory
  task.specUpdatedAt = isoFormatter.string(from: Date())
  task.updatedAt = task.specUpdatedAt ?? task.updatedAt
  task.reviewFeedback = "小程序检测到任务目标或规范文件更新；旧 Chat 链不再续作，下一轮必须新建 Chat 并应用完整新目标。"
  queueTrace(
    "task=\(task.id) stage=task-definition-refreshed revision=\(effectiveRevision) "
      + "digest=\(digest ?? "none") action=fresh-project-chat"
  )
  return true
}

func restartAutomationTaskForUpdatedGoal(_ task: inout AutomationTask) {
  task.status = "queued"
  task.attempts = 0
  task.continuationDepth = 0
  task.startedAt = nil
  task.finishedAt = nil
  task.workerPid = nil
  task.workerPort = nil
  task.workerTargetId = nil
  task.workerStatePath = nil
  task.workerProfilePath = nil
  task.conversationId = nil
  task.dispatchMarkerVerifiedAt = nil
  task.dispatchLocalConversationId = nil
  task.attachedConversationWithoutDispatchMarker = nil
  task.chatURL = nil
  task.reviewConversationId = nil
  task.reviewStatus = nil
  task.reviewReport = nil
  task.report = nil
  task.lastResultJSON = nil
  task.lastActivitySignature = nil
  task.lastProgressAt = nil
  task.waitingUntil = nil
  task.waitReason = nil
  task.lastError = nil
  task.updatedAt = isoFormatter.string(from: Date())
}

func automationTaskMessage(_ task: AutomationTask, forceFullGoal: Bool = false) -> String {
  // Queue snapshots can outlive a plugin upgrade. Strip every historical
  // report contract before adding the current Work-only context, so a retry
  // can never accidentally teach a Work Chat to emit the planner protocol.
  var goal = messageWithoutTaskReportContract(
    task.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
  )
  if let directive = task.pendingDirective?.trimmingCharacters(in: .whitespacesAndNewlines),
     !directive.isEmpty, !goal.contains(directive) {
    goal += "\n\n\(directive)"
  }
  if let reviewFeedback = task.reviewFeedback?.trimmingCharacters(in: .whitespacesAndNewlines),
     !reviewFeedback.isEmpty {
    goal += "\n\n插件编排上下文（请直接执行，不要输出规划模板）：\n\(reviewFeedback)"
  }
  // `forceFullGoal` is retained for persisted queue compatibility. Every Work
  // Chat now receives the executable goal and any planner handoff, but never a
  // completion-report contract.
  _ = forceFullGoal
  return messageWithoutTaskReportContract(goal)
}

func startAutomationPlanner(
  _ task: inout AutomationTask,
  workResult: String,
  port: Int,
  targetId: String,
  state: PluginState
) -> Bool {
  _ = state
  let trimmedWorkResult = messageWithoutTaskReportContract(workResult)
    .trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmedWorkResult.isEmpty else {
    queueTrace("task=\(task.id) stage=planner-branch failed reason=missing_work_result")
    return false
  }

  // The planner is intentionally a separate conversation. It receives the
  // completed Work Chat's natural result and is the only role that receives
  // the machine-readable report contract.
  guard let prepared = prepareNewChatTarget(
    port: port,
    targetId: targetId,
    timeout: 35.0,
    allowBlankConversationReuse: false
  ), prepared["ok"] as? Bool == true else {
    queueTrace("task=\(task.id) stage=planner-branch failed reason=new_chat_not_confirmed")
    return false
  }
  let nextReviewRound = task.reviewRound + 1
  let dispatchMarker = "规划验收 Chat 标识：\(task.id)-\(task.attempts)-\(nextReviewRound)"
  let outbound = acceptancePlannerMessage(
    originalGoal: task.originalPrompt ?? task.prompt,
    workResult: trimmedWorkResult,
    taskId: task.id,
    appliedRevision: task.currentRevision,
    appliedDigest: task.specDigest
  ) + "\n\n插件调度标记：\(dispatchMarker)"
  guard let sendResult = cdpValue(
    port: port,
    targetId: targetId,
    expression: sendMessageJS(
      message: outbound,
      connector: task.connector,
      newChat: false,
      expectedConversationId: normalizedConversationId(prepared["conversationId"] as? String)
    ),
    timeout: 65.0
  ), sendResult["ok"] as? Bool == true else {
    queueTrace("task=\(task.id) stage=planner-branch failed reason=send_not_confirmed")
    return false
  }
  _ = cdpValue(
    port: port,
    targetId: targetId,
    expression: autoConfirmChatContinuationJS(),
    timeout: 4.0
  )
  let resolvedConversation = cdpValue(
    port: port,
    targetId: targetId,
    expression: resolveDispatchedConversationJS(
      dispatchMarker: dispatchMarker,
      localConversationId: normalizedConversationId(prepared["conversationId"] as? String)
    ),
    timeout: 24.0
  )
  let resolvedConversationId = normalizedConversationId(
    resolvedConversation?["conversationId"] as? String
  )
  task.reviewRound = nextReviewRound
  task.reviewConversationId = resolvedConversationId
    ?? normalizedConversationId(prepared["conversationId"] as? String)
  task.reviewStatus = "running"
  task.reviewReport = nil
  task.lastResultJSON = jsonString([
    "plannerInput": trimmedWorkResult,
    "plannerConversationId": task.reviewConversationId as Any,
    "dispatchMarker": dispatchMarker,
    "sendResult": sendResult,
  ])
  task.lastError = nil
  task.lastActivitySignature = nil
  task.lastProgressAt = isoFormatter.string(from: Date())
  task.updatedAt = task.lastProgressAt ?? isoFormatter.string(from: Date())
  queueTrace(
    "task=\(task.id) stage=planner-branch complete "
      + "conversation=\(task.reviewConversationId ?? "none")"
  )
  return true
}

// Kept as a compatibility shim for queue snapshots created by older runtimes.
// New Work completion always goes through startAutomationPlanner with the
// natural Work reply; it never sends a report contract to the Work Chat.
func startAutomationReview(
  _ task: inout AutomationTask,
  report: AutomationTaskReport,
  port: Int,
  targetId: String,
  state: PluginState
) -> Bool {
  let legacyResult = [
    "摘要：\(report.summary)",
    "已完成：\(report.completed.joined(separator: "；"))",
    "剩余：\(report.remaining.joined(separator: "；"))",
    "卡点：\(report.blockers.joined(separator: "；"))",
  ].joined(separator: "\n")
  return startAutomationPlanner(
    &task,
    workResult: legacyResult,
    port: port,
    targetId: targetId,
    state: state
  )
}

func dependencyCycle(in tasks: [AutomationTask]) -> [String]? {
  let graph = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0.dependsOn) })
  var visiting = Set<String>()
  var visited = Set<String>()
  var stack: [String] = []
  func visit(_ id: String) -> [String]? {
    if visiting.contains(id), let start = stack.firstIndex(of: id) {
      return Array(stack[start...]) + [id]
    }
    if visited.contains(id) { return nil }
    visiting.insert(id)
    stack.append(id)
    for dependency in graph[id] ?? [] {
      if let cycle = visit(dependency) { return cycle }
    }
    _ = stack.popLast()
    visiting.remove(id)
    visited.insert(id)
    return nil
  }
  for id in graph.keys {
    if let cycle = visit(id) { return cycle }
  }
  return nil
}

func automationReport(_ raw: Any?) -> AutomationTaskReport? {
  guard let raw = raw as? [String: Any],
        JSONSerialization.isValidJSONObject(raw),
        let data = try? JSONSerialization.data(withJSONObject: raw),
        let report = try? decoder.decode(AutomationTaskReport.self, from: data),
        report.protocolName == "mahayana.task-report.v1",
        ["complete", "incomplete", "blocked"].contains(report.status) else { return nil }
  return report
}

func decodeLastJSONLine(at path: String?) -> (String, [String: Any])? {
  guard let path,
        let data = FileManager.default.contents(atPath: path),
        let text = String(data: data, encoding: .utf8) else { return nil }
  for line in text.split(whereSeparator: \Character.isNewline).reversed() {
    let raw = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
    guard let lineData = raw.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
          object["event"] == nil else { continue }
    return (raw, object)
  }
  return nil
}

func taskPublicPayload(_ task: AutomationTask, includeResult: Bool = false) -> [String: Any] {
  var payload: [String: Any] = [
    "id": task.id,
    "accountId": task.accountId as Any,
    "title": task.title,
    "status": task.status,
    "originalPrompt": task.originalPrompt ?? task.prompt,
    "promptTemplate": task.promptTemplate,
    "currentRevision": task.currentRevision ?? 1,
    "appliedRevision": task.appliedRevision as Any,
    "pendingRevision": task.pendingRevision as Any,
    "specSources": task.specSources ?? [],
    "specDigest": task.specDigest as Any,
    "appliedSpecDigest": task.appliedSpecDigest as Any,
    "applyMode": task.applyMode ?? "next_chat",
    "taskUpdateCount": task.taskUpdates?.count ?? 0,
    "specUpdatedAt": task.specUpdatedAt as Any,
    "connector": task.connector,
    "repository": task.repository as Any,
    "codeDirectory": task.codeDirectory as Any,
    "dependsOn": task.dependsOn,
    "resourceLocks": task.resourceLocks,
    "priority": task.priority,
    "attempts": task.attempts,
    "maxRuntimeRetries": task.maxRuntimeRetries,
    "reviewRound": task.reviewRound,
    "createdAt": task.createdAt,
    "updatedAt": task.updatedAt,
    "startedAt": task.startedAt as Any,
    "finishedAt": task.finishedAt as Any,
    "workerPid": task.workerPid as Any,
    "workerPort": task.workerPort as Any,
    "workerTargetId": task.workerTargetId as Any,
    "workerProfilePath": task.workerProfilePath as Any,
    "conversationId": task.conversationId as Any,
    "dispatchMarkerVerifiedAt": task.dispatchMarkerVerifiedAt as Any,
    "dispatchLocalConversationId": task.dispatchLocalConversationId as Any,
    "attachedConversationWithoutDispatchMarker": task.attachedConversationWithoutDispatchMarker ?? false,
    "reviewConversationId": task.reviewConversationId as Any,
    "reviewStatus": task.reviewStatus as Any,
    "chatUrl": task.chatURL as Any,
    "lastError": task.lastError as Any,
    "reviewFeedback": task.reviewFeedback as Any,
    "reviewedAt": task.reviewedAt as Any,
    "continuationDepth": task.continuationDepth ?? 0,
    "lastProgressAt": task.lastProgressAt as Any,
    "hiddenWorkerLastHeartbeatAt": task.hiddenWorkerLastHeartbeatAt as Any,
    "hiddenWorkerRecoveryCount": task.hiddenWorkerRecoveryCount ?? 0,
    "hiddenWorkerLastError": task.hiddenWorkerLastError as Any,
    "watchdogLastRecoveryAt": task.watchdogLastRecoveryAt as Any,
    "watchdogRecoveryCount": task.watchdogRecoveryCount ?? 0,
    "waitingUntil": task.waitingUntil as Any,
    "waitReason": task.waitReason as Any,
  ]
  if let updates = task.taskUpdates,
     let updatesData = try? encoder.encode(updates),
     let updatesObject = try? JSONSerialization.jsonObject(with: updatesData) {
    payload["taskUpdates"] = updatesObject
  }
  if let report = task.report,
     let reportData = try? encoder.encode(report),
     let reportObject = try? JSONSerialization.jsonObject(with: reportData) {
    payload["report"] = reportObject
  }
  if let report = task.reviewReport,
     let reportData = try? encoder.encode(report),
     let reportObject = try? JSONSerialization.jsonObject(with: reportData) {
    payload["reviewReport"] = reportObject
  }
  if let raw = task.lastResultJSON,
     let data = raw.data(using: .utf8),
     let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
    let reply = (result["reply"] as? [String: Any])
      ?? (result["reviewReply"] as? [String: Any])
    if let reply {
      payload["replyDiagnostics"] = [
        "kind": result["reviewReply"] == nil ? "reply" : "reviewReply",
        "hasCurrentDispatchMarker": result["hasCurrentDispatchMarker"] ?? NSNull(),
        "done": reply["done"] ?? NSNull(),
        "pending": reply["pending"] ?? NSNull(),
        "streaming": reply["streaming"] ?? NSNull(),
        "waitingForApproval": reply["waitingForApproval"] ?? NSNull(),
        "approvalTitle": reply["approvalTitle"] ?? NSNull(),
        "stopAvailable": reply["stopAvailable"] ?? NSNull(),
        "completionCandidate": reply["completionCandidate"] ?? NSNull(),
        "terminalIncomplete": reply["terminalIncomplete"] ?? NSNull(),
        "hasClosedTaskReport": reply["hasClosedTaskReport"] ?? NSNull(),
        "structuredComplete": reply["structuredComplete"] ?? NSNull(),
        "structuredIncomplete": reply["structuredIncomplete"] ?? NSNull(),
        "explicitlyIncomplete": reply["explicitlyIncomplete"] ?? NSNull(),
        "explicitFinalResult": reply["explicitFinalResult"] ?? NSNull(),
        "responseActions": reply["responseActions"] ?? NSNull(),
        "responseActionsComplete": reply["responseActionsComplete"] ?? NSNull(),
        "responseControlLabels": reply["responseControlLabels"] ?? NSNull(),
        "messageCount": reply["messageCount"] ?? NSNull(),
        "userMessageCount": reply["userMessageCount"] ?? NSNull(),
        "charCount": reply["charCount"] ?? NSNull(),
        "activityCharCount": reply["activityCharCount"] ?? NSNull(),
        "completedThinkingTitle": reply["completedThinkingTitle"] ?? NSNull(),
        "pageSnapshot": [
          "pageContent": reply["pageContent"] ?? NSNull(),
          "userContent": reply["userContent"] ?? NSNull(),
          "assistantContent": reply["content"] ?? NSNull(),
          "thinking": reply["thinking"] ?? NSNull(),
          "completedActivity": reply["completedActivity"] ?? NSNull(),
          "devspaceActivity": reply["devspaceActivity"] ?? NSNull(),
        ],
      ]
    }
  }
  if includeResult, let raw = task.lastResultJSON,
     let data = raw.data(using: .utf8),
     let result = try? JSONSerialization.jsonObject(with: data) {
    payload["result"] = result
  }
  return payload
}

func queueStatusPayload(_ state: PluginState) -> [String: Any] {
  let tasks = state.automationTasks ?? []
  let requestedMaxConcurrent = min(4, max(1, state.queueMaxConcurrent ?? 2))
  var counts: [String: Int] = [:]
  for task in tasks { counts[task.status, default: 0] += 1 }
  let attention = tasks.filter {
    ["awaiting_review", "blocked", "failed"].contains($0.status)
  }
  let workerRuntimeState: QueueTargetRuntimeState?
  let workerIsHidden: Bool
  let workerVisibilityVerified: Bool
  if queueUsesBackgroundWindow(state),
     let port = state.queueWorkerPort,
     let targetId = state.queueWorkerTargetId {
    let runtimeState = queueTargetRuntimeState(
      port: port,
      targetId: targetId,
      refreshLifecycle: false
    )
    workerRuntimeState = runtimeState
    workerIsHidden = runtimeState == .hidden
    workerVisibilityVerified = queueTargetStateIsUsableForQueue(
      runtimeState,
      workerMode: state.queueWorkerMode
    )
  } else {
    workerRuntimeState = nil
    workerIsHidden = false
    workerVisibilityVerified = false
  }
  let activeWorkers = tasks.filter { $0.status == "running" }.map { task in
    let runtimeState: QueueTargetRuntimeState? = {
      guard let port = task.workerPort, let targetId = task.workerTargetId else { return nil }
      return queueTargetRuntimeState(port: port, targetId: targetId, refreshLifecycle: false)
    }()
    return [
      "taskId": task.id,
      "port": task.workerPort as Any,
      "targetId": task.workerTargetId as Any,
      "conversationId": task.conversationId as Any,
      "runtimeState": runtimeState.map(queueTargetRuntimeStateName) ?? "not-started",
      "visibilityVerified": runtimeState.map {
        queueTargetStateIsUsableForQueue($0, workerMode: state.queueWorkerMode)
      } ?? false,
    ] as [String: Any]
  }
  return [
    "ok": true,
    "enabled": state.queueEnabled == true,
    "paused": state.queuePaused == true,
    "running": state.queueEnabled == true && watcherIsAlive(state.queueWatcherPid),
    "watcherPid": state.queueWatcherPid as Any,
    "maxConcurrent": requestedMaxConcurrent,
    "effectiveMaxConcurrent": requestedMaxConcurrent,
    "requestedMaxConcurrent": requestedMaxConcurrent,
    "executionMode": "parallel-chat-windows",
    "targetMode": state.queueWorkerMode ?? "not-started",
    "network": [
      "status": state.queueNetworkStatus ?? "unknown",
      "lastError": state.queueNetworkLastError as Any,
      "failureCount": state.queueNetworkFailureCount ?? 0,
      "waitingUntil": state.queueNetworkWaitUntil as Any,
    ],
    "workerProcess": [
      "port": state.queueWorkerPort as Any,
      "targetId": state.queueWorkerTargetId as Any,
      "profilePath": state.queueWorkerProfilePath as Any,
      "mode": state.queueWorkerMode as Any,
      "sharedProcess": queueUsesBackgroundWindow(state)
        && state.queueWorkerMode != parallelDedicatedProcessQueueWorkerMode,
      "sameApplicationProcess": queueUsesBackgroundWindow(state)
        && state.queueWorkerMode != parallelDedicatedProcessQueueWorkerMode,
      "isolatedFromVisiblePage": workerIsHidden,
      "visibilityVerified": workerVisibilityVerified,
      "runtimeState": workerRuntimeState.map(queueTargetRuntimeStateName) ?? "not-started",
      "separateApplicationProcess":
        state.queueWorkerMode == parallelDedicatedProcessQueueWorkerMode,
    ],
    "activeWorkers": activeWorkers,
    "watcherTrace": queueTraceTail(),
    "reviewGate": state.queueReviewGate != false,
    "counts": counts,
    "tasks": tasks.map { taskPublicPayload($0) },
    "attention": attention.map { taskPublicPayload($0, includeResult: true) },
    "recoverable": true,
    "statePath": queueStateURL().path,
  ]
}

func startQueueWatcher(_ state: inout PluginState) throws {
  cleanupOrphanedDedicatedTaskWorkerArtifacts(state)
  if watcherIsAlive(state.queueWatcherPid),
     state.queueRuntimeRevision == currentQueueRuntimeRevision { return }
  if watcherIsAlive(state.queueWatcherPid), let pid = state.queueWatcherPid {
    kill(pid, SIGTERM)
    Thread.sleep(forTimeInterval: 0.1)
  }
  let process = Process()
  process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
  process.arguments = ["queue_watch"]
  process.standardInput = FileHandle.nullDevice
  process.standardOutput = FileHandle.nullDevice
  process.standardError = FileHandle.nullDevice
  var environment = ProcessInfo.processInfo.environment
  environment["CHATGPT_AUTO_CONFIRM_STATE"] = queueStateURL().path
  environment["CHATGPT_AUTO_CONFIRM_QUEUE_STATE"] = queueStateURL().path
  // A local queue watcher is allowed to reuse its controller only when the
  // general confirmer has already proved that exact renderer is plugin-owned
  // and is a real Chat surface. Visibility is telemetry, not the ownership
  // decision, so local retries do not depend on a hidden-only environment flag.
  let approvalState = generalApprovalStateForQueue()
  let backgroundPort = state.backgroundAppPort ?? approvalState?.backgroundAppPort
  let backgroundTargetId = state.backgroundChatTargetId
    ?? approvalState?.backgroundChatTargetId
  let verifiedBackgroundController = approvalState?.enabled == true
    && approvalState?.backgroundAppPort == backgroundPort
    && approvalState?.backgroundChatTargetId == backgroundTargetId
    && approvalState?.backgroundProfilePath != nil
  if let backgroundPort, let backgroundTargetId,
     verifiedBackgroundController,
     CDPClient.fetchTargets(portOverride: backgroundPort).contains(where: {
       $0["id"] as? String == backgroundTargetId
         && ($0["url"] as? String ?? "").hasPrefix("app://-/index.html")
     }) {
    environment["CHATGPT_AUTO_CONFIRM_HEADLESS"] = "1"
  }
  process.environment = environment
  try process.run()
  state.queueWatcherPid = process.processIdentifier
  state.queueRuntimeRevision = currentQueueRuntimeRevision
}
