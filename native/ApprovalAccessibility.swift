import ApplicationServices
import Cocoa
import Darwin
import Foundation
import SystemConfiguration

let encoder: JSONEncoder = {
  let value = JSONEncoder()
  value.outputFormatting = [.sortedKeys]
  return value
}()
let decoder = JSONDecoder()
let isoFormatter = ISO8601DateFormatter()
func jsonString(_ object: [String: Any]) -> String? {
  guard JSONSerialization.isValidJSONObject(object),
        let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
    return nil
  }
  return String(data: data, encoding: .utf8)
}
let targetBundleIdentifiers = Set(["com.openai.codex", "com.openai.chat"])
let verifiedApprovalMarker = "已验证授权卡消失"
let pendingApprovalMarker = "AXPress 已发送，等待授权卡消失"
func stateURL() -> URL {
  if let override = ProcessInfo.processInfo.environment["CHATGPT_AUTO_CONFIRM_STATE"],
     !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
    return URL(fileURLWithPath: override)
  }
  return FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Mahayana/plugins/chatgpt-auto-confirm")
    .appendingPathComponent("state.json")
}

func loadState() -> PluginState {
  guard let data = try? Data(contentsOf: stateURL()),
        var state = try? decoder.decode(PluginState.self, from: data) else {
    return PluginState()
  }
  state.audit = state.audit.compactMap { event in
    let title = normalizedAXText(event.buttonTitle)
    guard title.isEmpty || isAllowButton(title: event.buttonTitle, context: "") else {
      return nil
    }
    let actionWasSent = event.clicked || event.error == "approval_still_present_after_ax_press"
    let migratedReason = event.error == "approval_still_present_after_ax_press"
      ? "\(event.reason)；\(pendingApprovalMarker)"
      : event.reason
    return AuditEvent(
      at: event.at,
      decision: event.decision,
      reason: migratedReason,
      clicked: actionWasSent,
      ruleId: event.ruleId,
      buttonTitle: event.buttonTitle,
      promptText: approvalAuditPrompt(event.promptText),
      error: event.error == "approval_still_present_after_ax_press" ? nil : event.error
    )
  }
  return state
}

func saveState(_ state: PluginState) throws {
  let url = stateURL()
  try FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  let data = try encoder.encode(state)
  try data.write(to: url, options: .atomic)
}

func output(_ payload: [String: Any], exitCode: Int32 = 0) -> Never {
  let safePayload = sanitizeJSONValue(payload)
  guard JSONSerialization.isValidJSONObject(safePayload),
        let data = try? JSONSerialization.data(withJSONObject: safePayload, options: [.sortedKeys]) else {
    let fallback = Data("{\"errorCode\":\"json_encoding_failed\",\"message\":\"原生插件无法编码返回结果\",\"ok\":false}\n".utf8)
    FileHandle.standardOutput.write(fallback)
    Foundation.exit(1)
  }
  FileHandle.standardOutput.write(data)
  FileHandle.standardOutput.write(Data([0x0a]))
  Foundation.exit(exitCode)
}

func emitProgress(_ payload: [String: Any]) {
  var event = payload
  event["event"] = event["event"] ?? "progress"
  let safePayload = sanitizeJSONValue(event)
  guard JSONSerialization.isValidJSONObject(safePayload),
        let data = try? JSONSerialization.data(withJSONObject: safePayload, options: [.sortedKeys]) else { return }
  FileHandle.standardOutput.write(data)
  FileHandle.standardOutput.write(Data([0x0a]))
}

func stringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String {
  var value: CFTypeRef?
  guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return "" }
  return value as? String ?? ""
}

func boolAttribute(_ element: AXUIElement, _ attribute: CFString) -> Bool? {
  var value: CFTypeRef?
  guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
  return value as? Bool
}

func role(of element: AXUIElement) -> String {
  stringAttribute(element, kAXRoleAttribute as CFString)
}

