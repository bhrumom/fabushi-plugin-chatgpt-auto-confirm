import ApplicationServices
import Cocoa
import Darwin
import Foundation
import SystemConfiguration

func canonicalPluginPath(_ rawPath: String) -> String {
  URL(fileURLWithPath: rawPath, isDirectory: true).standardizedFileURL.path
}

func pluginOwnedProfilePath(_ rawPath: String?) -> Bool {
  guard let rawPath,
        !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
    return false
  }
  let candidate = canonicalPluginPath(rawPath)
  let exactProfiles = [
    hiddenChatProfilePath(),
    configuredHiddenChatProfilePath(),
  ].compactMap { $0 }.map(canonicalPluginPath)
  if exactProfiles.contains(candidate) { return true }

  let roots = [
    accountsRootURL().standardizedFileURL.path,
    queueDirectoryURL().appendingPathComponent("workers", isDirectory: true)
      .standardizedFileURL.path,
  ]
  return roots.contains { root in
    candidate == root || candidate.hasPrefix(root + "/")
  }
}

func pluginProfilePathForPort(_ port: Int) -> String? {
  let process = Process()
  let output = Pipe()
  process.executableURL = URL(fileURLWithPath: "/bin/ps")
  process.arguments = ["-axo", "pid=,command="]
  process.standardInput = FileHandle.nullDevice
  process.standardOutput = output
  process.standardError = FileHandle.nullDevice
  let data: Data
  do {
    try process.run()
    data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
  } catch {
    return nil
  }
  guard let text = String(data: data, encoding: .utf8) else { return nil }
  let portMarker = "--remote-debugging-port=\(port)"
  for lineSlice in text.split(separator: "\n") {
    let line = String(lineSlice)
    guard line.contains("/Applications/ChatGPT.app/Contents/"),
          line.contains(portMarker),
          let profileRange = line.range(of: "--user-data-dir=") else { continue }
    let profileTail = line[profileRange.upperBound...]
    let profile = profileTail.range(of: " --").map {
      String(profileTail[..<$0.lowerBound])
    } ?? String(profileTail)
    let normalized = profile.trimmingCharacters(in: .whitespacesAndNewlines)
    if !normalized.isEmpty { return canonicalPluginPath(normalized) }
  }
  return nil
}

func pluginOwnsBackgroundTarget(
  port: Int,
  targetId: String,
  state: PluginState
) -> Bool {
  guard state.backgroundAppPort == port,
        state.backgroundChatTargetId == targetId else { return false }
  let allowTestTarget = ProcessInfo.processInfo.environment[
    "CHATGPT_AUTO_CONFIRM_ALLOW_TEST_WEB_TARGET"
  ] == "1"
  // The test seam may deliberately use the primary mock endpoint. Production
  // must never attach the plugin controller to the user's primary renderer just
  // because both endpoints happen to expose a Chat page.
  if port == CDPClient.port() && !allowTestTarget { return false }
  if allowTestTarget && port == CDPClient.port() { return true }
  guard pluginOwnedProfilePath(state.backgroundProfilePath) else { return false }
  guard let activeProfile = pluginProfilePathForPort(port) else { return false }
  return canonicalPluginPath(activeProfile)
    == canonicalPluginPath(state.backgroundProfilePath ?? "")
}

func pluginBackgroundRuntimeState(_ state: PluginState) -> QueueTargetRuntimeState? {
  guard let port = state.backgroundAppPort,
        let targetId = state.backgroundChatTargetId,
        pluginOwnsBackgroundTarget(port: port, targetId: targetId, state: state) else {
    return nil
  }
  return queueTargetRuntimeState(
    port: port,
    targetId: targetId,
    refreshLifecycle: false
  )
}

func loadedApprovalTargets(_ state: PluginState) -> [CDPApprovalTarget] {
  // The watcher may act only on the exact renderer recorded by the plugin. Its
  // window may be visible or hidden; ownership and the real Chat surface are
  // the safety boundary, while visibility is reported as telemetry.
  guard let port = state.backgroundAppPort,
        let targetId = state.backgroundChatTargetId,
        pluginOwnsBackgroundTarget(port: port, targetId: targetId, state: state),
        let runtimeState = pluginBackgroundRuntimeState(state),
        runtimeState == .hidden || (
          queueAllowsVisibleDedicatedRenderer() && runtimeState == .visible
        ),
        let target = CDPClient.fetchTargets(portOverride: port).first(where: {
          $0["id"] as? String == targetId && isLoadedApprovalRendererTarget($0)
        }) else { return [] }
  return [CDPApprovalTarget(port: port, target: target)]
}

func normalizedChatURL(_ rawValue: String?) -> String? {
  guard let rawValue,
        let url = URL(string: rawValue),
        url.scheme?.lowercased() == "https",
        url.host?.lowercased() == "chatgpt.com",
        url.path == "/" || url.path.hasPrefix("/c/") else { return nil }
  var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
  components?.fragment = nil
  return components?.url?.absoluteString
}

func rememberChatURL(_ rawValue: String?, in state: inout PluginState) {
  guard let url = normalizedChatURL(rawValue) else { return }
  var urls = state.trackedChatURLs ?? []
  urls.removeAll { $0 == url }
  urls.append(url)
  state.trackedChatURLs = Array(urls.suffix(20))
}

@discardableResult
func synchronizeBackgroundTargets(
  _ state: inout PluginState,
  targets: [[String: Any]]
) -> Int {
  let liveTargetIds = Set(targets.compactMap { $0["id"] as? String })
  var backgroundTargets = state.backgroundTargets ?? [:]
  backgroundTargets = backgroundTargets.filter { liveTargetIds.contains($0.value) }
  let missingURLs = (state.trackedChatURLs ?? []).filter { backgroundTargets[$0] == nil }
  if missingURLs.isEmpty {
    state.backgroundTargets = backgroundTargets
    return 0
  }
  let appContextId = targets.lazy.compactMap { target -> String? in
    guard target["type"] as? String == "page",
          (target["url"] as? String ?? "").hasPrefix("app://"),
          let targetId = target["id"] as? String else { return nil }
    return CDPClient.targetInfo(targetId: targetId)?["browserContextId"] as? String
  }.first
  var created = 0
  for url in missingURLs {
    // Keep one plugin-owned renderer alive even while the user-facing copy is
    // still open. This preserves the exact task before ChatGPT unloads it.
    if let targetId = CDPClient.createBackgroundTarget(
      url: url,
      browserContextId: appContextId
    ) {
      backgroundTargets[url] = targetId
      created += 1
    }
  }
  state.backgroundTargets = backgroundTargets
  return created
}

func closeBackgroundTargets(_ state: inout PluginState) {
  for targetId in (state.backgroundTargets ?? [:]).values {
    // These URLs are created through the primary CDP endpoint by
    // synchronizeBackgroundTargets and are tracked by exact target id.
    _ = CDPClient.closeTarget(targetId, portOverride: CDPClient.port())
  }
  if let port = state.backgroundAppPort,
     let targetId = state.backgroundChatTargetId,
     pluginOwnsBackgroundTarget(port: port, targetId: targetId, state: state) {
    _ = CDPClient.closeTarget(targetId, portOverride: port)
  }
  if let profilePath = state.backgroundProfilePath,
     pluginOwnedProfilePath(profilePath) {
    terminatePluginChatProcess(profilePath: profilePath)
  }
  state.backgroundTargets = [:]
  state.backgroundAppPort = nil
  state.backgroundChatTargetId = nil
  state.backgroundProfilePath = nil
  state.backgroundCodexHomePath = nil
  state.backgroundConversationId = nil
}

func pluginChatProcessIds(profilePath: String) -> [pid_t] {
  guard pluginOwnedProfilePath(profilePath) else { return [] }
  let canonicalProfile = canonicalPluginPath(profilePath)
  let process = Process()
  let output = Pipe()
  process.executableURL = URL(fileURLWithPath: "/bin/ps")
  process.arguments = ["-axo", "pid=,command="]
  process.standardInput = FileHandle.nullDevice
  process.standardOutput = output
  process.standardError = FileHandle.nullDevice
  let data: Data
  do {
    try process.run()
    data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
  } catch {
    return []
  }
  guard let text = String(data: data, encoding: .utf8) else { return [] }
  let executableMarker = "/Applications/ChatGPT.app/Contents/"
  let profileMarker = "--user-data-dir=\(canonicalProfile)"
  let crashpadMarker = "--database=\(canonicalProfile)/Crashpad"
  let ids = text.split(separator: "\n").compactMap { lineSlice -> pid_t? in
    let line = String(lineSlice)
    guard line.contains(executableMarker),
          line.contains(profileMarker) || line.contains(crashpadMarker) else {
      return nil
    }
    let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
    guard let first = fields.first, let pid = pid_t(String(first)), pid > 1, pid != getpid() else {
      return nil
    }
    return pid
  }
  return Array(Set(ids)).sorted()
}

func terminatePluginChatProcess(profilePath: String) {
  guard pluginOwnedProfilePath(profilePath) else { return }
  if profilePath.contains("/task-queue/workers/") {
    terminateDedicatedChatProcess(profilePath: profilePath)
    return
  }
  func removeStaleProfileLocks() {
    // A crashed or force-terminated ChatGPT renderer can leave Chromium's
    // singleton links and Default/LOCK behind. They belong only to this
    // plugin-owned profile; removing them after the process list is empty
    // lets the next retry mount the same authenticated profile without
    // creating another app instance or deleting its cookies.
    let staleLockPaths = [
      "SingletonCookie",
      "SingletonLock",
      "SingletonSocket",
      "RunningChromeVersion",
      "Default/LOCK",
    ]
    let fileManager = FileManager.default
    for relativePath in staleLockPaths {
      let lockURL = URL(fileURLWithPath: profilePath, isDirectory: true)
        .appendingPathComponent(relativePath)
      // removeItem also handles dangling Singleton* symlinks, for which
      // fileExists(atPath:) intentionally returns false.
      try? fileManager.removeItem(at: lockURL)
    }
  }
  func liveIds() -> [pid_t] {
    pluginChatProcessIds(profilePath: profilePath).filter { watcherIsAlive($0) }
  }
  var processIds = liveIds()
  if processIds.isEmpty {
    removeStaleProfileLocks()
    return
  }
  for pid in processIds { _ = kill(pid, SIGTERM) }
  let gracefulDeadline = Date().addingTimeInterval(2.0)
  while Date() < gracefulDeadline {
    processIds = liveIds()
    if processIds.isEmpty {
      removeStaleProfileLocks()
      return
    }
    Thread.sleep(forTimeInterval: 0.1)
  }
  for pid in liveIds() { _ = kill(pid, SIGKILL) }
  if liveIds().isEmpty {
    removeStaleProfileLocks()
  }
}

@discardableResult
func ensureChatTarget(_ rawValue: String?, in state: inout PluginState) -> String? {
  guard let rawValue else { return nil }
  guard let chatURL = normalizedChatURL(rawValue) else { return nil }
  rememberChatURL(chatURL, in: &state)
  let created = synchronizeBackgroundTargets(&state, targets: CDPClient.fetchTargets())
  if created > 0 { Thread.sleep(forTimeInterval: 0.25) }
  return chatURL
}

struct CDPValueReadResult {
  let value: [String: Any]?
  let error: String?
}

func cdpValueRead(
  port: Int,
  targetId: String,
  expression: String,
  timeout: TimeInterval = 5.0
) -> CDPValueReadResult {
  let targets = CDPClient.fetchTargets(portOverride: port)
  guard let target = targets.first(where: { $0["id"] as? String == targetId }) else {
    return CDPValueReadResult(
      value: nil,
      error: "target_missing:port=\(port):targets=\(targets.count)"
    )
  }
  guard let wsURL = target["webSocketDebuggerUrl"] as? String else {
    return CDPValueReadResult(value: nil, error: "target_websocket_missing")
  }
  guard let response = CDPClient.evaluate(
    wsURLString: wsURL,
    expression: expression,
    timeout: timeout
  ) else {
    return CDPValueReadResult(value: nil, error: "evaluate_timeout_or_transport_failure")
  }
  if let protocolError = response["error"] as? [String: Any] {
    let message = protocolError["message"] as? String ?? "unknown"
    return CDPValueReadResult(value: nil, error: "evaluate_protocol_error:\(message)")
  }
  guard let outer = response["result"] as? [String: Any] else {
    return CDPValueReadResult(value: nil, error: "evaluate_result_missing")
  }
  if let exception = outer["exceptionDetails"] as? [String: Any] {
    let text = (exception["exception"] as? [String: Any])?["description"] as? String
      ?? exception["text"] as? String
      ?? "unknown"
    return CDPValueReadResult(value: nil, error: "javascript_exception:\(text)")
  }
  if let value = (outer["result"] as? [String: Any])?["value"] as? [String: Any] {
    return CDPValueReadResult(
      value: sanitizeJSONValue(value) as? [String: Any],
      error: nil
    )
  }
  if let value = outer["value"] as? [String: Any] {
    return CDPValueReadResult(
      value: sanitizeJSONValue(value) as? [String: Any],
      error: nil
    )
  }
  let remoteType = (outer["result"] as? [String: Any])?["type"] as? String ?? "unknown"
  return CDPValueReadResult(value: nil, error: "evaluate_value_not_object:type=\(remoteType)")
}

func cdpValue(
  port: Int,
  targetId: String,
  expression: String,
  timeout: TimeInterval = 5.0
) -> [String: Any]? {
  let initial = cdpValueRead(
    port: port,
    targetId: targetId,
    expression: expression,
    timeout: timeout
  ).value
  guard let initial else { return nil }
  let modelSelectionErrors: Set<String> = [
    "reasoning_high_not_selected",
    "quick_chat_thinking_not_selected",
    "quick_chat_target_model_not_selected",
  ]
  guard initial["failedStage"] as? String == "model_selection",
        let error = initial["error"] as? String,
        modelSelectionErrors.contains(error),
        selectExtraHighReasoningWithTrustedCDP(port: port, targetId: targetId) else {
    return initial
  }
  // Model selection fails before connector insertion or message input, so it is
  // safe to evaluate the send script once more after the trusted CDP repair.
  return cdpValueRead(
    port: port,
    targetId: targetId,
    expression: expression,
    timeout: timeout
  ).value ?? initial
}

