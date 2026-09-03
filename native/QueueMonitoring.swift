import ApplicationServices
import Cocoa
import Darwin
import Foundation
import SystemConfiguration

let queueChatStagnationTimeoutSeconds = 10_800
let queueChatStartTimeoutSeconds = 300

func taskReportIsFullyComplete(_ report: AutomationTaskReport) -> Bool {
  report.status == "complete"
    && report.allTasksComplete == true
    && report.remaining.isEmpty
    && report.blockers.isEmpty
    && (report.waitSeconds ?? 0) == 0
    && report.nextTask.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}


func taskReportFingerprint(_ report: AutomationTaskReport) -> String {
  [report.summary, report.remaining.joined(separator: "\n"),
   report.blockers.joined(separator: "\n"), report.nextTask]
    .joined(separator: "|")
    .lowercased()
    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
}

func approvalDiagnosticToken(_ value: String) -> String {
  let normalized = value.replacingOccurrences(
    of: "[^A-Za-z0-9_-]+",
    with: "-",
    options: .regularExpression
  )
  return String(normalized.prefix(80)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
}

func approvalDetectionTraceFields(_ detection: [String: Any]?) -> String {
  guard let detection else {
    return "detection=none"
  }
  let details = jsonString([
    "candidateLabels": detection["candidateLabels"] ?? [],
    "cardButtonLabels": detection["cardButtonLabels"] ?? [],
    "sessionScopeLabels": detection["sessionScopeLabels"] ?? [],
    "menuTriggerLabels": detection["menuTriggerLabels"] ?? [],
    "menuTriggerCount": detection["menuTriggerCount"] ?? 0,
    "cardFingerprint": detection["cardFingerprint"] ?? "",
    "requestIdentityAvailable": detection["requestIdentityAvailable"] ?? false,
    "unlabeledControlCount": detection["unlabeledControlCount"] ?? 0,
  ]) ?? "{}"
  return "detection=\(details)"
}

func traceQueueApproval(
  _ result: [String: Any]?,
  taskId: String,
  stage: String,
  detection: [String: Any]? = nil,
  screenshotPath: String? = nil
) {
  guard let result else { return }
  guard result["clicked"] as? Bool == true
          || result["error"] as? String != nil else { return }
  let candidates = jsonString([
    "labels": result["candidateLabels"] ?? [],
    "menuTriggerLabel": result["menuTriggerLabel"] ?? "",
    "sessionScopeLabel": result["sessionScopeLabel"] ?? "",
    "menuCandidates": result["menuCandidates"] ?? [],
  ]) ?? "{\"labels\":[]}"
  queueTrace(
    "task=\(taskId) stage=approval-\(stage) "
      + "strategy=\(result["strategy"] as? String ?? "per-card") "
      + "clicked=\(result["clicked"] as? Bool == true) "
      + "confirmed=\(result["confirmed"] as? Bool == true) "
      + "label=\(result["label"] as? String ?? "none") "
      + "error=\(result["error"] as? String ?? "none") "
      + "screenshot=\(screenshotPath ?? "none") "
      + "candidates=\(candidates) "
      + approvalDetectionTraceFields(detection)
  )
}

@discardableResult
func approveDedicatedAuthorizationWithDiagnostics(
  port: Int,
  targetId: String,
  task: inout AutomationTask,
  state: inout PluginState,
  stage: String
) -> [String: Any]? {
  let taskId = task.id
  let detection = cdpValue(
    port: port,
    targetId: targetId,
    expression: detectDedicatedAuthorizationJS(),
    timeout: 4.0
  )
  guard detection?["found"] as? Bool == true else { return nil }

  let currentDate = Date()
  let now = isoFormatter.string(from: currentDate)
  let fingerprint = approvalFingerprint(detection)
  if let fingerprint,
     (task.handledApprovalFingerprints ?? []).contains(fingerprint) {
    // ChatGPT Desktop can remount a card after the confirmed click even
    // though the underlying authorization already succeeded. A confirmed
    // fingerprint is terminal for this queue task: never click it again and
    // never pause otherwise healthy work because of the renderer ghost.
    task.lastError = nil
    task.updatedAt = now
    queueTrace(
      "task=\(taskId) stage=approval-\(stage)-ignored "
        + "reason=confirmed-renderer-ghost fingerprint=\(fingerprint)"
    )
    return [
      "ok": true,
      "clicked": false,
      "confirmed": false,
      "skipped": true,
      "error": "confirmed_approval_renderer_ghost_ignored",
    ]
  }

  let recentApprovals = prunedAutomaticApprovalTimestamps(
    task.automaticApprovalTimestamps,
    now: currentDate
  )
  task.automaticApprovalTimestamps = recentApprovals
  if recentApprovals.count >= maxAutomaticApprovalsPerWindow {
    state.queuePaused = true
    task.status = "blocked"
    task.lastError = "approval_rate_circuit_open"
    task.updatedAt = now
    task.finishedAt = now
    queueTrace(
      "task=\(taskId) stage=approval-\(stage)-blocked "
        + "reason=rate count=\(recentApprovals.count) "
        + "window=\(Int(automaticApprovalWindowSeconds))"
    )
    return [
      "ok": false,
      "clicked": false,
      "confirmed": false,
      "skipped": true,
      "circuitOpen": true,
      "error": "approval_rate_circuit_open",
    ]
  }

  let safeTask = approvalDiagnosticToken(taskId)
  let safeStage = approvalDiagnosticToken(stage)
  let screenshotPath = captureHiddenChatScreenshot(
    port: port,
    targetId: targetId,
    label: "approval-\(safeTask)-\(safeStage)-before"
  )
  queueTrace(
    "task=\(taskId) stage=approval-\(stage)-detected strategy=per-card "
      + "selected=\(detection?["selectedLabel"] as? String ?? "none") "
      + "screenshot=\(screenshotPath ?? "none") "
      + approvalDetectionTraceFields(detection)
  )

  var result = cdpValue(
    port: port,
    targetId: targetId,
    expression: autoApproveDedicatedAuthorizationJS(),
    timeout: 8.0
  )
  if result?["clicked"] as? Bool == true,
     result?["confirmed"] as? Bool == true,
     let fingerprint {
    recordHandledApprovalFingerprint(
      fingerprint,
      fingerprints: &task.handledApprovalFingerprints,
      fingerprintAttempts: &task.automaticApprovalFingerprintAttempts,
      timestamps: &task.automaticApprovalTimestamps,
      lastFingerprint: &task.lastAutomaticApprovalFingerprint,
      lastApprovedAt: &task.lastAutomaticApprovalAt,
      now: currentDate
    )
    result?["cardFingerprint"] = fingerprint
  }
  traceQueueApproval(
    result,
    taskId: taskId,
    stage: stage,
    detection: detection,
    screenshotPath: screenshotPath
  )

  if result?["clicked"] as? Bool != true || result?["confirmed"] as? Bool != true {
    let afterPath = captureHiddenChatScreenshot(
      port: port,
      targetId: targetId,
      label: "approval-\(safeTask)-\(safeStage)-after"
    )
    queueTrace(
      "task=\(taskId) stage=approval-\(stage)-unconfirmed "
        + "strategy=\(result?["strategy"] as? String ?? "per-card") "
        + "beforeScreenshot=\(screenshotPath ?? "none") "
        + "afterScreenshot=\(afterPath ?? "none") "
        + "error=\(result?["error"] as? String ?? "none")"
    )
  }
  return result
}

func queueContinuation(
  _ task: inout AutomationTask,
  report: AutomationTaskReport?,
  reason: String
) {
  writeQueueConversationDiagnostic(task, finalReason: reason)
  let currentDate = Date()
  let now = isoFormatter.string(from: currentDate)
  let depth = task.continuationDepth ?? 0
  let roundElapsedSeconds = task.startedAt
    .flatMap(isoFormatter.date(from:))
    .map { max(0, Int(currentDate.timeIntervalSince($0))) } ?? 0
  // Keep depth for diagnostics, but do not use it as a lifetime limit. A
  // fixed continuation budget makes every otherwise healthy 24-hour queue
  // eventually stop merely because it crossed enough Chat boundaries.
  queueTrace(
    "task=\(task.id) stage=continuation-queued reason=\(reason) "
      + "depth=\(depth) nextDepth=\(depth + 1) "
      + "reportStatus=\(report?.status ?? "none")"
  )
  if let report {
    if let requestedConnector = normalizedConnector(report.nextConnector) {
      task.connector = requestedConnector
    }
    let fingerprint = taskReportFingerprint(report)
    var fingerprints = task.reportFingerprints ?? []
    fingerprints.append(fingerprint)
    task.reportFingerprints = Array(fingerprints.suffix(100))
    let requestedWait = min(604_800, max(0, report.waitSeconds ?? 0))
    let waitReason = (report.waitReason ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    task.reviewFeedback = "上一个 Chat 报告任务未完成。请从同一 checkout 的现有进度继续，完成以下续作，不要从头开始：\n\(report.nextTask)\n\n上轮摘要：\(report.summary)\n剩余：\(report.remaining.joined(separator: "；"))\n卡点：\(report.blockers.joined(separator: "；"))"
    if requestedWait > 0 {
      let dueDate = Date().addingTimeInterval(Double(max(30, requestedWait)))
      task.waitingUntil = isoFormatter.string(from: dueDate)
      task.waitReason = waitReason
      task.reviewFeedback = (task.reviewFeedback ?? "")
        + "\n\n上一轮预计需要等待 \(requestedWait) 秒（\(waitReason)）。小程序已等待到期；现在请先复查外部结果，再继续未完成步骤。"
      task.status = "waiting"
      task.lastError = "waiting_for_external_result"
    } else {
      task.waitingUntil = nil
      task.waitReason = nil
      task.status = "queued"
      task.lastError = reason
    }
  } else {
    task.reviewFeedback = "上一个 Chat 没有给出有效的最终完成证书（\(reason)）。请在新的 Chat 中重新读取同一 GitHub 仓库的项目文档和已落盘进度，只补做剩余步骤。只有整个项目全部完成时才输出唯一完成证书；否则不要输出报告模板。"
    task.waitingUntil = nil
    task.waitReason = nil
    task.status = "queued"
    task.lastError = reason
  }
  task.continuationDepth = depth + 1
  task.updatedAt = now
  task.startedAt = nil
  task.finishedAt = nil
  task.workerPid = nil
  task.report = nil
  task.reviewConversationId = nil
  task.reviewStatus = nil
  task.reviewReport = nil
  task.lastActivitySignature = nil
  task.lastProgressAt = nil

  // Fast terminal replies are usually inspection-only rounds. Do not flood
  // ChatGPT with another branch immediately: require a minimum productive
  // window and add a bounded repetition penalty for consecutive shallow
  // handoffs. Renderer/navigation recovery reasons remain immediate.
  let shallowTerminalReasons = [
    "unfinished_reply_missing_continuation_report",
    "terminal_reply_missing_task_report",
    "chat_finished_incomplete",
    "chat_finished_blocked",
  ]
  if shallowTerminalReasons.contains(reason), task.status == "queued" {
    let productiveFloor = 600
    let remainingFloor = max(60, productiveFloor - roundElapsedSeconds)
    let repetitionPenalty = min(1_800, max(0, depth - 1) * 30)
    let delay = max(remainingFloor, repetitionPenalty)
    task.status = "waiting"
    task.waitingUntil = isoFormatter.string(
      from: currentDate.addingTimeInterval(Double(delay))
    )
    task.waitReason = "本轮仅运行 \(roundElapsedSeconds) 秒且任务未完成；退避约 \(delay) 秒后继续，避免快速空转与限流"
    task.lastError = "waiting_after_short_unfinished_round"
    queueTrace(
      "task=\(task.id) stage=continuation-backoff elapsed=\(roundElapsedSeconds)s "
        + "delay=\(delay)s depth=\(depth) reason=\(reason)"
    )
  }
}

func automationTaskRevisionIsCurrent(
  _ task: AutomationTask,
  report: AutomationTaskReport?
) -> Bool {
  let currentRevision = max(1, task.currentRevision ?? 1)
  let currentDigest = task.specDigest ?? ""
  if let report {
    guard report.taskId == task.id,
          let appliedRevision = report.appliedTaskRevision,
          let appliedDigest = report.appliedSpecDigest else { return false }
    return currentRevision == appliedRevision && currentDigest == appliedDigest
  }
  return currentRevision == max(1, task.appliedRevision ?? 1)
    && currentDigest == (task.appliedSpecDigest ?? "")
}

func deferAutomationTaskForWorkerRecovery(
  _ task: inout AutomationTask,
  state: inout PluginState,
  reason: String
) {
  let recoveryCount = min(10, (task.hiddenWorkerRecoveryCount ?? 0) + 1)
  let delay = min(300, 15 * (1 << min(4, recoveryCount - 1)))
  let now = isoFormatter.string(from: Date())
  task.status = "waiting"
  task.waitingUntil = isoFormatter.string(
    from: Date().addingTimeInterval(Double(delay))
  )
  task.waitReason = "隐藏 Chat worker 自动恢复：\(reason)；约 \(delay) 秒后重试"
  task.lastError = "waiting_for_queue_worker_recovery"
  task.hiddenWorkerLastError = reason
  task.hiddenWorkerRecoveryCount = recoveryCount
  task.startedAt = nil
  task.finishedAt = nil
  task.workerPid = nil
  task.workerPort = nil
  task.workerTargetId = nil
  task.workerStatePath = nil
  task.workerProfilePath = nil
  task.lastActivitySignature = nil
  task.lastProgressAt = nil
  task.updatedAt = now
  task.reviewFeedback = [
    task.reviewFeedback,
    "隐藏 Chat worker 已由本地守护器自动重建。请从同一 checkout 的最新落盘进度继续，不要从头开始或重复已完成步骤。",
  ].compactMap { $0 }.joined(separator: "\n\n")
  state.queuePaused = false
  queueTrace(
    "task=\(task.id) stage=worker-recovery-deferred "
      + "reason=\(reason) delay=\(delay)s count=\(recoveryCount)"
  )
}

func monitorAutomationTask(
  _ task: inout AutomationTask,
  state: inout PluginState
) {
  let monitoringReview = task.reviewStatus == "running"
  let activeConversationId = monitoringReview ? task.reviewConversationId : task.conversationId
  guard let conversationId = activeConversationId else {
    queueContinuation(&task, report: nil, reason: "missing_conversation_id")
    return
  }
  // Do not restore the background queue renderer before its current page is read. A new
  // Chat may receive a durable remote id before the virtualized body/sidebar
  // has caught up; the dispatch marker below is the reliable proof that the
  // visible page is still this task. Manual conversation drift is handled
  // after that marker check, without blocking a just-sent response.
  state.approveAll = true
  var workerPort = task.workerPort ?? state.queueWorkerPort
  var workerTargetId = task.workerTargetId ?? state.queueWorkerTargetId
  if workerPort == nil || workerTargetId == nil {
    if let recoveredWorker = createIndependentQueueWorkerTarget(&state, accountId: task.accountId) {
      workerPort = recoveredWorker.port
      workerTargetId = recoveredWorker.targetId
      task.workerPort = recoveredWorker.port
      task.workerTargetId = recoveredWorker.targetId
      task.workerProfilePath = recoveredWorker.profilePath
      task.hiddenWorkerRecoveryCount = (task.hiddenWorkerRecoveryCount ?? 0) + 1
      task.hiddenWorkerLastError = nil
    }
  }
  guard let initialPort = workerPort, let initialTargetId = workerTargetId else {
    deferAutomationTaskForWorkerRecovery(
      &task,
      state: &state,
      reason: "queue_monitor_requires_background_window"
    )
    return
  }
  var port = initialPort
  var targetId = initialTargetId
  var runtimeState = queueTargetRuntimeState(
    port: port,
    targetId: targetId,
    refreshLifecycle: true
  )
  if runtimeState == .hiddenNonChat {
    // A hidden prewarm page may survive an internal app reload on Work. Ask
    // that hidden page to return to Chat before treating the renderer as lost.
    let chatSelection = cdpValue(
      port: port,
      targetId: targetId,
      expression: clickChatJS(),
      timeout: 4.0
    )
    _ = dispatchRecommendedCDPClick(
      chatSelection,
      port: port,
      targetId: targetId
    )
    runtimeState = queueTargetRuntimeState(
      port: port,
      targetId: targetId,
      refreshLifecycle: true
    )
  }
  let workerStateUsable = queueTargetStateIsUsableForQueue(
    runtimeState,
    workerMode: state.queueWorkerMode
  )
  // The local fallback uses the primary renderer of a separate queue-owned
  // ChatGPT process. Electron can report that document as `visible` after an
  // approval-card remount even though the background application and profile
  // remain isolated from the user's visible ChatGPT process. Accept this
  // narrow ownership match; never broaden visible-page access to another
  // profile, port, target, or worker mode.
  let queueOwnedSharedControllerVisible = runtimeState == .visible
    && state.queueWorkerMode == sharedConversationQueueWorkerMode
    && port == state.backgroundAppPort
    && targetId == state.backgroundChatTargetId
    && task.workerPort == port
    && task.workerTargetId == targetId
    && task.workerProfilePath == state.backgroundProfilePath
    && state.queueWorkerProfilePath == state.backgroundProfilePath
    && state.backgroundProfilePath == hiddenChatProfilePath()
  let effectiveWorkerStateUsable = workerStateUsable || queueOwnedSharedControllerVisible
  if queueOwnedSharedControllerVisible {
    queueTrace("task=\(task.id) stage=queue-owned-shared-controller-visible-accepted")
  }
  if !effectiveWorkerStateUsable {
    if runtimeState == .visible {
      // Safety remains fail-closed for every visible renderer that does not
      // exactly match the queue-owned background controller above.
      let now = isoFormatter.string(from: Date())
      state.queuePaused = true
      task.status = "blocked"
      task.hiddenWorkerLastError = "queue_worker_visibility_not_hidden"
      task.lastError = task.hiddenWorkerLastError
      task.updatedAt = now
      task.finishedAt = now
      return
    }

    // Missing, suspended, and hidden-but-not-Chat renderers are disposable
    // queue-owned pages. Close any stale target, recreate ChatGPT's official
    // show:false prewarm BrowserWindow, and verify hidden Chat again.
    let failedRuntimeState = queueTargetRuntimeStateName(runtimeState)
    closeDedicatedAutomationTarget(task, state: state)
    let recoveredWorker: (port: Int, targetId: String, profilePath: String)?
    if task.accountId == nil {
      recoveredWorker = createIndependentQueueWorkerTarget(&state)
    } else {
      recoveredWorker = createIndependentQueueWorkerTarget(&state, accountId: task.accountId)
    }
    guard let recoveredWorker else {
      deferAutomationTaskForWorkerRecovery(
        &task,
        state: &state,
        reason: "queue_monitor_hidden_target_rebuild_failed:\(failedRuntimeState)"
      )
      return
    }
    port = recoveredWorker.port
    targetId = recoveredWorker.targetId
    task.workerPort = recoveredWorker.port
    task.workerTargetId = recoveredWorker.targetId
    task.workerProfilePath = recoveredWorker.profilePath
    task.hiddenWorkerRecoveryCount = (task.hiddenWorkerRecoveryCount ?? 0) + 1

    if conversationId.hasPrefix("local-chatgpt:") {
      // A reclaimed local-only Chat has no durable route to restore. The page
      // is already rebuilt and verified hidden; continue the task in a fresh
      // Chat that explicitly resumes from the same checkout instead of waiting
      // forever on an identity that no longer exists.
      task.hiddenWorkerLastError = "queue_monitor_hidden_target_recreated_without_durable_conversation"
      queueContinuation(
        &task,
        report: nil,
        reason: "queue_monitor_hidden_target_recreated_without_durable_conversation"
      )
      return
    }

    let restoration = restoreHiddenConversation(
      port: port,
      targetId: targetId,
      conversationId: conversationId,
      allowVisible: queueTargetStateIsUsableForQueue(
        .visible,
        workerMode: state.queueWorkerMode
      )
    )
    let restored = restoration["ok"] as? Bool == true
    runtimeState = queueTargetRuntimeState(
      port: port,
      targetId: targetId,
      refreshLifecycle: true
    )
    guard restored,
          queueTargetStateIsUsableForQueue(
            runtimeState,
            workerMode: state.queueWorkerMode
          ) else {
      closeDedicatedAutomationTarget(task, state: state)
      task.hiddenWorkerLastError = "queue_monitor_hidden_target_recovery_failed"
      queueContinuation(
        &task,
        report: nil,
        reason: "queue_monitor_hidden_target_recovery_failed"
      )
      return
    }
  }
  task.hiddenWorkerLastHeartbeatAt = isoFormatter.string(from: Date())
  task.hiddenWorkerLastError = nil
  // A permission card can replace the normal conversation body temporarily.
  // Confirm it before restoring a task through its exact hidden-page route, so
  // an unloaded conversation cannot suppress automatic authorization.
  let now = isoFormatter.string(from: Date())
  let approval = approveDedicatedAuthorizationWithDiagnostics(
    port: port,
    targetId: targetId,
    task: &task,
    state: &state,
    stage: "before-read"
  )
  if approval?["circuitOpen"] as? Bool == true || task.status == "blocked" {
    return
  }
  // The authorization card is replaced asynchronously after a confirmed
  // decision. Reading the conversation during that renderer transition can
  // fail even though the click succeeded, which used to leave a false
  // queue_monitor_cdp_failed error and immediately poll the next card. Treat
  // the confirmed authorization itself as progress and resume normal
  // conversation monitoring on the next queue tick.
  if approval?["clicked"] as? Bool == true,
     approval?["confirmed"] as? Bool == true {
    task.lastError = nil
    task.lastProgressAt = now
    task.updatedAt = now
    return
  }
  let statusRead = cdpValueRead(
    port: port,
    targetId: targetId,
    expression: chatStatusJS(),
    timeout: 5.0
  )
  guard var liveStatus = statusRead.value else {
    queueTrace(
      "task=\(task.id) stage=monitor-cdp-failed read=chat-status "
        + "port=\(port) target=\(targetId) "
        + "error=\(statusRead.error ?? "unknown")"
    )
    task.lastError = "queue_monitor_cdp_failed"
    task.updatedAt = isoFormatter.string(from: Date())
    return
  }
  let replyRead = cdpValueRead(
    port: port,
    targetId: targetId,
    expression: getReplyJS(),
    timeout: 6.0
  )
  guard var reply = replyRead.value else {
    queueTrace(
      "task=\(task.id) stage=monitor-cdp-failed read=reply "
        + "port=\(port) target=\(targetId) "
        + "error=\(replyRead.error ?? "unknown")"
    )
    task.lastError = "queue_monitor_cdp_failed"
    task.updatedAt = now
    return
  }
  let confirmedApprovalGhost = approval?["error"] as? String
    == "confirmed_approval_renderer_ghost_ignored"
  if confirmedApprovalGhost,
     reply["stopAvailable"] as? Bool != true {
    // The user-approved request already succeeded; a remounted card is only a
    // renderer ghost. Do not let it manufacture permanent streaming/pending
    // state. The visible assistant result can now be evaluated normally and,
    // if incomplete, handed to the continuation backoff.
    reply["waitingForApproval"] = false
    reply["devspaceWaiting"] = false
    reply["streaming"] = false
    reply["pending"] = false
    if reply["explicitFinalResult"] as? Bool == true {
      reply["done"] = true
    }
  }
  let dispatchMarker = monitoringReview
    ? "验收 Chat 标识：\(task.id)-\(task.attempts)-\(task.reviewRound)"
    : "任务发送轮次：\(task.attempts)"
  let currentPageContent = [
    reply["pageContent"] as? String ?? "",
    reply["userContent"] as? String ?? "",
  ].joined(separator: "\n")
  let hasCurrentDispatchMarker = currentPageContent.contains(dispatchMarker)
  if hasCurrentDispatchMarker,
     let resolved = cdpValue(
       port: port,
       targetId: targetId,
       expression: resolveDispatchedConversationJS(
         dispatchMarker: dispatchMarker,
         localConversationId: normalizedConversationId(
           monitoringReview ? task.reviewConversationId : task.conversationId
         )
       ),
       timeout: 8.0
     ),
     let durableConversationId = normalizedConversationId(resolved["conversationId"] as? String) {
    if monitoringReview {
      task.reviewConversationId = durableConversationId
    } else if task.conversationId != durableConversationId {
      task.conversationId = durableConversationId
      task.chatURL = "https://chatgpt.com/c/\(durableConversationId)"
      queueTrace(
        "task=\(task.id) stage=monitor-promoted-dispatch-conversation "
          + "conversation=\(durableConversationId)"
      )
    }
    liveStatus["conversationId"] = durableConversationId
  }
  let observedConversationId = normalizedConversationId(
    liveStatus["conversationId"] as? String
  )
  let verifiedDispatchConversationBinding = !monitoringReview
    && task.dispatchMarkerVerifiedAt != nil
    && (observedConversationId == conversationId
      || observedConversationId == normalizedConversationId(task.dispatchLocalConversationId))
  let attachedConversationBinding = !monitoringReview
    && task.attachedConversationWithoutDispatchMarker == true
    && (observedConversationId == conversationId
      || observedConversationId == normalizedConversationId(task.dispatchLocalConversationId))
  let hasCurrentDispatchEvidence = hasCurrentDispatchMarker
    || verifiedDispatchConversationBinding
    || attachedConversationBinding
  let terminalDecision = queueReplyTerminalDecision(reply)
  let replyIsActivelyResponding = reply["streaming"] as? Bool == true
    || reply["stopAvailable"] as? Bool == true
    || reply["waitingForApproval"] as? Bool == true
    || reply["devspaceWaiting"] as? Bool == true
  let replyIsPending = reply["pending"] as? Bool == true
  let responseIsInFlight = terminalDecision.responseIsInFlight
  let dispatchAge = task.startedAt
    .flatMap(isoFormatter.date(from:))
    .map { Date().timeIntervalSince($0) } ?? 0
  let observedActivitySignature = reply["activitySignature"] as? String ?? ""
  if responseIsInFlight,
     !observedActivitySignature.isEmpty,
     observedActivitySignature != task.lastActivitySignature {
    task.lastActivitySignature = observedActivitySignature
    task.lastProgressAt = now
  }
  // The hidden queue renderer can still drift after an internal reload. Never
  // parse a stale page as the active task or create a continuation/review Chat
  // from it. Restoring here is safe because this process has no user composer.
  if let observed = observedConversationId,
     observed != conversationId,
     !verifiedDispatchConversationBinding,
     !attachedConversationBinding {
    // In the desktop app the active conversation pane can be rendered outside
    // `<main>`, while `<main>` contains only the title/share chrome. Include
    // the scoped user bubbles so a freshly sent dispatch marker is not missed.
    if hasCurrentDispatchMarker {
      // ChatGPT may replace the local id with its durable remote id after the
      // first response begins. The per-dispatch marker proves this is still
      // the current Chat, not a manually selected older attempt.
      // A virtualized sidebar can keep an older row marked current while the
      // new local Chat is already streaming. Only a route/portal identity is
      // authoritative enough to replace that local id; an active-row-only id
      // must not bind the task to the stale sidebar conversation.
      let identitySource = liveStatus["conversationSource"] as? String
      let canPromoteLocalId = !observed.hasPrefix("local-chatgpt:")
        && (!conversationId.hasPrefix("local-chatgpt:")
          || identitySource == "route"
          || identitySource == "portal")
      if canPromoteLocalId {
        if !monitoringReview {
          task.conversationId = observed
          task.chatURL = liveStatus["chatUrl"] as? String
        } else {
          task.reviewConversationId = observed
        }
      }
    } else {
      // A just-created Chat starts with a local id while ChatGPT replaces the
      // sidebar and body asynchronously. It is not evidence of a manual
      // switch. Wait for the dispatch marker instead of pausing every queued
      // task; recover in one fresh Chat only if that binding never arrives.
      // Never navigate away from or close a renderer while ChatGPT is still
      // responding. Closing the hidden target cancels the server-side stream
      // and is exactly what users see as an automatically stopped reply.
      if responseIsInFlight || dispatchAge < 300 {
        let pendingReason = responseIsInFlight
          ? "queue_monitor_conversation_marker_active"
          : "queue_monitor_conversation_marker_grace"
        if task.lastError != pendingReason {
          queueTrace(
            "task=\(task.id) stage=monitor-pending reason=\(pendingReason) "
              + "expectedConversation=\(conversationId) observedConversation=\(observed) "
              + "dispatchAge=\(Int(dispatchAge)) streaming=\(replyIsActivelyResponding) "
              + "pending=\(replyIsPending) stopAvailable=\(reply["stopAvailable"] as? Bool == true) "
              + "userMessages=\(reply["userMessageCount"] as? Int ?? 0)"
          )
        }
        task.lastError = pendingReason
        task.updatedAt = now
        return
      }
      if conversationId.hasPrefix("local-chatgpt:") {
        queueContinuation(&task, report: nil, reason: "fresh_chat_body_pending_timeout")
        return
      }
      let restoredOK = navigateHiddenConversation(
        port: port,
        targetId: targetId,
        conversationId: conversationId,
        allowVisible: queueTargetStateIsUsableForQueue(
          .visible,
          workerMode: state.queueWorkerMode
        )
      )
      if restoredOK,
         let statusAfterRestore = cdpValue(
           port: port, targetId: targetId, expression: chatStatusJS(), timeout: 5.0),
         let restoredId = normalizedConversationId(statusAfterRestore["conversationId"] as? String),
         restoredId == conversationId {
        liveStatus = statusAfterRestore
      } else {
        // This hidden renderer is owned solely by the queue, so a failed
        // restore is a disposable renderer fault rather than user navigation.
        // Recreate it inside the same app process and continue from checkout.
        closeDedicatedAutomationTarget(task, state: state)
        queueContinuation(&task, report: nil, reason: "queue_monitor_conversation_drift")
        return
      }
    }
  }
  // ChatGPT can publish the new conversation id before replacing the
  // virtualized body. Never parse an older response as this dispatch merely
  // because the route/id already matches. The user-message marker is the
  // durable proof that the body belongs to the current queue attempt.
  if !hasCurrentDispatchEvidence {
    let markerError = responseIsInFlight
      ? "queue_monitor_current_dispatch_marker_active"
      : "queue_monitor_current_dispatch_marker_pending"
    if task.lastError != markerError {
      queueTrace(
        "task=\(task.id) stage=monitor-pending reason=\(markerError) "
          + "conversation=\(conversationId) expectedMarker=\(dispatchMarker) "
          + "dispatchAge=\(Int(dispatchAge)) streaming=\(replyIsActivelyResponding) "
          + "pending=\(replyIsPending) stopAvailable=\(reply["stopAvailable"] as? Bool == true) "
          + "userMessages=\(reply["userMessageCount"] as? Int ?? 0) "
          + "userContentChars=\((reply["userContent"] as? String ?? "").count)"
      )
    }
    task.lastError = markerError
    task.updatedAt = now
    task.lastResultJSON = jsonString([
      "reply": reply,
      "conversationId": conversationId,
      "chatUrl": task.chatURL as Any,
      "expectedDispatchMarker": dispatchMarker,
      "hasCurrentDispatchMarker": false,
    ])
    if !responseIsInFlight, dispatchAge >= 300 {
      closeDedicatedAutomationTarget(task, state: state)
      queueContinuation(
        &task,
        report: nil,
        reason: "current_dispatch_marker_timeout"
      )
    }
    return
  }
  let chatContinuation = cdpValue(
    port: port,
    targetId: targetId,
    expression: autoConfirmChatContinuationJS(),
    timeout: 4.0
  )
  let chatContinuationDispatched = dispatchRecommendedCDPClick(
    chatContinuation,
    port: port,
    targetId: targetId
  )
  if chatContinuation?["clicked"] as? Bool == true {
    Thread.sleep(forTimeInterval: 0.6)
    let continuationStatus = cdpValue(
      port: port,
      targetId: targetId,
      expression: chatStatusJS(),
      timeout: 5.0
    )
    let surface = continuationStatus?["surface"] as? String ?? "unknown"
    let chatMode = continuationStatus?["chatMode"] as? Bool == true
    queueTrace(
      "task=\(task.id) stage=chat-continuation "
        + "dispatched=\(chatContinuationDispatched) surface=\(surface) chatMode=\(chatMode)"
    )
    guard chatContinuationDispatched, surface == "chat", chatMode else {
      let screenshot = captureHiddenChatScreenshot(
        port: port,
        targetId: targetId,
        label: "chat-surface-drift"
      )
      state.queuePaused = true
      task.status = "blocked"
      task.lastError = "chat_surface_drift"
      task.updatedAt = now
      task.finishedAt = now
      queueTrace(
        "task=\(task.id) stage=chat-continuation-blocked "
          + "reason=chat_surface_drift screenshot=\(screenshot ?? "none")"
      )
      return
    }
    task.lastProgressAt = now
  }
  let afterReadApproval = approveDedicatedAuthorizationWithDiagnostics(
    port: port,
    targetId: targetId,
    task: &task,
    state: &state,
    stage: "after-read"
  )
  if afterReadApproval?["circuitOpen"] as? Bool == true || task.status == "blocked" {
    return
  }
  task.lastError = nil
  // A new local id is the authoritative identity. The sidebar can keep the
  // previous row marked current briefly, so never replace a local id with
  // transitional remote metadata from that stale row.
  if !monitoringReview && task.conversationId?.hasPrefix("local-chatgpt:") != true,
     let resolved = normalizedConversationId(liveStatus["conversationId"] as? String),
     !resolved.hasPrefix("local-chatgpt:") {
    task.conversationId = resolved
  }
  if !monitoringReview && task.conversationId?.hasPrefix("local-chatgpt:") != true,
     let chatURL = liveStatus["chatUrl"] as? String {
    task.chatURL = chatURL
  }
  let completedActivity = reply["completedActivity"] as? String ?? ""
  let visibleContent = reply["content"] as? String ?? ""
  let connectionText = [
    visibleContent,
    completedActivity,
    reply["devspaceActivity"] as? String ?? "",
    // `pageContent` also contains the queue's own user instruction, which
    // deliberately documents network errors. Inspect only assistant/tool
    // activity so the prompt can never trigger a false network outage.
    reply["thinking"] as? String ?? ""
  ].joined(separator: "\n")
  let recoverySignal = networkRecoverySignal(connectionText)
  let activitySignature = reply["activitySignature"] as? String ?? ""
  let activityCharCount = reply["activityCharCount"] as? Int ?? 0
  if !activitySignature.isEmpty && activitySignature != task.lastActivitySignature {
    task.lastActivitySignature = activitySignature
    // Page virtualization can temporarily replace the full task stream with
    // only the conversation title and Share/Sources chrome. Record the new
    // signature so it does not churn, but do not treat that regression as
    // real task progress or postpone interruption recovery.
    if activityCharCount >= 80 {
      task.lastProgressAt = now
      if recoverySignal == nil {
        state.queueNetworkFailureCount = 0
        state.queueNetworkStatus = "online"
        state.queueNetworkLastError = nil
        state.queueNetworkWaitUntil = nil
      }
    }
  }
  task.updatedAt = now
  task.lastResultJSON = jsonString([
    monitoringReview ? "reviewReply" : "reply": reply,
    "conversationId": conversationId,
    "chatUrl": task.chatURL as Any,
    "reviewConversationId": task.reviewConversationId as Any,
  ])
  writeQueueConversationDiagnostic(task)

  // A user bubble with no assistant/tool activity is not a long-running
  // connector operation: ChatGPT never started the turn. Recover after five
  // minutes. Once assistant/tool activity exists, the separate three-hour
  // stagnation window below still protects legitimately long operations.
  let hasAssistantActivity = (reply["messageCount"] as? Int ?? 0) > 0
    || !(reply["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    || !(reply["devspaceActivity"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  let isStreaming = reply["streaming"] as? Bool == true
  let isPending = reply["pending"] as? Bool == true
  if !hasAssistantActivity, !isStreaming, isPending,
     let lastProgressAt = task.lastProgressAt.flatMap(isoFormatter.date(from:)),
     Date().timeIntervalSince(lastProgressAt) >= Double(queueChatStartTimeoutSeconds) {
    queueContinuation(&task, report: nil, reason: "chat_start_no_reply")
    return
  }

  if let signal = recoverySignal {
    closeDedicatedAutomationTarget(task, state: state)
    queueNetworkRecovery(&task, state: &state, reason: signal)
    return
  }
  let reportText = completedActivity.isEmpty ? visibleContent : completedActivity
  let parsedReport = parseTaskReport(reportText).flatMap(automationReport)
  let parsedWait = parseTaskWait(reportText)
  let terminalIncomplete = terminalDecision.terminalIncomplete
  let terminal = terminalDecision.terminal
  let hasClosedTaskReport = reply["hasClosedTaskReport"] as? Bool == true
  if terminal, hasClosedTaskReport, parsedReport == nil {
    queueTrace(
      "task=\(task.id) stage=report-parse-failed action=continue "
        + "reason=closed_task_report_not_fully_complete"
    )
    closeDedicatedAutomationTarget(task, state: state)
    queueContinuation(
      &task,
      report: nil,
      reason: "closed_task_report_not_fully_complete"
    )
    return
  }
  if terminal, let wait = parsedWait,
     wait["task_id"] as? String == task.id,
     let waitSeconds = wait["wait_seconds"] as? Int,
     let waitReason = wait["reason"] as? String {
    closeDedicatedAutomationTarget(task, state: state)
    queueContinuation(&task, report: nil, reason: "chat_requested_wait")
    task.status = "waiting"
    task.waitingUntil = isoFormatter.string(
      from: Date().addingTimeInterval(Double(waitSeconds))
    )
    task.waitReason = waitReason
    task.lastError = "waiting_for_external_result"
    task.updatedAt = now
    queueTrace(
      "task=\(task.id) stage=chat-requested-wait delay=\(waitSeconds)s "
        + "reason=\(String(waitReason.prefix(200)))"
    )
    return
  }
  if terminal, !automationTaskRevisionIsCurrent(task, report: parsedReport) {
    let currentRevision = max(1, task.currentRevision ?? 1)
    let appliedRevision = max(1, parsedReport?.appliedTaskRevision ?? task.appliedRevision ?? 1)
    closeDedicatedAutomationTarget(task, state: state)
    restartAutomationTaskForUpdatedGoal(&task)
    task.reviewFeedback = "上一轮基于 revision \(appliedRevision)，任务已更新到 revision \(currentRevision)。小程序已停止旧分支续作；下一轮新建 Chat 并发送更新后的完整目标及已配置任务文件（如有）。"
    queueTrace("task=\(task.id) stage=task-revision-superseded action=fresh-project-chat")
    return
  }
  if terminal {
    let actions = reply["responseActions"] as? [String: Any] ?? [:]
    let actionEvidence = jsonString(actions) ?? "{}"
    queueTrace(
      "task=\(task.id) stage=terminal-observed marker=true "
        + "done=\(reply["done"] as? Bool == true) "
        + "candidate=\(reply["completionCandidate"] as? Bool == true) "
        + "incomplete=\(terminalIncomplete) "
        + "actions=\(actionEvidence) "
        + "report=\(parsedReport?.status ?? "none")"
    )
    writeQueueConversationDiagnostic(task, finalReason: "terminal_observed")
  }
  if terminal, let report = parsedReport {
    if let requestedConnector = normalizedConnector(report.nextConnector) {
      task.connector = requestedConnector
    }
    if monitoringReview {
      task.reviewReport = report
      task.reviewStatus = report.status
      if taskReportIsFullyComplete(report) {
        task.status = "completed"
        task.lastError = nil
        task.finishedAt = now
        task.reviewedAt = now
      } else {
        if let reviewConversationId = normalizedConversationId(task.reviewConversationId) {
          // The review is another round of the same task. Make that branch the
          // parent for the next work round so every same-task Chat stays in one
          // branch chain instead of creating an unrelated top-level Chat.
          task.conversationId = reviewConversationId
        }
        task.reviewConversationId = nil
        task.reviewStatus = nil
        queueContinuation(&task, report: report, reason: "chat_review_\(report.status)")
      }
      return
    }
    task.report = report
    if taskReportIsFullyComplete(report) {
      guard startAutomationReview(
        &task,
        report: report,
        port: port,
        targetId: targetId,
        state: state
      ) else {
        // Review is another round of the same task and must be created as a
        // branch. A transient menu/renderer failure must not turn that into a
        // top-level Chat or permanently block the queue; keep monitoring the
        // completed parent and retry the branch on the next pass.
        task.status = "running"
        task.lastError = "chat_review_branch_pending"
        task.finishedAt = nil
        task.updatedAt = now
        task.lastProgressAt = now
        return
      }
      task.status = "running"
      task.lastError = nil
      task.finishedAt = nil
    } else {
      closeDedicatedAutomationTarget(task, state: state)
      queueContinuation(&task, report: report, reason: "chat_finished_\(report.status)")
    }
    return
  }
  if terminal {
    closeDedicatedAutomationTarget(task, state: state)
    queueContinuation(
      &task,
      report: nil,
      reason: terminalIncomplete
        ? "unfinished_reply_missing_continuation_report"
        : "terminal_reply_missing_task_report"
    )
    return
  }

  if let lastProgressAt = task.lastProgressAt.flatMap(isoFormatter.date(from:)),
     Date().timeIntervalSince(lastProgressAt) >= Double(queueChatStagnationTimeoutSeconds) {
    if responseIsInFlight {
      let activeStallError = "page_stalled_but_response_active"
      if task.lastError != activeStallError {
        queueTrace(
          "task=\(task.id) stage=monitor-preserved reason=\(activeStallError) "
            + "streaming=\(replyIsActivelyResponding) pending=\(replyIsPending) "
            + "stopAvailable=\(reply["stopAvailable"] as? Bool == true)"
        )
      }
      // An active ChatGPT stream may legitimately spend a long time inside a
      // connector. Never click Stop or close its renderer, and never start a
      // second Chat merely because visible text stopped changing. The current Chat
      // remains authoritative until it reaches a real terminal state or an
      // explicit transport/runtime recovery path takes over.
      task.lastError = activeStallError
      task.updatedAt = now
      return
    }
    queueContinuation(&task, report: nil, reason: "page_stalled")
  }
}

func runQueueIteration(_ state: inout PluginState) {
  var tasks = state.automationTasks ?? []
  let now = isoFormatter.string(from: Date())
  let currentDate = Date()
  guard state.queueEnabled == true, state.queuePaused != true else {
    state.automationTasks = tasks
    return
  }
  // Update detection belongs to the miniapp. Re-read the authoritative task
  // entry and every declared file before monitoring completion or dispatching
  // another round. A changed goal immediately loses the old branch identity;
  // the old server-side response may settle independently, but it can never
  // complete or supply context to the new goal.
  for index in tasks.indices where tasks[index].status != "cancelled" {
    if refreshAutomationTaskDefinitionFromDisk(&tasks[index]) {
      restartAutomationTaskForUpdatedGoal(&tasks[index])
    }
  }
  let hasPendingQueueWork = tasks.contains {
    $0.status == "queued" || $0.status == "running" || $0.status == "waiting"
  }
  if state.queueWorkerMode == sharedConversationQueueWorkerMode
      || state.queueWorkerMode == parallelHiddenWindowQueueWorkerMode
      || state.queueWorkerMode == parallelHeadlessWindowQueueWorkerMode,
     !hasPendingQueueWork {
    // v82 restores the previously successful dedicated-process path. The
    // official quick-chat prewarm service owns only one window and closes it
    // when the next prewarm starts, so migrate both shared-renderer variants
    // only while idle. Migrating a running task closes its active response.
    if state.queueWorkerMode == parallelHiddenWindowQueueWorkerMode
        || state.queueWorkerMode == parallelHeadlessWindowQueueWorkerMode {
      state.automationTasks = tasks
      stopQueueWorker(&state)
    } else if let port = state.queueWorkerPort,
              let targetId = state.queueWorkerTargetId,
              queueTargetIsHidden(port: port, targetId: targetId) {
      _ = CDPClient.closeTarget(targetId, portOverride: port)
    }
    state.queueWorkerPort = nil
    state.queueWorkerTargetId = nil
    state.queueWorkerProfilePath = nil
    state.queueWorkerMode = nil
  }
  if state.queueWorkerMode != nil && !queueUsesBackgroundWindow(state)
      && !hasPendingQueueWork {
    // Migrate pre-v41 queues without touching a borrowed visible renderer. Any
    // running Chat must finish before the migration is allowed.
    if state.queueWorkerMode == legacyIsolatedQueueWorkerMode,
       let profilePath = state.queueWorkerProfilePath {
      terminateDedicatedChatProcess(profilePath: profilePath)
    }
    state.queueWorkerPort = nil
    state.queueWorkerTargetId = nil
    state.queueWorkerProfilePath = nil
    state.queueWorkerMode = nil
  }
  let network = queueNetworkProbe()
  if !network.reachable {
    state.queueNetworkStatus = "offline"
    state.queueNetworkLastError = network.detail
    for runningIndex in tasks.indices where tasks[runningIndex].status == "running" {
      closeDedicatedAutomationTarget(tasks[runningIndex], state: state)
      queueNetworkRecovery(&tasks[runningIndex], state: &state, reason: network.detail)
    }
    state.automationTasks = tasks
    return
  }
  if state.queueNetworkStatus == "offline" {
    state.queueNetworkStatus = "online"
    state.queueNetworkLastError = nil
  }
  for index in tasks.indices where tasks[index].status == "waiting" {
    guard let waitingUntil = tasks[index].waitingUntil.flatMap(isoFormatter.date(from:)) else {
      tasks[index].status = "queued"
      tasks[index].waitReason = nil
      tasks[index].updatedAt = now
      continue
    }
    guard currentDate >= waitingUntil else { continue }
    tasks[index].status = "queued"
    tasks[index].waitingUntil = nil
    tasks[index].waitReason = nil
    tasks[index].lastError = nil
    tasks[index].updatedAt = now
  }
  for index in tasks.indices where tasks[index].status == "running" {
    if tasks[index].workerPid != nil {
      if watcherIsAlive(tasks[index].workerPid) { continue }
      finishAutomationTask(&tasks[index], state: state)
    } else {
      monitorAutomationTask(&tasks[index], state: &state)
    }
  }

  if tasks.isEmpty {
    state.queueEnabled = false
    stopQueueWorker(&state)
    state.automationTasks = tasks
    return
  }
  let terminalStatuses = Set(["completed", "cancelled", "failed"])
  if !tasks.isEmpty && tasks.allSatisfy({ terminalStatuses.contains($0.status) }) {
    state.queueEnabled = false
    stopQueueWorker(&state)
    state.automationTasks = tasks
    return
  }
  if state.queueReviewGate != false && tasks.contains(where: {
    ["awaiting_review", "blocked"].contains($0.status)
  }) {
    state.automationTasks = tasks
    return
  }

  // The renderer serializes page actions, but each task has a different Chat
  // conversation. Once sent, ChatGPT runs those responses independently.
  let maxConcurrent = min(4, max(1, state.queueMaxConcurrent ?? 2))
  var runningCount = tasks.filter { $0.status == "running" }.count
  var heldLocks = Set(tasks.filter { $0.status == "running" }.flatMap(\.resourceLocks))
  var statuses = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0.status) })
  for index in tasks.indices where tasks[index].status == "queued" {
    let failedDependencies = tasks[index].dependsOn.filter {
      ["blocked", "failed", "cancelled"].contains(statuses[$0] ?? "")
    }
    if !failedDependencies.isEmpty {
      tasks[index].status = "blocked"
      tasks[index].lastError = "dependency_not_completed:\(failedDependencies.joined(separator: ","))"
      tasks[index].updatedAt = now
      statuses[tasks[index].id] = "blocked"
    }
  }
  let candidates = tasks.indices
    .filter { tasks[$0].status == "queued" }
    .sorted {
      if tasks[$0].priority != tasks[$1].priority {
        return tasks[$0].priority > tasks[$1].priority
      }
      return tasks[$0].createdAt < tasks[$1].createdAt
    }
  for index in candidates where runningCount < maxConcurrent {
    let task = tasks[index]
    let dependenciesReady = task.dependsOn.allSatisfy { statuses[$0] == "completed" }
    guard dependenciesReady else { continue }
    let locks = Set(task.resourceLocks)
    guard heldLocks.isDisjoint(with: locks) else { continue }
    do {
      queueTrace("task=\(tasks[index].id) stage=scheduler-selected")
      // Persist the processes already assigned earlier in this scheduling pass
      // so cleanup and diagnostics always know every task-owned target.
      state.automationTasks = tasks
      try startAutomationTask(&tasks[index], state: &state)
      runningCount += 1
      heldLocks.formUnion(locks)
    } catch {
      queueTrace("task=\(tasks[index].id) stage=start-failed error=\(error.localizedDescription)")
      if let signal = networkRecoverySignal(error.localizedDescription) {
        queueNetworkRecovery(&tasks[index], state: &state, reason: signal)
        continue
      }
      // `attempts` is the number embedded in a message that was actually sent.
      // Renderer/setup failures happen before that send and must neither
      // advance the marker nor exhaust a budget based on successful Chats.
      // A capped delay lets a long-lived local queue recover indefinitely.
      deferAutomationTaskForWorkerRecovery(
        &tasks[index],
        state: &state,
        reason: error.localizedDescription
      )
    }
  }
  state.automationTasks = tasks
}

func waitForAutomationReview(timeout: Int) -> [String: Any] {
  let deadline = Date().addingTimeInterval(Double(min(7200, max(1, timeout))))
  while Date() < deadline {
    let state = loadQueueState()
    let tasks = state.automationTasks ?? []
    if let task = tasks.first(where: {
      ["awaiting_review", "blocked", "failed"].contains($0.status)
    }) {
      return [
        "ok": true,
        "ready": true,
        "task": taskPublicPayload(task, includeResult: true),
        "queue": queueStatusPayload(state),
        "reviewInstruction": task.status == "awaiting_review"
          ? "请验收修改和验证证据，然后调用 review_task。accepted=true 会自动启动后续任务；accepted=false 会携带 feedback 重新排队。"
          : "任务需要处理卡点或运行失败。可检查报告后取消、修正任务或重新排队。",
      ]
    }
    if tasks.isEmpty || tasks.allSatisfy({ ["completed", "cancelled"].contains($0.status) }) {
      return ["ok": true, "ready": false, "queueComplete": true, "queue": queueStatusPayload(state)]
    }
    Thread.sleep(forTimeInterval: 0.5)
  }
  return [
    "ok": true,
    "ready": false,
    "timedOut": true,
    "queue": queueStatusPayload(loadQueueState()),
  ]
}

let watchdogRecoverableStatuses = Set([
  "queued", "running", "waiting", "blocked", "failed",
])

func watchdogTaskHasNonRecoverableFailure(_ task: AutomationTask) -> Bool {
  let detail = [
    task.lastError,
    task.hiddenWorkerLastError,
  ].compactMap { $0 }.joined(separator: " ").lowercased()
  return [
    "dependency_not_completed",
    "model_picker_not_found",
    "quick_chat_thinking_not_selected",
    "reasoning_high_not_selected",
    "target_model_not_selected",
    "connector_selection_not_confirmed",
  ].contains { detail.contains($0) }
}

func watchdogAnchorDate(_ task: AutomationTask) -> Date? {
  [
    task.watchdogLastRecoveryAt,
    task.lastProgressAt,
    task.startedAt,
    task.createdAt,
  ]
  .compactMap { $0.flatMap(isoFormatter.date(from:)) }
  .max()
}

// The watchdog runs in a separate process from the queue renderer. Keep the
// last renderer reply in durable task state so a restart cannot mistake an
// authorization card or an in-flight response for a dead renderer.
func watchdogReply(_ task: AutomationTask) -> [String: Any]? {
  guard let rawResult = task.lastResultJSON,
        let data = rawResult.data(using: .utf8),
        let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
    return nil
  }
  return (result["reply"] as? [String: Any])
    ?? (result["reviewReply"] as? [String: Any])
}