func accessibleString(_ element: AXUIElement) -> String {
  for attribute in [
    kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXValueAttribute,
  ] {
    let value = stringAttribute(element, attribute as CFString)
    if !value.isEmpty { return value }
  }
  return ""
}

func normalizedAXText(_ text: String) -> String {
  text
    .lowercased()
    .split(whereSeparator: \.isWhitespace)
    .joined(separator: " ")
}

func diagnosticStrings(_ element: AXUIElement) -> [String: String] {
  var values: [String: String] = [:]
  for (name, attribute) in [
    ("title", kAXTitleAttribute),
    ("description", kAXDescriptionAttribute),
    ("help", kAXHelpAttribute),
    ("value", kAXValueAttribute),
    ("identifier", kAXIdentifierAttribute),
    ("subrole", kAXSubroleAttribute),
  ] {
    let value = stringAttribute(element, attribute as CFString)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if !value.isEmpty { values[name] = String(value.prefix(1_000)) }
  }
  return values
}

func children(of element: AXUIElement) -> [AXUIElement] {
  var value: CFTypeRef?
  guard AXUIElementCopyAttributeValue(
    element,
    kAXChildrenAttribute as CFString,
    &value
  ) == .success else { return [] }
  return value as? [AXUIElement] ?? []
}

func parent(of element: AXUIElement) -> AXUIElement? {
  var value: CFTypeRef?
  guard AXUIElementCopyAttributeValue(
    element,
    kAXParentAttribute as CFString,
    &value
  ) == .success,
    let value,
    CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
  return unsafeBitCast(value, to: AXUIElement.self)
}

func descendants(of root: AXUIElement, matchingRole expectedRole: String) -> [AXUIElement] {
  var queue: [(AXUIElement, Int)] = [(root, 0)]
  var matches: [AXUIElement] = []
  var visited = Set<CFHashCode>()
  var cursor = 0
  while cursor < queue.count && cursor < 8_000 {
    let (element, depth) = queue[cursor]
    cursor += 1
    guard visited.insert(CFHash(element)).inserted else { continue }
    if role(of: element) == expectedRole { matches.append(element) }
    if depth < 40 { queue.append(contentsOf: children(of: element).map { ($0, depth + 1) }) }
  }
  return matches
}

func allDescendants(of root: AXUIElement) -> [AXUIElement] {
  var queue: [(AXUIElement, Int)] = [(root, 0)]
  var values: [AXUIElement] = []
  var visited = Set<CFHashCode>()
  var cursor = 0
  while cursor < queue.count && cursor < 8_000 {
    let (element, depth) = queue[cursor]
    cursor += 1
    guard visited.insert(CFHash(element)).inserted else { continue }
    values.append(element)
    if depth < 40 { queue.append(contentsOf: children(of: element).map { ($0, depth + 1) }) }
  }
  return values
}

func boundedDescendants(
  of root: AXUIElement,
  maximumNodes: Int = 600,
  maximumDepth: Int = 14
) -> [AXUIElement] {
  var queue: [(AXUIElement, Int)] = [(root, 0)]
  var values: [AXUIElement] = []
  var visited = Set<CFHashCode>()
  var cursor = 0
  while cursor < queue.count && cursor < maximumNodes {
    let (element, depth) = queue[cursor]
    cursor += 1
    guard visited.insert(CFHash(element)).inserted else { continue }
    values.append(element)
    if depth < maximumDepth {
      queue.append(contentsOf: children(of: element).map { ($0, depth + 1) })
    }
  }
  return values
}

func nativeSearchElements(
  from root: AXUIElement,
  searchKey: String,
  text: String = "",
  limit: Int = 200
) -> [AXUIElement] {
  let parameters: [String: Any] = [
    "AXSearchKey": searchKey,
    "AXSearchText": text,
    "AXDirection": "AXDirectionNext",
    "AXImmediateDescendantsOnly": false,
    "AXResultsLimit": limit,
    // AXPress on a virtualized, hidden conversation can make ChatGPT restore
    // that conversation before dispatching the action. Hidden renderers are
    // handled through CDP instead; the compatibility path is intentionally
    // limited to elements that macOS reports as visible.
    "AXVisibleOnly": true,
  ]
  var value: CFTypeRef?
  guard AXUIElementCopyParameterizedAttributeValue(
    root,
    "AXUIElementsForSearchPredicate" as CFString,
    parameters as CFDictionary,
    &value
  ) == .success else { return [] }
  return value as? [AXUIElement] ?? []
}