private func selectExtraHighReasoningWithTrustedCDP(port: Int, targetId: String) -> Bool {
  guard let target = CDPClient.fetchTargets(portOverride: port).first(where: {
          $0["id"] as? String == targetId
        }),
        let wsURL = target["webSocketDebuggerUrl"] as? String else { return false }

  let discoveryJS = #"""
  (() => {
    const visible = element => {
      if (!element) return false;
      const rect = element.getBoundingClientRect();
      return rect.width > 0 && rect.height > 0;
    };
    const picker = [...document.querySelectorAll('button[aria-haspopup="menu"], button[aria-label]')]
      .find(element => visible(element) && /chatgpt model|选择 chatgpt 模型|選擇 chatgpt 模型/i.test(
        `${element.getAttribute('aria-label') || ''} ${element.textContent || ''}`
      ));
    const menu = [...document.querySelectorAll('[role="menu"]')].find(visible);
    const rect = picker?.getBoundingClientRect();
    return {
      menuOpen: !!menu,
      pickerX: rect ? rect.x + rect.width / 2 : null,
      pickerY: rect ? rect.y + rect.height / 2 : null
    };
  })()
  """#
  guard var discovery = cdpValueRead(
    port: port,
    targetId: targetId,
    expression: discoveryJS
  ).value else { return false }
  if discovery["menuOpen"] as? Bool != true {
    guard let x = (discovery["pickerX"] as? NSNumber)?.doubleValue,
          let y = (discovery["pickerY"] as? NSNumber)?.doubleValue,
          CDPClient.clickTarget(targetId, x: x, y: y, portOverride: port) else { return false }
    Thread.sleep(forTimeInterval: 0.45)
    discovery = cdpValueRead(
      port: port,
      targetId: targetId,
      expression: discoveryJS
    ).value ?? [:]
    guard discovery["menuOpen"] as? Bool == true else { return false }
  }

  let focusAndReadJS = #"""
  (() => {
    const control = document.querySelector('[data-reasoning-slider="true"]');
    control?.focus();
    const slider = document.querySelector('[data-model-picker-power-slider] [role="slider"]');
    const status = control?.parentElement?.querySelector('[role="status"]')
      || document.querySelector('[role="menu"] [role="status"]');
    const indexed = (status?.textContent || '').match(/第\s*(\d+)\s*[项項][，,\s]*共\s*(\d+)\s*[项項]/);
    return {
      focused: document.activeElement === control,
      now: Number(slider?.getAttribute('aria-valuenow') ?? (indexed ? Number(indexed[1]) - 1 : NaN)),
      max: Number(slider?.getAttribute('aria-valuemax') ?? (indexed ? Number(indexed[2]) - 1 : NaN))
    };
  })()
  """#
  guard let state = cdpValueRead(
    port: port,
    targetId: targetId,
    expression: focusAndReadJS
  ).value,
        state["focused"] as? Bool == true,
        let now = (state["now"] as? NSNumber)?.doubleValue,
        let max = (state["max"] as? NSNumber)?.doubleValue,
        now.isFinite, max.isFinite, max >= 2 else { return false }
  let desired = Int(max) - 1
  let current = Int(now)
  let key = current <= desired ? "ArrowRight" : "ArrowLeft"
  for _ in 0..<abs(desired - current) {
    guard CDPClient.dispatchArrowKey(wsURLString: wsURL, key: key) else { return false }
    Thread.sleep(forTimeInterval: 0.2)
  }
  Thread.sleep(forTimeInterval: 0.35)

  let verificationJS = #"""
  (() => {
    const picker = [...document.querySelectorAll('button[aria-haspopup="menu"], button[aria-label]')]
      .find(element => /chatgpt model|选择 chatgpt 模型|選擇 chatgpt 模型/i.test(
        `${element.getAttribute('aria-label') || ''} ${element.textContent || ''}`
      ));
    const label = `${picker?.textContent || ''} ${picker?.getAttribute('data-selected-reasoning-effort') || ''}`.toLowerCase();
    const slider = document.querySelector('[data-model-picker-power-slider] [role="slider"]');
    const now = Number(slider?.getAttribute('aria-valuenow'));
    const max = Number(slider?.getAttribute('aria-valuemax'));
    return {ok: /extra high|极高|極高|额外高|額外高/.test(label)
      || (Number.isFinite(now) && Number.isFinite(max) && now === max - 1)};
  })()
  """#
  return cdpValueRead(
    port: port,
    targetId: targetId,
    expression: verificationJS
  ).value?["ok"] as? Bool == true
}

func pageDiagnosticJS() -> String {
  #"""
  (async () => {
    const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
    const thinkingToggles = [...document.querySelectorAll('button')].filter(button => {
      const text = (button.innerText || '').trim();
      return text.startsWith('正在思考') || text.startsWith('Thinking');
    });
    const latestThinking = thinkingToggles[thinkingToggles.length - 1];
    if (latestThinking?.getAttribute('aria-expanded') === 'false') {
      latestThinking.click();
      await sleep(120);
    }
    const root = document.querySelector('main') || document.body;
    const redact = value => (value || '')
      .replace(/\bsk-[A-Za-z0-9_-]{4,}\b/g, '[REDACTED_API_KEY]')
      .replace(/\b(Bearer\s+)[A-Za-z0-9._~+\/-]+=*/gi, '$1[REDACTED_TOKEN]')
      .replace(/\b([A-Z][A-Z0-9_]*(?:TOKEN|API_KEY|SECRET|PASSWORD))=([^\s,]+)/g, '$1=[REDACTED]')
      .replace(/(DeviceID\s*\n)[^\n]+/gi, '$1[REDACTED_DEVICE_ID]');
    const text = redact((root?.innerText || '').replace(/\s+$/g, ''));
    const buttons = [...document.querySelectorAll('button')]
      .filter(button => button.offsetWidth || button.offsetHeight || button.getClientRects().length)
      .map(button => (button.innerText || button.getAttribute('aria-label') || '').trim())
      .filter(Boolean)
      .slice(0, 100);
    const normalizeModeText = value => (value || '').replace(/\s+/g, ' ').trim();
    const modeNodes = [...document.querySelectorAll('body *')]
      .filter(node => node.children.length === 0)
      .filter(node => ['Chat', 'Work', '聊天', '工作'].includes(normalizeModeText(node.innerText || node.textContent)))
      .filter(node => node.offsetWidth || node.offsetHeight || node.getClientRects().length)
      .slice(0, 40)
      .map(node => ({
        text: normalizeModeText(node.innerText || node.textContent),
        tag: node.tagName || '',
        role: node.getAttribute('role') || '',
        ariaSelected: node.getAttribute('aria-selected') || '',
        ariaPressed: node.getAttribute('aria-pressed') || '',
        className: normalizeModeText(node.className),
        parent: node.parentElement?.outerHTML?.slice(0, 600) || ''
      }));
    return {
      ok: true,
      content: text.substring(0, 50000),
      buttons,
      modeNodes,
      signature: `${text.length}:${text.slice(-4000)}:${buttons.join('|')}`,
      url: window.location.href || ''
    };
  })()
  """#
}

func captureHiddenChatScreenshot(
  port: Int,
  targetId: String,
  label: String = "stalled"
) -> String? {
  guard let target = CDPClient.fetchTargets(portOverride: port).first(where: {
          $0["id"] as? String == targetId
        }),
        let wsURL = target["webSocketDebuggerUrl"] as? String else { return nil }
  let formatter = DateFormatter()
  formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
  let outputURL = stateURL().deletingLastPathComponent()
    .appendingPathComponent("diagnostics", isDirectory: true)
    .appendingPathComponent("chat-\(label)-\(formatter.string(from: Date())).png")
  _ = CDPClient.setWebLifecycleActive(wsURLString: wsURL)
  return CDPClient.captureScreenshot(wsURLString: wsURL, outputURL: outputURL)
    ? outputURL.path
    : nil
}

func captureHiddenChatScreenshot(_ state: PluginState, label: String = "stalled") -> String? {
  guard let port = state.backgroundAppPort,
        let targetId = state.backgroundChatTargetId else { return nil }
  return captureHiddenChatScreenshot(port: port, targetId: targetId, label: label)
}

func hiddenChatProfilePath() -> String {
  FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Mahayana/plugins/chatgpt-auto-confirm/background-chat-profile")
    .path
}

func configuredHiddenChatProfilePath() -> String? {
  guard let raw = ProcessInfo.processInfo.environment["CHATGPT_AUTO_CONFIRM_PROFILE_PATH"]?
          .trimmingCharacters(in: .whitespacesAndNewlines),
        !raw.isEmpty else { return nil }
  return raw
}

func hiddenChatPort(_ state: PluginState) -> Int {
  if let raw = ProcessInfo.processInfo.environment["CHATGPT_AUTO_CONFIRM_BACKGROUND_PORT"],
     let port = Int(raw), port > 0 && port <= 65535 { return port }
  return state.backgroundAppPort ?? 9324
}

func configuredHiddenChatPort() -> Int? {
  guard let raw = ProcessInfo.processInfo.environment["CHATGPT_AUTO_CONFIRM_BACKGROUND_PORT"],
        let port = Int(raw), port > 0 && port <= 65535 else { return nil }
  return port
}

func backgroundConversationURL(_ conversationId: String) -> String? {
  var components = URLComponents(string: "app://-/index.html")
  components?.queryItems = [
    URLQueryItem(
      name: "initialRoute",
      value: "/work/conversation/\(conversationId)"
    )
  ]
  return components?.url?.absoluteString
}

func wakeHiddenRenderer(
  port: Int,
  targetId: String,
  wsURL: String
) -> Bool {
  // Electron can leave a show:false renderer with its document and scripts
  // loaded while React remains suspended. CDP focus emulation and an active
  // idle state wake the renderer scheduler without showing the BrowserWindow,
  // focusing the application, or changing document.visibilityState.
  _ = CDPClient.setWebLifecycleActive(wsURLString: wsURL)
  _ = CDPClient.setHiddenPageFocusEmulation(wsURLString: wsURL)
  _ = CDPClient.setHiddenPageUserActive(wsURLString: wsURL)
  let probe = cdpValue(
    port: port,
    targetId: targetId,
    expression: """
    (async () => {
      document.dispatchEvent(new Event('visibilitychange'));
      window.dispatchEvent(new Event('focus'));
      const startedAt = performance.now();
      await new Promise(resolve => setTimeout(resolve, 50));
      return {
        bridge: !!window.electronBridge,
        visibility: document.visibilityState,
        href: location.href,
        eventLoopDelayMs: performance.now() - startedAt
      };
    })()
    """,
    timeout: 4.0
  )
  let eventLoopDelayMs = (probe?["eventLoopDelayMs"] as? NSNumber)?.doubleValue
    ?? Double.greatestFiniteMagnitude
  return (probe?["bridge"] as? NSNumber)?.boolValue == true
    && probe?["visibility"] as? String == "hidden"
    && (probe?["href"] as? String ?? "").hasPrefix("app://-/index.html")
    && eventLoopDelayMs < 2_500
}

func navigateHiddenConversation(
  port: Int,
  targetId: String,
  conversationId: String,
  timeout: TimeInterval = 35.0,
  allowVisible: Bool = false
) -> Bool {
  guard let url = backgroundConversationURL(conversationId),
        let target = CDPClient.fetchTargets(portOverride: port).first(where: {
          $0["id"] as? String == targetId
        }),
        let wsURL = target["webSocketDebuggerUrl"] as? String,
        CDPClient.navigate(wsURLString: wsURL, url: url) else { return false }
  Thread.sleep(forTimeInterval: 0.5)
  let initialRuntimeState = queueTargetRuntimeState(
    port: port,
    targetId: targetId,
    refreshLifecycle: false
  )
  switch initialRuntimeState {
  case .hidden, .hiddenNonChat:
    guard wakeHiddenRenderer(port: port, targetId: targetId, wsURL: wsURL) else {
      return false
    }
  case .visible:
    guard allowVisible else { return false }
  case .missing, .suspended:
    return false
  }
  let deadline = Date().addingTimeInterval(timeout)
  repeat {
    let runtimeState = queueTargetRuntimeState(
      port: port,
      targetId: targetId,
      refreshLifecycle: true
    )
    switch runtimeState {
    case .hidden, .hiddenNonChat:
      break
    case .visible:
      if !allowVisible { return false }
    case .missing, .suspended:
      return false
    }
    if let status = cdpValue(
      port: port,
      targetId: targetId,
      expression: chatStatusJS(),
      timeout: 5.0
    ), normalizedConversationId(status["conversationId"] as? String) == conversationId,
       status["chatMode"] as? Bool == true {
      return true
    }
    Thread.sleep(forTimeInterval: 0.25)
  } while Date() < deadline
  return false
}

func restoreHiddenConversation(
  port: Int,
  targetId: String,
  conversationId: String,
  timeout: TimeInterval = 35.0,
  allowVisible: Bool = false,
  dispatchMarker: String? = nil
) -> [String: Any] {
  // Prefer the live sidebar. A direct Page.navigate on the hosted desktop
  // renderer can leave the app on its startup spinner, which also poisons the
  // subsequent fresh-chat fallback.
  let sidebar = cdpValue(
    port: port,
    targetId: targetId,
    expression: selectBackgroundConversationJS(conversationId),
    timeout: min(timeout, 20.0)
  )
  if sidebar?["ok"] as? Bool == true,
     let status = cdpValue(
       port: port,
       targetId: targetId,
       expression: chatStatusJS(),
       timeout: 5.0
     ), normalizedConversationId(status["conversationId"] as? String) == conversationId,
        status["chatMode"] as? Bool == true {
    var result = sidebar ?? [:]
    result["ok"] = true
    result["strategy"] = "sidebar"
    return result
  }

  // The desktop sidebar and portal id can lag behind the body after a long
  // response. For a queue-owned renderer, the per-send marker in the current
  // user bubble is stronger evidence than stale navigation metadata. Keep the
  // current page and branch it directly instead of navigating away.
  if let dispatchMarker,
     let status = cdpValue(
       port: port,
       targetId: targetId,
       expression: chatStatusJS(),
       timeout: 5.0
     ), status["chatMode"] as? Bool == true,
     let reply = cdpValue(
       port: port,
       targetId: targetId,
       expression: getReplyJS(),
       timeout: 6.0
     ) {
    let pageText = [
      reply["userContent"] as? String ?? "",
      reply["pageContent"] as? String ?? "",
    ].joined(separator: "\n")
    if pageText.contains(dispatchMarker) {
      // chatStatusJS intentionally prefers the initial route, but the hosted
      // desktop app can keep that route stale after replacing the composer
      // with a local conversation. The continuation guard reads the composer
      // portal, so obtain the identity from that exact same source.
      let composerIdentity = cdpValue(
        port: port,
        targetId: targetId,
        expression: currentComposerConversationIdentityJS(),
        timeout: 5.0
      )
      let liveConversationId = normalizedConversationId(
        composerIdentity?["conversationId"] as? String
      )
      var result: [String: Any] = [
        "ok": true,
        "strategy": "current-dispatch-marker",
        "selected": false,
        "alreadyActive": true,
        "dispatchMarkerConfirmed": true,
      ]
      if let liveConversationId {
        result["conversationId"] = liveConversationId
      }
      return result
    }
  }

  let sidebarError = sidebar?["error"] as? String
    ?? "continuation_sidebar_selection_failed"
  let navigated = navigateHiddenConversation(
    port: port,
    targetId: targetId,
    conversationId: conversationId,
    timeout: timeout,
    allowVisible: allowVisible
  )
  return [
    "ok": navigated,
    "error": navigated ? "" : "continuation_route_navigation_failed",
    "strategy": "route",
    "sidebarError": sidebarError,
    "conversationId": conversationId,
  ]
}

func currentComposerConversationIdentityJS() -> String {
  #"""
  (() => {
    const raw = document.querySelector('[data-above-composer-conversation-id]')
      ?.getAttribute('data-above-composer-conversation-id') || '';
    const conversationId = raw.startsWith('chatgpt:')
      ? raw.slice('chatgpt:'.length)
      : raw;
    return {
      ok: !!conversationId,
      conversationId: conversationId || null,
      source: conversationId ? 'composer-portal' : 'none'
    };
  })()
  """#
}

func selectBackgroundConversationJS(_ conversationId: String) -> String {
  let expected = jsonStringLiteral(conversationId)
  return """
  (async () => {
    const expected = \(expected);
    const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
    const rendered = element => !!(element
      && (element.offsetWidth || element.offsetHeight || element.getClientRects().length));
    const dispatchPointerClick = element => {
      const rect = element.getBoundingClientRect?.();
      const clientX = rect ? rect.left + Math.max(1, rect.width / 2) : 1;
      const clientY = rect ? rect.top + Math.max(1, rect.height / 2) : 1;
      const pressed = {
        bubbles: true, cancelable: true, composed: true,
        button: 0, buttons: 1, clientX, clientY
      };
      element.dispatchEvent(new PointerEvent('pointerdown', {
        ...pressed, pointerId: 1, pointerType: 'mouse', isPrimary: true
      }));
      element.dispatchEvent(new MouseEvent('mousedown', pressed));
      element.dispatchEvent(new PointerEvent('pointerup', {
        ...pressed, buttons: 0, pointerId: 1, pointerType: 'mouse', isPrimary: true
      }));
      element.dispatchEvent(new MouseEvent('mouseup', { ...pressed, buttons: 0 }));
      element.dispatchEvent(new MouseEvent('click', { ...pressed, buttons: 0 }));
    };
    const portalId = () => {
      const raw = document.querySelector('[data-above-composer-conversation-id]')
        ?.getAttribute('data-above-composer-conversation-id') || '';
      return raw.startsWith('chatgpt:') ? raw.slice('chatgpt:'.length) : raw;
    };
    const conversationFingerprint = () => {
      const nodes = [...document.querySelectorAll(
        '[data-message-author-role], [data-user-message-bubble], [data-local-conversation-final-assistant]'
      )];
      return nodes.map((node, index) => {
        const role = node.getAttribute('data-message-author-role')
          || (node.hasAttribute('data-user-message-bubble') ? 'user' : 'assistant');
        const text = (node.innerText || node.textContent || '').trim();
        return `${index}:${role}:${text.length}:${text.slice(-240)}`;
      }).join('|');
    };
    const waitForConversationBody = async (previousFingerprint = '', requireChange = false) => {
      for (let index = 0; index < 40; index += 1) {
        const fingerprint = conversationFingerprint();
        if (fingerprint && (!requireChange || fingerprint !== previousFingerprint)) {
          return { ok: true, fingerprint };
        }
        await sleep(150);
      }
      return { ok: false, error: 'conversation_body_not_ready' };
    };
    const matches = value => {
      if (!value || typeof value !== 'string') return false;
      let decoded = value;
      try { decoded = decodeURIComponent(value); } catch {}
      return decoded === expected || decoded.endsWith(`:${expected}`)
        || decoded.endsWith(`/c/${expected}`)
        || decoded.endsWith(`/work/conversation/${expected}`)
        || (expected.startsWith('local-chatgpt:') && decoded.includes(expected));
    };
    const rowMatches = row => {
      const domCandidates = [
        row.getAttribute?.('href'), row.getAttribute?.('data-conversation-id'),
        row.getAttribute?.('data-thread-id'), row.getAttribute?.('data-testid')
      ];
      if (domCandidates.some(matches)) return true;
      const fiberKey = Object.keys(row).find(key => key.startsWith('__reactFiber$'));
      let fiber = fiberKey ? row[fiberKey] : null;
      // Stop before the virtual-list parent. That parent contains every item
      // key and would make the first visible row appear to match any task.
      for (let depth = 0; fiber && depth < 8; depth += 1, fiber = fiber.return) {
        const props = fiber.memoizedProps || {};
        // activeConversationId is shared by every visible row and identifies
        // the current page, not the row. Never use it for row ownership.
        const candidates = [props.conversationId, props.route,
          props.shortcutKey, props.item, props.conversation?.id];
        if (candidates.some(matches)) return true;
      }
      return false;
    };
    const current = portalId();
    if (matches(current)) {
      const ready = await waitForConversationBody();
      return ready.ok
        ? { ok: true, selected: false, alreadyActive: true, messagesReady: true, conversationId: current }
        : { ok: false, error: ready.error, expected, conversationId: current };
    }
    const directLinks = [...document.querySelectorAll(
      `a[href*="/c/${expected}"], a[href*="/work/conversation/${expected}"], `
        + `[data-conversation-id="${expected}"], [data-thread-id="${expected}"]`
    )];
    const titledRows = [...document.querySelectorAll('[data-thread-title="true"]')]
      .map(title => title.closest('a, button, [role="button"]')).filter(Boolean);
    const rows = [...new Set([...directLinks, ...titledRows])].filter(rendered);
    const row = rows.find(rowMatches);
    if (!row) {
      return {
        ok: false,
        error: 'conversation_sidebar_row_not_found',
        expected,
        candidateRowCount: rows.length,
        directLinkCount: directLinks.length
      };
    }
    const previousFingerprint = conversationFingerprint();
    const clickStrategy = directLinks.includes(row) ? 'direct-link' : 'sidebar-row';
    dispatchPointerClick(row);
    for (let index = 0; index < 40; index += 1) {
      await sleep(150);
      const resolved = portalId();
      const input = document.querySelector('#prompt-textarea')
        || document.querySelector('[contenteditable="true"]');
      if (resolved && input && (matches(resolved) || rowMatches(row))) {
        const exactConversation = matches(resolved);
        const ready = await waitForConversationBody(previousFingerprint, !exactConversation);
        return ready.ok
          ? {
              ok: true, selected: true, messagesReady: true,
              conversationId: resolved, clickStrategy,
              candidateRowCount: rows.length, directLinkCount: directLinks.length
            }
          : {
              ok: false, error: ready.error, expected,
              conversationId: resolved, clickStrategy,
              candidateRowCount: rows.length, directLinkCount: directLinks.length
            };
      }
    }
    return {
      ok: false,
      error: 'conversation_sidebar_selection_timeout', expected, clickStrategy,
      candidateRowCount: rows.length, directLinkCount: directLinks.length
    };
  })()
  """
}

func normalizedConversationId(_ rawValue: String?) -> String? {
  guard let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
        !value.isEmpty,
        value.range(
          of: "^(?:local-chatgpt:)?[A-Za-z0-9-]{8,128}$",
          options: .regularExpression
        ) != nil else { return nil }
  return value
}

func prepareBackgroundChatJS(
  newChat: Bool,
  conversationId: String? = nil,
  confirmedChatMode: Bool = false
) -> String {
  let newChatValue = newChat ? "true" : "false"
  let confirmedChatModeValue = confirmedChatMode ? "true" : "false"
  let expectedConversationId = jsonStringLiteral(conversationId ?? "")
  return """
  (async () => {
    const result = {
      ok: false,
      backgroundOnly: document.visibilityState === 'hidden',
      runtimeState: document.visibilityState === 'hidden' ? 'hidden' : 'visible',
      workerUsed: false,
      newChatClicked: false, chatSelected: false, error: null,
      url: window.location.href || '', conversationId: null
    };
    const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
    const confirmedChatMode = \(confirmedChatModeValue);
    // Selecting ChatGPT can replace the Electron renderer and erase transient
    // window globals. The native caller carries that verified selection across
    // the replacement and reseeds the new renderer before surface detection.
    if (confirmedChatMode) window.__mahayanaConfirmedChatGPTMode = true;
    const exactButton = text => [...document.querySelectorAll('button, a, [role="button"]')].find(button =>
      (button.innerText || button.textContent || button.getAttribute('title') || '').trim().toLowerCase() === text.toLowerCase()
    );
    const currentConversationId = () => {
      const raw = document.querySelector('[data-above-composer-conversation-id]')
        ?.getAttribute('data-above-composer-conversation-id') || '';
      return raw.startsWith('chatgpt:') ? raw.slice('chatgpt:'.length) : raw;
    };
    const previousConversationId = currentConversationId();

    if (\(newChatValue)) {
      // The desktop app has used all of these labels for the same action
      // across Chat/Work releases and locales.
      const button = ['新聊天', '新对话', '新建任务', '新任务', 'New chat', 'New conversation', 'New task']
        .map(exactButton).find(Boolean);
      if (!button) {
        result.error = 'new_chat_button_not_found';
        return result;
      }
      button.click();
      result.newChatClicked = true;
      await sleep(650);
    }

    if (\(newChatValue)) {
      let freshConversationId = currentConversationId();
      for (let index = 0; index < 40 && (!freshConversationId
          || freshConversationId === previousConversationId); index += 1) {
        await sleep(150);
        freshConversationId = currentConversationId();
      }
      if (!freshConversationId || freshConversationId === previousConversationId) {
        result.error = 'new_chat_conversation_not_created';
        result.previousConversationId = previousConversationId || null;
        result.conversationId = freshConversationId || null;
        return result;
      }
    }

    const quickChatRoot = document.querySelector(
      '[data-pip-obstacle="quick-chat"], [data-quick-chat-drag-handle]'
    )?.closest('[role="dialog"], section, div');
    const input = quickChatRoot?.querySelector(
      '#prompt-textarea, [contenteditable="true"]'
    ) || document.querySelector('#prompt-textarea')
      || document.querySelector('[contenteditable="true"]');
    const chatModel = [...document.querySelectorAll('button, a, [role="button"]')].some(button => {
      const label = button.getAttribute('aria-label') || '';
      return label.includes('ChatGPT 模型') || /select chatgpt model/i.test(label);
    });
    const currentChatGPTMode = window.__mahayanaConfirmedChatGPTMode === true
      || [...document.querySelectorAll('button, a, [role="button"]')]
      .some(button => {
        const label = [
          button.innerText,
          button.textContent,
          button.getAttribute('aria-label'),
          button.getAttribute('title')
        ].filter(Boolean).join(' ').toLowerCase();
        return label.includes('current mode: chatgpt')
          || (label.includes('当前模式') && label.includes('chatgpt'));
      });
    const webChat = window.location.protocol === 'https:'
      && window.location.hostname === 'chatgpt.com';
    // The top-level Chat/Work switch is authoritative. A stale mode flag must
    // not make the Work composer look like Chat after a renderer replacement.
    const workComposer = !quickChatRoot
      && !!document.querySelector('[data-codex-composer="true"]');
    
    const isChatSurface = !!quickChatRoot
      || !!document.querySelector('#prompt-textarea')
      || chatModel
      || currentChatGPTMode
      || webChat
      || window.location.protocol === 'chatgpt:';

    const initialRoute = new URL(window.location.href).searchParams.get('initialRoute') || '';
    const routeMatch = initialRoute.match(/^\\/work\\/conversation\\/([^/?#]+)/);
    const portalConversation = document.querySelector('[data-above-composer-conversation-id]')
      ?.getAttribute('data-above-composer-conversation-id') || '';
    const portalConversationId = portalConversation.startsWith('chatgpt:')
      ? portalConversation.slice('chatgpt:'.length)
      : portalConversation;
    // The Electron shell keeps initialRoute from the previously opened Chat
    // after New conversation has already replaced the live renderer state.
    // Prefer the portal owned by the current composer; use the route only
    // while that live marker is absent during startup.
    result.conversationId = portalConversationId
      || (routeMatch ? decodeURIComponent(routeMatch[1]) : null);
    result.messageCount = document.querySelectorAll(
      '[data-message-author-role], [data-user-message-bubble], [data-local-conversation-final-assistant]'
    ).length;
    result.inputTextLength = (
      input?.tagName === 'TEXTAREA' || input?.tagName === 'INPUT'
        ? (input.value || '')
        : (input?.innerText || input?.textContent || '')
    ).trim().length;
    const expectedConversationId = \(expectedConversationId);
    result.expectedConversationId = expectedConversationId || null;
    if (!input || !isChatSurface || workComposer) {
      result.error = 'not_chat_surface';
      result.hasInput = !!input;
      result.chatModel = chatModel;
      result.workComposer = workComposer;
      result.html = document.body ? document.body.innerHTML.slice(0, 50000) : '';
      return result;
    }
    result.ok = true;
    result.chatSelected = true;
    result.surface = 'chat';
    result.hasInput = true;
    return result;
  })()
  """
}

func resolveDispatchedConversationJS(
  dispatchMarker: String,
  localConversationId: String?
) -> String {
  let marker = jsonStringLiteral(dispatchMarker)
  let localId = jsonStringLiteral(localConversationId ?? "")
  return """
  (async () => {
    const dispatchMarker = \(marker);
    const expectedLocalId = \(localId);
    const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
    const normalizeId = raw => {
      if (typeof raw !== 'string' || !raw) return '';
      let value = raw;
      try { value = decodeURIComponent(value); } catch {}
      return value.startsWith('chatgpt:') ? value.slice('chatgpt:'.length) : value;
    };
    const portalId = () => normalizeId(
      document.querySelector('[data-above-composer-conversation-id]')
        ?.getAttribute('data-above-composer-conversation-id') || ''
    );
    const rowCandidates = () => {
      const values = [];
      const rows = [...new Set(
        [...document.querySelectorAll(
          '[data-thread-title="true"], a[href*="/c/"], a[href*="/work/conversation/"]'
        )]
          .map(element => element.closest('[role="button"], a[href]'))
          .filter(Boolean)
      )];
      for (const row of rows) {
        const title = (
          row.querySelector('[data-thread-title="true"]')?.textContent
            || row.textContent || ''
        ).trim();
        const fiberKey = Object.keys(row).find(key => key.startsWith('__reactFiber$'));
        let fiber = fiberKey ? row[fiberKey] : null;
        const identities = [];
        const durableIds = [];
        for (const attribute of ['data-conversation-id', 'data-thread-id']) {
          identities.push(row.getAttribute(attribute));
        }
        const routeValues = [
          row.getAttribute('href'),
          ...[...row.querySelectorAll('a[href]')].map(anchor => anchor.getAttribute('href'))
        ];
        for (const route of routeValues) {
          if (typeof route !== 'string') continue;
          const match = route.match(/\\/(?:c|work\\/conversation)\\/([^/?#]+)/);
          if (match) identities.push(match[1]), durableIds.push(match[1]);
        }
        for (let depth = 0; fiber && depth < 8; depth += 1, fiber = fiber.return) {
          const props = fiber.memoizedProps || {};
          identities.push(props.conversationId, props.conversation?.id);
          if (typeof props.conversation?.id === 'string') {
            durableIds.push(props.conversation.id);
          }
          for (const route of [props.route, props.shortcutKey]) {
            if (typeof route !== 'string') continue;
            const match = route.match(/\\/(?:c|work\\/conversation)\\/([^/?#]+)/);
            if (match) identities.push(match[1]);
          }
        }
        const normalizedIdentities = [...new Set(identities.map(normalizeId).filter(Boolean))];
        const durableId = durableIds.map(normalizeId).find(id =>
          id && !id.startsWith('local-chatgpt:')
        ) || normalizedIdentities.find(id => id && !id.startsWith('local-chatgpt:'));
        values.push({
          identities: normalizedIdentities,
          durableId: durableId || '',
          title
        });
      }
      return values;
    };
    for (let index = 0; index < 80; index += 1) {
      const users = [...document.querySelectorAll(
        '[data-message-author-role="user"], [data-user-message-bubble]'
      )];
      const markerVisible = users.some(user =>
        (user.innerText || user.textContent || '').includes(dispatchMarker)
      );
      if (markerVisible) {
        const portal = portalId();
        if (portal && !portal.startsWith('local-chatgpt:')) {
          return {ok: true, conversationId: portal, source: 'portal'};
        }
        // The sidebar can virtualize old rows while the user creates a
        // foreground Chat, so "first id absent from the baseline" is unsafe.
        // ChatGPT exposes an exact local->durable mapping on the task's own
        // row: its route keeps the local id while conversation.id is durable.
        const candidate = expectedLocalId
          ? rowCandidates().find(value =>
              value.identities.includes(expectedLocalId) && value.durableId
            )
          : null;
        if (candidate?.durableId) {
          return {
            ok: true,
            conversationId: candidate.durableId,
            source: 'local-row-mapping',
            title: candidate.title
          };
        }
      }
      await sleep(250);
    }
    return {
      ok: false,
      error: 'durable_conversation_id_pending',
      portalConversationId: portalId() || null
    };
  })()
  """
}

func clickNewChatJS() -> String {
  #"""
  (() => {
    const raw = document.querySelector('[data-above-composer-conversation-id]')
      ?.getAttribute('data-above-composer-conversation-id') || '';
    const previousConversationId = raw.startsWith('chatgpt:')
      ? raw.slice('chatgpt:'.length)
      : raw;
    const exactButton = text => [...document.querySelectorAll('button, a, [role="button"]')].find(button => {
      const target = text.toLowerCase();
      const labels = [
        button.innerText,
        button.textContent,
        button.getAttribute('aria-label'),
        button.getAttribute('title')
      ].filter(Boolean).map(t => t.trim().toLowerCase());
      return labels.includes(target) || labels.some(l => l.includes(target));
    });
    const button = ['新聊天', '新对话', '新建任务', '新任务', 'new chat', 'new conversation', 'new task']
      .map(exactButton).find(Boolean) || document.querySelector('[href="/"]');
    if (!button) {
      const isMac = window.location.protocol === 'chatgpt:';
      window.location.href = isMac ? 'chatgpt://work/' : '/';
      return { ok: true, newChatClicked: true, previousConversationId, fallbackNavigated: true };
    }
    const rect = button.getBoundingClientRect?.();
    if (rect && rect.width > 0 && rect.height > 0) {
      return {
        ok: true,
        newChatClicked: true,
        previousConversationId,
        nativeClickRecommended: true,
        x: rect.left + rect.width / 2,
        y: rect.top + rect.height / 2
      };
    }
    button.click();
    return { ok: true, newChatClicked: true, previousConversationId };
  })()
  """#
}

func clickChatJS() -> String {
  #"""
  (async () => {
    const normalize = value => (value || '').replace(/\s+/g, ' ').trim().toLowerCase();
    const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
    const candidates = () => [...document.querySelectorAll(
      'button, a, [role="button"], [role="menuitem"], '
        + '[role="menuitemradio"], [role="option"], [role="tab"]'
    )];
    const labelsFor = candidate => [
      candidate.innerText,
      candidate.textContent,
      candidate.getAttribute('aria-label'),
      candidate.getAttribute('title')
    ].map(normalize).filter(Boolean);
    const dispatchPointerClick = candidate => {
      const rect = candidate.getBoundingClientRect?.();
      const clientX = rect ? rect.left + Math.min(12, Math.max(1, rect.width / 2)) : 1;
      const clientY = rect ? rect.top + Math.min(12, Math.max(1, rect.height / 2)) : 1;
      const pressed = {
        bubbles: true,
        cancelable: true,
        composed: true,
        button: 0,
        buttons: 1,
        clientX,
        clientY
      };
      // Radix's compact mode trigger opens on pointerdown. HTMLElement.click()
      // emits only click, so the hosted app silently stayed on the Codex/Work
      // composer even though the dispatch itself reported success.
      candidate.dispatchEvent(new PointerEvent('pointerdown', {
        ...pressed,
        pointerId: 1,
        pointerType: 'mouse',
        isPrimary: true
      }));
      candidate.dispatchEvent(new MouseEvent('mousedown', pressed));
      candidate.dispatchEvent(new PointerEvent('pointerup', {
        ...pressed,
        buttons: 0,
        pointerId: 1,
        pointerType: 'mouse',
        isPrimary: true
      }));
      candidate.dispatchEvent(new MouseEvent('mouseup', { ...pressed, buttons: 0 }));
      candidate.dispatchEvent(new MouseEvent('click', { ...pressed, buttons: 0 }));
    };
    const visible = candidate => {
      const rect = candidate.getBoundingClientRect?.();
      return !!rect && (rect.width > 0 || rect.height > 0 || candidate.offsetParent !== null);
    };
    const isSelected = candidate => {
      const selectedValues = [
        candidate.getAttribute('aria-selected'),
        candidate.getAttribute('aria-pressed'),
        candidate.getAttribute('data-state'),
        candidate.getAttribute('data-selected'),
        candidate.getAttribute('data-active')
      ].map(normalize);
      if (selectedValues.some(value => ['true', 'active', 'selected', 'on'].includes(value))) {
        return true;
      }
      return /(?:^|[ _-])(active|selected|current|chosen)(?:$|[ _-])/.test(
        normalize(candidate.className)
      );
    };
    // Do not treat labels such as "Chat sidebar options" as the Chat mode.
    // The Work composer exposes that sidebar label even when the top-level
    // Chat/Work switch is absent, which previously produced a false success.
    const isChatLabel = label => label === 'chat' || label === '聊天';
    const isWorkLabel = label => label === 'work' || label === '工作';
    // The compact desktop layout replaces the top Chat/Work tabs with a mode
    // popup whose real Chat choice is named "ChatGPT". Accept that exact label
    // only when it is a menu/list choice, never from the sidebar heading or a
    // model button.
    const isChatGPTMenuChoice = candidate => {
      const role = normalize(candidate.getAttribute('role'));
      const choiceRole = role === 'menuitem'
        || role === 'menuitemradio'
        || role === 'option';
      const insideChoicePopup = !!candidate.closest('[role="menu"], [role="listbox"]');
      const hasExactChatGPTChild = [...candidate.querySelectorAll('*')].some(child =>
        child.children.length === 0 && normalize(child.textContent) === 'chatgpt'
      );
      return (choiceRole || insideChoicePopup)
        && (labelsFor(candidate).some(label => label === 'chatgpt')
          || hasExactChatGPTChild);
    };
    const modeTabScore = candidate => {
      const rect = candidate.getBoundingClientRect?.();
      const role = normalize(candidate.getAttribute('role'));
      const labels = labelsFor(candidate);
      let score = 0;
      if (role === 'tab' || role === 'option' || role.startsWith('menuitem')) score += 100;
      if (isSelected(candidate)) score += 50;
      if (visible(candidate)) score += 10;
      if (rect && rect.top >= -20 && rect.top < 180) score += 20;
      if (rect && window.innerWidth > 0
          && rect.left > window.innerWidth * 0.25
          && rect.right < window.innerWidth * 0.8) score += 10;
      if (labels.some(label => isChatLabel(label) || isWorkLabel(label))
          || isChatGPTMenuChoice(candidate)) score += 5;
      return score;
    };
    const textModeNodes = () => [...document.querySelectorAll('body *')]
      .filter(candidate => candidate.children.length === 0 && visible(candidate))
      .filter(candidate => labelsFor(candidate).some(label => isChatLabel(label) || isWorkLabel(label)));
    const modeTabs = () => [...new Set([...candidates(), ...textModeNodes()])]
      .filter(candidate => visible(candidate))
      .filter(candidate =>
        labelsFor(candidate).some(label => isChatLabel(label) || isWorkLabel(label))
          || isChatGPTMenuChoice(candidate)
      );
    const modeControls = modeTabs().map(candidate => ({
      label: labelsFor(candidate)[0] || '',
      tag: candidate.tagName || '',
      role: candidate.getAttribute('role') || '',
      className: normalize(candidate.className),
      selected: isSelected(candidate),
      score: modeTabScore(candidate)
    }));
    const chatSurface = () => {
      const quickChatRoot = document.querySelector(
        '[data-pip-obstacle="quick-chat"], [data-quick-chat-drag-handle]'
      )?.closest('[role="dialog"], section, div');
      const input = quickChatRoot?.querySelector(
        '#prompt-textarea, [contenteditable="true"]'
      ) || document.querySelector('#prompt-textarea')
        || document.querySelector('[contenteditable="true"]');
      const chatModel = [...document.querySelectorAll('button, a, [role="button"]')].some(button => {
        const label = [
          button.getAttribute('aria-label'),
          button.getAttribute('title'),
          button.innerText,
          button.textContent
        ].filter(Boolean).map(normalize).join(' ');
        return label.includes('chatgpt model') || label.includes('chatgpt 模型')
          || label.includes('select chatgpt model') || label.includes('选择 chatgpt 模型');
      });
      const workComposer = !quickChatRoot
        && !!document.querySelector('[data-codex-composer="true"]');
      const webChat = location.protocol === 'https:' && location.hostname === 'chatgpt.com';
      return {
        active: !!input && !workComposer && (!!quickChatRoot || chatModel || webChat),
        hasInput: !!input,
        chatModel,
        workComposer,
        quickChatRoot: !!quickChatRoot,
        webChat
      };
    };
    const surface = chatSurface();
    if (surface.active) {
      window.__mahayanaConfirmedChatGPTMode = true;
      return {
        ok: true,
        chatSelected: false,
        alreadySelected: true,
        selectedLabel: 'chat-surface-validated',
        surface,
        modeControls
      };
    }
    // Current desktop builds expose an explicit top-level Chat/Work toggle.
    // The shell can still expose a stale "current mode: ChatGPT" trigger while
    // the composer belongs to Work. Prefer the real, unselected Chat tab before
    // considering the compact-mode trigger or a Work-side "new conversation"
    // button; otherwise the latter only creates another Work task and the
    // plugin sender never reaches the Chat surface.
    const explicitChatTab = modeTabs()
      .filter(candidate => labelsFor(candidate).some(label => isChatLabel(label)))
      .filter(candidate => !isSelected(candidate))
      .filter(candidate => {
        const role = normalize(candidate.getAttribute('role'));
        return ['BUTTON', 'A'].includes(candidate.tagName)
          || ['button', 'tab', 'menuitem', 'menuitemradio', 'option'].includes(role);
      })
      .sort((lhs, rhs) => modeTabScore(rhs) - modeTabScore(lhs))[0];
    if (surface.workComposer && explicitChatTab) {
      const rect = explicitChatTab.getBoundingClientRect();
      setTimeout(() => {
        try { dispatchPointerClick(explicitChatTab); } catch (_) {}
      }, 0);
      return {
        ok: true,
        chatSelected: true,
        dispatchOnly: true,
        nativeClickRecommended: true,
        x: rect.left + rect.width / 2,
        y: rect.top + rect.height / 2,
        selectedLabel: labelsFor(explicitChatTab)[0] || 'chat',
        surface,
        modeControls
      };
    }
    const currentChatGPTMode = candidates().find(candidate =>
      labelsFor(candidate).some(label =>
        label.includes('current mode: chatgpt')
        || (label.includes('当前模式') && label.includes('chatgpt'))
      )
    );
    if (currentChatGPTMode && surface.hasInput && !surface.workComposer) {
      window.__mahayanaConfirmedChatGPTMode = true;
      return {
        ok: true,
        chatSelected: false,
        alreadySelected: true,
        selectedLabel: labelsFor(currentChatGPTMode)[0] || 'chatgpt',
        surface,
        modeControls
      };
    }
    // Switching the app shell to ChatGPT can leave the previously selected
    // Work conversation mounted in the content pane. In that state the mode
    // switch is already correct; opening it again only loops. Starting a new
    // Chat from the ChatGPT sidebar is the transition that replaces the stale
    // Work composer with the real Chat composer.
    if (currentChatGPTMode && surface.workComposer) {
      const newChatButton = candidates().find(candidate =>
        labelsFor(candidate).some(label => [
          'new chat', '新聊天', 'new conversation', '新对话',
          'new task', '新建任务', '新任务'
        ].includes(label))
      );
      if (newChatButton) {
        const rect = newChatButton.getBoundingClientRect();
        return {
          ok: false,
          error: 'chat_surface_new_chat_dispatched',
          retryAfterModeSwitch: true,
          nativeClickRecommended: true,
          x: rect.left + rect.width / 2,
          y: rect.top + rect.height / 2
        };
      }
    }
    const modeSwitch = candidates().find(candidate =>
      labelsFor(candidate).some(label =>
        label.includes('switch mode, current mode:')
        || label.includes('切换模式')
        || label.includes('当前模式')
      )
    );
    const modeSwitchOpen = modeSwitch
      && (modeSwitch.getAttribute('aria-expanded') === 'true'
        || modeSwitch.getAttribute('data-state') === 'open');
    // Closed Radix menus keep old text nodes mounted. Looking for a generic
    // leaf named "Chat" before opening the real mode switch can therefore
    // select stale/off-surface content. Always open the identified top-level
    // switch first, then resolve its visible ChatGPT menu item on the next CDP
    // evaluation.
    if (modeSwitch && !modeSwitchOpen) {
      window.__mahayanaChatModeSwitchAttempted = true;
      setTimeout(() => {
        try { dispatchPointerClick(modeSwitch); } catch (_) {}
      }, 0);
      const rect = modeSwitch.getBoundingClientRect();
      return {
        ok: false,
        error: 'mode_switch_dispatched',
        retryAfterModeSwitch: true,
        nativeClickRecommended: true,
        x: rect.left + rect.width / 2,
        y: rect.top + rect.height / 2
      };
    }
    const exactChat = () => modeTabs()
      .filter(candidate =>
        labelsFor(candidate).some(label => isChatLabel(label))
          || isChatGPTMenuChoice(candidate)
      )
      .sort((lhs, rhs) => modeTabScore(rhs) - modeTabScore(lhs))[0];
    let button = exactChat();
    if (!button) {
      if (modeSwitch) {
        return {
          ok: false,
          error: 'chat_mode_choice_not_found_after_switch',
          retryAfterModeSwitch: true
        };
      }
    }
    if (!button) {
      button = candidates().find(candidate =>
        labelsFor(candidate).some(label =>
          label === 'quick chat' || label === '快速聊天'
        )
      );
    }
    if (!button) {
      const visibleCandidates = candidates();
      return {
        ok: false,
        error: 'chat_button_not_found',
        candidateLabels: visibleCandidates.flatMap(candidate => [
          candidate.innerText,
          candidate.getAttribute('aria-label'),
          candidate.getAttribute('title')
        ]).map(normalize).filter(Boolean).slice(0, 60)
      };
    }
    // Selecting ChatGPT can replace the renderer immediately. Dispatch the
    // click after this evaluation returns so a destroyed execution context is
    // not mistaken for a failed mode selection. The caller independently
    // waits for and validates the resulting plugin-owned Chat surface; it may
    // be visible or hidden.
    const rect = button.getBoundingClientRect();
    setTimeout(() => {
      try { dispatchPointerClick(button); } catch (_) {}
    }, 200);
    return {
      ok: true,
      chatSelected: true,
      dispatchOnly: true,
      nativeClickRecommended: true,
      x: rect.left + rect.width / 2,
      y: rect.top + rect.height / 2,
      selectedLabel: normalize(
        button.innerText || button.getAttribute('aria-label') || button.getAttribute('title')
      ),
      surface,
      modeControls
    };
  })()
  """#
}

/// React's Chat/Work mode switch can ignore synthetic DOM clicks even though
/// Runtime.evaluate reports that the correct control was found. Mirror the
/// successful queue-worker path by completing those clicks through CDP's
/// native input domain whenever the page returns viewport coordinates.
@discardableResult
func dispatchRecommendedCDPClick(
  _ result: [String: Any]?,
  port: Int,
  targetId: String
) -> Bool {
  guard result?["nativeClickRecommended"] as? Bool == true,
        let x = (result?["x"] as? NSNumber)?.doubleValue,
        let y = (result?["y"] as? NSNumber)?.doubleValue else { return false }
  return CDPClient.clickTarget(targetId, x: x, y: y, portOverride: port)
}

func clickCodexModeJS() -> String {
  #"""
  (() => {
    const normalize = value => (value || '').replace(/\s+/g, ' ').trim().toLowerCase();
    const candidates = () => [...document.querySelectorAll(
      'button, [role="button"], [role="menuitem"], [role="menuitemradio"], '
        + '[role="option"], [role="tab"]'
    )];
    const labelsFor = candidate => [
      candidate.innerText,
      candidate.textContent,
      candidate.getAttribute('aria-label'),
      candidate.getAttribute('title')
    ].map(normalize).filter(Boolean);
    const visible = candidate => {
      const rect = candidate.getBoundingClientRect?.();
      return !!rect && (rect.width > 0 || rect.height > 0 || candidate.offsetParent !== null);
    };
    const dispatchPointerClick = candidate => {
      const rect = candidate.getBoundingClientRect?.();
      const clientX = rect ? rect.left + Math.min(12, Math.max(1, rect.width / 2)) : 1;
      const clientY = rect ? rect.top + Math.min(12, Math.max(1, rect.height / 2)) : 1;
      const pressed = {
        bubbles: true,
        cancelable: true,
        composed: true,
        button: 0,
        buttons: 1,
        clientX,
        clientY
      };
      candidate.dispatchEvent(new PointerEvent('pointerdown', {
        ...pressed,
        pointerId: 1,
        pointerType: 'mouse',
        isPrimary: true
      }));
      candidate.dispatchEvent(new MouseEvent('mousedown', pressed));
      candidate.dispatchEvent(new PointerEvent('pointerup', {
        ...pressed,
        buttons: 0,
        pointerId: 1,
        pointerType: 'mouse',
        isPrimary: true
      }));
      candidate.dispatchEvent(new MouseEvent('mouseup', { ...pressed, buttons: 0 }));
      candidate.dispatchEvent(new MouseEvent('click', { ...pressed, buttons: 0 }));
    };
    const isCodexMenuChoice = candidate => {
      const role = normalize(candidate.getAttribute('role'));
      const choiceRole = role === 'menuitem'
        || role === 'menuitemradio'
        || role === 'option';
      const insideChoicePopup = !!candidate.closest('[role="menu"], [role="listbox"]');
      const hasExactCodexChild = [...candidate.querySelectorAll('*')].some(child =>
        child.children.length === 0 && normalize(child.textContent) === 'codex'
      );
      return (choiceRole || insideChoicePopup)
        && (labelsFor(candidate).some(label => label === 'codex')
          || hasExactCodexChild);
    };
    let target = candidates().find(candidate =>
      visible(candidate) && isCodexMenuChoice(candidate)
    );
    if (!target) {
      target = candidates().find(candidate => {
        const role = normalize(candidate.getAttribute('role'));
        return visible(candidate)
          && role === 'tab'
          && labelsFor(candidate).some(label => label === 'work' || label === '工作');
      });
    }
    if (target) {
      const rect = target.getBoundingClientRect();
      setTimeout(() => {
        try { dispatchPointerClick(target); } catch (_) {}
      }, 200);
      return {
        ok: true,
        dispatchOnly: true,
        nativeClickRecommended: true,
        x: rect.left + rect.width / 2,
        y: rect.top + rect.height / 2,
        selectedLabel: normalize(
          target.innerText || target.getAttribute('aria-label') || target.getAttribute('title')
        )
      };
    }
    const modeSwitch = candidates().find(candidate =>
      labelsFor(candidate).some(label =>
        label.includes('switch mode, current mode:')
        || label.includes('切换模式')
        || label.includes('当前模式')
      )
    );
    if (modeSwitch) {
      setTimeout(() => {
        try { dispatchPointerClick(modeSwitch); } catch (_) {}
      }, 0);
      const rect = modeSwitch.getBoundingClientRect();
      return {
        ok: false,
        error: 'mode_switch_dispatched',
        retryAfterModeSwitch: true,
        nativeClickRecommended: true,
        x: rect.left + rect.width / 2,
        y: rect.top + rect.height / 2
      };
    }
    return {
      ok: false,
      error: 'codex_mode_choice_not_found',
      candidateLabels: candidates().flatMap(candidate => labelsFor(candidate)).slice(0, 60)
    };
  })()
  """#
}

func composerSurfaceStateJS() -> String {
  #"""
  (() => {
    const normalize = value => (value || '').replace(/\s+/g, ' ').trim().toLowerCase();
    const quickChatRoot = document.querySelector(
      '[data-pip-obstacle="quick-chat"], [data-quick-chat-drag-handle]'
    )?.closest('[role="dialog"], section, div');
    const input = quickChatRoot?.querySelector(
      '#prompt-textarea, [contenteditable="true"]'
    ) || document.querySelector('#prompt-textarea')
      || document.querySelector('[contenteditable="true"]');
    const chatModel = [...document.querySelectorAll('button, a, [role="button"]')].some(button => {
      const label = [
        button.getAttribute('aria-label'),
        button.getAttribute('title'),
        button.innerText,
        button.textContent
      ].filter(Boolean).map(normalize).join(' ');
      return label.includes('chatgpt model') || label.includes('chatgpt 模型')
        || label.includes('select chatgpt model') || label.includes('选择 chatgpt 模型');
    });
    const workComposer = !quickChatRoot
      && !!document.querySelector('[data-codex-composer="true"]');
    const currentMode = [...document.querySelectorAll('button, [role="button"]')]
      .flatMap(candidate => [
        candidate.getAttribute('aria-label'),
        candidate.getAttribute('title'),
        candidate.innerText
      ])
      .map(normalize)
      .find(label =>
        label.includes('switch mode, current mode:')
        || label.includes('切换模式')
        || label.includes('当前模式')
      ) || '';
    return {
      ok: true,
      hasInput: !!input,
      chatModel,
      workComposer,
      quickChatRoot: !!quickChatRoot,
      currentMode
    };
  })()
  """#
}

func forcePrimaryComposerModeJS(_ requestedMode: String) -> String {
  let mode = requestedMode == "work" ? "work" : "chat"
  let modeLiteral = jsonStringLiteral(mode)
  return #"""
  (async () => {
    const key = 'home-composer-mode-v1';
    const value = \#(modeLiteral);
    const message = {
      type: 'persisted-atom-update',
      key,
      value,
      deleted: false
    };
    try {
      if (!window.electronBridge?.sendMessageFromView) {
        return { ok: false, error: 'electron_bridge_unavailable' };
      }
      await window.electronBridge.sendMessageFromView(message);
      // The host broadcasts this event to other renderers, but the source
      // renderer may not receive its own update while it is in Work mode.
      // Deliver the same official persisted-atom event locally as well.
      window.postMessage({
        type: 'persisted-atom-updated',
        key,
        value,
        deleted: false
      }, '*');
      // Keep the legacy renderer store aligned too. New renderers receive the
      // authoritative value from the host, while older ones still bootstrap
      // from this localStorage key.
      try {
        window.localStorage.setItem(`codex:persisted-atom:${key}`, JSON.stringify(value));
      } catch (_) {}
      return { ok: true, dispatched: true, key, value };
    } catch (error) {
      return {
        ok: false,
        error: String(error?.message || error || 'persisted_atom_update_failed')
      };
    }
  })()
  """#
}

func forcePrimaryChatModeJS() -> String {
  forcePrimaryComposerModeJS("chat")
}

func autoConfirmWorkHandoffJS() -> String {
  #"""
  (() => {
    const normalize = value => (value || '').replace(/[\s↵]+/g, ' ').trim().toLowerCase();
    const button = [...document.querySelectorAll('button')].find(button => {
      const label = normalize(button.innerText || button.textContent || button.getAttribute('aria-label'));
      return label === '继续工作' || label === 'continue working'
        || label === 'continue in work' || label === 'switch to work';
    });
    if (!button) return { ok: true, clicked: false };
    setTimeout(() => {
      try { button.click(); } catch (_) {}
    }, 0);
    return { ok: true, clicked: true, dispatchOnly: true };
  })()
  """#
}

// Work/worker is only the queue controller. Task execution and acceptance must
// remain on Chat, even when ChatGPT offers a coding-task handoff to Work. Keep
// the old Work helper above for explicit legacy callers, but never invoke it
// from the queue's default send, continuation, or review paths.
func autoConfirmChatContinuationJS() -> String {
  #"""
  (() => {
    const normalize = value => (value || '').replace(/[\s↵]+/g, ' ').trim().toLowerCase();
    const allowed = new Set([
      '继续在此聊天', '继续聊天', 'continue in this chat', 'stay in this chat',
      'continue here', 'continue chat'
    ]);
    const button = [...document.querySelectorAll('button')].find(button => {
      if (button.disabled || !(button.offsetWidth || button.offsetHeight || button.getClientRects().length)) return false;
      return allowed.has(normalize(button.innerText || button.textContent || button.getAttribute('aria-label')));
    });
    if (!button) return { ok: true, clicked: false, surface: 'chat' };
    const rect = button.getBoundingClientRect();
    return {
      ok: true,
      clicked: true,
      dispatchOnly: true,
      nativeClickRecommended: true,
      x: rect.left + rect.width / 2,
      y: rect.top + rect.height / 2,
      surface: 'chat'
    };
  })()
  """#
}

func detectDedicatedAuthorizationJS() -> String {
  #"""
  (() => {
    const normalize = value => (value || '').replace(/[\s↵⏎]+/g, ' ').trim().toLowerCase();
    const fingerprint = value => {
      let hash = 2166136261;
      for (const character of value) {
        hash ^= character.codePointAt(0);
        hash = Math.imul(hash, 16777619);
      }
      return `fnv1a32:${(hash >>> 0).toString(16).padStart(8, '0')}`;
    };
    const approvalRequestIdentity = element => {
      let domNode = element;
      for (let ancestorIndex = 0; ancestorIndex < 15 && domNode; ancestorIndex += 1) {
        const reactKeys = Object.keys(domNode).filter(key =>
          key.startsWith('__reactFiber$') || key.startsWith('__reactProps$')
        );
        for (const reactKey of reactKeys) {
          let reactNode = domNode[reactKey];
          for (let fiberIndex = 0; fiberIndex < 20 && reactNode; fiberIndex += 1) {
            const props = reactNode.memoizedProps || reactNode.pendingProps
              || reactNode.props || reactNode;
            const pluginData = props?.jit_plugin_data || props?.pluginData
              || props?.card?.jit_plugin_data;
            const allowOnce = pluginData?.from_server?.actions?.allow_once;
            const identity = allowOnce?.target_message_id || allowOnce?.targetMessageId
              || props?.target_message_id || props?.targetMessageId;
            if (identity) return String(identity);
            reactNode = reactNode.return;
          }
        }
        domNode = domNode.parentElement;
      }
      return '';
    };
    const hasApprovalMetadata = element => {
      let domNode = element;
      for (let ancestorIndex = 0; ancestorIndex < 15 && domNode; ancestorIndex += 1) {
        const structuralAttributes = [...(domNode.attributes || [])].some(attribute =>
          /^(?:data-|aria-|role$)/i.test(attribute.name)
            && /(?:approval|authorize|authorization|permission|consent|access|tool)/i.test(
              attribute.name === 'role' ? attribute.value : `${attribute.name} ${attribute.value}`
            )
        );
        if (structuralAttributes || domNode.getAttribute?.('aria-modal') === 'true') return true;
        const reactKeys = Object.keys(domNode).filter(key =>
          key.startsWith('__reactFiber$') || key.startsWith('__reactProps$')
        );
        for (const reactKey of reactKeys) {
          let reactNode = domNode[reactKey];
          for (let fiberIndex = 0; fiberIndex < 20 && reactNode; fiberIndex += 1) {
            const props = reactNode.memoizedProps || reactNode.pendingProps
              || reactNode.props || reactNode;
            if (props?.jit_plugin_data || props?.pluginData || props?.allow_once
                || props?.allowOnce || props?.target_message_id || props?.targetMessageId
                || props?.requiresApproval || props?.authorization || props?.permission
                || props?.consent || props?.approval) return true;
            reactNode = reactNode.return;
          }
        }
        domNode = domNode.parentElement;
      }
      return false;
    };
    const hasDialogSemantics = element => {
      const role = normalize(element?.getAttribute?.('role'));
      if (role === 'dialog' || role === 'alertdialog'
          || element?.getAttribute?.('aria-modal') === 'true') return true;
      return [...(element?.attributes || [])].some(attribute =>
        /^(?:data-testid|data-test|data-state|class|id)$/i.test(attribute.name)
          && /(?:approval|authorize|authorization|permission|consent|access|tool-?call)/i.test(
            attribute.value || ''
          )
      );
    };
    const visible = element => !!(element
      && !element.disabled
      && (element.offsetWidth || element.offsetHeight || element.getClientRects().length));
    const label = button => normalize(
      button.innerText || button.textContent
        || button.getAttribute('aria-label') || button.getAttribute('title')
    );
    const allowLabels = new Set([
      'allow', 'allow once', 'approve', 'approve once', 'confirm', 'confirm once',
      'allow this time', 'authorize', 'authorize once', 'grant', 'grant once',
      '允许', '允许一次', '同意', '同意一次', '确认', '确认一次', '授权', '授权一次',
      'full access', 'complete access', '完全访问', '完整访问'
    ]);
    const rejectLabels = new Set([
      'deny', 'reject', 'cancel', 'deny once', 'reject once', 'not now',
      '拒绝', '拒绝一次', '不允许', '不允许一次', '取消', '暂不'
    ]);
    const sessionHints = [
      'this chat', 'this conversation', 'for this chat', 'for this conversation',
      'for this session', 'during this chat', 'always allow in this chat',
      '本次会话', '这次会话', '此会话', '当前会话', '在此聊天中', '本次聊天',
      '始终允许', '会话期间'
    ];
    const isSessionScope = value => !!value && (
      sessionHints.some(hint => value.includes(hint))
        || /(?:allow|approve|confirm|允许|同意|确认).*(?:this (?:chat|conversation|session)|本次(?:会话|聊天)|当前会话)/i.test(value)
    );
    const isMenuTrigger = button => {
      if (!button || button.disabled) return false;
      const attributes = [
        button.getAttribute('aria-label') || '',
        button.getAttribute('title') || '',
        button.getAttribute('data-testid') || '',
        button.getAttribute('data-slot') || '',
        button.getAttribute('class') || ''
      ].join(' ');
      return button.getAttribute('aria-haspopup') === 'menu'
        || button.getAttribute('aria-haspopup') === 'listbox'
        || button.getAttribute('aria-expanded') !== null
        || button.getAttribute('data-state') !== null
        || /menu|dropdown|chevron|caret|arrow|下拉|箭头|更多|选项/i.test(normalize(attributes));
    };
    const isAdjacentSplitControl = (allowButton, control) => {
      if (!allowButton || !control || control === allowButton || !isMenuTrigger(control)) return false;
      const allowRect = allowButton.getBoundingClientRect?.();
      const controlRect = control.getBoundingClientRect?.();
      if (!allowRect || !controlRect) return false;
      const verticalOverlap = Math.min(allowRect.bottom, controlRect.bottom)
        - Math.max(allowRect.top, controlRect.top);
      const horizontalGap = Math.max(
        allowRect.left - controlRect.right,
        controlRect.left - allowRect.right,
        0
      );
      return verticalOverlap > 0 && horizontalGap <= 12;
    };
    const buttons = [...document.querySelectorAll('button, a, [role="button"]')]
      .filter(visible);
    const candidates = buttons
      .map((button, index) => ({ button, index, label: label(button) }))
      .filter(candidate => allowLabels.has(candidate.label));
    const candidate = candidates[0];
    if (!candidate) {
      return {
        ok: true,
        found: false,
        candidates: 0,
        candidateLabels: [],
        selectedLabel: '',
        cardButtonLabels: [],
        sessionScopeLabels: [],
        menuTriggerLabels: [],
        menuTriggerCount: 0,
        unlabeledControlCount: 0
      };
    }

    let container = candidate.button.parentElement;
    for (let index = 0; index < 15 && container; index += 1) {
      const cardButtons = [...container.querySelectorAll('button, a, [role="button"]')]
        .filter(visible);
      const cardLabels = cardButtons.map(label);
      const hasReject = cardLabels.some(value => rejectLabels.has(value));
      const compact = cardButtons.length > 0 && cardButtons.length <= 16;
      const structuralCard = hasDialogSemantics(container)
        || hasApprovalMetadata(candidate.button)
        || hasApprovalMetadata(container);
      if (compact && (hasReject || structuralCard)) {
        const nonDecisionControls = cardButtons.filter(button => {
          const value = label(button);
          return !allowLabels.has(value) && !rejectLabels.has(value);
        });
        const menuTriggers = nonDecisionControls.filter(button =>
          isSessionScope(label(button))
            || isMenuTrigger(button)
            || isAdjacentSplitControl(candidate.button, button)
        );
        const sessionScopeLabels = cardLabels.filter(value =>
          isSessionScope(value)
        );
        const requestIdentity = approvalRequestIdentity(candidate.button);
        return {
          ok: true,
          found: true,
          candidates: candidates.length,
          candidateLabels: candidates.map(item => item.label),
          selectedLabel: candidate.label,
          cardButtonLabels: cardLabels.filter(Boolean),
          sessionScopeLabels,
          menuTriggerLabels: menuTriggers.map(label).filter(Boolean),
          menuTriggerCount: menuTriggers.length,
          sessionScopeAvailable: sessionScopeLabels.length > 0 || menuTriggers.length > 0,
          cardFingerprint: fingerprint(requestIdentity
            ? `request:${requestIdentity}`
            : `card:${cardLabels.join('|')}:${container.getAttribute('id') || ''}`),
          requestIdentityAvailable: !!requestIdentity,
          unlabeledControlCount: nonDecisionControls.filter(button => !label(button)).length
        };
      }
      container = container.parentElement;
    }

    return {
      ok: true,
      found: false,
      candidates: candidates.length,
      candidateLabels: candidates.map(item => item.label),
      selectedLabel: candidate.label,
      cardButtonLabels: [],
      sessionScopeLabels: [],
      menuTriggerLabels: [],
      menuTriggerCount: 0,
      sessionScopeAvailable: false,
      cardFingerprint: '',
      requestIdentityAvailable: false,
      unlabeledControlCount: 0
    };
  })()
  """#
}

func autoApproveDedicatedAuthorizationJS() -> String {
  #"""
  (async () => {
    const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
    const normalize = value => (value || '').replace(/[\s\u21b5\u23ce]+/g, ' ').trim().toLowerCase();
    const fingerprint = value => {
      let hash = 2166136261;
      for (const character of value) {
        hash ^= character.codePointAt(0);
        hash = Math.imul(hash, 16777619);
      }
      return `fnv1a32:${(hash >>> 0).toString(16).padStart(8, '0')}`;
    };
    const rendered = element => !!(element && element.isConnected !== false
      && (element.offsetWidth || element.offsetHeight || element.getClientRects().length));
    const visible = element => rendered(element) && !element.disabled;
    const allowed = new Set([
      '\u5b8c\u5168\u8bbf\u95ee', 'full access', 'allow', 'allow once',
      'allow this time', 'authorize', 'authorize once', 'grant', 'grant once',
      '\u5141\u8bb8', '\u5141\u8bb8\u4e00\u6b21', 'approve', 'approve once',
      'confirm', 'confirm once', '\u786e\u8ba4', '\u786e\u8ba4\u4e00\u6b21',
      '\u540c\u610f', '\u540c\u610f\u4e00\u6b21', '\u6388\u6743', '\u6388\u6743\u4e00\u6b21',
      'complete access', '\u5b8c\u6574\u8bbf\u95ee'
    ]);
    const rejectLabels = new Set([
      'deny', 'reject', 'cancel', 'deny once', 'reject once', 'not now',
      '\u62d2\u7edd', '\u62d2\u7edd\u4e00\u6b21', '\u4e0d\u5141\u8bb8',
      '\u4e0d\u5141\u8bb8\u4e00\u6b21', '\u53d6\u6d88', '\u6682\u4e0d'
    ]);
    const sessionHints = [
      'this chat', 'this conversation', 'for this chat', 'for this conversation',
      'for this session', 'during this chat', 'always allow in this chat',
      '\u672c\u6b21\u4f1a\u8bdd', '\u8fd9\u6b21\u4f1a\u8bdd',
      '\u6b64\u4f1a\u8bdd', '\u5f53\u524d\u4f1a\u8bdd',
      '\u5728\u6b64\u804a\u5929\u4e2d', '\u672c\u6b21\u804a\u5929',
      '\u59cb\u7ec8\u5141\u8bb8', '\u4f1a\u8bdd\u671f\u95f4'
    ];
    const label = button => normalize(
      button.innerText || button.textContent
        || button.getAttribute('aria-label') || button.getAttribute('title')
    );
    const isSessionScope = value => !!value && (
      sessionHints.some(hint => value.includes(hint))
        || /(?:allow|approve|confirm|\u5141\u8bb8|\u540c\u610f|\u786e\u8ba4).*(?:this (?:chat|conversation|session)|\u672c\u6b21(?:\u4f1a\u8bdd|\u804a\u5929)|\u5f53\u524d\u4f1a\u8bdd)/i.test(value)
    );
    const isMenuTrigger = button => {
      if (!button || button.disabled) return false;
      const attributes = [
        button.getAttribute('aria-label') || '',
        button.getAttribute('title') || '',
        button.getAttribute('data-testid') || '',
        button.getAttribute('data-slot') || '',
        button.getAttribute('class') || ''
      ].join(' ');
      return button.getAttribute('aria-haspopup') === 'menu'
        || button.getAttribute('aria-haspopup') === 'listbox'
        || button.getAttribute('aria-expanded') !== null
        || button.getAttribute('data-state') !== null
        || /menu|dropdown|chevron|caret|arrow|\u4e0b\u62c9|\u7bad\u5934|\u66f4\u591a|\u9009\u9879/i.test(normalize(attributes));
    };
    const isAdjacentSplitControl = (allowButton, control) => {
      if (!allowButton || !control || control === allowButton || !isMenuTrigger(control)) return false;
      const allowRect = allowButton.getBoundingClientRect?.();
      const controlRect = control.getBoundingClientRect?.();
      if (!allowRect || !controlRect) return false;
      const verticalOverlap = Math.min(allowRect.bottom, controlRect.bottom)
        - Math.max(allowRect.top, controlRect.top);
      const horizontalGap = Math.max(
        allowRect.left - controlRect.right,
        controlRect.left - allowRect.right,
        0
      );
      return verticalOverlap > 0 && horizontalGap <= 12;
    };
    const findSessionControl = (allowButton, controls) => {
      const direct = controls.find(button => button !== allowButton
        && isSessionScope(label(button)));
      if (direct) return direct;
      const menuTrigger = controls.find(button => button !== allowButton
        && isMenuTrigger(button)
        && isAdjacentSplitControl(allowButton, button));
      if (menuTrigger) return menuTrigger;
      return controls.find(button => button !== allowButton && isMenuTrigger(button)) || null;
    };
    const approvalRequestIdentity = element => {
      let domNode = element;
      for (let ancestorIndex = 0; ancestorIndex < 15 && domNode; ancestorIndex += 1) {
        const reactKeys = Object.keys(domNode).filter(key =>
          key.startsWith('__reactFiber$') || key.startsWith('__reactProps$')
        );
        for (const reactKey of reactKeys) {
          let reactNode = domNode[reactKey];
          for (let fiberIndex = 0; fiberIndex < 20 && reactNode; fiberIndex += 1) {
            const props = reactNode.memoizedProps || reactNode.pendingProps
              || reactNode.props || reactNode;
            const pluginData = props?.jit_plugin_data || props?.pluginData
              || props?.card?.jit_plugin_data;
            const allowOnce = pluginData?.from_server?.actions?.allow_once;
            const identity = allowOnce?.target_message_id || allowOnce?.targetMessageId
              || props?.target_message_id || props?.targetMessageId;
            if (identity) return String(identity);
            reactNode = reactNode.return;
          }
        }
        domNode = domNode.parentElement;
      }
      return '';
    };
    const hasApprovalMetadata = element => {
      let domNode = element;
      for (let ancestorIndex = 0; ancestorIndex < 15 && domNode; ancestorIndex += 1) {
        const structuralAttributes = [...(domNode.attributes || [])].some(attribute =>
          /^(?:data-|aria-|role$)/i.test(attribute.name)
            && /(?:approval|authorize|authorization|permission|consent|access|tool)/i.test(
              attribute.name === 'role' ? attribute.value : `${attribute.name} ${attribute.value}`
            )
        );
        if (structuralAttributes || domNode.getAttribute?.('aria-modal') === 'true') return true;
        const reactKeys = Object.keys(domNode).filter(key =>
          key.startsWith('__reactFiber$') || key.startsWith('__reactProps$')
        );
        for (const reactKey of reactKeys) {
          let reactNode = domNode[reactKey];
          for (let fiberIndex = 0; fiberIndex < 20 && reactNode; fiberIndex += 1) {
            const props = reactNode.memoizedProps || reactNode.pendingProps
              || reactNode.props || reactNode;
            if (props?.jit_plugin_data || props?.pluginData || props?.allow_once
                || props?.allowOnce || props?.target_message_id || props?.targetMessageId
                || props?.requiresApproval || props?.authorization || props?.permission
                || props?.consent || props?.approval) return true;
            reactNode = reactNode.return;
          }
        }
        domNode = domNode.parentElement;
      }
      return false;
    };
    const hasDialogSemantics = element => {
      const role = normalize(element?.getAttribute?.('role'));
      if (role === 'dialog' || role === 'alertdialog'
          || element?.getAttribute?.('aria-modal') === 'true') return true;
      return [...(element?.attributes || [])].some(attribute =>
        /^(?:data-testid|data-test|data-state|class|id)$/i.test(attribute.name)
          && /(?:approval|authorize|authorization|permission|consent|access|tool-?call)/i.test(
            attribute.value || ''
          )
      );
    };
    const approvalCardShape = button => {
      let card = button?.parentElement;
      for (let index = 0; index < 15 && card && card !== document.body; index += 1) {
        const cardButtons = [...card.querySelectorAll('button, a, [role="button"]')]
          .filter(visible);
        const cardLabels = cardButtons.map(label);
        const compact = cardButtons.length > 0 && cardButtons.length <= 16;
        const hasReject = cardLabels.some(value => rejectLabels.has(value));
        const structuralCard = hasDialogSemantics(card)
          || hasApprovalMetadata(button)
          || hasApprovalMetadata(card);
        if (compact && (hasReject || structuralCard)) {
          return { container: card, buttons: cardButtons, labels: cardLabels };
        }
        card = card.parentElement;
      }
      return null;
    };
    const approvalCardFingerprint = button => {
      const shape = approvalCardShape(button);
      if (!shape) return '';
      const requestIdentity = approvalRequestIdentity(button);
      return fingerprint(requestIdentity
        ? `request:${requestIdentity}`
        : `card:${shape.labels.join('|')}:${shape.container.getAttribute('id') || ''}`);
    };
    const dispatchPointerClick = candidate => {
      try {
        if (typeof PointerEvent !== 'function' || typeof MouseEvent !== 'function') {
          throw new Error('pointer_events_unavailable');
        }
        const rect = candidate.getBoundingClientRect?.();
        const clientX = rect ? rect.left + Math.min(12, Math.max(1, rect.width / 2)) : 1;
        const clientY = rect ? rect.top + Math.min(12, Math.max(1, rect.height / 2)) : 1;
        const pressed = {
          bubbles: true, cancelable: true, composed: true,
          button: 0, buttons: 1, clientX, clientY
        };
        candidate.dispatchEvent(new PointerEvent('pointerdown', {
          ...pressed, pointerId: 1, pointerType: 'mouse', isPrimary: true
        }));
        candidate.dispatchEvent(new MouseEvent('mousedown', pressed));
        candidate.dispatchEvent(new PointerEvent('pointerup', {
          ...pressed, buttons: 0, pointerId: 1, pointerType: 'mouse', isPrimary: true
        }));
        candidate.dispatchEvent(new MouseEvent('mouseup', { ...pressed, buttons: 0 }));
        candidate.dispatchEvent(new MouseEvent('click', { ...pressed, buttons: 0 }));
      } catch (_) {
        // The in-app Browser's isolated page context may expose DOM nodes but
        // not constructible PointerEvent/MouseEvent classes. Native click()
        // still reaches the page's React/Radix handler and remains scoped to
        // the already selected authorization-card control.
        if (typeof candidate.click === 'function') {
          candidate.click();
        } else {
          candidate.dispatchEvent(new Event('click', {
            bubbles: true, cancelable: true, composed: true
          }));
        }
      }
    };
    const confirmCardClosed = async candidate => {
      const expectedFingerprint = approvalCardFingerprint(candidate);
      let stableMissingSamples = 0;
      for (let index = 0; index < 40; index += 1) {
        await sleep(100);
        const matchingRequestStillRendered = expectedFingerprint && [...document.querySelectorAll('button')]
          .filter(visible)
          .filter(button => allowed.has(label(button)))
          .some(button => approvalCardFingerprint(button) === expectedFingerprint);
        if (!matchingRequestStillRendered) {
          stableMissingSamples += 1;
          if (stableMissingSamples >= 5) return true;
        } else {
          stableMissingSamples = 0;
        }
      }
      return false;
    };
    const priority = new Map([
      ['allow', 0], ['\u5141\u8bb8', 0], ['approve', 0], ['\u540c\u610f', 0],
      ['confirm', 0], ['\u786e\u8ba4', 0], ['allow once', 1],
      ['\u5141\u8bb8\u4e00\u6b21', 1], ['approve once', 1],
      ['\u540c\u610f\u4e00\u6b21', 1], ['confirm once', 1],
      ['\u786e\u8ba4\u4e00\u6b21', 1], ['full access', 20],
      ['\u5b8c\u5168\u8bbf\u95ee', 20]
    ]);
    const candidates = [...document.querySelectorAll('button')]
      .filter(visible)
      .map((button, index) => ({ button, index, label: label(button) }))
      .filter(candidate => allowed.has(candidate.label) && approvalCardShape(candidate.button))
      .sort((left, right) =>
        (priority.get(left.label) ?? 10) - (priority.get(right.label) ?? 10)
          || left.index - right.index
      );
    const candidateLabels = candidates.map(candidate => candidate.label);
    const candidate = candidates[0];
    if (!candidate) {
      return { ok: true, clicked: false, confirmed: false, candidateLabels };
    }

    const cardShape = approvalCardShape(candidate.button);
    const card = cardShape?.container || null;
    const cardButtons = cardShape?.buttons || [];

    const sessionControl = findSessionControl(candidate.button, cardButtons);

    if (sessionControl) {
      const menuTriggerLabel = label(sessionControl);
      try {
        dispatchPointerClick(sessionControl);
      } catch (error) {
        return {
          ok: false, clicked: false, confirmed: false,
          strategy: 'session-scope', label: menuTriggerLabel, candidateLabels,
          error: String(error?.message || error || 'session_scope_menu_click_failed')
        };
      }
      let menuCandidates = [];
      for (let index = 0; index < 40; index += 1) {
        await sleep(100);
        if (!candidate.button.isConnected || !rendered(candidate.button)) {
          return {
            ok: true, clicked: true, confirmed: true,
            strategy: 'session-scope-direct', label: menuTriggerLabel,
            menuTriggerLabel, candidateLabels
          };
        }
        const menuItems = [...document.querySelectorAll(
          '[role="menuitem"], [role="menuitemradio"], [role="option"], '
            + '[role="menu"] button, [role="listbox"] button, '
            + '[data-radix-menu-content] button, '
            + '[data-radix-popper-content-wrapper] button'
        )].filter(item => item !== sessionControl && visible(item));
        menuCandidates = menuItems.map(label).filter(Boolean).slice(-30);
        const sessionOption = menuItems.find(item => isSessionScope(label(item)));
        if (!sessionOption) continue;
        const sessionScopeLabel = label(sessionOption);
        try {
          dispatchPointerClick(sessionOption);
        } catch (error) {
          return {
            ok: false, clicked: true, confirmed: false,
            strategy: 'session-scope', label: sessionScopeLabel,
            menuTriggerLabel, candidateLabels, menuCandidates,
            error: String(error?.message || error || 'session_scope_option_click_failed')
          };
        }
        const confirmed = await confirmCardClosed(candidate.button);
        return {
          ok: confirmed, clicked: true, confirmed,
          strategy: 'session-scope', label: sessionScopeLabel,
          menuTriggerLabel, sessionScopeLabel, candidateLabels, menuCandidates,
          error: confirmed ? null : 'session_scope_approval_not_confirmed'
        };
      }
      return {
        ok: false, clicked: true, confirmed: false,
        strategy: 'session-scope', label: menuTriggerLabel,
        menuTriggerLabel, candidateLabels, menuCandidates,
        error: 'session_scope_option_not_found'
      };
    }

    try {
      dispatchPointerClick(candidate.button);
    } catch (error) {
      return {
        ok: false, clicked: false, confirmed: false,
        strategy: 'single-approval', label: candidate.label, candidateLabels,
        error: String(error?.message || error || 'approval_click_failed')
      };
    }
    const confirmed = await confirmCardClosed(candidate.button);
    return {
      ok: confirmed, clicked: true, confirmed,
      strategy: 'single-approval', label: candidate.label, candidateLabels,
      error: confirmed ? null : 'approval_click_not_confirmed'
    };
  })()
  """#
}

func prepareNewChatTarget(
  port: Int,
  targetId: String,
  timeout: TimeInterval = 4.0,
  allowBlankConversationReuse: Bool = false
) -> [String: Any]? {
  // First wait for the app bundle/composer. Target.createTarget can expose a
  // static startup shell until its explicit Page.navigate has completed.
  func confirmedChatSelection(_ result: [String: Any]?) -> Bool {
    guard result?["ok"] as? Bool == true else { return false }
    return result?["alreadySelected"] as? Bool == true
  }
  let initialChatSelection = cdpValue(
    port: port,
    targetId: targetId,
    expression: clickChatJS(),
    timeout: timeout
  )
  _ = dispatchRecommendedCDPClick(
    initialChatSelection,
    port: port,
    targetId: targetId
  )
  var chatModeConfirmed = confirmedChatSelection(initialChatSelection)
  var baseline: [String: Any]?
  for _ in 0..<40 {
    baseline = cdpValue(
      port: port,
      targetId: targetId,
      expression: prepareBackgroundChatJS(
        newChat: false,
        confirmedChatMode: chatModeConfirmed
      ),
      timeout: timeout
    )
    if baseline?["ok"] as? Bool == true { break }
    if baseline?["error"] as? String == "not_chat_surface" {
      let retryChatSelection = cdpValue(
        port: port,
        targetId: targetId,
        expression: clickChatJS(),
        timeout: timeout
      )
      _ = dispatchRecommendedCDPClick(
        retryChatSelection,
        port: port,
        targetId: targetId
      )
      chatModeConfirmed = confirmedChatSelection(retryChatSelection)
        || chatModeConfirmed
    }
    Thread.sleep(forTimeInterval: 0.25)
  }
  guard let baseline,
        baseline["ok"] as? Bool == true else {
    return [
      "ok": false,
      "error": "prepare_new_chat_baseline_failed:"
        + (baseline?["error"] as? String ?? "no_result"),
    ]
  }
  let previousConversationId = baseline["conversationId"] as? String
  let baselineWasBlank = (baseline["messageCount"] as? Int ?? 1) == 0 &&
    (baseline["inputTextLength"] as? Int ?? 1) == 0
  if allowBlankConversationReuse && baselineWasBlank {
    var stableBlankSamples = 0
    for _ in 0..<12 {
      let current = cdpValue(
        port: port,
        targetId: targetId,
        expression: prepareBackgroundChatJS(
          newChat: false,
          confirmedChatMode: chatModeConfirmed
        ),
        timeout: timeout
      )
      let blankAndReady = current?["ok"] as? Bool == true
        && (current?["messageCount"] as? Int ?? 1) == 0
        && (current?["inputTextLength"] as? Int ?? 1) == 0
      stableBlankSamples = blankAndReady ? stableBlankSamples + 1 : 0
      if stableBlankSamples >= 3 {
        var result = current ?? [:]
        result["newChatClicked"] = false
        result["blankConversationReused"] = true
        result["stableSamples"] = stableBlankSamples
        return result
      }
      Thread.sleep(forTimeInterval: 0.15)
    }
  }
  guard let clicked = cdpValue(
    port: port,
    targetId: targetId,
    expression: clickNewChatJS(),
    timeout: timeout
  ) else {
    return ["ok": false, "error": "new_chat_click_no_result"]
  }
  guard clicked["ok"] as? Bool == true else {
    return [
      "ok": false,
      "error": clicked["error"] as? String ?? "new_chat_click_failed",
    ]
  }
  _ = dispatchRecommendedCDPClick(clicked, port: port, targetId: targetId)
  let previous = clicked["previousConversationId"] as? String ?? previousConversationId

  var stableConversationId: String?
  var stableSamples = 0
  // The desktop app can take slightly more than twenty seconds to replace a
  // durable conversation id with its new local-chatgpt id after clicking New
  // conversation. Keep this retry bounded, but allow forty seconds before
  // declaring that the blank Chat was not created.
  for _ in 0..<160 {
    let prepared = cdpValue(
      port: port,
      targetId: targetId,
      expression: prepareBackgroundChatJS(
        newChat: false,
        confirmedChatMode: chatModeConfirmed
      ),
      timeout: timeout
    )
    if prepared?["ok"] as? Bool == true {
      let conversationId = prepared?["conversationId"] as? String ?? ""
      let changed = (previous?.isEmpty != false && !conversationId.isEmpty) || 
                    (previous?.isEmpty == false && conversationId != previous)
      let blankConversation = allowBlankConversationReuse &&
        baselineWasBlank &&
        (prepared?["messageCount"] as? Int ?? 1) == 0
      // Some desktop builds retain the portal id of an empty shell until the
      // first outbound message. Because this path already verified an exact
      // New Chat click and the old composer was blank, a stable blank composer
      // is sufficient fresh-chat evidence without ever reusing a conversation
      // that contains user or assistant content.
      let blankAfterExplicitNewChat = baselineWasBlank &&
        (prepared?["messageCount"] as? Int ?? 1) == 0
      // Current ChatGPT builds do not allocate a local conversation id until
      // the first message is dispatched. A verified New Chat click followed
      // by a stable, empty Chat composer is therefore a fresh conversation
      // even while both the previous and current portal ids are empty.
      let unmaterializedBlankConversation = (previous?.isEmpty != false) &&
        conversationId.isEmpty &&
        (prepared?["messageCount"] as? Int ?? 1) == 0
      // The desktop renderer intentionally keeps a virtualized fallback turn
      // from the previous Chat in the DOM after switching. The portal id and
      // composer are authoritative; requiring zero message nodes would reject
      // a correctly created blank Chat forever.
      let composerReady = (prepared?["inputTextLength"] as? Int ?? 1) == 0
      let candidateReady = composerReady &&
        (changed || blankConversation || unmaterializedBlankConversation
          || blankAfterExplicitNewChat)
      if candidateReady && stableConversationId == conversationId {
        stableSamples += 1
      } else if candidateReady {
        stableConversationId = conversationId
        stableSamples = 1
      } else {
        stableConversationId = nil
        stableSamples = 0
      }
      // React updates the portal conversation id before it finishes replacing
      // the old message tree and composer. Require several identical blank
      // observations so task B cannot type into task A's transitioning view.
      if stableSamples >= 3 {
        var result = prepared ?? [:]
        result["newChatClicked"] = true
        result["freshBlankAfterNewChat"] = blankAfterExplicitNewChat
        result["stableSamples"] = stableSamples
        return result
      }
    }
    Thread.sleep(forTimeInterval: 0.25)
  }
  return [
    "ok": false,
    "error": "new_chat_creation_not_confirmed",
    "previousConversationId": previous as Any,
    "conversationId": stableConversationId as Any,
    "stableSamples": stableSamples,
  ]
}

@discardableResult
func ensureHiddenChatTarget(
  _ state: inout PluginState,
  newChat: Bool = false,
  conversationId: String? = nil
) -> [String: Any]? {
  let port = hiddenChatPort(state)
  let profilePath = canonicalPluginPath(
    configuredHiddenChatProfilePath()
      ?? state.backgroundProfilePath
      ?? hiddenChatProfilePath()
  )
  var targets = CDPClient.fetchTargets(portOverride: port)
  let allowTestWebTarget = ProcessInfo.processInfo.environment["CHATGPT_AUTO_CONFIRM_ALLOW_TEST_WEB_TARGET"] == "1"
  if port == CDPClient.port() && !allowTestWebTarget {
    state.lastError = "background_port_matches_primary"
    return [
      "ok": false,
      "errorCode": "background_port_matches_primary",
      "message": "插件专用 ChatGPT 实例不能与用户主 ChatGPT 共用 CDP 端口。",
      "backgroundOnly": false,
      "runtimeState": "primary-rejected",
      "workerUsed": false,
      "port": port,
    ]
  }
  let assignedTargetId = state.backgroundChatTargetId
  func eligibleTarget(_ target: [String: Any]) -> Bool {
    guard let targetId = target["id"] as? String else { return false }
    if targetId == assignedTargetId {
      guard allowTestWebTarget && port == CDPClient.port()
        || pluginOwnedProfilePath(profilePath) else { return false }
    } else if port == CDPClient.port() && !allowTestWebTarget {
      return false
    }
    if target["type"] as? String == "page"
        && (target["url"] as? String ?? "").hasPrefix("app://-/index.html")
        && !(target["url"] as? String ?? "").contains("/avatar-overlay") {
      return true
    }
    if targetId == assignedTargetId && isChatGptRendererTarget(target) {
      return true
    }
    return allowTestWebTarget && isChatGptRendererTarget(target)
  }
  var mainTarget = targets.first(where: {
    eligibleTarget($0) && $0["id"] as? String == assignedTargetId
  }) ?? targets.first(where: eligibleTarget)

  if mainTarget == nil {
    do {
      try FileManager.default.createDirectory(
        atPath: profilePath,
        withIntermediateDirectories: true
      )
      let launcher = Process()
      launcher.executableURL = URL(fileURLWithPath: "/usr/bin/open")
      launcher.arguments = [
        "-g", "-j", "-n", "-a", "/Applications/ChatGPT.app", "--args",
        "--user-data-dir=\(profilePath)",
        "--remote-debugging-port=\(port)",
      ]
      if let codexHomePath = state.backgroundCodexHomePath {
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = codexHomePath
        launcher.environment = environment
      }
      launcher.standardInput = FileHandle.nullDevice
      launcher.standardOutput = FileHandle.nullDevice
      launcher.standardError = FileHandle.nullDevice
      try launcher.run()
      launcher.waitUntilExit()
    } catch {
      state.lastError = "background_chat_launch_failed"
      return [
        "ok": false,
        "errorCode": "background_chat_launch_failed",
        "message": error.localizedDescription,
        "backgroundOnly": false,
        "runtimeState": "unavailable",
        "workerUsed": false,
      ]
    }

    for _ in 0..<100 {
      Thread.sleep(forTimeInterval: 0.25)
      targets = CDPClient.fetchTargets(portOverride: port)
      mainTarget = targets.first(where: eligibleTarget)
      if mainTarget != nil { break }
    }
  }

  guard var targetId = mainTarget?["id"] as? String else {
    state.lastError = "background_chat_target_unavailable"
    return [
      "ok": false,
      "errorCode": "background_chat_target_unavailable",
      "message": "插件自有 ChatGPT Chat 实例未能就绪；未使用当前 Work/worker 页面作为回退。",
      "backgroundOnly": false,
      "workerUsed": false,
      "port": port,
    ]
  }
  if !allowTestWebTarget {
    guard let activeProfile = pluginProfilePathForPort(port),
          canonicalPluginPath(activeProfile) == canonicalPluginPath(profilePath) else {
      state.lastError = "background_chat_profile_not_plugin_owned"
      return [
        "ok": false,
        "errorCode": "background_chat_profile_not_plugin_owned",
        "message": "调试端口上的 ChatGPT 实例不是插件创建的专用 profile；已拒绝接管。",
        "backgroundOnly": false,
        "workerUsed": false,
        "port": port,
      ]
    }
  }

  func rebindAfterRendererReplacement() {
    let liveTargets = CDPClient.fetchTargets(portOverride: port)
    if liveTargets.contains(where: { $0["id"] as? String == targetId }) { return }
    if let replacement = liveTargets.first(where: eligibleTarget)?["id"] as? String {
      targetId = replacement
    }
  }
  func wakeCurrentTargetWithoutShowingIt() {
    _ = resumeDedicatedProcessForPort(port)
    guard let target = CDPClient.fetchTargets(portOverride: port).first(where: {
      $0["id"] as? String == targetId
    }), let wsURL = target["webSocketDebuggerUrl"] as? String else { return }
    _ = CDPClient.setWebLifecycleActive(wsURLString: wsURL)
    _ = CDPClient.setHiddenPageFocusEmulation(wsURLString: wsURL)
    _ = CDPClient.setHiddenPageUserActive(wsURLString: wsURL)
  }

  // The hidden window can reopen on Work. Opening the Radix mode picker and
  // selecting ChatGPT are separate native CDP clicks. Selecting ChatGPT may
  // also replace the page target, so rediscover the plugin-owned app root
  // before every retry and require the replacement renderer to prove Chat.
  var initialChatSelection: [String: Any]?
  var chatModeConfirmed = false
  for _ in 0..<30 {
    rebindAfterRendererReplacement()
    wakeCurrentTargetWithoutShowingIt()
    initialChatSelection = cdpValue(
      port: port,
      targetId: targetId,
      expression: clickChatJS(),
      timeout: 4.0
    )
    _ = dispatchRecommendedCDPClick(
      initialChatSelection,
      port: port,
      targetId: targetId
    )
    if initialChatSelection?["ok"] as? Bool == true,
       initialChatSelection?["alreadySelected"] as? Bool == true {
      chatModeConfirmed = true
      break
    }
    Thread.sleep(forTimeInterval:
      initialChatSelection?["dispatchOnly"] as? Bool == true
        || initialChatSelection?["retryAfterModeSwitch"] as? Bool == true
        ? 0.6 : 0.25
    )
    rebindAfterRendererReplacement()
  }

  if let conversationId, !conversationId.isEmpty {
    let selected = cdpValue(
      port: port,
      targetId: targetId,
      expression: selectBackgroundConversationJS(conversationId),
      timeout: 16.0
    )
    guard selected?["ok"] as? Bool == true else {
      state.lastError = selected?["error"] as? String ?? "conversation_sidebar_selection_failed"
      return selected ?? [
        "ok": false,
        "errorCode": "conversation_sidebar_selection_failed",
        "message": "插件 Chat 无法从侧栏恢复指定会话。",
        "backgroundOnly": false,
        "workerUsed": false,
      ]
    }
  }

  // A connector can replace the composer with a "Continue in this chat"
  // routing card. Resolve that Chat-local transition before requiring the
  // composer, including for chat_status and resumeExisting entry paths.
  let chatContinuation = cdpValue(
    port: port,
    targetId: targetId,
    expression: autoConfirmChatContinuationJS(),
    timeout: 4.0
  )
  if chatContinuation?["clicked"] as? Bool == true {
    _ = dispatchRecommendedCDPClick(
      chatContinuation,
      port: port,
      targetId: targetId
    )
    Thread.sleep(forTimeInterval: 0.8)
    rebindAfterRendererReplacement()
  }

  let prepared: [String: Any]?
  if newChat {
    // Direct outbound sends promise a newly created Chat and main.swift
    // verifies newChatClicked. Reusing an existing blank composer here makes
    // preparation look successful but is then correctly rejected by that
    // contract, so require the sidebar action for this path.
    prepared = prepareNewChatTarget(port: port, targetId: targetId, allowBlankConversationReuse: false)
  } else {
    var current: [String: Any]?
    for _ in 0..<40 {
      rebindAfterRendererReplacement()
      wakeCurrentTargetWithoutShowingIt()
      current = cdpValue(
        port: port,
        targetId: targetId,
        expression: prepareBackgroundChatJS(
          newChat: false,
          conversationId: conversationId,
          confirmedChatMode: chatModeConfirmed
        ),
        timeout: 4.0
      )
      if current?["ok"] as? Bool == true { break }
      if current?["error"] as? String == "not_chat_surface" {
        let retrySelection = cdpValue(
          port: port,
          targetId: targetId,
          expression: clickChatJS(),
          timeout: 4.0
        )
        _ = dispatchRecommendedCDPClick(
          retrySelection,
          port: port,
          targetId: targetId
        )
        Thread.sleep(forTimeInterval: 0.35)
        rebindAfterRendererReplacement()
        chatModeConfirmed = chatModeConfirmed
          || (retrySelection?["alreadySelected"] as? Bool == true)
      }
      Thread.sleep(forTimeInterval: 0.25)
    }
    prepared = current
  }
  guard var prepared, prepared["ok"] as? Bool == true else {
    state.lastError = prepared?["error"] as? String ?? "background_chat_not_ready"
    return prepared ?? [
      "ok": false,
      "errorCode": "background_chat_not_ready",
      "message": "插件自有 ChatGPT 实例没有进入 Chat 页面；未向当前 Work/worker 页面发送。",
      "backgroundOnly": false,
      "workerUsed": false,
      "port": port,
    ]
  }

  // Visibility is deliberately not a startup gate. A visible renderer is valid
  // when it is the exact plugin-owned Chat surface; deployments that need the
  // old policy can opt in through CHATGPT_AUTO_CONFIRM_REQUIRE_HIDDEN or
  // CHATGPT_AUTO_CONFIRM_HEADLESS=0.
  let runtimeState = queueTargetRuntimeState(
    port: port,
    targetId: targetId,
    refreshLifecycle: false
  )
  if runtimeState == .visible && !queueAllowsVisibleDedicatedRenderer() {
    state.lastError = "background_chat_visibility_not_hidden"
    return [
      "ok": false,
      "errorCode": "background_chat_visibility_not_hidden",
      "message": "当前部署要求隐藏 ChatGPT 页面，但专用页面是可见的。",
      "backgroundOnly": false,
      "runtimeState": queueTargetRuntimeStateName(runtimeState),
      "workerUsed": false,
    ]
  }
  guard runtimeState == .hidden || runtimeState == .visible else {
    state.lastError = "background_chat_runtime_unusable"
    return [
      "ok": false,
      "errorCode": "background_chat_runtime_unusable",
      "message": "插件自有 ChatGPT 页面未处于可用的 Chat renderer 状态。",
      "backgroundOnly": false,
      "runtimeState": queueTargetRuntimeStateName(runtimeState),
      "workerUsed": false,
    ]
  }

  state.backgroundAppPort = port
  state.backgroundProfilePath = profilePath
  state.backgroundChatTargetId = targetId
  state.backgroundConversationId = conversationId
  state.lastError = nil
  prepared["port"] = port
  prepared["targetId"] = targetId
  prepared["profilePath"] = profilePath
  prepared["backgroundOnly"] = runtimeState == .hidden
  prepared["runtimeState"] = queueTargetRuntimeStateName(runtimeState)
  return prepared
}

func keepApprovalBackgroundEndpointAlive(_ state: inout PluginState) {
  guard let port = state.backgroundAppPort,
        let targetId = state.backgroundChatTargetId,
        let target = CDPClient.fetchTargets(portOverride: port).first(where: {
          $0["id"] as? String == targetId
        }),
        let wsURL = target["webSocketDebuggerUrl"] as? String else {
    // Locally, a missing endpoint can mean the user intentionally quit the
    // plugin-owned ChatGPT instance. Respect that decision and require an
    // explicit start instead of reopening an app behind the user's back.
    state.backgroundChatTargetId = nil
    if !runningOnGitHubActions() {
      state.enabled = false
      state.lastError = "background_chat_closed_requires_restart"
      return
    }
    _ = ensureHiddenChatTarget(&state)
    return
  }
  // Reassert an active Chromium lifecycle on every watcher pass. These CDP
  // commands do not show a BrowserWindow or activate ChatGPT, but they prevent
  // a hidden renderer from remaining frozen after screen lock/App Nap.
  _ = CDPClient.setWebLifecycleActive(wsURLString: wsURL)
  _ = CDPClient.setHiddenPageFocusEmulation(wsURLString: wsURL)
  _ = CDPClient.setHiddenPageUserActive(wsURLString: wsURL)
}

func scanIPC(_ state: inout PluginState) -> [String: Any]? {
  guard state.approveAll == true || !state.rules.isEmpty else { return nil }
  let pageTargets = loadedApprovalTargets(state)
  guard !pageTargets.isEmpty else { return nil }

  guard let rulesData = try? JSONSerialization.data(withJSONObject: state.rules.map { [
    "id": $0.id, "application": $0.application, "action": $0.action, "resource": $0.resource
  ] }), let rulesJSON = String(data: rulesData, encoding: .utf8) else { return nil }
  let approveAllBool = state.approveAll == true ? "true" : "false"

  let jsScript = """
  (() => {
    const rules = \(rulesJSON);
    const approveAll = \(approveAllBool);
    const results = { candidates: 0, approved: 0, pending: 0, blocked: 0, unmatched: 0, internalActions: 0, domEvents: 0, modeContinuations: 0, audits: [] };

    function sanitizeContext(text) {
      if (!text) return "";
      let clean = text.replace(/\\s+/g, ' ').trim();
      if (clean.length > 200) clean = clean.substring(0, 200) + "...";
      let hash = 0x811c9dc5;
      for (let i = 0; i < clean.length; i++) {
        hash ^= clean.charCodeAt(i);
        hash += (hash << 1) + (hash << 4) + (hash << 7) + (hash << 8) + (hash << 24);
      }
      return "Allow ChatGPT to use [approval details redacted] #" + (hash >>> 0).toString(16);
    }

    function isAllowTitle(text) {
      const norm = (text || "").toLowerCase().replace(/[\\s\\u21b5\\u23ce]+/g, " ").trim()
        .replace(/\\s*[\\(（\\[]?\\s*(?:esc|escape|enter|return|\\u21b5|\\u23ce|\\u238b|cmd\\s*enter|ctrl\\s*enter)\\s*[\\)）\\]]?\\s*$/i, "");
      return ["allow", "allow once", "allow this time", "approve", "approve once",
              "confirm", "confirm once", "authorize", "authorize once", "grant", "grant once",
              "full access", "complete access", "允许", "允许一次", "同意", "同意一次",
              "确认", "确认一次", "授权", "授权一次", "完全访问", "完整访问"].includes(norm);
    }

    function isRejectTitle(text) {
      const norm = (text || "").toLowerCase().replace(/[\\s\\u21b5\\u23ce]+/g, " ").trim()
        .replace(/\\s*[\\(（\\[]?\\s*(?:esc|escape|enter|return|\\u21b5|\\u23ce|\\u238b|cmd\\s*enter|ctrl\\s*enter)\\s*[\\)）\\]]?\\s*$/i, "");
      return ["deny", "reject", "cancel", "deny once", "reject once", "not now", "拒绝", "拒绝一次",
              "不允许", "不允许一次", "取消", "暂不"].includes(norm);
    }

    function isContinueInChatTitle(text) {
      const norm = (text || "").toLowerCase().replace(/\\s+/g, " ").trim();
      return ["继续在此聊天", "continue in this chat", "stay in this chat", "continue here"].includes(norm);
    }

    function checkCardMatch(contextText, metadataBody) {
      if (approveAll) return { match: true, reason: "IPC 主路径：通用模式：已通过进程间通信自动确认 (allow_once/target_message_id)", ruleId: null };
      const norm = (contextText || "").toLowerCase() + " " + (metadataBody || "").toLowerCase();
      for (const rule of rules) {
        if (norm.includes((rule.application || "").toLowerCase()) &&
            norm.includes((rule.action || "").toLowerCase()) &&
            norm.includes((rule.resource || "").toLowerCase())) {
          return { match: true, reason: "IPC 主路径：命中精确允许规则 " + rule.id + " (allow_once/target_message_id)", ruleId: rule.id };
        }
      }
      return { match: false, reason: "未同时匹配应用、动作和资源", ruleId: null };
    }

    function collectButtons(root, output, visited) {
      if (!root || visited.has(root)) return;
      visited.add(root);
      try {
        output.push(...Array.from(root.querySelectorAll('button, a, [role="button"]')));
        for (const el of root.querySelectorAll('*')) {
          if (el.shadowRoot) collectButtons(el.shadowRoot, output, visited);
        }
        for (const frame of root.querySelectorAll('iframe')) {
          try {
            if (frame.contentDocument) collectButtons(frame.contentDocument, output, visited);
          } catch (_) {}
        }
      } catch (_) {}
    }

    function invokeInternalApproval(btn) {
      const propsKey = Object.keys(btn).find(k => k.startsWith('__reactProps$'));
      const fiberKey = Object.keys(btn).find(k => k.startsWith('__reactFiber$'));
      const directProps = propsKey ? btn[propsKey] : null;
      const fiberProps = fiberKey ? btn[fiberKey]?.memoizedProps : null;
      const handler = directProps?.onClick || fiberProps?.onClick;
      if (typeof handler === 'function') {
        const event = {
          type: 'click', target: btn, currentTarget: btn,
          defaultPrevented: false,
          preventDefault() { this.defaultPrevented = true; },
          stopPropagation() {}, persist() {},
          nativeEvent: { type: 'click', target: btn }
        };
        handler(event);
        return 'react_handler';
      }
      btn.click();
      return 'dom_event';
    }

    // Split approval buttons have a primary "Allow" action and a small
    // adjacent arrow.  For the broad, always-on watcher, prefer the arrow's
    // session menu too; otherwise the generic IPC path could consume the
    // one-shot Allow action before the dedicated Chat watcher gets a chance
    // to select "Allow for this conversation".
    function normalizedLabel(button) {
      return [
        button?.innerText || '',
        button?.getAttribute?.('aria-label') || '',
        button?.getAttribute?.('title') || '',
      ].join(' ').replace(/[\\s\\u21b5\\u23ce]+/g, ' ').trim().toLowerCase();
    }
    const sessionHints = [
      'this chat', 'this conversation', 'for this chat', 'for this conversation',
      'for this session', 'during this chat', 'always allow in this chat',
      '本次会话', '这次会话', '此会话', '当前会话', '在此聊天中', '本次聊天',
      '始终允许', '会话期间'
    ];
    function isSessionScopeLabel(value) {
      const normalized = (value || '').toLowerCase();
      return sessionHints.some(hint => normalized.includes(hint))
        || /(?:allow|approve|confirm|允许|同意|确认).*(?:this (?:chat|conversation|session)|本次(?:会话|聊天)|当前会话)/i.test(normalized);
    }
    function isVisibleControl(button) {
      return !!(button && !button.disabled
        && (button.offsetWidth || button.offsetHeight || button.getClientRects?.().length));
    }
    function hasStructuralCardSemantics(element) {
      if (!element) return false;
      const role = (element.getAttribute?.('role') || '').toLowerCase();
      if (role === 'dialog' || role === 'alertdialog'
          || element.getAttribute?.('aria-modal') === 'true') return true;
      return Array.from(element.attributes || []).some(attribute =>
        /^(?:data-testid|data-test|data-state|class|id)$/i.test(attribute.name)
          && /(?:approval|authorize|authorization|permission|consent|access|tool-?call)/i.test(
            attribute.value || ''
          )
      );
    }
    function hasApprovalReactMetadata(element) {
      let node = element;
      for (let ancestorIndex = 0; ancestorIndex < 15 && node; ancestorIndex++) {
        const keys = Object.keys(node).filter(key =>
          key.startsWith('__reactFiber$') || key.startsWith('__reactProps$'));
        for (const key of keys) {
          let current = node[key];
          for (let depth = 0; depth < 20 && current; depth++) {
            const props = current.memoizedProps || current.pendingProps || current.props || current;
            if (props?.jit_plugin_data || props?.pluginData || props?.allow_once
                || props?.allowOnce || props?.target_message_id || props?.targetMessageId
                || props?.requiresApproval || props?.authorization || props?.permission
                || props?.consent || props?.approval) return true;
            current = current.return;
          }
        }
        node = node.parentElement;
      }
      return false;
    }
    function isMenuTrigger(button) {
      if (!isVisibleControl(button)) return false;
      const attributes = [
        button.getAttribute?.('aria-label') || '',
        button.getAttribute?.('title') || '',
        button.getAttribute?.('data-testid') || '',
        button.getAttribute?.('data-slot') || '',
        button.getAttribute?.('class') || '',
      ].join(' ');
      return button.getAttribute?.('aria-haspopup') === 'menu'
        || button.getAttribute?.('aria-haspopup') === 'listbox'
        || button.getAttribute?.('aria-expanded') !== null
        || button.getAttribute?.('data-state') !== null
        || /menu|dropdown|chevron|caret|arrow|下拉|箭头|更多|选项/i.test(attributes.toLowerCase());
    }
    function isAdjacentSplitControl(allowButton, control) {
      if (!allowButton || !control || control === allowButton || !isMenuTrigger(control)) return false;
      const allowRect = allowButton.getBoundingClientRect?.();
      const controlRect = control.getBoundingClientRect?.();
      if (!allowRect || !controlRect) return false;
      const verticalOverlap = Math.min(allowRect.bottom, controlRect.bottom)
        - Math.max(allowRect.top, controlRect.top);
      const horizontalGap = Math.max(
        allowRect.left - controlRect.right,
        controlRect.left - allowRect.right,
        0
      );
      return verticalOverlap > 0 && horizontalGap <= 12;
    }
    function visibleMenuItems() {
      return Array.from(document.querySelectorAll(
        '[role="menuitem"], [role="menuitemradio"], [role="option"], '
          + '[role="menu"] button, [role="listbox"] button, '
          + '[data-radix-menu-content] button, '
          + '[data-radix-popper-content-wrapper] button'
      )).filter(isVisibleControl);
    }
    function findSessionScopeAction(allowButton, cardButtons) {
      const sessionOption = visibleMenuItems().find(item =>
        item !== allowButton && isSessionScopeLabel(normalizedLabel(item))
      );
      if (sessionOption) return { type: 'option', button: sessionOption };
      const direct = cardButtons.find(button => button !== allowButton
        && isSessionScopeLabel(normalizedLabel(button)));
      if (direct) return { type: 'trigger', button: direct };
      const adjacent = cardButtons.find(button => button !== allowButton
        && isAdjacentSplitControl(allowButton, button));
      if (adjacent) return { type: 'trigger', button: adjacent };
      const fallback = cardButtons.find(button => button !== allowButton
        && isMenuTrigger(button));
      return fallback ? { type: 'trigger', button: fallback } : null;
    }
    function invokeSessionScopeAction(allowButton, cardButtons) {
      const action = findSessionScopeAction(allowButton, cardButtons);
      if (!action) return null;
      if (action.type === 'option') {
        invokeInternalApproval(action.button);
        return 'session_scope_option';
      }
      const expanded = action.button.getAttribute?.('aria-expanded') === 'true'
        || (action.button.getAttribute?.('data-state') || '').toLowerCase() === 'open';
      if (!expanded) {
        invokeInternalApproval(action.button);
        return 'session_scope_menu_opened';
      }
      return 'session_scope_menu_pending';
    }

    const buttons = [];
    collectButtons(document, buttons, new Set());
    const processedContainers = new Set();

    // Chat can ask whether to remain in Chat or switch to Work for a coding
    // task. The plugin must explicitly stay in Chat and must never select the
    // adjacent "继续工作 / Continue working" action.
    for (const btn of buttons) {
      const title = btn.innerText || btn.getAttribute('aria-label') || btn.getAttribute('title') || "";
      if (!isContinueInChatTitle(title) || btn.disabled) continue;
      try {
        const internalMode = invokeInternalApproval(btn);
        if (internalMode === 'react_handler') results.internalActions++;
        else results.domEvents++;
        results.candidates++;
        results.approved++;
        results.modeContinuations++;
        results.audits.push({
          buttonTitle: title,
          decision: "continue_in_chat",
          reason: "保留 Chat 模式；拒绝切换到 Work/worker",
          clicked: true,
          ruleId: null,
          promptText: "Chat mode continuation"
        });
      } catch (_) {
        results.candidates++;
        results.blocked++;
      }
      break;
    }

    for (const btn of buttons) {
      const title = btn.innerText || btn.getAttribute('aria-label') || btn.getAttribute('title') || "";
      if (!isAllowTitle(title)) continue;

      let container = btn.parentElement;
      let foundReject = false;
      let contextText = "";
      let targetMessageId = null;
      let metadataBody = "";
      let cardButtons = [];

      for (let i = 0; i < 15 && container; i++) {
        if (processedContainers.has(container)) break;
        const cText = container.innerText || "";
        cardButtons = Array.from(container.querySelectorAll('button, a, [role="button"]'));
        const hasReject = cardButtons.some(b => isRejectTitle(b.innerText || b.getAttribute('aria-label') || b.getAttribute('title') || ""));

        let fiberKey = Object.keys(container).find(k => k.startsWith('__reactFiber$') || k.startsWith('__reactProps$'));
        if (fiberKey) {
          let currNode = container[fiberKey];
          for (let j = 0; j < 15 && currNode; j++) {
            const props = currNode.memoizedProps || currNode.props || {};
            const pluginData = props.jit_plugin_data || props.pluginData || (props.card && props.card.jit_plugin_data);
            if (pluginData && pluginData.from_server && pluginData.from_server.body) {
              metadataBody = typeof pluginData.from_server.body === 'string' ? pluginData.from_server.body : JSON.stringify(pluginData.from_server.body);
              if (pluginData.from_server.actions && pluginData.from_server.actions.allow_once) {
                targetMessageId = pluginData.from_server.actions.allow_once.target_message_id || pluginData.from_server.actions.allow_once.targetMessageId;
              }
            }
            if (props.targetMessageId || props.target_message_id) {
              targetMessageId = props.targetMessageId || props.target_message_id;
            }
            currNode = currNode.return;
          }
        }

        const compact = cardButtons.length > 0 && cardButtons.length <= 16;
        const structuralCard = hasReject || hasStructuralCardSemantics(container)
          || hasApprovalReactMetadata(btn) || hasApprovalReactMetadata(container)
          || Boolean(targetMessageId || metadataBody);
        if (compact && structuralCard) {
          foundReject = true;
          contextText = cText;
          processedContainers.add(container);
          break;
        }
        container = container.parentElement;
      }

      if (foundReject && container) {
        results.candidates++;
        const matchRes = checkCardMatch(contextText, metadataBody);
        const auditPrompt = sanitizeContext(contextText || title);

        if (matchRes.match) {
          try {
            const scopedMode = approveAll
              ? invokeSessionScopeAction(btn, cardButtons)
              : null;
            if (scopedMode === 'session_scope_menu_opened'
                || scopedMode === 'session_scope_menu_pending') {
              results.pending++;
              results.audits.push({
                buttonTitle: title,
                decision: 'session_scope_pending',
                reason: scopedMode === 'session_scope_menu_opened'
                  ? '已打开允许范围菜单，等待选择本次会话'
                  : '允许范围菜单已打开，等待本次会话选项',
                clicked: scopedMode === 'session_scope_menu_opened',
                ruleId: matchRes.ruleId,
                promptText: auditPrompt,
              });
              break;
            }
            const internalMode = scopedMode === 'session_scope_option'
              ? scopedMode
              : invokeInternalApproval(btn);
            if (internalMode === 'react_handler') results.internalActions++;
            else results.domEvents++;
            results.approved++;
            results.audits.push({
              buttonTitle: title,
              decision: "allow",
              reason: matchRes.reason + "；内部执行=" + internalMode,
              clicked: true,
              ruleId: matchRes.ruleId,
              promptText: auditPrompt
            });
          } catch (e) {
            results.blocked++;
            results.audits.push({
              buttonTitle: title,
              decision: "allow",
              reason: matchRes.reason,
              clicked: false,
              ruleId: matchRes.ruleId,
              promptText: auditPrompt,
              error: "ipc_click_failed"
            });
          }
        } else {
          results.unmatched++;
          results.audits.push({
            buttonTitle: title,
            decision: "noMatch",
            reason: matchRes.reason,
            clicked: false,
            ruleId: null,
            promptText: auditPrompt
          });
        }
        // Handle at most one authorization request per watcher tick. The
        // native rate limiter persists the decision before the next scan.
        break;
      }
    }

    return results;
  })()
  """

  var totalCandidates = 0
  var totalApproved = 0
  var totalPending = 0
  var totalBlocked = 0
  var totalUnmatched = 0
  var totalInternalActions = 0
  var totalDOMEvents = 0
  let scannedTargetCount = pageTargets.count
  let scannedPorts = Array(Set(pageTargets.map(\.port))).sorted()

  for endpoint in pageTargets {
    guard let wsURL = endpoint.target["webSocketDebuggerUrl"] as? String else { continue }
    let targetId = endpoint.target["id"] as? String ?? "unknown-target"
    var approvalDetection: [String: Any]?
    var approvalScreenshotPath: String?
    if let detectionEval = CDPClient.evaluate(
          wsURLString: wsURL,
          expression: detectDedicatedAuthorizationJS()
        ),
       let detectionResult = detectionEval["result"] as? [String: Any],
       let detectionValue = ((detectionResult["result"] as? [String: Any])?["value"]
         ?? detectionResult["value"]) as? [String: Any],
       detectionValue["found"] as? Bool == true {
      approvalDetection = detectionValue
      approvalScreenshotPath = captureHiddenChatScreenshot(
        port: endpoint.port,
        targetId: targetId,
        label: "approval-watcher-before"
      )
      queueTrace(
        "task=approval-watcher stage=approval-ipc-detected strategy=per-card "
          + "target=\(targetId) selected=\(detectionValue["selectedLabel"] as? String ?? "none") "
          + "screenshot=\(approvalScreenshotPath ?? "none") "
          + approvalDetectionTraceFields(detectionValue)
      )
    }
    if let fingerprint = approvalFingerprint(approvalDetection) {
      let currentDate = Date()
      if (state.handledApprovalFingerprints ?? []).contains(fingerprint) {
        totalCandidates += 1
        totalPending += 1
        state.lastError = nil
        queueTrace(
          "task=approval-watcher stage=approval-ipc-ignored "
            + "reason=confirmed-renderer-ghost fingerprint=\(fingerprint)"
        )
        continue
      }
      let recentApprovals = prunedAutomaticApprovalTimestamps(
        state.automaticApprovalTimestamps,
        now: currentDate
      )
      state.automaticApprovalTimestamps = recentApprovals
      if recentApprovals.count >= maxAutomaticApprovalsPerWindow {
        state.enabled = false
        state.lastError = "approval_rate_circuit_open"
        totalCandidates += 1
        totalBlocked += 1
        queueTrace(
          "task=approval-watcher stage=approval-ipc-blocked "
            + "reason=rate count=\(recentApprovals.count) "
            + "window=\(Int(automaticApprovalWindowSeconds))"
        )
        continue
      }
    }
    guard let evalRes = CDPClient.evaluate(wsURLString: wsURL, expression: jsScript),
          let result = evalRes["result"] as? [String: Any],
          let value = ((result["result"] as? [String: Any])?["value"] ?? result["value"]) as? [String: Any] else { continue }
    let c = value["candidates"] as? Int ?? 0
    let a = value["approved"] as? Int ?? 0
    let p = value["pending"] as? Int ?? 0
    let b = value["blocked"] as? Int ?? 0
    let u = value["unmatched"] as? Int ?? 0
    let internalActions = value["internalActions"] as? Int ?? 0
    let domEvents = value["domEvents"] as? Int ?? 0
    totalCandidates += c
    totalApproved += a
    totalPending += p
    totalBlocked += b
    totalUnmatched += u
    totalInternalActions += internalActions
    totalDOMEvents += domEvents
    if a > 0, let fingerprint = approvalFingerprint(approvalDetection) {
      recordHandledApprovalFingerprint(
        fingerprint,
        fingerprints: &state.handledApprovalFingerprints,
        fingerprintAttempts: &state.automaticApprovalFingerprintAttempts,
        timestamps: &state.automaticApprovalTimestamps,
        lastFingerprint: &state.lastAutomaticApprovalFingerprint,
        lastApprovedAt: &state.lastAutomaticApprovalAt,
        now: Date()
      )
    }

    if approvalDetection != nil || a > 0 || b > 0 {
      queueTrace(
        "task=approval-watcher stage=approval-ipc-result strategy=per-card "
          + "target=\(targetId) approved=\(a) pending=\(p) blocked=\(b) unmatched=\(u) "
          + "internalActions=\(internalActions) domEvents=\(domEvents) "
          + "screenshot=\(approvalScreenshotPath ?? "none") "
          + approvalDetectionTraceFields(approvalDetection)
      )
      if approvalDetection != nil && a == 0 {
        let afterPath = captureHiddenChatScreenshot(
          port: endpoint.port,
          targetId: targetId,
          label: "approval-watcher-after"
        )
        queueTrace(
          "task=approval-watcher stage=approval-ipc-unconfirmed strategy=per-card "
            + "target=\(targetId) beforeScreenshot=\(approvalScreenshotPath ?? "none") "
            + "afterScreenshot=\(afterPath ?? "none")"
        )
      }
    }

    if let audits = value["audits"] as? [[String: Any]] {
      for item in audits {
        let buttonTitle = item["buttonTitle"] as? String ?? ""
        let decision = item["decision"] as? String ?? ""
        let reason = item["reason"] as? String ?? ""
        let clicked = item["clicked"] as? Bool ?? false
        let ruleId = item["ruleId"] as? String
        let promptText = item["promptText"] as? String ?? ""
        let error = item["error"] as? String

        if !state.audit.contains(where: { $0.promptText == promptText && $0.decision == decision && $0.clicked == clicked && $0.reason == reason }) {
          state.audit.append(AuditEvent(
            at: isoFormatter.string(from: Date()),
            decision: decision,
            reason: reason,
            clicked: clicked,
            ruleId: ruleId,
            buttonTitle: buttonTitle,
            promptText: promptText,
            error: error
          ))
        }
      }
    }
  }

  if totalCandidates > 0 {
    if state.audit.count > 100 { state.audit.removeFirst(state.audit.count - 100) }
    if state.enabled { state.lastError = nil }
    return [
      "ok": true, "candidates": totalCandidates, "approved": totalApproved,
      "pending": totalPending, "blocked": totalBlocked, "unmatched": totalUnmatched,
      "backgroundOnly": pluginBackgroundRuntimeState(state) == .hidden,
      "runtimeState": pluginBackgroundRuntimeState(state).map(queueTargetRuntimeStateName) as Any,
      "pageChanged": false, "ipcPrimaryPath": true,
      "hiddenTargetCount": scannedTargetCount,
      "loadedRendererCount": scannedTargetCount, "scannedPorts": scannedPorts,
      "internalActions": totalInternalActions, "domEvents": totalDOMEvents
    ]
  }
  if scannedTargetCount > 0 {
    state.lastError = nil
    return [
      "ok": true, "candidates": 0, "approved": 0, "pending": 0,
      "blocked": 0, "unmatched": 0,
      "backgroundOnly": pluginBackgroundRuntimeState(state) == .hidden,
      "runtimeState": pluginBackgroundRuntimeState(state).map(queueTargetRuntimeStateName) as Any,
      "pageChanged": false, "ipcPrimaryPath": true,
      "hiddenTargetCount": scannedTargetCount,
      "loadedRendererCount": scannedTargetCount, "scannedPorts": scannedPorts,
    ]
  }
  return nil
}