func watchdogActiveResponseFlags(_ task: AutomationTask) -> [String] {
  guard let reply = watchdogReply(task) else { return [] }
  return [
    "waitingForApproval",
    "pending",
    "streaming",
    "stopAvailable",
    "devspaceWaiting",
  ].filter { reply[$0] as? Bool == true }
}

func watchdogRunningTaskProtection(
  _ task: AutomationTask,
  now: Date,
  staleAfterSeconds: Int
) -> String? {
  guard task.status == "running" else { return nil }
  let activeFlags = watchdogActiveResponseFlags(task)
  if !activeFlags.isEmpty {
    return "active_response:\(activeFlags.joined(separator: ","))"
  }
  // A force recovery may repair a genuinely stale worker, but never during
  // the handoff immediately after send. The watcher may not have persisted its
  // first reply yet, and restarting here strands the authorization card and
  // creates a duplicate Chat.
  guard let anchor = watchdogAnchorDate(task) else { return nil }
  let age = now.timeIntervalSince(anchor)
  guard age >= Double(staleAfterSeconds) else {
    return "startup_grace:\(Int(max(0, age)))s<\(staleAfterSeconds)s"
  }
  return nil
}

func watchdogTaskIsEligible(
  _ task: AutomationTask,
  now: Date,
  staleAfterSeconds: Int,
  force: Bool
) -> Bool {
  guard watchdogRecoverableStatuses.contains(task.status) else { return false }
  guard !watchdogTaskHasNonRecoverableFailure(task) else { return false }
  // Never detach a running Chat while it is waiting for authorization or still
  // responding. `force` is reserved for stale renderer recovery and must not
  // override this protection.
  if watchdogRunningTaskProtection(
    task,
    now: now,
    staleAfterSeconds: staleAfterSeconds
  ) != nil {
    return false
  }
  if force { return true }
  if task.status == "waiting",
     let waitingUntil = task.waitingUntil.flatMap(isoFormatter.date(from:)),
     now < waitingUntil {
    return false
  }
  guard let anchor = watchdogAnchorDate(task) else { return true }
  return now.timeIntervalSince(anchor) >= Double(staleAfterSeconds)
}