func searchedElements(
  in application: NSRunningApplication,
  searchKey: String,
  text: String = "",
  limit: Int = 200
) -> [AXUIElement] {
  let root = AXUIElementCreateApplication(application.processIdentifier)
  AXUIElementSetMessagingTimeout(root, 1.5)
  let direct = nativeSearchElements(from: root, searchKey: searchKey, text: text, limit: limit)
  if !direct.isEmpty { return direct }

  // Chromium exposes the predicate on its web areas rather than the application root.
  // Locating those hosts is deliberately bounded; page content is searched by the OS.
  var results: [AXUIElement] = []
  for element in boundedDescendants(of: root, maximumNodes: 350, maximumDepth: 12)
    where role(of: element) == "AXWebArea" {
    results.append(contentsOf: nativeSearchElements(
      from: element,
      searchKey: searchKey,
      text: text,
      limit: max(1, limit - results.count)
    ))
    if results.count >= limit { break }
  }
  return Array(results.prefix(limit))
}

func actionNames(of element: AXUIElement) -> [String] {
  var names: CFArray?
  guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
  return names as? [String] ?? []
}

func textContent(of root: AXUIElement, limit: Int = 350) -> String {
  var queue = [root]
  var cursor = 0
  var visited = Set<CFHashCode>()
  var seen = Set<String>()
  var fragments: [String] = []
  while cursor < queue.count && cursor < limit {
    let element = queue[cursor]
    cursor += 1
    guard visited.insert(CFHash(element)).inserted else { continue }
    let text = accessibleString(element).trimmingCharacters(in: .whitespacesAndNewlines)
    if !text.isEmpty && seen.insert(text).inserted { fragments.append(text) }
    queue.append(contentsOf: children(of: element))
  }
  return fragments.joined(separator: "\n")
}

func closestApprovalContext(for element: AXUIElement) -> String? {
  var current = parent(of: element)
  for _ in 0..<20 {
    guard let container = current else { break }
    let context = textContent(of: container, limit: 220)
    if isStructurallyVerifiedApprovalButton(element, in: container, context: context) {
      return context
    }
    current = parent(of: container)
  }
  return nil
}

func approvalAuditPrompt(_ context: String) -> String {
  let normalized = normalizedAXText(context)
  if normalized.hasPrefix("allow chatgpt to use [approval details redacted] #") {
    return context
  }
  var hash: UInt64 = 14_695_981_039_346_656_037
  for byte in context.utf8 {
    hash ^= UInt64(byte)
    hash &*= 1_099_511_628_211
  }
  return "Allow ChatGPT to use [approval details redacted] #\(String(hash, radix: 16))"
}

func isAllowButton(title: String, context _: String) -> Bool {
  let normalizedTitle = normalizedAXText(title)
  let allowedTitles = [
    "allow", "allow once", "approve", "approve once", "confirm", "confirm once",
    "authorize", "authorize once", "grant", "grant once", "full access", "complete access",
    "允许", "允许一次", "同意", "同意一次", "确认", "确认一次", "授权", "授权一次",
    "完全访问", "完整访问",
  ]
  return allowedTitles.contains(normalizedTitle)
}

func isRejectButton(title: String) -> Bool {
  [
    "deny", "reject", "cancel", "deny once", "reject once", "not now",
    "拒绝", "拒绝一次", "不允许", "不允许一次", "取消", "暂不",
  ].contains(normalizedAXText(title))
}

