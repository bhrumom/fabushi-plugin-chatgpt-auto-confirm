import ApplicationServices
import Cocoa
import Darwin
import Foundation
import SystemConfiguration

struct ApprovalRule: Codable {
  let id: String
  let application: String
  let action: String
  let resource: String
}

struct AuditEvent: Codable {
  let at: String
  let decision: String
  let reason: String
  let clicked: Bool
  let ruleId: String?
  let buttonTitle: String
  let promptText: String
  let error: String?
}

struct PluginState: Codable {
  var enabled = false
  var rules: [ApprovalRule] = []
  var approveAll: Bool?
  var chatTitles: [String]?
  var trackedChatURLs: [String]?
  var backgroundTargets: [String: String]?
  var backgroundAppPort: Int?
  var backgroundChatTargetId: String?
  var backgroundProfilePath: String?
  var backgroundCodexHomePath: String?
  var backgroundConversationId: String?
  var intervalMs = 750
  var watcherPid: Int32?
  var startedAt: String?
  var lastError: String?
  var audit: [AuditEvent] = []
  var automationTasks: [AutomationTask]?
  var queueEnabled: Bool?
  var queuePaused: Bool?
  var queueMaxConcurrent: Int?
  var queueReviewGate: Bool?
  var queueWatcherPid: Int32?
  var queueRuntimeRevision: String?
  // Every running task owns a hidden ChatGPT process cloned from the restored
  // authenticated profile. It never navigates the primary window where the
  // user types, and tasks cannot close one another's renderer.
  var queueWorkerPort: Int?
  var queueWorkerTargetId: String?
  var queueWorkerProfilePath: String?
  var queueWorkerMode: String?
  // Reachability is queue-level state: a transient DNS/network/upstream
  // outage pauses the durable queue instead of terminating or duplicating
  // active Chat work.
  var queueNetworkStatus: String?
  var queueNetworkLastError: String?
  var queueNetworkFailureCount: Int?
  var queueNetworkWaitUntil: String?
  // Approval safety is persisted so a renderer re-mount or watcher restart
  // cannot turn the same authorization request into another click.
  var handledApprovalFingerprints: [String]?
  var automaticApprovalFingerprintAttempts: [String: Int]?
  var automaticApprovalTimestamps: [String]?
  var lastAutomaticApprovalFingerprint: String?
  var lastAutomaticApprovalAt: String?
}

struct AutomationTaskReport: Codable {
  var protocolName: String
  var taskId: String?
  var appliedTaskRevision: Int?
  var appliedSpecDigest: String?
  var status: String
  // This is the only terminal-completion switch. `completed` may contain
  // work finished during an incomplete round, so it must never stop a task.
  var allTasksComplete: Bool?
  var summary: String
  var completed: [String]
  var remaining: [String]
  var blockers: [String]
  var verification: [String]
  var nextTask: String
  // When an external job (for example, GitHub Actions) is still running, the
  // Chat ends with an incomplete report and asks the queue to come back later
  // instead of keeping a renderer and a model response idle.
  var waitSeconds: Int?
  var waitReason: String?
  // A finished Chat can choose the connector for the next fresh Chat. This
  // is useful when a local bhrum2 step has pushed code and the next step must
  // inspect GitHub Actions through the GitHub connector.
  var nextConnector: String?

  enum CodingKeys: String, CodingKey {
    case protocolName = "protocol"
    case taskId = "task_id"
    case appliedTaskRevision = "applied_task_revision"
    case appliedSpecDigest = "applied_spec_digest"
    case status, summary, completed, remaining, blockers, verification
    case allTasksComplete = "all_tasks_complete"
    case nextTask = "next_task"
    case waitSeconds = "wait_seconds"
    case waitReason = "wait_reason"
    case nextConnector = "next_connector"
  }
}