func recoverQueueWithWatchdog(
  _ state: inout PluginState,
  staleAfterSeconds: Int,
  force: Bool,
  dryRun: Bool
) throws -> [String: Any] {
  let nowDate = Date()
  let now = isoFormatter.string(from: nowDate)
  var tasks = state.automationTasks ?? []
  let deferredTaskIds = tasks.indices.compactMap { index -> String? in
    guard let reason = watchdogRunningTaskProtection(
      tasks[index],
      now: nowDate,
      staleAfterSeconds: staleAfterSeconds
    ) else { return nil }
    queueTrace(
      "task=\(tasks[index].id) stage=watchdog-deferred reason=\(reason)"
    )
    return tasks[index].id
  }
  let eligibleIndexes = tasks.indices.filter {
    watchdogTaskIsEligible(
      tasks[$0],
      now: nowDate,
      staleAfterSeconds: staleAfterSeconds,
      force: force
    )
  }
  let eligibleIds = eligibleIndexes.map { tasks[$0].id }
  guard !eligibleIndexes.isEmpty else {
    return [
      "ok": true,
      "recovered": false,
      "dryRun": dryRun,
      "staleAfterSeconds": staleAfterSeconds,
      "eligibleTaskIds": eligibleIds,
      "deferredTaskIds": deferredTaskIds,
      "queue": queueStatusPayload(state),
    ]
  }
  if dryRun {
    return [
      "ok": true,
      "recovered": false,
      "wouldRecover": true,
      "dryRun": true,
      "staleAfterSeconds": staleAfterSeconds,
      "eligibleTaskIds": eligibleIds,
      "deferredTaskIds": deferredTaskIds,
      "queue": queueStatusPayload(state),
    ]
  }

  let runningIndexes = tasks.indices.filter { tasks[$0].status == "running" }
  if runningIndexes.isEmpty {
    stopQueueWorker(&state)
  } else {
    // A watchdog recovery may discover a quiet but still active Chat. Do not
    // click Stop or close any running task renderer; detach its ownership and
    // let the restarted queue create a fresh Chat alongside the old one.
    queueTrace(
      "stage=watchdog-preserve-running-chats count=\(runningIndexes.count)"
    )
    state.queueWorkerPort = nil
    state.queueWorkerTargetId = nil
    state.queueWorkerProfilePath = nil
    state.queueWorkerMode = nil
  }

  if watcherIsAlive(state.queueWatcherPid), let pid = state.queueWatcherPid {
    kill(pid, SIGTERM)
    Thread.sleep(forTimeInterval: 0.2)
  }
  state.queueWatcherPid = nil

  for index in eligibleIndexes {
    let previousStatus = tasks[index].status
    if previousStatus == "running" {
      queueContinuation(
        &tasks[index],
        report: tasks[index].report,
        reason: "github_actions_watchdog_recovery"
      )
      // The old hidden page is intentionally left running, but it is no
      // longer the task's active ownership record. The next Chat gets a new
      // renderer and can proceed independently.
      tasks[index].workerPort = nil
      tasks[index].workerTargetId = nil
      tasks[index].workerStatePath = nil
      tasks[index].workerProfilePath = nil
    } else if previousStatus != "queued" {
      tasks[index].status = "queued"
      tasks[index].startedAt = nil
      tasks[index].finishedAt = nil
      tasks[index].workerPid = nil
      tasks[index].workerPort = nil
      tasks[index].workerTargetId = nil
      tasks[index].workerStatePath = nil
      tasks[index].workerProfilePath = nil
      tasks[index].resultPath = nil
      if let reviewConversationId = normalizedConversationId(tasks[index].reviewConversationId) {
        tasks[index].conversationId = reviewConversationId
        tasks[index].chatURL = "https://chatgpt.com/c/\(reviewConversationId)"
      }
      tasks[index].reviewConversationId = nil
      tasks[index].reviewStatus = nil
      tasks[index].reviewReport = nil
      tasks[index].waitingUntil = nil
      tasks[index].waitReason = nil
      tasks[index].lastProgressAt = nil
      tasks[index].lastError = "github_actions_watchdog_recovery"
      tasks[index].reviewFeedback = [
        tasks[index].reviewFeedback,
        "GitHub Actions 守护已安全重建隐藏 Chat。请从同一 checkout 的最新落盘进度继续，不要从头开始。",
      ].compactMap { $0 }.joined(separator: "\n\n")
      tasks[index].updatedAt = now
    } else {
      tasks[index].workerPid = nil
      tasks[index].workerPort = nil
      tasks[index].workerTargetId = nil
      tasks[index].workerStatePath = nil
      tasks[index].workerProfilePath = nil
      tasks[index].lastError = "github_actions_watchdog_recovery"
      tasks[index].updatedAt = now
    }
    tasks[index].watchdogLastRecoveryAt = now
    tasks[index].watchdogRecoveryCount = (tasks[index].watchdogRecoveryCount ?? 0) + 1
  }

  state.automationTasks = tasks
  state.queueEnabled = true
  state.queuePaused = false
  try startQueueWatcher(&state)
  return [
    "ok": true,
    "recovered": true,
    "dryRun": false,
    "staleAfterSeconds": staleAfterSeconds,
    "eligibleTaskIds": eligibleIds,
    "deferredTaskIds": deferredTaskIds,
    "watcherPid": state.queueWatcherPid as Any,
    "queue": queueStatusPayload(state),
  ]
}