func isStructurallyVerifiedApprovalButton(
  _ element: AXUIElement,
  in container: AXUIElement,
  context _: String
) -> Bool {
  guard role(of: element) == kAXButtonRole as String,
        actionNames(of: element).contains(kAXPressAction as String) else { return false }
  return verifiedApprovalButtons(in: container, context: "").contains {
    CFEqual($0, element)
  }
}

func verifiedApprovalButtons(
  in container: AXUIElement,
  context _: String
) -> [AXUIElement] {
  let buttons = boundedDescendants(
    of: container,
    maximumNodes: 400,
    maximumDepth: 12
  ).filter {
    role(of: $0) == kAXButtonRole as String &&
      actionNames(of: $0).contains(kAXPressAction as String)
  }
  guard buttons.contains(where: { isRejectButton(title: accessibleString($0)) }) else {
    return []
  }
  let explicitAllowButtons = buttons.filter {
    isAllowButton(title: accessibleString($0), context: "")
  }
  if !explicitAllowButtons.isEmpty { return explicitAllowButtons }

  // Some ChatGPT builds expose the white Allow button without an AX label.
  // Accept that shape only when this compact approval container has exactly
  // the reject button and one unlabeled companion button.
  guard buttons.count == 2,
        buttons.filter({ isRejectButton(title: accessibleString($0)) }).count == 1 else {
    return []
  }
  return buttons.filter { normalizedAXText(accessibleString($0)).isEmpty }
}

func alreadyApproved(_ candidate: Candidate, in state: PluginState) -> Bool {
  let candidatePrompt = approvalAuditPrompt(candidate.promptText)
  return state.audit.reversed().contains { event in
    guard event.clicked,
          event.decision == "allow",
          event.buttonTitle == candidate.buttonTitle else { return false }
    guard event.promptText == candidatePrompt || event.promptText == candidate.promptText else { return false }
    guard let sentAt = isoFormatter.date(from: event.at) else { return false }
    return Date().timeIntervalSince(sentAt) < 15
  }
}

func reconcilePendingApprovals(
  _ state: inout PluginState,
  activeCandidates: [Candidate]
) {
  let activePrompts = Set(activeCandidates.map { approvalAuditPrompt($0.promptText) })
  state.audit = state.audit.map { event in
    guard event.clicked,
          event.decision == "allow",
          event.reason.contains(pendingApprovalMarker),
          !event.reason.contains(verifiedApprovalMarker),
          !activePrompts.contains(event.promptText) else { return event }
    return AuditEvent(
      at: event.at,
      decision: event.decision,
      reason: "\(event.reason)；\(verifiedApprovalMarker)",
      clicked: true,
      ruleId: event.ruleId,
      buttonTitle: event.buttonTitle,
      promptText: event.promptText,
      error: nil
    )
  }
}

func candidateStillPresent(_ candidate: Candidate) -> Bool {
  guard role(of: candidate.element) == kAXButtonRole as String,
        let context = closestApprovalContext(for: candidate.element),
        String(context.prefix(600)) == String(candidate.promptText.prefix(600)) else { return false }
  return true
}

func waitForCandidateToDisappear(
  _ candidate: Candidate,
  timeout: TimeInterval
) -> Bool {
  let deadline = Date().addingTimeInterval(timeout)
  repeat {
    if !candidateStillPresent(candidate) { return true }
    Thread.sleep(forTimeInterval: 0.12)
  } while Date() < deadline
  return !candidateStillPresent(candidate)
}

func containingWindow(of element: AXUIElement) -> AXUIElement? {
  var current: AXUIElement? = element
  for _ in 0..<40 {
    guard let node = current else { return nil }
    if role(of: node) == kAXWindowRole as String { return node }
    current = parent(of: node)
  }
  return nil
}