struct AutomationTaskUpdate: Codable {
  var id: String
  var revision: Int
  var createdAt: String
  var source: String
  var directive: String
  var specDigest: String
  var applyMode: String
}

struct AutomationTask: Codable {
  var id: String
  // The account is captured when a task is enqueued.  It is intentionally
  // optional for backwards-compatible decoding of pre-multi-account queue
  // snapshots; new tasks always receive the current default account id.
  var accountId: String?
  var title: String
  var prompt: String
  var originalPrompt: String?
  var promptTemplate: String
  var currentRevision: Int?
  var appliedRevision: Int?
  var pendingRevision: Int?
  var specSources: [String]?
  var specSnapshot: String?
  var specDigest: String?
  // Checkout metadata lets the miniapp re-read the authoritative task entry
  // and its files before each dispatch instead of delegating that check to Chat.
  var workspaceRoot: String? = nil
  var taskControlPath: String? = nil
  // Repository coordinates are repeated in every outbound round so the model
  // never has to infer which connected GitHub checkout it must edit.
  var repository: String? = nil
  var codeDirectory: String? = nil
  var appliedSpecDigest: String?
  var pendingDirective: String?
  var applyMode: String?
  var taskUpdates: [AutomationTaskUpdate]?
  var specUpdatedAt: String?
  var connector: String
  var dependsOn: [String]
  var resourceLocks: [String]
  var priority: Int
  var timeout: Int
  var maxTaskContinuations: Int
  var maxRuntimeRetries: Int
  var attempts: Int
  var reviewRound: Int
  var status: String
  var createdAt: String
  var updatedAt: String
  var startedAt: String?
  var finishedAt: String?
  var workerPid: Int32?
  var workerPort: Int?
  var workerTargetId: String?
  var workerStatePath: String?
  var workerProfilePath: String?
  var resultPath: String?
  var conversationId: String?
  // Queue-owned sends prove their exact per-attempt marker before entering the
  // running state. Persist that proof plus the local composer identity because
  // ChatGPT may virtualize the user bubble or expose a durable sidebar id while
  // the live composer still carries its local id. queue_attach can also bind an
  // operator-owned existing Chat that intentionally has no queue marker.
  var dispatchMarkerVerifiedAt: String? = nil
  var dispatchLocalConversationId: String? = nil
  var attachedConversationWithoutDispatchMarker: Bool? = nil
  var reviewConversationId: String?
  var reviewStatus: String?
  var reviewReport: AutomationTaskReport?
  var chatURL: String?
  var report: AutomationTaskReport?
  var lastResultJSON: String?
  var lastError: String?
  var reviewFeedback: String?
  var reviewedAt: String?
  var continuationDepth: Int?
  var reportFingerprints: [String]?
  var lastActivitySignature: String?
  var lastProgressAt: String?
  var waitingUntil: String?
  var waitReason: String?
  // Conversation is durable state; hidden renderer is only a recoverable worker.
  // These fields allow the queue to recover after a renderer disappears instead
  // of treating the task as failed.
  var hiddenWorkerLastHeartbeatAt: String? = nil
  var hiddenWorkerRecoveryCount: Int? = nil
  var hiddenWorkerLastError: String? = nil
  // GitHub-hosted sessions persist their recovery boundary in task state so a
  // later Actions run can distinguish fresh progress from an old renderer.
  var watchdogLastRecoveryAt: String? = nil
  var watchdogRecoveryCount: Int? = nil
  // Queue approvals use the same durable safety boundary as the general
  // watcher, but are isolated per task/conversation.
  var handledApprovalFingerprints: [String]? = nil
  var automaticApprovalFingerprintAttempts: [String: Int]? = nil
  var automaticApprovalTimestamps: [String]? = nil
  var lastAutomaticApprovalFingerprint: String? = nil
  var lastAutomaticApprovalAt: String? = nil
}

struct Candidate {
  let element: AXUIElement
  let promptText: String
  let buttonTitle: String
}