func dismissHistoryOverlay(covering candidate: Candidate) -> Bool {
  guard let window = containingWindow(of: candidate.element) else { return false }
  let elements = boundedDescendants(
    of: window,
    maximumNodes: 1_800,
    maximumDepth: 32
  )
  let hasVisibleHistoryHeading = elements.contains { element in
    guard role(of: element) == kAXHeadingRole as String else { return false }
    let text = normalizedAXText(accessibleString(element))
    return text == "历史记录" || text == "history"
  }
  guard hasVisibleHistoryHeading else { return false }
  guard let toggle = elements.first(where: { element in
    guard role(of: element) == kAXButtonRole as String,
          actionNames(of: element).contains(kAXPressAction as String) else { return false }
    let text = normalizedAXText(accessibleString(element))
    return text.contains("查看聊天历史记录，当前聊天：") ||
      (text.contains("view chat history") && text.contains("current chat"))
  }) else { return false }
  return AXUIElementPerformAction(toggle, kAXPressAction as CFString) == .success
}

func performApprovalClick(_ candidate: Candidate) -> (Bool, Bool, String?) {
  if boolAttribute(candidate.element, kAXEnabledAttribute as CFString) == false {
    return (false, false, "approval_button_disabled")
  }
  guard actionNames(of: candidate.element).contains(kAXPressAction as String) else {
    return (false, false, "approval_button_has_no_press_action")
  }
  let axError = AXUIElementPerformAction(candidate.element, kAXPressAction as CFString)
  guard axError == .success else {
    return (false, false, "ax_press_failed_\(axError.rawValue)")
  }
  if waitForCandidateToDisappear(candidate, timeout: 2.5) {
    return (true, true, nil)
  }
  if dismissHistoryOverlay(covering: candidate) {
    Thread.sleep(forTimeInterval: 0.4)
    if !candidateStillPresent(candidate) { return (true, true, nil) }
    let retryError = AXUIElementPerformAction(candidate.element, kAXPressAction as CFString)
    guard retryError == .success else {
      return (true, false, "ax_press_retry_failed_\(retryError.rawValue)")
    }
    if waitForCandidateToDisappear(candidate, timeout: 2.5) {
      return (true, true, nil)
    }
  }
  return (true, false, nil)
}

func runningChatGptApplications() -> [NSRunningApplication] {
  NSWorkspace.shared.runningApplications.filter { application in
    guard !application.isTerminated else { return false }
    if let bundleIdentifier = application.bundleIdentifier,
       targetBundleIdentifiers.contains(bundleIdentifier) { return true }
    return application.localizedName?.caseInsensitiveCompare("ChatGPT") == .orderedSame
  }
}

func pointAttribute(_ element: AXUIElement, _ attribute: CFString) -> CGPoint? {
  var value: CFTypeRef?
  guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
        let value,
        CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
  let axValue = unsafeBitCast(value, to: AXValue.self)
  guard AXValueGetType(axValue) == .cgPoint else { return nil }
  var point = CGPoint.zero
  guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
  return point
}

func sizeAttribute(_ element: AXUIElement, _ attribute: CFString) -> CGSize? {
  var value: CFTypeRef?
  guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
        let value,
        CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
  let axValue = unsafeBitCast(value, to: AXValue.self)
  guard AXValueGetType(axValue) == .cgSize else { return nil }
  var size = CGSize.zero
  guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
  return size
}

func frame(of element: AXUIElement) -> CGRect? {
  guard let origin = pointAttribute(element, kAXPositionAttribute as CFString),
        let size = sizeAttribute(element, kAXSizeAttribute as CFString) else { return nil }
  return CGRect(origin: origin, size: size)
}

func focusedWindow(in application: NSRunningApplication) -> AXUIElement? {
  let root = AXUIElementCreateApplication(application.processIdentifier)
  var value: CFTypeRef?
  guard AXUIElementCopyAttributeValue(
    root,
    kAXFocusedWindowAttribute as CFString,
    &value
  ) == .success,
    let value,
    CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
  return unsafeBitCast(value, to: AXUIElement.self)
}

func isActuallyVisible(
  _ element: AXUIElement,
  inside focusedWindow: AXUIElement
) -> Bool {
  if boolAttribute(element, "AXVisible" as CFString) == false { return false }
  guard let elementFrame = frame(of: element),
        let windowFrame = frame(of: focusedWindow),
        elementFrame.width > 1,
        elementFrame.height > 1,
        !elementFrame.intersection(windowFrame).isNull else { return false }

  var current: AXUIElement? = element
  for _ in 0..<40 {
    guard let node = current else { return false }
    if CFEqual(node, focusedWindow) { return true }
    if boolAttribute(node, "AXVisible" as CFString) == false { return false }
    current = parent(of: node)
  }
  return false
}

func candidates() -> [Candidate] {
  var values: [Candidate] = []
  var seenButtons = Set<CFHashCode>()
  // Never AXPress a background ChatGPT process. Pressing an accessibility
  // element can activate its window, and virtualized hidden conversation
  // elements can restore an old route. Background and hidden work is handled
  // through the renderer IPC path without focusing or navigating the UI.
  for application in runningChatGptApplications() where application.isActive {
    guard let activeWindow = focusedWindow(in: application) else { continue }
    let root = AXUIElementCreateApplication(application.processIdentifier)
    AXUIElementSetMessagingTimeout(root, 1.5)
    var matchedElements: [AXUIElement] = []
    for term in ["Allow", "允许", "Approve", "Confirm", "同意", "确认"] {
      matchedElements.append(contentsOf: searchedElements(
        in: application,
        searchKey: "AXAnyTypeSearchKey",
        text: term,
        limit: 20
      ))
    }
    if matchedElements.isEmpty {
      matchedElements = boundedDescendants(
        of: root,
        maximumNodes: 500,
        maximumDepth: 18
      ).filter {
        let normalized = accessibleString($0).lowercased()
        return ["allow", "允许", "approve", "confirm", "同意", "确认"].contains {
          normalized.contains($0)
        }
      }
    }

    var approvalAnchors: [AXUIElement] = []
    for phrase in [
      "Reject", "Deny", "Cancel", "拒绝", "不允许", "取消",
    ] {
      approvalAnchors.append(contentsOf: searchedElements(
        in: application,
        searchKey: "AXAnyTypeSearchKey",
        text: phrase,
        limit: 10
      ))
    }
    if approvalAnchors.isEmpty {
      approvalAnchors = boundedDescendants(
        of: root,
        maximumNodes: 1_800,
        maximumDepth: 28
      ).filter {
        let text = accessibleString($0)
        return isRejectButton(title: text)
      }
    }

    var buttons: [AXUIElement] = []
    for element in matchedElements {
      var current: AXUIElement? = element
      for _ in 0..<5 {
        guard let candidate = current else { break }
        if role(of: candidate) == kAXButtonRole as String &&
            actionNames(of: candidate).contains(kAXPressAction as String) {
          if seenButtons.insert(CFHash(candidate)).inserted { buttons.append(candidate) }
          break
        }
        current = parent(of: candidate)
      }
    }

    // Some ChatGPT builds expose the white Allow button without an AX label.
    // Starting from either the approval heading or its Reject button finds that
    // unlabeled companion without inspecting or filtering the card contents.
    for anchor in approvalAnchors {
      var container: AXUIElement? = anchor
      for _ in 0..<12 {
        guard let node = container else { break }
        let context = textContent(of: node, limit: 220)
        let verifiedButtons = verifiedApprovalButtons(in: node, context: context)
        for candidate in verifiedButtons {
          if seenButtons.insert(CFHash(candidate)).inserted { buttons.append(candidate) }
        }
        if !verifiedButtons.isEmpty { break }
        container = parent(of: node)
      }
    }
    for button in buttons {
      guard values.count < 3,
            isActuallyVisible(button, inside: activeWindow),
            let context = closestApprovalContext(for: button) else { continue }
      let title = accessibleString(button)
      guard isAllowButton(title: title, context: context) ||
              normalizedAXText(title).isEmpty else { continue }
      values.append(Candidate(
        element: button,
        promptText: context,
        buttonTitle: title
      ))
    }
  }
  return values
}
