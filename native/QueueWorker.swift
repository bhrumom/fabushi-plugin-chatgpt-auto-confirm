import ApplicationServices
import Cocoa
import CoreGraphics
import Darwin
import Foundation
import SystemConfiguration

let backgroundWindowQueueWorkerMode = "single-process-hidden-prewarm"
let sharedConversationQueueWorkerMode = "single-process-hidden-chat-conversations"
let parallelHiddenWindowQueueWorkerMode = "single-process-hidden-chat-windows"
let parallelHeadlessWindowQueueWorkerMode = "parallel-headless-chat-windows"
let parallelDedicatedProcessQueueWorkerMode = "parallel-dedicated-hidden-chat-processes"
let legacyIsolatedQueueWorkerMode = "isolated-dedicated-process"
// Electron stays alive after its executable is launched. Keep the launcher
// objects alive for the lifetime of each dedicated worker; otherwise releasing
// `Process` can tear down the child before its CDP endpoint is ready.
var dedicatedQueueChatLaunchers: [Int: Process] = [:]

// The first CDP target exposed by a fresh ChatGPT process is often the
// browser target (or an about:blank page), not the renderer that owns the
// authenticated app. Starting the Chat target timeout from that first target
// made a slow second worker look dead just before its app renderer appeared.
// Keep each direct/LaunchServices bootstrap bounded: the parallel verifier
// waits 300 seconds for both workers, and two isolated attempts must be able
// to fail and retry within that window instead of holding the queue lock for
// several minutes with no renderer target.
let dedicatedRendererBootstrapTimeout: TimeInterval = 20.0

enum QueueTargetRuntimeState {
  case missing
  case hidden
  case hiddenNonChat
  case visible
  case suspended
}

// A hosted GitHub Actions runner has no user-facing ChatGPT window. Keep the
// dedicated process private to its copied profile, but do not make bootstrap
// depend on macOS successfully applying a hidden/occluded lifecycle state.
// Desktop runs remain fail-closed when a renderer is genuinely visible.
func queueAllowsVisibleDedicatedRenderer() -> Bool {
  let environment = ProcessInfo.processInfo.environment
  let explicit = environment["CHATGPT_AUTO_CONFIRM_HEADLESS"]?
    .trimmingCharacters(in: .whitespacesAndNewlines)
    .lowercased()
  if explicit == "1" || explicit == "true" {
    return true
  }
  return environment["GITHUB_ACTIONS"]?.lowercased() == "true"
}

func runningOnGitHubActions() -> Bool {
  ProcessInfo.processInfo.environment["GITHUB_ACTIONS"]?.lowercased() == "true"
}

// Persistent hosted runs normally have one logical task at a time. Reuse the
// authenticated app process's official prewarm service for that path: it is
// the renderer that the login check already proved to have a working preload
// bridge. The parallel smoke command explicitly sets its private state path
// and still uses isolated workers so it can verify two concurrent Chats.
func hostedPersistentQueueUsesPrewarmWorker() -> Bool {
  guard runningOnGitHubActions() else { return false }
  let parallelState = ProcessInfo.processInfo.environment[
    "CHATGPT_AUTO_CONFIRM_PARALLEL_STATE"
  ]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  return parallelState.isEmpty
}

func cgWindowNumber(_ value: Any?) -> CGFloat? {
  if let number = value as? NSNumber {
    return CGFloat(number.doubleValue)
  }
  if let number = value as? Double {
    return CGFloat(number)
  }
  if let number = value as? Int {
    return CGFloat(number)
  }
  return nil
}

// System privacy alerts are sometimes not exposed to System Events as an
// AXSystemDialog. Quartz still reports the frontmost ChatGPT-owned alert as a
// small on-screen window, so use that strictly scoped geometry as a second
// path. This keeps the click limited to ChatGPT's own compact foreground
// window and does not weaken the in-page authorization checks.
func clickCompactChatGPTLocalNetworkWindowViaQuartz() -> Bool {
  guard queueAllowsVisibleDedicatedRenderer(),
        NSWorkspace.shared.runningApplications.contains(where: { application in
          guard let bundleIdentifier = application.bundleIdentifier else { return false }
          return targetBundleIdentifiers.contains(bundleIdentifier)
        }),
        let windowInfo = CGWindowListCopyWindowInfo(
          [.optionOnScreenOnly, .excludeDesktopElements],
          kCGNullWindowID
        ) as? [[String: Any]] else {
    return false
  }

  func postClick(at point: CGPoint, stage: String) -> Bool {
    guard let mouseDown = CGEvent(
      mouseEventSource: nil,
      mouseType: .leftMouseDown,
      mouseCursorPosition: point,
      mouseButton: .left
    ), let mouseUp = CGEvent(
      mouseEventSource: nil,
      mouseType: .leftMouseUp,
      mouseCursorPosition: point,
      mouseButton: .left
    ) else {
      return false
    }
    queueTrace(stage)
    mouseDown.post(tap: .cghidEventTap)
    mouseUp.post(tap: .cghidEventTap)
    return true
  }

  for window in windowInfo {
    let ownerName = window[kCGWindowOwnerName as String] as? String ?? "unknown"
    guard let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue,
          layer >= 0, layer < 100,
          let bounds = window[kCGWindowBounds as String] as? [String: Any],
          let originX = cgWindowNumber(bounds["X"]),
          let originY = cgWindowNumber(bounds["Y"]),
          let width = cgWindowNumber(bounds["Width"]),
          let height = cgWindowNumber(bounds["Height"]),
          width > 180, width < 420, height > 180, height < 360 else {
      continue
    }
    let clickPoint = CGPoint(
      x: originX + width * 0.72,
      y: originY + height * 0.87
    )
    if postClick(
      at: clickPoint,
      stage:
      "worker-create stage=dedicated-native-local-network-geometry-detected "
        + "window=\(Int(width))x\(Int(height)) owner=\(ownerName)"
    ) {
      return true
    }
  }

  // CoreServicesUIAgent can own the privacy alert while ChatGPT remains the
  // running application, so there may be no matching compact window in the
  // list. The hosted headless display uses the standard macOS alert layout;
  // click its Allow location only after a ChatGPT process was confirmed.
  if let screen = NSScreen.screens.first {
    let fallbackPoint = CGPoint(
      x: screen.frame.minX + screen.frame.width * 0.557,
      y: screen.frame.minY + screen.frame.height * 0.420
    )
    if postClick(
      at: fallbackPoint,
      stage: "worker-create stage=dedicated-native-local-network-screen-fallback"
    ) {
      return true
    }
  }
  return false
}

// A fresh copied ChatGPT profile can trigger macOS's one-time local-network
// privacy alert before its preload bridge is mounted. On hosted Actions there
// is no person who can click that native alert, so the dedicated worker would
// otherwise remain an empty/overlay renderer forever. Scope this helper to the
// headless worker path and require the exact macOS prompt text; ChatGPT's own
// in-page authorization cards continue through the normal CDP approval flow.
func approveHeadlessChatGPTLocalNetworkPrompt() -> Bool {
  guard queueAllowsVisibleDedicatedRenderer() else { return false }
  if clickCompactChatGPTLocalNetworkWindowViaQuartz() {
    return true
  }
  let script = #"""
  tell application "System Events"
    repeat with processRef in (application processes whose name is "ChatGPT")
      repeat with windowRef in (windows of processRef)
        try
          set promptTexts to ""
          try
            set promptTexts to (value of static texts of windowRef) as text
          end try
        set dialogRole to ""
        try
          set dialogRole to (subrole of windowRef) as text
        end try
        set compactDialog to false
        try
          set windowSize to size of windowRef
          set windowWidth to item 1 of windowSize
          set windowHeight to item 2 of windowSize
          if (frontmost of processRef) and ¬
             (windowWidth is greater than 180) and (windowWidth is less than 420) and ¬
             (windowHeight is greater than 180) and (windowHeight is less than 360) then
            set compactDialog to true
          end if
        end try
        if (dialogRole is "AXSystemDialog") or compactDialog or ¬
           (promptTexts contains "find devices on local networks") or ¬
           (promptTexts contains "在本地网络上查找设备") or ¬
           (promptTexts contains "在本地網絡上查找設備") then
            if exists (button "Allow" of windowRef) then
              click button "Allow" of windowRef
              return "clicked"
            end if
            if exists (button "允许" of windowRef) then
              click button "允许" of windowRef
              return "clicked"
            end if
            if exists (button "允許" of windowRef) then
              click button "允許" of windowRef
              return "clicked"
            end if
            try
              if compactDialog then
                set windowPosition to position of windowRef
                set clickX to ((item 1 of windowPosition) + (windowWidth * 72 / 100)) as integer
                set clickY to ((item 2 of windowPosition) + (windowHeight * 87 / 100)) as integer
                click at {clickX, clickY}
                return "clicked"
              end if
            end try
            if (dialogRole is "AXSystemDialog") and (frontmost of processRef) then
              return "dialog"
            end if
          end if
        end try
      end repeat
    end repeat
  end tell
  return "none"
  """#
  let process = Process()
  let output = Pipe()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
  process.arguments = ["-e", script]
  process.standardInput = FileHandle.nullDevice
  process.standardOutput = output
  process.standardError = FileHandle.nullDevice
  do {
    try process.run()
  } catch {
    return false
  }
  let deadline = Date().addingTimeInterval(1.5)
  while process.isRunning && Date() < deadline {
    Thread.sleep(forTimeInterval: 0.05)
  }
  guard !process.isRunning else {
    process.terminate()
    return false
  }
  guard process.terminationStatus == 0,
        let result = String(
          data: output.fileHandleForReading.readDataToEndOfFile(),
          encoding: .utf8
        ) else {
    return false
  }
  if result.contains("clicked") { return true }
  guard result.contains("dialog") else { return false }
  let keyPress = Process()
  keyPress.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
  keyPress.arguments = [
    "-e",
    "tell application \"System Events\" to key code 36",
  ]
  keyPress.standardInput = FileHandle.nullDevice
  keyPress.standardOutput = FileHandle.nullDevice
  keyPress.standardError = FileHandle.nullDevice
  do {
    try keyPress.run()
  } catch {
    return false
  }
  let keyDeadline = Date().addingTimeInterval(1.0)
  while keyPress.isRunning && Date() < keyDeadline {
    Thread.sleep(forTimeInterval: 0.05)
  }
  guard !keyPress.isRunning else {
    keyPress.terminate()
    return false
  }
  return keyPress.terminationStatus == 0
}

func queueTargetStateIsUsableForQueue(
  _ runtimeState: QueueTargetRuntimeState,
  workerMode: String?
) -> Bool {
  switch runtimeState {
  case .hidden:
    return true
  case .visible:
    return queueAllowsVisibleDedicatedRenderer()
      && (
        workerMode == parallelDedicatedProcessQueueWorkerMode
          || workerMode == parallelHeadlessWindowQueueWorkerMode
          // The shared controller fallback deliberately borrows the primary
          // renderer after proving it is a real Chat surface. It is reachable
          // only when queueAllowsVisibleDedicatedRenderer() has been explicitly
          // enabled (or on GitHub Actions), and shared mode prevents task
          // cleanup from closing that borrowed renderer.
          || workerMode == sharedConversationQueueWorkerMode
      )
  case .missing, .hiddenNonChat, .suspended:
    return false
  }
}

func queueUsesBackgroundWindow(_ state: PluginState) -> Bool {
  state.queueWorkerMode == backgroundWindowQueueWorkerMode
    || state.queueWorkerMode == sharedConversationQueueWorkerMode
    || state.queueWorkerMode == parallelHiddenWindowQueueWorkerMode
    || state.queueWorkerMode == parallelHeadlessWindowQueueWorkerMode
    || state.queueWorkerMode == parallelDedicatedProcessQueueWorkerMode
}

func queueTargetRuntimeState(
  port: Int,
  targetId: String,
  refreshLifecycle: Bool
) -> QueueTargetRuntimeState {
  _ = resumeDedicatedProcessForPort(port)
  guard let target = CDPClient.fetchTargets(portOverride: port).first(where: {
    $0["id"] as? String == targetId
  }), let wsURL = target["webSocketDebuggerUrl"] as? String else {
    return .missing
  }
  let expression = """
  (async () => {
    const startedAt = performance.now();
    await new Promise(resolve => setTimeout(resolve, 50));
    const quickChatRoot = document.querySelector(
      '[data-pip-obstacle="quick-chat"], [data-quick-chat-drag-handle]'
    )?.closest('[role="dialog"], section, div');
    const textarea = quickChatRoot?.querySelector(
      '#prompt-textarea, [contenteditable="true"]'
    ) || document.querySelector('#prompt-textarea')
      || document.querySelector('[contenteditable="true"]');
    // Quick Chat is rendered above the existing Work page. The Work composer
    // remains mounted behind the overlay and must not disqualify the active
    // Quick Chat surface.
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
    const workComposer = !quickChatRoot
      && !!document.querySelector('[data-codex-composer="true"]');
    const chatModel = [...document.querySelectorAll('button')].some(button => {
      const label = button.getAttribute('aria-label') || '';
      return label.includes('ChatGPT 模型') || /select chatgpt model/i.test(label);
    });
    const webChat = window.location.protocol === 'https:'
      && window.location.hostname === 'chatgpt.com';
    const chatMode = (
      !!quickChatRoot
        || !!document.querySelector('#prompt-textarea')
        || chatModel
        || currentChatGPTMode
        || webChat
        || window.location.protocol === 'chatgpt:'
    )
      && !!textarea && !workComposer;
    return {
      bridge: !!window.electronBridge,
      visibility: document.visibilityState,
      href: location.href,
      eventLoopDelayMs: performance.now() - startedAt,
      chatMode,
      surface: chatMode ? 'chat' : 'not-chat'
    };
  })()
  """
  let initial = cdpValue(
    port: port,
    targetId: targetId,
    expression: expression,
    timeout: 3.0
  )
  if initial?["visibility"] as? String == "visible",
     !dedicatedProcessIsHiddenForPort(port) {
    return .visible
  }
  if refreshLifecycle {
    _ = wakeHiddenRenderer(port: port, targetId: targetId, wsURL: wsURL)
  }
  let probe = refreshLifecycle
    ? cdpValue(port: port, targetId: targetId, expression: expression, timeout: 3.0)
    : initial
  if probe?["visibility"] as? String == "visible",
     !dedicatedProcessIsHiddenForPort(port) {
    return .visible
  }
  let bridge = (probe?["bridge"] as? NSNumber)?.boolValue ?? false
  let visibility = probe?["visibility"] as? String
  let href = probe?["href"] as? String ?? ""
  let eventLoopDelayMs = (probe?["eventLoopDelayMs"] as? NSNumber)?.doubleValue
    ?? Double.greatestFiniteMagnitude
  let rendererOwnedByHiddenProcess = visibility == "hidden"
    || dedicatedProcessIsHiddenForPort(port)
  if bridge && rendererOwnedByHiddenProcess
      && href.hasPrefix("app://-/index.html")
      && eventLoopDelayMs < 2_500 {
    let chatMode = (probe?["chatMode"] as? NSNumber)?.boolValue ?? false
    let surface = probe?["surface"] as? String ?? "not-chat"
    return chatMode && surface == "chat" ? .hidden : .hiddenNonChat
  }
  return .suspended
}

func queueTargetRuntimeStateName(_ state: QueueTargetRuntimeState) -> String {
  switch state {
  case .missing: return "missing"
  case .hidden: return "hidden-chat"
  case .hiddenNonChat: return "hidden-not-chat"
  case .visible: return "visible"
  case .suspended: return "suspended"
  }
}

func queueTargetIsHidden(port: Int, targetId: String) -> Bool {
  queueTargetRuntimeState(
    port: port,
    targetId: targetId,
    refreshLifecycle: false
  ) == .hidden
}

func queueTargetIsReady(port: Int, targetId: String) -> Bool {
  switch queueTargetRuntimeState(port: port, targetId: targetId, refreshLifecycle: true) {
  case .hidden, .visible:
    return true
  case .missing, .hiddenNonChat, .suspended:
    return false
  }
}

func generalApprovalStateForQueue() -> PluginState? {
  let url = queueStateURL().deletingLastPathComponent().appendingPathComponent("state.json")
  guard let data = try? Data(contentsOf: url) else { return nil }
  return try? decoder.decode(PluginState.self, from: data)
}

func sharedChatController(
  _ state: inout PluginState
) -> (port: Int, targetId: String, profilePath: String)? {
  let general = generalApprovalStateForQueue()
  let port = configuredHiddenChatPort()
    ?? general?.backgroundAppPort
    ?? state.backgroundAppPort
    ?? hiddenChatPort(state)
  let profilePath = configuredHiddenChatProfilePath()
    ?? general?.backgroundProfilePath
    ?? state.backgroundProfilePath
    ?? hiddenChatProfilePath()
  let preferredTargetIds = [
    general?.backgroundChatTargetId,
    state.backgroundChatTargetId,
  ].compactMap { $0 }
  let queueOwnedTargetIds = Set(
    (state.automationTasks ?? []).compactMap(\.workerTargetId)
      + [state.queueWorkerTargetId].compactMap { $0 }
  )
  let mayReuseSerialSharedController =
    state.queueWorkerMode == sharedConversationQueueWorkerMode
      && !(state.automationTasks ?? []).contains(where: { $0.status == "running" })
  let discoveryStartedAt = Date()
  let discoveryDeadline = discoveryStartedAt.addingTimeInterval(30.0)
  var discoveryProbeAttempts = 0
  var lastDiscoveryTargetCount = 0
  queueTrace("worker-create stage=controller-discovery begin port=\(port) timeout=30s")
  // Hosted macOS runners invoke the queue only a few seconds after launching
  // ChatGPT. Bound discovery by wall-clock time rather than a loop count:
  // every CDP probe can itself block until its timeout, so 120 nominal 250 ms
  // iterations previously held the queue-state lock for several minutes when
  // the primary renderer was suspended.
  while Date() < discoveryDeadline {
    let targets = CDPClient.fetchTargets(portOverride: port)
    lastDiscoveryTargetCount = targets.count
    let orderedTargets = targets.sorted { lhs, rhs in
      let lhsId = lhs["id"] as? String ?? ""
      let rhsId = rhs["id"] as? String ?? ""
      return (preferredTargetIds.firstIndex(of: lhsId) ?? Int.max)
        < (preferredTargetIds.firstIndex(of: rhsId) ?? Int.max)
    }
    for target in orderedTargets {
      guard Date() < discoveryDeadline else { break }
      guard target["type"] as? String == "page",
            (target["url"] as? String ?? "").hasPrefix("app://-/index.html"),
            let targetId = target["id"] as? String,
            !queueOwnedTargetIds.contains(targetId)
              || (mayReuseSerialSharedController
                && targetId == state.queueWorkerTargetId) else { continue }
      discoveryProbeAttempts += 1
      let remaining = discoveryDeadline.timeIntervalSinceNow
      guard remaining > 0 else { break }
      let probe = cdpValue(
        port: port,
        targetId: targetId,
        expression: """
        (() => ({
          bridge: !!window.electronBridge,
          ready: document.readyState,
          textLength: (document.body?.innerText || '').trim().length,
          hasInput: !!document.querySelector(
            'textarea, [contenteditable="true"], [role="textbox"]'
          ),
          entryScripts: [...document.scripts].filter(script =>
            /\\/assets\\/index-[^/]+\\.js$/.test(script.src || '')
          ).length
        }))()
        """,
        timeout: min(1.0, max(0.2, remaining))
      )
      let bridge = (probe?["bridge"] as? NSNumber)?.boolValue ?? false
      let ready = probe?["ready"] as? String
      let textLength = (probe?["textLength"] as? NSNumber)?.intValue ?? 0
      let hasInput = (probe?["hasInput"] as? NSNumber)?.boolValue ?? false
      let entryScripts = (probe?["entryScripts"] as? NSNumber)?.intValue ?? 0
      guard bridge, ready == "complete", entryScripts > 0,
            textLength > 100, hasInput else { continue }
      state.backgroundAppPort = port
      state.backgroundChatTargetId = targetId
      state.backgroundProfilePath = profilePath
      let elapsedMs = Int(Date().timeIntervalSince(discoveryStartedAt) * 1_000)
      queueTrace(
        "worker-create stage=controller-discovery complete target=\(targetId) "
          + "elapsedMs=\(elapsedMs) probes=\(discoveryProbeAttempts)"
      )
      return (port, targetId, profilePath)
    }
    let remaining = discoveryDeadline.timeIntervalSinceNow
    if remaining > 0 {
      Thread.sleep(forTimeInterval: min(0.25, remaining))
    }
  }
  let discoveryElapsedMs = Int(Date().timeIntervalSince(discoveryStartedAt) * 1_000)
  queueTrace(
    "worker-create stage=controller-discovery timeout port=\(port) "
      + "elapsedMs=\(discoveryElapsedMs) probes=\(discoveryProbeAttempts) "
      + "targets=\(lastDiscoveryTargetCount)"
  )
  guard let prepared = ensureHiddenChatTarget(&state),
        prepared["ok"] as? Bool == true,
        let port = prepared["port"] as? Int,
        let targetId = prepared["targetId"] as? String else { return nil }
  queueTrace("worker-create stage=controller-fallback complete target=\(targetId)")
  return (
    port,
    targetId,
    prepared["profilePath"] as? String
      ?? configuredHiddenChatProfilePath()
      ?? hiddenChatProfilePath()
  )
}

func quickChatPrewarmServiceJS(_ action: String) -> String {
  let actionLiteral = jsonStringLiteral(action)
  return #"""
  (async () => {
    try {
      const action = \#(actionLiteral);
      const entryURL = [...document.scripts]
        .map(script => script.src)
        .find(src => src && /\/assets\/index-[^/]+\.js$/.test(src));
      if (!entryURL) return {ok: false, error: 'app_entry_module_not_found'};
      const entrySource = await (await fetch(entryURL)).text();
      // Desktop bundles changed from the long shared-chunk name to compact
      // `app-initial-<hash>.js` names in July 2026. Discover every matching
      // app-initial module instead of coupling queue startup to one generated
      // filename. Keep the legacy pattern as a fallback for older releases.
      const serviceModulePaths = [...new Set([
        ...[...entrySource.matchAll(
          /["'](\.\/app-initial-[^"']+\.js)["']/g
        )].map(match => match[1]),
        ...[...entrySource.matchAll(
          /["'](\.\/app-initial~[^"']+\.js)["']/g
        )].map(match => match[1]),
      ])];
      if (serviceModulePaths.length === 0) {
        return {ok: false, error: 'quick_chat_service_module_not_found'};
      }
      let services = null;
      let moduleURL = null;
      for (const serviceModulePath of serviceModulePaths) {
        const candidateURL = new URL(serviceModulePath, entryURL).href;
        const serviceModule = await import(candidateURL);
        const candidate = Object.values(serviceModule).find(value => {
          try {
            return value != null
              && typeof value === 'object'
              && typeof value.quickChatWindow?.prewarm === 'function'
              && String(value.quickChatWindow) === '[object RpcStub]';
          } catch {
            return false;
          }
        });
        if (candidate) {
          services = candidate;
          moduleURL = candidateURL;
          break;
        }
      }
      if (!services) {
        return {
          ok: false,
          error: 'quick_chat_service_not_found',
          modulePaths: serviceModulePaths
        };
      }
      if (action === 'reset-prewarm') {
        await services.quickChatWindow.clearPrewarm();
        await services.quickChatWindow.prewarm();
      } else if (action === 'renderer-ready') {
        await services.quickChatWindow.rendererReady(null);
      } else if (action === 'clear-prewarm') {
        await services.quickChatWindow.clearPrewarm();
      } else {
        return {ok: false, error: 'unsupported_quick_chat_action'};
      }
      return {
        ok: true,
        action,
        moduleURL,
        href: location.href,
        visibility: document.visibilityState
      };
    } catch (error) {
      return {
        ok: false,
        error: String(error),
        stack: error?.stack || ''
      };
    }
  })()
  """#
}

func continueHiddenOnboardingJS() -> String {
  #"""
  (() => {
    const normalize = value => (value || '').replace(/\s+/g, ' ').trim().toLowerCase();
    const preferred = [
      'continue', '继续', 'next', '下一步', 'done', '完成',
      'go to chatgpt', '前往 chatgpt', '进入 chatgpt',
      'skip', '跳过'
    ];
    const nodes = [...document.querySelectorAll('button, a, [role="button"]')];
    const labelsFor = node => [
        node.innerText,
        node.textContent,
        node.getAttribute('aria-label'),
        node.getAttribute('title')
      ].map(normalize).filter(Boolean);
    const button = preferred
      .map(label => nodes.find(node => labelsFor(node).includes(label)))
      .find(Boolean);
    if (!button) return {ok: true, clicked: false};
    const label = normalize(
      button.innerText || button.getAttribute('aria-label') || button.getAttribute('title')
    );
    button.click();
    return {ok: true, clicked: true, label};
  })()
  """#
}

func wakeHiddenQueueRenderer(
  port: Int,
  targetId: String,
  wsURL: String,
  timeout: TimeInterval = 12.0
) -> Bool {
  let startedAt = Date()
  let deadline = startedAt.addingTimeInterval(timeout)
  var attempt = 0
  repeat {
    attempt += 1
    queueTrace(
      "worker-create stage=prewarm-renderer-wake attempt=\(attempt) target=\(targetId)"
    )
    if wakeHiddenRenderer(port: port, targetId: targetId, wsURL: wsURL) {
      let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1_000)
      queueTrace(
        "worker-create stage=prewarm-renderer-wake complete target=\(targetId) "
          + "attempts=\(attempt) elapsedMs=\(elapsedMs)"
      )
      return true
    }
    let targetStillExists = CDPClient.fetchTargets(portOverride: port).contains {
      $0["id"] as? String == targetId
    }
    guard targetStillExists else {
      queueTrace(
        "worker-create stage=prewarm-renderer-wake target-missing "
          + "target=\(targetId) attempts=\(attempt)"
      )
      return false
    }
    let remaining = deadline.timeIntervalSinceNow
    if remaining > 0 {
      Thread.sleep(forTimeInterval: min(0.5, remaining))
    }
  } while Date() < deadline
  let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1_000)
  queueTrace(
    "worker-create stage=prewarm-renderer-wake timeout target=\(targetId) "
      + "attempts=\(attempt) elapsedMs=\(elapsedMs)"
  )
  return false
}

func openBackgroundQueueWindow(
  port: Int,
  controllerTargetId: String,
  failure: inout String?
) -> String? {
  queueTrace("worker-create stage=prewarm-open begin controller=\(controllerTargetId)")
  let existingTargetIds = Set(CDPClient.fetchTargets(portOverride: port).compactMap {
    $0["id"] as? String
  })
  guard existingTargetIds.contains(controllerTargetId) else {
    failure = "prewarm_controller_target_missing"
    return nil
  }
  let reset = cdpValue(
    port: port,
    targetId: controllerTargetId,
    expression: quickChatPrewarmServiceJS("reset-prewarm"),
    timeout: 8.0
  )
  guard reset?["ok"] as? Bool == true else {
    failure = "desktop_prewarm_reset_failed:\(reset?["error"] as? String ?? "no_result")"
    return nil
  }
  queueTrace("worker-create stage=prewarm-reset complete")

  var targetId: String?
  for _ in 0..<100 {
    targetId = CDPClient.fetchTargets(portOverride: port).compactMap { target -> String? in
      guard let id = target["id"] as? String,
            !existingTargetIds.contains(id),
            target["type"] as? String == "page",
            (target["url"] as? String ?? "").contains("quick-chat-prewarm") else { return nil }
      return id
    }.first
    if targetId != nil { break }
    Thread.sleep(forTimeInterval: 0.05)
  }
  guard let targetId else {
    failure = "prewarm_target_not_created"
    return nil
  }
  queueTrace("worker-create stage=prewarm-target complete target=\(targetId)")

  // ChatGPT's prewarm controller closes a renderer that has not reported
  // readiness within 15 seconds. A hidden prewarm route does not always mount
  // its normal React page, so acknowledge it explicitly through that
  // renderer's own app-host service before navigating it to the full app.
  var prewarmLoaded = false
  var acknowledged = false
  for _ in 0..<100 {
    let prewarmReady = cdpValue(
      port: port,
      targetId: targetId,
      expression: "(() => ({bridge: !!window.electronBridge, ready: document.readyState, visibility: document.visibilityState, href: location.href}))()",
      timeout: 3.0
    )
    if (prewarmReady?["bridge"] as? NSNumber)?.boolValue == true,
       prewarmReady?["ready"] as? String == "complete",
       prewarmReady?["visibility"] as? String == "hidden",
       (prewarmReady?["href"] as? String ?? "").contains("quick-chat-prewarm") {
      prewarmLoaded = true
      break
    }
    Thread.sleep(forTimeInterval: 0.05)
  }
  guard prewarmLoaded else {
    failure = "prewarm_renderer_not_loaded"
    _ = CDPClient.closeTarget(targetId, portOverride: port)
    return nil
  }
  queueTrace("worker-create stage=prewarm-renderer-loaded")
  // In current desktop builds the prewarm renderer can report document
  // readiness before its RPC client is fully registered with the main
  // process. The measured stable handoff needs roughly 1.8 seconds.
  Thread.sleep(forTimeInterval: 1.8)
  for _ in 0..<100 {
    let result = cdpValue(
      port: port,
      targetId: targetId,
      expression: quickChatPrewarmServiceJS("renderer-ready"),
      timeout: 8.0
    )
    if result?["ok"] as? Bool == true,
       result?["visibility"] as? String == "hidden" {
      acknowledged = true
      break
    }
    Thread.sleep(forTimeInterval: 0.05)
  }
  guard acknowledged else {
    failure = "prewarm_renderer_ready_not_acknowledged"
    _ = CDPClient.closeTarget(targetId, portOverride: port)
    return nil
  }
  queueTrace("worker-create stage=prewarm-renderer-acknowledged")
  // Let the main process consume rendererReady before replacing the prewarm
  // route. Navigating immediately can leave the quick-chat shell unclaimed.
  Thread.sleep(forTimeInterval: 1.0)
  // Quick Chat itself is feature-gated per account. The official prewarm
  // service is still the supported way to obtain a show:false BrowserWindow,
  // but hosted accounts without that gate must mount the normal authenticated
  // app root in the same hidden window before selecting Chat.
  let hiddenAppURL = "app://-/index.html?initialRoute=%2F"
  guard
        let target = CDPClient.fetchTargets(portOverride: port).first(where: {
          $0["id"] as? String == targetId
        }),
        let wsURL = target["webSocketDebuggerUrl"] as? String,
        CDPClient.navigate(
          wsURLString: wsURL,
          url: hiddenAppURL
        ) else {
    failure = "prewarm_navigation_failed"
    _ = CDPClient.closeTarget(targetId, portOverride: port)
    return nil
  }
  queueTrace("worker-create stage=prewarm-navigation complete target=\(targetId)")
  // Electron deprioritizes show:false pages so aggressively that the Chat
  // surface may need over a minute to mount. Keep the actual BrowserWindow
  // hidden while asking Chromium to run this renderer at active lifecycle
  // priority. document.visibilityState remains hidden and is rechecked below.
  Thread.sleep(forTimeInterval: 0.5)
  guard wakeHiddenQueueRenderer(
    port: port,
    targetId: targetId,
    wsURL: wsURL
  ) else {
    failure = "prewarm_renderer_wake_failed"
    _ = CDPClient.closeTarget(targetId, portOverride: port)
    return nil
  }
  queueTrace("worker-create stage=prewarm-renderer-awake")

  // A show:false renderer is intentionally deprioritized by Electron. On
  // current ChatGPT builds the full Chat surface can take more than 30 seconds
  // to mount even though its document and preload bridge are already ready.
  var lastReady: [String: Any]?
  var transientErrorRetryCount = 0
  for _ in 0..<600 {
    let ready = cdpValue(
      port: port,
      targetId: targetId,
      expression: """
      (() => {
        const redact = value => (value || '')
          .replace(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}/gi, '[email]')
          .replace(/[0-9a-f]{8}-[0-9a-f-]{27,}/gi, '[id]')
          .replace(/\\s+/g, ' ')
          .trim();
        const buttonLabels = [...document.querySelectorAll('button, a, [role="button"]')]
          .flatMap(node => [
            node.innerText,
            node.getAttribute('aria-label'),
            node.getAttribute('title')
          ])
          .map(redact)
          .filter(Boolean)
          .slice(0, 12);
        return {
          bridge: !!window.electronBridge,
          ready: document.readyState,
          scripts: document.scripts.length,
          buttons: document.querySelectorAll('button').length,
          buttonLabels,
          inputs: document.querySelectorAll('textarea, [contenteditable="true"]').length,
          text: (document.body?.innerText || '').length,
          safeText: redact(document.body?.innerText).slice(0, 800),
          html: (document.body?.innerHTML || '').length,
          visibility: document.visibilityState,
          href: location.href
        };
      })()
      """,
      timeout: 3.0
    )
    lastReady = ready
    let bridge = (ready?["bridge"] as? NSNumber)?.boolValue ?? false
    let buttons = (ready?["buttons"] as? NSNumber)?.intValue ?? 0
    let textLength = (ready?["text"] as? NSNumber)?.intValue ?? 0
    let visibility = ready?["visibility"] as? String
    let href = ready?["href"] as? String
    if bridge,
       buttons >= 1,
       textLength > 100,
       visibility == "hidden",
       href?.hasPrefix("app://-/index.html") == true,
       href?.contains("initialRoute=%2F") == true {
      queueTrace("worker-create stage=hidden-shell-ready target=\(targetId)")
      return targetId
    }
    let buttonLabels = ready?["buttonLabels"] as? [String] ?? []
    let safeText = (ready?["safeText"] as? String ?? "").lowercased()
    let hasTransientError = buttonLabels.contains { label in
      let normalized = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      return normalized == "try again" || normalized == "重试" || normalized == "再试一次"
    } && (safeText.contains("oops") || safeText.contains("error") || safeText.contains("出错"))
    if hasTransientError {
      if transientErrorRetryCount < 3 {
        let retry = cdpValue(
          port: port,
          targetId: targetId,
          expression: """
          (() => {
            const normalize = value => (value || '').replace(/\\s+/g, ' ').trim().toLowerCase();
            const allowed = new Set(['try again', '重试', '再试一次']);
            const labelFor = node => normalize(
              node.getAttribute('aria-label') || node.innerText || node.textContent
                || node.getAttribute('title')
            );
            const button = [...document.querySelectorAll('button, [role="button"]')]
              .find(node => allowed.has(labelFor(node))
                && !node.disabled
                && node.getAttribute('aria-disabled') !== 'true');
            if (!button) return { found: false };
            const label = labelFor(button);
            const rect = button.getBoundingClientRect();
            return {
              found: true,
              label,
              x: rect.left + rect.width / 2,
              y: rect.top + rect.height / 2
            };
          })()
          """,
          timeout: 4.0
        )
        let retryClicked: Bool
        if retry?["found"] as? Bool == true,
           let x = (retry?["x"] as? NSNumber)?.doubleValue,
           let y = (retry?["y"] as? NSNumber)?.doubleValue {
          retryClicked = CDPClient.clickTarget(
            targetId,
            x: x,
            y: y,
            portOverride: port
          )
        } else {
          retryClicked = false
        }
        if retryClicked {
          transientErrorRetryCount += 1
          queueTrace(
            "worker-create stage=prewarm-transient-error-retry "
              + "attempt=\(transientErrorRetryCount) label=\(retry?["label"] as? String ?? "unknown")"
          )
          Thread.sleep(forTimeInterval: 2.0)
          continue
        }
      }
      failure = "prewarm_transient_error_persistent"
      queueTrace(
        "worker-create stage=prewarm-transient-error-failed "
          + "attempts=\(transientErrorRetryCount)"
      )
      _ = CDPClient.closeTarget(targetId, portOverride: port)
      return nil
    }
    Thread.sleep(forTimeInterval: 0.1)
  }
  failure = [
    "prewarm_hidden_chat_surface_timeout",
    "bridge=\((lastReady?["bridge"] as? NSNumber)?.boolValue ?? false)",
    "ready=\(lastReady?["ready"] as? String ?? "none")",
    "scripts=\((lastReady?["scripts"] as? NSNumber)?.intValue ?? -1)",
    "buttons=\((lastReady?["buttons"] as? NSNumber)?.intValue ?? -1)",
    "inputs=\((lastReady?["inputs"] as? NSNumber)?.intValue ?? -1)",
    "text=\((lastReady?["text"] as? NSNumber)?.intValue ?? -1)",
    "html=\((lastReady?["html"] as? NSNumber)?.intValue ?? -1)",
    "visibility=\(lastReady?["visibility"] as? String ?? "none")",
    "routeMatches=\((lastReady?["href"] as? String ?? "").contains("initialRoute=%2F"))",
    "labels=\((lastReady?["buttonLabels"] as? [String] ?? []).joined(separator: "|"))",
    "safeText=\(lastReady?["safeText"] as? String ?? "none")",
  ].joined(separator: ":")
  _ = CDPClient.closeTarget(targetId, portOverride: port)
  return nil
}

// The quick-chat prewarm RPC owns one show:false BrowserWindow and clears the
// previous prewarm whenever it creates the next one. That contract is correct
// for the legacy single hidden worker, but it cannot back two overlapping
// Actions tasks. Headless runners can ask Chromium/Electron for independent
// normal BrowserWindows directly; the authenticated app process and preload
// bridge are shared, while each target remains queue-owned and isolated.
func openHeadlessParallelQueueWindow(
  port: Int,
  controllerTargetId: String,
  failure: inout String?
) -> String? {
  let appRootURL = "app://-/index.html?initialRoute=%2F"
  guard CDPClient.fetchTargets(portOverride: port).contains(where: {
    $0["id"] as? String == controllerTargetId
  }) else {
    failure = "headless_window_controller_target_missing"
    return nil
  }
  // Electron may expose a default browser context without the ChatGPT
  // partition/preload bridge. Reuse the authenticated controller's context
  // when it is available; CDPClient still falls back to the default context
  // for older desktop builds that reject the reported id.
  let browserContextId = CDPClient.targetInfo(
    targetId: controllerTargetId,
    portOverride: port
  )?["browserContextId"] as? String
  queueTrace(
    "worker-create stage=headless-window-context "
      + "present=\(browserContextId?.isEmpty == false)"
  )
  // Target.createTarget is a browser-level operation. On some ChatGPT
  // desktop builds it creates a normal Chromium page even when the
  // authenticated browserContextId is supplied; that page has no Electron
  // preload bridge and can never become a usable Chat surface. Ask the
  // authenticated app renderer to open a real BrowserWindow first. Electron
  // inherits the opener's session and preload when it handles window.open,
  // which keeps the window signed in and preserves electronBridge.
  let existingTargetIds = Set(
    CDPClient.fetchTargets(portOverride: port).compactMap { $0["id"] as? String }
  )
  var targetId: String?
  let openerTargets = CDPClient.fetchTargets(portOverride: port)
    .filter { target in
      (target["type"] as? String) == "page"
        && (target["url"] as? String ?? "").hasPrefix("app://-/index.html")
        && target["webSocketDebuggerUrl"] as? String != nil
    }
    .sorted { lhs, rhs in
      let lhsIsController = lhs["id"] as? String == controllerTargetId
      let rhsIsController = rhs["id"] as? String == controllerTargetId
      if lhsIsController != rhsIsController { return lhsIsController }
      return (lhs["id"] as? String ?? "") < (rhs["id"] as? String ?? "")
    }
  for opener in openerTargets {
    guard targetId == nil,
          let openerId = opener["id"] as? String else { break }
    let windowName = "fabushi-queue-\(UUID().uuidString)"
    let openerProbe = cdpValue(
      port: port,
      targetId: openerId,
      expression: """
      (() => ({
        bridge: !!window.electronBridge,
        visibility: document.visibilityState,
        ready: document.readyState,
        href: location.href
      }))()
      """,
      timeout: 3.0
    )
    let windowOpen = cdpValue(
      port: port,
      targetId: openerId,
      expression: """
      (() => {
        try {
          const popup = window.open(\(jsonStringLiteral(appRootURL)),
            \(jsonStringLiteral(windowName)),
            'width=1280,height=900,resizable=yes');
          return {opened: !!popup};
        } catch (error) {
          return {opened: false, error: String(error)};
        }
      })()
      """,
      timeout: 5.0
    )
    let opened = windowOpen?["opened"] as? Bool ?? false
    queueTrace(
      "worker-create stage=headless-window-open "
        + "opener=\(openerId) "
        + "visibility=\(openerProbe?["visibility"] as? String ?? "none") "
        + "bridge=\((openerProbe?["bridge"] as? NSNumber)?.boolValue ?? false) "
        + "requested=true opened=\(opened) "
        + "error=\(windowOpen?["error"] as? String ?? "none")"
    )
    guard opened else { continue }
    let discoveryDeadline = Date().addingTimeInterval(8.0)
    while Date() < discoveryDeadline, targetId == nil {
      let candidates = CDPClient.fetchTargets(portOverride: port).filter { target in
        guard let candidateId = target["id"] as? String,
              !existingTargetIds.contains(candidateId),
              target["type"] as? String == "page",
              target["webSocketDebuggerUrl"] as? String != nil else { return false }
        return true
      }
      if let candidate = candidates.first,
         let candidateId = candidate["id"] as? String {
        targetId = candidateId
        queueTrace(
          "worker-create stage=headless-window-open-target "
            + "opener=\(openerId) target=\(candidateId) "
            + "url=\(candidate["url"] as? String ?? "none")"
        )
        break
      }
      Thread.sleep(forTimeInterval: 0.25)
    }
  }
  if targetId == nil {
    targetId = CDPClient.createTarget(
      url: appRootURL,
      browserContextId: browserContextId,
      background: false,
      portOverride: port
    )
    guard targetId != nil else {
      failure = "headless_window_target_create_failed"
      return nil
    }
    queueTrace(
      "worker-create stage=headless-window-target-created "
        + "port=\(port) target=\(targetId!)"
    )
  }
  guard let targetId else {
    failure = "headless_window_target_missing_after_create"
    return nil
  }

  var lastProbe: [String: Any]?
  var navigated = false
  let deadline = Date().addingTimeInterval(30.0)
  while Date() < deadline {
    guard let target = CDPClient.fetchTargets(portOverride: port).first(where: {
      $0["id"] as? String == targetId
    }), let wsURL = target["webSocketDebuggerUrl"] as? String else {
      Thread.sleep(forTimeInterval: 0.25)
      continue
    }
    // Target.createTarget may expose a static shell first. Explicitly
    // navigate the new target and wake it as a real visible Electron window;
    // unlike quick-chat prewarm this does not retire another task's target.
    if !navigated {
      navigated = CDPClient.navigate(wsURLString: wsURL, url: appRootURL)
    }
    _ = CDPClient.activateTarget(targetId, portOverride: port)
    _ = CDPClient.bringPageToFront(wsURLString: wsURL)
    _ = CDPClient.setWebLifecycleActive(wsURLString: wsURL)
    _ = CDPClient.setHiddenPageFocusEmulation(wsURLString: wsURL)
    _ = CDPClient.setHiddenPageUserActive(wsURLString: wsURL)
    lastProbe = cdpValue(
      port: port,
      targetId: targetId,
      expression: """
      (() => ({
        bridge: !!window.electronBridge,
        ready: document.readyState,
        text: (document.body?.innerText || '').length,
        visibility: document.visibilityState,
        href: location.href
      }))()
      """,
      timeout: 3.0
    )
    let bridge = (lastProbe?["bridge"] as? NSNumber)?.boolValue ?? false
    let ready = lastProbe?["ready"] as? String
    let textLength = (lastProbe?["text"] as? NSNumber)?.intValue ?? 0
    if bridge, ready == "complete", textLength > 50 {
      queueTrace(
        "worker-create stage=headless-window-target-ready "
          + "port=\(port) target=\(targetId) "
          + "visibility=\(lastProbe?["visibility"] as? String ?? "none")"
      )
      return targetId
    }
    Thread.sleep(forTimeInterval: 0.25)
  }
  failure = [
    "headless_window_target_not_ready",
    "bridge=\((lastProbe?["bridge"] as? NSNumber)?.boolValue ?? false)",
    "ready=\(lastProbe?["ready"] as? String ?? "none")",
    "text=\((lastProbe?["text"] as? NSNumber)?.intValue ?? -1)",
  ].joined(separator: ":")
  _ = CDPClient.closeTarget(targetId, portOverride: port)
  return nil
}

func selectChatOnPrimaryController(
  port: Int,
  targetId: String
) -> [String: Any]? {
  var selection: [String: Any]?
  let forced = cdpValue(
    port: port,
    targetId: targetId,
    expression: forcePrimaryChatModeJS(),
    timeout: 5.0
  )
  queueTrace(
    "worker-create stage=primary-chat-selection force-persisted-mode "
      + "ok=\(forced?["ok"] as? Bool ?? false) "
      + "error=\(forced?["error"] as? String ?? "none")"
  )
  Thread.sleep(forTimeInterval: 1.2)
  _ = resetStaleChatModeIfNeeded(
    port: port,
    targetId: targetId,
    stage: "primary-chat-selection"
  )
  for _ in 0..<20 {
    selection = cdpValue(
      port: port,
      targetId: targetId,
      expression: clickChatJS(),
      timeout: 4.0
    )
    if selection?["nativeClickRecommended"] as? Bool == true,
       let x = (selection?["x"] as? NSNumber)?.doubleValue,
       let y = (selection?["y"] as? NSNumber)?.doubleValue {
      _ = CDPClient.clickTarget(targetId, x: x, y: y, portOverride: port)
    }
    if selection?["alreadySelected"] as? Bool == true { return selection }
    if selection?["retryAfterModeSwitch"] as? Bool == true {
      Thread.sleep(forTimeInterval: 0.8)
      continue
    }
    if selection?["dispatchOnly"] as? Bool == true {
      // The primary Chat/Work control is a React text toggle. Its click can
      // replace the renderer after Runtime.evaluate returns, so re-probe the
      // same target instead of trusting the dispatch result.
      Thread.sleep(forTimeInterval: 0.8)
      continue
    }
    Thread.sleep(forTimeInterval: 0.35)
  }
  return selection
}

@discardableResult
func resetStaleChatModeIfNeeded(
  port: Int,
  targetId: String,
  stage: String
) -> [String: Any]? {
  let initial = cdpValue(
    port: port,
    targetId: targetId,
    expression: composerSurfaceStateJS(),
    timeout: 5.0
  )
  let initialHasInput = initial?["hasInput"] as? Bool == true
  let initialChatModel = initial?["chatModel"] as? Bool == true
  let initialQuickChat = initial?["quickChatRoot"] as? Bool == true
  let initialWorkComposer = initial?["workComposer"] as? Bool == true
  let initialChatReady = initialHasInput && !initialWorkComposer
    && (initialChatModel || initialQuickChat)
  guard !initialChatReady else { return initial }

  // The hosted shell can persist "chat" while the mounted page is still Work
  // or while no composer has mounted at all. Re-selecting ChatGPT is then a
  // no-op because the atom already has that value. Use the real Chat/Work
  // control to cross the state boundary through Work once, then return to
  // Chat and require a real Chat composer before creating the hidden window.
  queueTrace("worker-create stage=\(stage) reset-stale-mode begin")
  var codexSelection: [String: Any]?
  for _ in 0..<12 {
    codexSelection = cdpValue(
      port: port,
      targetId: targetId,
      expression: clickCodexModeJS(),
      timeout: 5.0
    )
    if codexSelection?["nativeClickRecommended"] as? Bool == true,
       let x = (codexSelection?["x"] as? NSNumber)?.doubleValue,
       let y = (codexSelection?["y"] as? NSNumber)?.doubleValue {
      _ = CDPClient.clickTarget(targetId, x: x, y: y, portOverride: port)
    }
    if codexSelection?["dispatchOnly"] as? Bool == true { break }
    if codexSelection?["retryAfterModeSwitch"] as? Bool == true {
      Thread.sleep(forTimeInterval: 0.6)
      continue
    }
    Thread.sleep(forTimeInterval: 0.35)
  }
  queueTrace(
    "worker-create stage=\(stage) reset-stale-mode codex "
      + "ok=\(codexSelection?["ok"] as? Bool ?? false) "
      + "selectedLabel=\(codexSelection?["selectedLabel"] as? String ?? "none") "
      + "error=\(codexSelection?["error"] as? String ?? "none")"
  )
  guard codexSelection?["dispatchOnly"] as? Bool == true else { return initial }
  Thread.sleep(forTimeInterval: 1.2)

  var chatSelection: [String: Any]?
  for _ in 0..<20 {
    chatSelection = cdpValue(
      port: port,
      targetId: targetId,
      expression: clickChatJS(),
      timeout: 5.0
    )
    if chatSelection?["nativeClickRecommended"] as? Bool == true,
       let x = (chatSelection?["x"] as? NSNumber)?.doubleValue,
       let y = (chatSelection?["y"] as? NSNumber)?.doubleValue {
      _ = CDPClient.clickTarget(targetId, x: x, y: y, portOverride: port)
    }
    if chatSelection?["alreadySelected"] as? Bool == true { break }
    if chatSelection?["retryAfterModeSwitch"] as? Bool == true
        || chatSelection?["dispatchOnly"] as? Bool == true {
      Thread.sleep(forTimeInterval: 0.8)
      continue
    }
    Thread.sleep(forTimeInterval: 0.35)
  }
  queueTrace(
    "worker-create stage=\(stage) reset-stale-mode chat "
      + "ok=\(chatSelection?["ok"] as? Bool ?? false) "
      + "alreadySelected=\(chatSelection?["alreadySelected"] as? Bool ?? false) "
      + "selectedLabel=\(chatSelection?["selectedLabel"] as? String ?? "none") "
      + "error=\(chatSelection?["error"] as? String ?? "none")"
  )
  return cdpValue(
    port: port,
    targetId: targetId,
    expression: composerSurfaceStateJS(),
    timeout: 5.0
  )
}

func dedicatedTaskWorkerProcessRecords() -> [(pid: pid_t, profilePath: String, port: Int)] {
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
    // Drain stdout before waiting.  `ps -axo ...` can exceed the pipe buffer on
    // a busy machine (renderer command lines are especially large); waiting
    // first would deadlock while the child is blocked writing the remainder.
    data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
  } catch {
    return []
  }
  guard let text = String(
    data: data,
    encoding: .utf8
  ) else { return [] }

  let executableMarker = "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"
  let workerMarker = "/task-queue/workers/"
  var records: [(pid: pid_t, profilePath: String, port: Int)] = []
  for lineSlice in text.split(separator: "\n") {
    let line = String(lineSlice)
    guard line.contains(executableMarker), line.contains(workerMarker) else { continue }
    let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
    guard let first = fields.first, let pid = pid_t(String(first)) else { continue }
    guard let profileRange = line.range(of: "--user-data-dir=") else { continue }
    let profileStart = profileRange.upperBound
    let profileTail = line[profileStart...]
    // `ps` prints the command line without preserving argv boundaries, and the
    // macOS Application Support path contains spaces.  Stop at the next long
    // option instead of the first whitespace so worker processes can be found
    // and terminated before a bootstrap retry.
    let profilePath: String
    if let nextArgument = profileTail.range(of: " --") {
      profilePath = String(profileTail[..<nextArgument.lowerBound])
    } else {
      profilePath = String(profileTail)
    }
    guard profilePath.contains(workerMarker) else { continue }
    guard let portRange = line.range(of: "--remote-debugging-port=") else { continue }
    let portStart = portRange.upperBound
    let portTail = line[portStart...]
    let portText = String(portTail.prefix { $0.isNumber })
    guard let port = Int(portText) else { continue }
    records.append((pid: pid, profilePath: profilePath, port: port))
  }
  return records
}

func dedicatedTaskWorkerHelperProcessIds(profilePath: String) -> [pid_t] {
  guard profilePath.contains("/task-queue/workers/") else { return [] }
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
  let crashpadMarker = "--database=\(profilePath)/Crashpad"
  return text.split(separator: "\n").compactMap { lineSlice in
    let line = String(lineSlice)
    guard line.contains("/Applications/ChatGPT.app/Contents/Frameworks/"),
          line.contains("/Helpers/browser_crashpad_handler"),
          line.contains(crashpadMarker) else { return nil }
    let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
    guard let first = fields.first, let pid = pid_t(String(first)) else { return nil }
    return pid
  }
}

func dedicatedQueueWorkerPort() -> Int? {
  let processReservedPorts = Set(dedicatedTaskWorkerProcessRecords().map(\.port))
  for port in 9330..<9380
    where !processReservedPorts.contains(port)
      && CDPClient.fetchTargets(portOverride: port).isEmpty {
    return port
  }
  return nil
}

func copyProfileForDedicatedQueueWorker(
  source: String,
  destination: String
) -> Bool {
  do {
    try FileManager.default.createDirectory(
      atPath: destination,
      withIntermediateDirectories: true
    )
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/rsync")
    process.arguments = [
      "-a",
      "--exclude=Singleton*",
      "--exclude=**/LOCK",
      "--exclude=**/LOCK.*",
      "--exclude=Lockfile",
      "--exclude=lockfile",
      "--exclude=DevToolsActivePort",
      source.hasSuffix("/") ? source : source + "/",
      destination.hasSuffix("/") ? destination : destination + "/",
    ]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus == 0
  } catch {
    return false
  }
}

func boundedDedicatedRendererTargets(
  port: Int,
  timeout: TimeInterval = 2.0
) -> [[String: Any]] {
  // CDPClient.fetchTargets owns the bounded URLSession request and cancels
  // the task when its 1.8s deadline expires. Do not dispatch another probe
  // onto a shared GCD worker here: a second Electron process can leave that
  // nested semaphore path waiting indefinitely while the queue scheduler is
  // still trying to bring up the renderer. Keeping one synchronous, already
  // bounded request per loop also prevents timed-out probes from piling up.
  _ = timeout
  return CDPClient.fetchTargets(portOverride: port)
}

func dedicatedRendererTargetExists(port: Int) -> Bool {
  boundedDedicatedRendererTargets(port: port).contains { target in
    guard target["type"] as? String == "page",
          target["webSocketDebuggerUrl"] as? String != nil else {
      return false
    }
    let url = target["url"] as? String ?? ""
    return url.hasPrefix("app://-/index.html")
  }
}

func boundedDedicatedRendererTargetExists(
  port: Int,
  timeout: TimeInterval = 2.0
) -> Bool {
  boundedDedicatedRendererTargets(port: port, timeout: timeout).contains { target in
    guard target["type"] as? String == "page",
          target["webSocketDebuggerUrl"] as? String != nil else {
      return false
    }
    let url = target["url"] as? String ?? ""
    return url.hasPrefix("app://-/index.html")
  }
}

func dedicatedRendererTargetSummary(port: Int) -> String {
  let summaries = boundedDedicatedRendererTargets(port: port).prefix(8).map { target in
    let type = target["type"] as? String ?? "unknown"
    let rawURL = target["url"] as? String ?? ""
    let safeURL: String
    if rawURL.hasPrefix("app://-/index.html") {
      safeURL = rawURL.contains("avatar-overlay")
        ? "app://-/index.html/avatar-overlay"
        : "app://-/index.html"
    } else if let scheme = URL(string: rawURL)?.scheme, !scheme.isEmpty {
      safeURL = "\(scheme)://"
    } else {
      safeURL = "(empty)"
    }
    return "\(type):\(safeURL)"
  }
  return summaries.isEmpty ? "none" : summaries.joined(separator: ",")
}

func waitForDedicatedRendererTarget(
  port: Int,
  timeout: TimeInterval = dedicatedRendererBootstrapTimeout
) -> Bool {
  let deadline = Date().addingTimeInterval(timeout)
  while Date() < deadline {
    if boundedDedicatedRendererTargetExists(
      port: port,
      timeout: min(2.0, max(0.2, timeout))
    ) {
      return true
    }
    Thread.sleep(forTimeInterval: 0.25)
  }
  return false
}

func launchDedicatedQueueChatProcessViaLaunchServices(
  profilePath: String,
  port: Int,
  codexHomePath: String? = nil
) -> Bool {
  // The hosted runner's direct Electron executable can expose an app root
  // target without loading ChatGPT's preload bridge. The workflow's proven
  // `open -na ... --args` path goes through LaunchServices and creates the
  // renderer with the normal application bootstrap instead.
  let configuration = NSWorkspace.OpenConfiguration()
  configuration.activates = true
  configuration.hides = false
  configuration.addsToRecentItems = false
  configuration.createsNewApplicationInstance = true
  configuration.arguments = [
    "--user-data-dir=\(profilePath)",
    "--remote-debugging-port=\(port)",
  ]
  if let codexHomePath {
    var environment = ProcessInfo.processInfo.environment
    environment["CODEX_HOME"] = codexHomePath
    configuration.environment = environment
  }
  let launchSemaphore = DispatchSemaphore(value: 0)
  var launchError: Error?
  NSWorkspace.shared.openApplication(
    at: URL(fileURLWithPath: "/Applications/ChatGPT.app"),
    configuration: configuration
  ) { _, error in
    launchError = error
    launchSemaphore.signal()
  }
  _ = launchSemaphore.wait(timeout: .now() + 10.0)
  guard launchError == nil else {
    queueTrace(
      "worker-create stage=dedicated-launchservices-first-error "
        + "port=\(port) error=\(String(describing: launchError))"
    )
    return false
  }
  queueTrace(
    "worker-create stage=dedicated-launchservices-first-start "
      + "port=\(port) visible=true"
  )
  return true
}

func launchDedicatedQueueChatProcess(
  profilePath: String,
  port: Int,
  codexHomePath: String? = nil
) -> Bool {
  do {
    if queueAllowsVisibleDedicatedRenderer() {
      return launchDedicatedQueueChatProcessViaLaunchServices(
        profilePath: profilePath,
        port: port,
        codexHomePath: codexHomePath
      )
    }
    let existingApplicationPids = Set(
      NSWorkspace.shared.runningApplications.compactMap { application -> pid_t? in
        guard let bundleIdentifier = application.bundleIdentifier,
              targetBundleIdentifiers.contains(bundleIdentifier) else { return nil }
        return application.processIdentifier
      }
    )
    func dedicatedProcessID() -> pid_t? {
      let process = Process()
      let output = Pipe()
      process.executableURL = URL(fileURLWithPath: "/bin/ps")
      process.arguments = ["-axo", "pid=,command="]
      process.standardInput = FileHandle.nullDevice
      process.standardOutput = output
      process.standardError = FileHandle.nullDevice
      do {
        try process.run()
        process.waitUntilExit()
      } catch {
        return nil
      }
      guard let text = String(
        data: output.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8
      ) else { return nil }
      let marker = "--user-data-dir=\(profilePath)"
      for line in text.split(separator: "\n") {
        guard line.contains(marker),
              line.contains("/Applications/ChatGPT.app/Contents/MacOS/ChatGPT") else {
          continue
        }
        let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        if let first = fields.first, let pid = pid_t(String(first)) {
          return pid
        }
      }
      return nil
    }
    func requestAccessibilityHide(processID: pid_t) -> Bool {
      let script = "tell application \"System Events\" to set visible of first process whose unix id is \(processID) to false"
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
      process.arguments = ["-e", script]
      process.standardInput = FileHandle.nullDevice
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
      } catch {
        return false
      }
    }
    func dedicatedRendererIsHidden() -> Bool {
      let targets = CDPClient.fetchTargets(portOverride: port)
      for target in targets {
        guard target["type"] as? String == "page",
              (target["url"] as? String ?? "").hasPrefix("app://-/index.html"),
              !(target["url"] as? String ?? "").contains("avatar-overlay"),
              let targetId = target["id"] as? String else { continue }
        let state = cdpValue(
          port: port,
          targetId: targetId,
          expression: "({visibility:document.visibilityState, hidden:document.hidden})",
          timeout: 2.0
        )
        if state?["visibility"] as? String == "hidden",
           (state?["hidden"] as? NSNumber)?.boolValue == true {
          return true
        }
      }
      return false
    }
    func hideNewDedicatedApplication(
      preferredProcessId: pid_t?,
      attempts: Int
    ) -> Bool {
      for iteration in 0..<attempts {
        if dedicatedRendererIsHidden() {
          queueTrace(
            "worker-create stage=dedicated-process-hidden-verified port=\(port)"
          )
          return true
        }
        let application = NSWorkspace.shared.runningApplications.first { candidate in
          guard !candidate.isTerminated else { return false }
          if candidate.processIdentifier == preferredProcessId { return true }
          guard let bundleIdentifier = candidate.bundleIdentifier else { return false }
          return targetBundleIdentifiers.contains(bundleIdentifier)
            && !existingApplicationPids.contains(candidate.processIdentifier)
        }
        if let application {
          let systemHidden = application.isHidden
          let hideRequested = application.hide()
          let accessibilityHide = iteration % 10 == 0
            && requestAccessibilityHide(processID: application.processIdentifier)
          if (systemHidden || accessibilityHide) && dedicatedRendererIsHidden() {
            queueTrace(
              "worker-create stage=dedicated-process-hide-requested "
                + "port=\(port) pid=\(application.processIdentifier)"
            )
            return true
          }
          _ = hideRequested
        } else if iteration % 10 == 0,
                  let processID = preferredProcessId ?? dedicatedProcessID(),
                  requestAccessibilityHide(processID: processID),
                  dedicatedRendererIsHidden() {
          queueTrace(
            "worker-create stage=dedicated-process-hidden-accessibility "
              + "port=\(port) pid=\(processID)"
          )
          return true
        }
        Thread.sleep(forTimeInterval: 0.05)
      }
      return false
    }
    let launcher = Process()
    // Launch the Electron executable directly. LaunchServices can coalesce
    // `open -n` requests into the visible controller process on hosted macOS,
    // which leaves the dedicated CDP port empty forever.
    launcher.executableURL = URL(
      fileURLWithPath: "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"
    )
    launcher.arguments = [
      "--user-data-dir=\(profilePath)",
      "--remote-debugging-port=\(port)",
    ]
    if let codexHomePath {
      var environment = ProcessInfo.processInfo.environment
      environment["CODEX_HOME"] = codexHomePath
      launcher.environment = environment
    }
    launcher.standardInput = FileHandle.nullDevice
    launcher.standardOutput = FileHandle.nullDevice
    launcher.standardError = FileHandle.nullDevice
    try launcher.run()
    dedicatedQueueChatLaunchers[port] = launcher
    // Do not wait for Electron to exit: it is the long-lived worker process.
    // Waiting here blocked the queue scheduler until the smoke action timed out.
    Thread.sleep(forTimeInterval: 0.25)
    if !launcher.isRunning && launcher.terminationStatus != 0 {
      dedicatedQueueChatLaunchers.removeValue(forKey: port)
      return false
    }
    let launchedProcessId = launcher.processIdentifier

    // Let the dedicated renderer finish its first visible bootstrap before
    // hiding the application. Hiding the Electron process immediately after
    // launch can suspend the avatar-overlay/empty-shell renderer on hosted
    // macOS, so it never mounts the authenticated Chat surface. The target
    // probe below hides the process only after a real app body is present.
    queueTrace(
      "worker-create stage=dedicated-process-launched "
        + "port=\(port) pid=\(launchedProcessId)"
    )
    // GitHub Actions has no user-facing window to hide and the first CDP
    // endpoint can remain unresponsive while Electron is still creating its
    // renderer. Defer the readiness probe to dedicatedQueueChatTarget(),
    // whose complete bootstrap loop is independently bounded. Keeping this
    // launcher call non-blocking prevents a second worker from holding the
    // queue scheduler forever after its process has already started.
    if queueAllowsVisibleDedicatedRenderer() {
      queueTrace(
        "worker-create stage=dedicated-headless-probe-deferred "
          + "port=\(port) pid=\(launchedProcessId)"
      )
      return true
    }
    if waitForDedicatedRendererTarget(port: port) {
      return true
    }
    queueTrace(
      "worker-create stage=dedicated-process-renderer-timeout "
        + "port=\(port) pid=\(launchedProcessId) "
        + "targets=\(dedicatedRendererTargetSummary(port: port))"
    )
    let killer = Process()
    killer.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    killer.arguments = ["-TERM", "-f", "--user-data-dir=\(profilePath)"]
    killer.standardInput = FileHandle.nullDevice
    killer.standardOutput = FileHandle.nullDevice
    killer.standardError = FileHandle.nullDevice
    try? killer.run()
    killer.waitUntilExit()
    dedicatedQueueChatLaunchers.removeValue(forKey: port)

    // On some hosted macOS images the direct Electron executable becomes a
    // short-lived launcher and never registers an NSRunningApplication. Use
    // LaunchServices only as a bounded fallback, retaining the isolated
    // profile and CDP port; subsequent code still requires a verified Chat page.
    queueTrace("worker-create stage=dedicated-process-launchservices-fallback begin port=\(port)")
    // Use LaunchServices' native configuration instead of `/usr/bin/open`.
    // The latter keeps the instance out of the foreground but does not
    // reliably mark the new Electron process hidden on recent macOS builds.
    // `hides` applies to the newly-created instance before its first window
    // is shown, so the renderer reaches the same hidden lifecycle used by
    // the background worker without flashing a second visible ChatGPT UI.
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    // The first renderer must be allowed to mount while visible. The queue
    // probe hides it after it has a real Chat body, avoiding App Nap/suspended
    // avatar overlays on hosted runners.
    configuration.hides = false
    configuration.addsToRecentItems = false
    configuration.createsNewApplicationInstance = true
    configuration.arguments = [
      "--user-data-dir=\(profilePath)",
      "--remote-debugging-port=\(port)",
    ]
    if let codexHomePath {
      var environment = ProcessInfo.processInfo.environment
      environment["CODEX_HOME"] = codexHomePath
      configuration.environment = environment
    }
    let launchSemaphore = DispatchSemaphore(value: 0)
    var launchError: Error?
    NSWorkspace.shared.openApplication(
      at: URL(fileURLWithPath: "/Applications/ChatGPT.app"),
      configuration: configuration
    ) { _, error in
      launchError = error
      launchSemaphore.signal()
    }
    _ = launchSemaphore.wait(timeout: .now() + 8.0)
    guard launchError == nil else {
      queueTrace(
        "worker-create stage=dedicated-process-launchservices-fallback-error "
          + "port=\(port) error=\(launchError!)"
      )
      return false
    }
    queueTrace(
      "worker-create stage=dedicated-process-launchservices-fallback complete "
        + "port=\(port) hidden=false"
    )
    if waitForDedicatedRendererTarget(port: port) {
      return true
    }
    queueTrace(
      "worker-create stage=dedicated-process-launchservices-renderer-timeout "
        + "port=\(port) targets=\(dedicatedRendererTargetSummary(port: port))"
    )
    return false
  } catch {
    return false
  }
}

func hideDedicatedProcessForPort(_ port: Int) -> Bool {
  guard let processID = dedicatedProcessIDForPort(port),
        let application = NSRunningApplication(processIdentifier: processID) else {
    return false
  }
  _ = application.hide()
  for _ in 0..<20 {
    if application.isHidden { return true }
    Thread.sleep(forTimeInterval: 0.05)
  }
  return application.isHidden
}

func dedicatedProcessIDForPort(_ port: Int) -> pid_t? {
  // Avoid piping the full process table and waiting before consuming it. On
  // busy hosts that pipe can fill and deadlock the watcher indefinitely.
  let process = Process()
  let output = Pipe()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
  process.arguments = ["-f", "--", "--remote-debugging-port=\(port)"]
  process.standardInput = FileHandle.nullDevice
  process.standardOutput = output
  process.standardError = FileHandle.nullDevice
  do {
    try process.run()
    process.waitUntilExit()
  } catch {
    return nil
  }
  guard let text = String(
    data: output.fileHandleForReading.readDataToEndOfFile(),
    encoding: .utf8
  ) else { return nil }
  func parentProcessID(_ processID: pid_t) -> pid_t? {
    let parentLookup = Process()
    let parentOutput = Pipe()
    parentLookup.executableURL = URL(fileURLWithPath: "/bin/ps")
    parentLookup.arguments = ["-p", String(processID), "-o", "ppid="]
    parentLookup.standardInput = FileHandle.nullDevice
    parentLookup.standardOutput = parentOutput
    parentLookup.standardError = FileHandle.nullDevice
    do {
      try parentLookup.run()
      parentLookup.waitUntilExit()
      let data = parentOutput.fileHandleForReading.readDataToEndOfFile()
      let value = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      return pid_t(value)
    } catch {
      return nil
    }
  }
  for line in text.split(separator: "\n") {
    guard let matchedProcessID = pid_t(
      line.trimmingCharacters(in: .whitespacesAndNewlines)
    ) else { continue }
    // Electron exposes the debugging-port flag reliably on renderer children,
    // but macOS pgrep may omit the app's main process even when `ps` shows the
    // same argument there. Resolve the renderer's parent and validate it as the
    // exact ChatGPT executable before using it as the dedicated GUI process.
    for processID in [matchedProcessID, parentProcessID(matchedProcessID)].compactMap({ $0 }) {
      guard let application = NSRunningApplication(processIdentifier: processID),
            application.executableURL?.path == "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT" else {
        continue
      }
      return processID
    }
  }
  return nil
}

func dedicatedProcessIsHiddenForPort(_ port: Int) -> Bool {
  guard let processID = dedicatedProcessIDForPort(port),
        let application = NSRunningApplication(processIdentifier: processID) else {
    return false
  }
  return application.isHidden
}

@discardableResult
func resumeDedicatedProcessForPort(_ port: Int) -> Bool {
  guard let processID = dedicatedProcessIDForPort(port) else { return false }
  return kill(processID, SIGCONT) == 0
}

@discardableResult
func unhideDedicatedProcessForPort(_ port: Int) -> Bool {
  // Directly launched Electron instances are not always discoverable through
  // `ps` with the original command line (the app can hand off to a helper
  // process before its renderer is ready).  Keep the launcher PID as the
  // primary identity and explicitly bring that application to the foreground
  // so Chromium can resume the root renderer and attach its preload bridge.
  if let launcher = dedicatedQueueChatLaunchers[port],
     let application = NSRunningApplication(processIdentifier: launcher.processIdentifier) {
    let unhidden = application.unhide()
    let activated = application.activate(options: [.activateIgnoringOtherApps])
    if unhidden || activated || !application.isHidden {
      return true
    }
  }
  let process = Process()
  let output = Pipe()
  process.executableURL = URL(fileURLWithPath: "/bin/ps")
  process.arguments = ["-axo", "pid=,command="]
  process.standardInput = FileHandle.nullDevice
  process.standardOutput = output
  process.standardError = FileHandle.nullDevice
  do {
    try process.run()
    process.waitUntilExit()
  } catch {
    return false
  }
  guard let text = String(
    data: output.fileHandleForReading.readDataToEndOfFile(),
    encoding: .utf8
  ) else { return false }
  let portMarker = "--remote-debugging-port=\(port)"
  for line in text.split(separator: "\n") {
    guard line.contains(portMarker),
          line.contains("/Applications/ChatGPT.app/Contents/MacOS/ChatGPT") else {
      continue
    }
    let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
    guard let first = fields.first, let processID = pid_t(String(first)),
          let application = NSRunningApplication(processIdentifier: processID) else {
      continue
    }
    let unhidden = application.unhide()
    let activated = application.activate(options: [.activateIgnoringOtherApps])
    return unhidden || activated || !application.isHidden
  }
  return false
}

func dedicatedQueueChatTarget(
  port: Int,
  timeout: TimeInterval = 90.0
) -> String? {
  let startedAt = Date()
  let deadline = startedAt.addingTimeInterval(timeout)
  var attempt = 0
  var blankNavigationCounts: [String: Int] = [:]
  var lastBlankNavigationAttempt: [String: Int] = [:]
  var interactiveNavigationCounts: [String: Int] = [:]
  var bootstrapRecoveryCounts: [String: Int] = [:]
  var lastProbeDiagnosticAttempt = -8
  var lastVisibleWakeAttempt = -8
  var lastProbe: [String: Any]?
  var nativePromptApprovalObserved = false
  var avatarOverlayRetired = false
  let appRootURL = "app://-/index.html?initialRoute=%2F"
  let allowVisibleRenderer = queueAllowsVisibleDedicatedRenderer()
  while Date() < deadline {
    if allowVisibleRenderer, attempt % 4 == 0,
       approveHeadlessChatGPTLocalNetworkPrompt() {
      nativePromptApprovalObserved = true
      queueTrace(
        "worker-create stage=dedicated-native-local-network-permission-allowed "
          + "port=\(port)"
      )
    }
    let targets = boundedDedicatedRendererTargets(port: port)
    for target in targets {
      guard target["type"] as? String == "page",
            let url = target["url"] as? String,
            url.hasPrefix("app://-/index.html"),
            let targetId = target["id"] as? String,
            let wsURL = target["webSocketDebuggerUrl"] as? String else { continue }
      let decodedURL = url.removingPercentEncoding ?? url
      if url.contains("/avatar-overlay") || decodedURL.contains("/avatar-overlay") {
        // A fresh ChatGPT process can expose only the blank avatar overlay
        // renderer first. Navigating replaces that document, so never reuse
        // this websocket for the verification probe; rediscover the current
        // renderer on the next pass just like the hosted restore script.
        if nativePromptApprovalObserved, !avatarOverlayRetired {
          avatarOverlayRetired = true
          let closed = CDPClient.closeTarget(targetId, portOverride: port)
          queueTrace(
            "worker-create stage=dedicated-avatar-overlay-retire "
              + "port=\(port) target=\(targetId) closed=\(closed)"
          )
          continue
        }
        let navigated = CDPClient.navigate(
          wsURLString: wsURL,
          url: appRootURL
        )
        queueTrace(
          "worker-create stage=dedicated-avatar-overlay-navigation "
            + "port=\(port) target=\(targetId) navigate=\(navigated)"
        )
        continue
      }
      let loaded = cdpValue(
        port: port,
        targetId: targetId,
        expression: """
        (() => ({
          bridge: !!window.electronBridge,
          ready: document.readyState,
          buttons: document.querySelectorAll('button').length,
          text: (document.body?.innerText || '').length,
          visibility: document.visibilityState,
          href: location.href
        }))()
        """,
        timeout: 3.0
      )
      lastProbe = loaded
      let bridge = (loaded?["bridge"] as? NSNumber)?.boolValue ?? false
      let ready = loaded?["ready"] as? String
      let textLength = (loaded?["text"] as? NSNumber)?.intValue ?? 0
      let visibility = loaded?["visibility"] as? String
      let readyValue = ready ?? "none"
      let visibilityValue = visibility ?? "none"
      if allowVisibleRenderer,
         (loaded == nil || ready != "complete" || visibility != "visible" || textLength <= 100),
         attempt - lastVisibleWakeAttempt >= 4 {
        lastVisibleWakeAttempt = attempt
        let processUnhidden = unhideDedicatedProcessForPort(port)
        let targetActivated = CDPClient.activateTarget(targetId, portOverride: port)
        let pageBroughtToFront = CDPClient.bringPageToFront(wsURLString: wsURL)
        _ = CDPClient.setWebLifecycleActive(wsURLString: wsURL)
        _ = CDPClient.setHiddenPageFocusEmulation(wsURLString: wsURL)
        _ = CDPClient.setHiddenPageUserActive(wsURLString: wsURL)
        queueTrace(
          "worker-create stage=dedicated-visible-renderer-wake "
            + "port=\(port) target=\(targetId) "
            + "processUnhidden=\(processUnhidden) "
            + "targetActivated=\(targetActivated) "
            + "pageBroughtToFront=\(pageBroughtToFront)"
        )
      }
      guard bridge, ready == "complete" else {
        // A renderer can expose the correct app URL while its preload bridge
        // is still suspended. Wake the page without changing the user's
        // visible/hidden policy, then navigate once so a stale document and
        // its old CDP websocket are replaced by a fresh renderer.
        let recoveryCount = bootstrapRecoveryCounts[targetId, default: 0]
        if attempt % 8 == 0, recoveryCount < 3 {
          let nextRecoveryCount = recoveryCount + 1
          bootstrapRecoveryCounts[targetId] = nextRecoveryCount
          _ = CDPClient.setWebLifecycleActive(wsURLString: wsURL)
          _ = CDPClient.setHiddenPageFocusEmulation(wsURLString: wsURL)
          _ = CDPClient.setHiddenPageUserActive(wsURLString: wsURL)
          // Do not replace a document that is still naturally loading. The
          // first renderer can take several seconds to attach its preload
          // bridge; navigating during that interval closes the only target
          // and leaves the dedicated process with no renderer at all. An
          // interactive renderer that has remained an empty shell for two
          // probes is no longer naturally loading, so give it one bounded
          // root navigation and rediscover the replacement target below.
          // A nil probe means that the renderer stopped answering its old
          // websocket.  Navigating through that stale connection can close
          // the only page in a dedicated process, so let the bounded startup
          // retry replace the process instead.  Only navigate a renderer
          // whose latest probe was actually received.
          if allowVisibleRenderer {
            // GitHub Actions has no user-facing desktop window to protect.
            // Keep the dedicated renderer in the foreground so macOS does not
            // silently transition its document to hidden and suspend the
            // preload bridge while the app is still bootstrapping.
            _ = CDPClient.bringPageToFront(wsURLString: wsURL)
          }
          let interactiveNavigationCount = interactiveNavigationCounts[targetId, default: 0]
          let shouldNavigate = (
            loaded != nil && (
            ready == "complete"
              || (
                ready == "interactive"
                  && textLength <= 100
                && nextRecoveryCount >= 2
                && interactiveNavigationCount < 2
              )
            )
          ) || (
            nativePromptApprovalObserved
              && avatarOverlayRetired
              && nextRecoveryCount >= 2
          )
          queueTrace(
            "worker-create stage=dedicated-renderer-bootstrap-recovery "
              + "port=\(port) target=\(targetId) attempt=\(recoveryCount + 1) "
              + "bridge=\(bridge) ready=\(readyValue) "
              + "navigate=\(shouldNavigate)"
          )
          if shouldNavigate {
            if ready == "interactive" {
              interactiveNavigationCounts[targetId] = interactiveNavigationCount + 1
              queueTrace(
                "worker-create stage=dedicated-interactive-shell-navigation "
                  + "port=\(port) target=\(targetId) "
                  + "attempt=\(interactiveNavigationCount + 1)"
              )
            }
            let navigated = CDPClient.navigate(
              wsURLString: wsURL,
              url: appRootURL
            )
            queueTrace(
              "worker-create stage=dedicated-renderer-bootstrap-navigation "
                + "port=\(port) target=\(targetId) result=\(navigated)"
            )
          }
        }
        if attempt - lastProbeDiagnosticAttempt >= 8 {
          lastProbeDiagnosticAttempt = attempt
          queueTrace(
            "worker-create stage=dedicated-renderer-probe "
              + "port=\(port) target=\(targetId) bridge=\(bridge) "
              + "ready=\(readyValue) text=\(textLength) "
              + "visibility=\(visibilityValue)"
          )
        }
        continue
      }
      let blankNavigationCount = blankNavigationCounts[targetId, default: 0]
      let lastBlankAttempt = lastBlankNavigationAttempt[targetId] ?? Int.min
      if bridge, ready == "complete", textLength <= 100,
         blankNavigationCount < 3,
         (blankNavigationCount == 0 || attempt - lastBlankAttempt >= 16) {
        // A dedicated copy may finish on the root URL with an empty shell
        // before the app mounts its real renderer. A one-time root navigation
        // forces the same bootstrap transition as the avatar-overlay path;
        // subsequent passes always rediscover the current target. Some hosted
        // launches need more than one pass after macOS has activated a second
        // Electron process, so keep this bounded per renderer.
        blankNavigationCounts[targetId] = blankNavigationCount + 1
        lastBlankNavigationAttempt[targetId] = attempt
        queueTrace(
          "worker-create stage=dedicated-empty-shell-navigation "
            + "port=\(port) target=\(targetId) "
            + "attempt=\(blankNavigationCount + 1)"
        )
        _ = CDPClient.navigate(
          wsURLString: wsURL,
          url: appRootURL
        )
        continue
      }
      if bridge, ready == "complete", textLength > 100,
         visibility != "hidden" {
        if allowVisibleRenderer {
          // The hosted runner has no user-facing page to protect. Returning
          // the live renderer lets the authenticated Chat surface finish its
          // own bootstrap instead of waiting for a hidden lifecycle state.
          queueTrace(
            "worker-create stage=dedicated-chat-target-visible-headless "
              + "port=\(port) target=\(targetId) visibility=\(visibilityValue)"
          )
          return targetId
        }
        if attempt % 8 == 0 {
          _ = hideDedicatedProcessForPort(port)
        }
        _ = CDPClient.setWebLifecycleHidden(wsURLString: wsURL)
        continue
      }
      if bridge, ready == "complete", textLength > 100, visibility == "hidden" {
        return targetId
      }
    }
    attempt += 1
    Thread.sleep(forTimeInterval: 0.25)
  }
  let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1_000)
  let probeBridge = (lastProbe?["bridge"] as? NSNumber)?.boolValue ?? false
  let probeReady = lastProbe?["ready"] as? String ?? "none"
  let probeText = (lastProbe?["text"] as? NSNumber)?.intValue ?? -1
  let probeVisibility = lastProbe?["visibility"] as? String ?? "none"
  queueTrace(
    "worker-create stage=dedicated-chat-target-timeout port=\(port) "
      + "elapsedMs=\(elapsedMs) "
      + "targets=\(dedicatedRendererTargetSummary(port: port)) "
      + "probeBridge=\(probeBridge) "
      + "probeReady=\(probeReady) "
      + "probeText=\(probeText) "
      + "probeVisibility=\(probeVisibility)"
  )
  return nil
}

func createDedicatedParallelQueueWorkerTarget(
  _ state: inout PluginState,
  sourceProfilePath: String? = nil,
  codexHomePath: String? = nil
) -> (port: Int, targetId: String, profilePath: String)? {
  let general = generalApprovalStateForQueue()
  let sourceProfile = sourceProfilePath
    ?? configuredHiddenChatProfilePath()
    ?? general?.backgroundProfilePath
    ?? state.backgroundProfilePath
    ?? hiddenChatProfilePath()
  guard FileManager.default.fileExists(atPath: sourceProfile) else {
    state.lastError = "dedicated_source_profile_missing"
    return nil
  }
  guard let port = dedicatedQueueWorkerPort() else {
    state.lastError = "dedicated_worker_port_unavailable"
    return nil
  }
  let workerDirectory = queueDirectoryURL()
    .appendingPathComponent("workers", isDirectory: true)
  var profilePath = workerDirectory
    .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
    .path
  // A renderer can become unresponsive after exposing its initial app target
  // (most often while a second isolated ChatGPT process is starting).  Keep
  // the authentication checks fail-closed, but replace that entire process a
  // bounded number of times instead of navigating through a stale websocket.
  // Each attempt receives a fresh copied profile so Chromium's renderer and
  // lock state cannot leak from the failed attempt.
  let maximumBootstrapAttempts = 2
  var targetId: String?
  for bootstrapAttempt in 1...maximumBootstrapAttempts {
    if bootstrapAttempt > 1 {
      profilePath = workerDirectory
        .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        .path
    }
    queueTrace(
      "worker-create stage=dedicated-process-bootstrap-attempt "
        + "port=\(port) attempt=\(bootstrapAttempt) "
        + "max=\(maximumBootstrapAttempts)"
    )
    queueTrace(
      "worker-create stage=dedicated-profile-copy begin "
        + "port=\(port) attempt=\(bootstrapAttempt)"
    )
    guard copyProfileForDedicatedQueueWorker(
      source: sourceProfile,
      destination: profilePath
    ) else {
      queueTrace(
        "worker-create stage=dedicated-process-bootstrap-retry "
          + "port=\(port) attempt=\(bootstrapAttempt) reason=profile_copy_failed"
      )
      terminateDedicatedChatProcess(profilePath: profilePath)
      if bootstrapAttempt == maximumBootstrapAttempts {
        state.lastError = "dedicated_profile_copy_failed"
        return nil
      }
      Thread.sleep(forTimeInterval: 1.0)
      continue
    }
    queueTrace(
      "worker-create stage=dedicated-process-launch begin "
        + "port=\(port) attempt=\(bootstrapAttempt)"
    )
    let launched: Bool
    if bootstrapAttempt == 1 {
      launched = launchDedicatedQueueChatProcess(
        profilePath: profilePath,
        port: port,
        codexHomePath: codexHomePath
      )
    } else {
      // A direct Electron launch can expose app:// targets without attaching
      // ChatGPT's preload bridge. Retrying the exact same launch path simply
      // reproduces that broken shell. After the failed worker is fully gone,
      // make the bounded second attempt through LaunchServices so macOS runs
      // the normal application bootstrap and preload lifecycle.
      queueTrace(
        "worker-create stage=dedicated-process-bootstrap-launchservices "
          + "port=\(port) attempt=\(bootstrapAttempt)"
      )
      launched = launchDedicatedQueueChatProcessViaLaunchServices(
        profilePath: profilePath,
        port: port,
        codexHomePath: codexHomePath
      )
    }
    if launched, let candidate = dedicatedQueueChatTarget(port: port) {
      targetId = candidate
      break
    }
    queueTrace(
      "worker-create stage=dedicated-process-bootstrap-retry "
        + "port=\(port) attempt=\(bootstrapAttempt) "
        + "reason=renderer_not_ready targets=\(dedicatedRendererTargetSummary(port: port))"
    )
    terminateDedicatedChatProcess(profilePath: profilePath)
    if bootstrapAttempt < maximumBootstrapAttempts {
      Thread.sleep(forTimeInterval: 1.0)
    }
  }
  guard let targetId else {
    state.lastError = "dedicated_chat_process_not_ready"
    terminateDedicatedChatProcess(profilePath: profilePath)
    return nil
  }
  queueTrace(
    "worker-create stage=dedicated-process-launch complete port=\(port) target=\(targetId)"
  )
  let selection = selectChatOnPrimaryController(port: port, targetId: targetId)
  var prepared: [String: Any]?
  for _ in 0..<80 {
    prepared = cdpValue(
      port: port,
      targetId: targetId,
      expression: prepareBackgroundChatJS(
        newChat: false,
        confirmedChatMode: selection?["alreadySelected"] as? Bool == true
      ),
      timeout: 5.0
    )
    let runtimeState = queueTargetRuntimeState(
      port: port,
      targetId: targetId,
      refreshLifecycle: true
    )
    if prepared?["ok"] as? Bool == true,
       queueTargetStateIsUsableForQueue(
         runtimeState,
         workerMode: parallelDedicatedProcessQueueWorkerMode
       ) {
      state.queueWorkerPort = port
      state.queueWorkerTargetId = targetId
      state.queueWorkerProfilePath = profilePath
      state.queueWorkerMode = parallelDedicatedProcessQueueWorkerMode
      state.lastError = nil
      queueTrace(
        "worker-create stage=dedicated-chat-ready port=\(port) target=\(targetId) "
          + "visibility=\(queueTargetRuntimeStateName(runtimeState))"
      )
      return (port, targetId, profilePath)
    }
    _ = cdpValue(
      port: port,
      targetId: targetId,
      expression: clickChatJS(),
      timeout: 4.0
    )
    Thread.sleep(forTimeInterval: 0.25)
  }
  let prepareError = prepared?["error"] as? String ?? "no_result"
    state.lastError = "dedicated_target_not_chat:\(prepareError)"
  _ = captureHiddenChatScreenshot(
    port: port,
    targetId: targetId,
    label: "dedicated-not-chat"
  )
  terminateDedicatedChatProcess(profilePath: profilePath)
  return nil
}

func createQueueWorkerTarget(
  _ state: inout PluginState,
  reuseExisting: Bool = true
) -> (port: Int, targetId: String, profilePath: String)? {
  // A compatibility caller may reuse the plugin-owned hidden Chat renderer.
  // Parallel task dispatch always passes reuseExisting=false so every running
  // task owns a different hidden BrowserWindow and never has to navigate away
  // from another task while that Chat is streaming.
  if reuseExisting,
     let port = state.queueWorkerPort,
     let targetId = state.queueWorkerTargetId,
     queueUsesBackgroundWindow(state),
     queueTargetIsHidden(port: port, targetId: targetId) {
    return (port, targetId, state.queueWorkerProfilePath ?? "")
  }
  if reuseExisting {
    if state.queueWorkerMode == legacyIsolatedQueueWorkerMode,
       let profilePath = state.queueWorkerProfilePath {
      terminateDedicatedChatProcess(profilePath: profilePath)
    }
    state.queueWorkerPort = nil
    state.queueWorkerTargetId = nil
    state.queueWorkerProfilePath = nil
    state.queueWorkerMode = nil
  }

  let general = generalApprovalStateForQueue()
  let port = configuredHiddenChatPort()
    ?? general?.backgroundAppPort
    ?? state.backgroundAppPort
    ?? hiddenChatPort(state)
  let profilePath = configuredHiddenChatProfilePath()
    ?? general?.backgroundProfilePath
    ?? state.backgroundProfilePath
    ?? hiddenChatProfilePath()
  let preferredTargetIds = [
    general?.backgroundChatTargetId,
    state.backgroundChatTargetId,
  ].compactMap { $0 }
  let targets = CDPClient.fetchTargets(portOverride: port).sorted { lhs, rhs in
    let lhsId = lhs["id"] as? String ?? ""
    let rhsId = rhs["id"] as? String ?? ""
    return (preferredTargetIds.firstIndex(of: lhsId) ?? Int.max)
      < (preferredTargetIds.firstIndex(of: rhsId) ?? Int.max)
  }
  queueTrace(
    "worker-create stage=reuse-scan enabled=\(reuseExisting) targets=\(targets.count)"
  )
  for target in reuseExisting ? targets : [] {
    guard target["type"] as? String == "page",
          (target["url"] as? String ?? "") == "app://-/index.html",
          let targetId = target["id"] as? String,
          queueTargetRuntimeState(
            port: port,
            targetId: targetId,
            refreshLifecycle: true
          ) == .hidden else { continue }
    let prepared = cdpValue(
      port: port,
      targetId: targetId,
      expression: prepareBackgroundChatJS(newChat: false),
      timeout: 5.0
    )
    guard prepared?["ok"] as? Bool == true else { continue }
    state.backgroundAppPort = port
    state.backgroundChatTargetId = targetId
    state.backgroundProfilePath = profilePath
    state.queueWorkerPort = port
    state.queueWorkerTargetId = targetId
    state.queueWorkerProfilePath = profilePath
    state.queueWorkerMode = sharedConversationQueueWorkerMode
    return (port, targetId, profilePath)
  }

  // A fresh runner normally has only ChatGPT's visible primary window.
  // Ask that authenticated renderer's official quick-chat service to create
  // the show:false prewarm BrowserWindow, then turn it into the queue-owned
  // hidden Chat surface. Previously this implementation existed but was never
  // called, so the queue could only reuse a hidden target created elsewhere.
  var prewarmFailure: String?
  queueTrace("worker-create stage=new-hidden-window begin")
  if let controller = sharedChatController(&state),
     let controllerSelection = selectChatOnPrimaryController(
       port: controller.port,
       targetId: controller.targetId
     ) {
    queueTrace(
      "worker-create stage=primary-chat-selection complete "
        + "alreadySelected=\(controllerSelection["alreadySelected"] as? Bool ?? false) "
        + "selectedLabel=\(controllerSelection["selectedLabel"] as? String ?? "none")"
    )
  }
  if let controller = sharedChatController(&state),
     let hiddenTargetId = openBackgroundQueueWindow(
       port: controller.port,
       controllerTargetId: controller.targetId,
       failure: &prewarmFailure
     ) {
    queueTrace("worker-create stage=new-hidden-window complete target=\(hiddenTargetId)")
    _ = resetStaleChatModeIfNeeded(
      port: controller.port,
      targetId: hiddenTargetId,
      stage: "hidden-chat-selection"
    )
    // A fresh hosted runner can restore authentication before completing the
    // desktop app's informational onboarding. Advance only neutral navigation
    // buttons, then select Chat once the real app shell is available.
    var chatSelection: [String: Any]?
    for _ in 0..<12 {
      queueTrace("worker-create stage=chat-selection attempt")
      chatSelection = cdpValue(
        port: controller.port,
        targetId: hiddenTargetId,
        expression: clickChatJS(),
        timeout: 4.0
      )
      if chatSelection?["ok"] as? Bool == true { break }
      if chatSelection?["retryAfterModeSwitch"] as? Bool == true {
        Thread.sleep(forTimeInterval: 0.8)
        continue
      }
      let onboarding = cdpValue(
        port: controller.port,
        targetId: hiddenTargetId,
        expression: continueHiddenOnboardingJS(),
        timeout: 4.0
      )
      guard onboarding?["clicked"] as? Bool == true else { break }
      Thread.sleep(forTimeInterval: 0.8)
    }
    queueTrace(
      "worker-create stage=chat-selection complete ok=\(chatSelection?["ok"] as? Bool ?? false)"
    )
    var workerPrepared = false
    var lastHiddenPrepare: [String: Any]?
    for _ in 0..<80 {
      queueTrace("worker-create stage=chat-prepare attempt")
      let prepared = cdpValue(
        port: controller.port,
        targetId: hiddenTargetId,
        expression: prepareBackgroundChatJS(
          newChat: false,
          // clickChatJS returns dispatchOnly before the top Chat/Work switch
          // has actually changed. Only an already-selected Chat state may be
          // carried across a renderer replacement.
          confirmedChatMode: chatSelection?["alreadySelected"] as? Bool == true
        ),
        timeout: 5.0
      )
      lastHiddenPrepare = prepared
      if prepared?["error"] as? String == "not_chat_surface" {
        // A dispatch-only Chat click can replace the renderer asynchronously.
        // Retry against the fresh top-level Chat/Work switch until the new
        // renderer proves it is actually Chat; never accept the stale Work
        // composer just because the previous page set a transient flag.
        let retrySelection = cdpValue(
          port: controller.port,
          targetId: hiddenTargetId,
          expression: clickChatJS(),
          timeout: 4.0
        )
        if retrySelection?["alreadySelected"] as? Bool == true {
          chatSelection = retrySelection
        }
      }
      let state = queueTargetRuntimeState(
        port: controller.port,
        targetId: hiddenTargetId,
        refreshLifecycle: true
      )
      queueTrace("worker-create stage=chat-prepare state=\(queueTargetRuntimeStateName(state))")
      if prepared?["ok"] as? Bool == true,
         (state == .hidden || state == .visible) {
        workerPrepared = true
        queueTrace("worker-create stage=chat-prepare complete")
        break
      }
      Thread.sleep(forTimeInterval: 0.25)
    }
    if workerPrepared {
      state.backgroundAppPort = controller.port
      state.backgroundChatTargetId = hiddenTargetId
      state.backgroundProfilePath = controller.profilePath
      state.queueWorkerPort = controller.port
      state.queueWorkerTargetId = hiddenTargetId
      state.queueWorkerProfilePath = controller.profilePath
      state.queueWorkerMode = sharedConversationQueueWorkerMode
      return (controller.port, hiddenTargetId, controller.profilePath)
    }
    let surfaceDiagnostic = cdpValue(
      port: controller.port,
      targetId: hiddenTargetId,
      expression: pageDiagnosticJS(),
      timeout: 5.0
    )
    let diagnosticButtons = (surfaceDiagnostic?["buttons"] as? [String] ?? [])
      .joined(separator: "|")
    let diagnosticModes = (surfaceDiagnostic?["modeNodes"] as? [[String: Any]] ?? [])
      .map { node in
        let text = node["text"] as? String ?? ""
        let tag = node["tag"] as? String ?? ""
        let role = node["role"] as? String ?? ""
        let selected = node["ariaSelected"] as? String ?? ""
        let pressed = node["ariaPressed"] as? String ?? ""
        let className = node["className"] as? String ?? ""
        return "\(text)@\(tag)#\(role)[selected=\(selected),pressed=\(pressed)]{\(className)}"
      }
      .joined(separator: "|")
    let diagnosticURL = surfaceDiagnostic?["url"] as? String ?? "none"
    let diagnosticScreenshot = captureHiddenChatScreenshot(
      port: controller.port,
      targetId: hiddenTargetId,
      label: "prewarm-not-chat"
    ) ?? captureHiddenChatScreenshot(
      port: controller.port,
      targetId: controller.targetId,
      label: "primary-not-chat"
    ) ?? "none"
    queueTrace(
      "worker-create stage=chat-prepare diagnostics url=\(diagnosticURL) "
        + "buttons=\(diagnosticButtons) modes=\(diagnosticModes) "
        + "screenshot=\(diagnosticScreenshot)"
    )
    _ = CDPClient.closeTarget(hiddenTargetId, portOverride: controller.port)
    let selectionError = chatSelection?["error"] as? String ?? "none"
    let selectionLabels = (chatSelection?["candidateLabels"] as? [String] ?? [])
      .joined(separator: "|")
    let prepareError = lastHiddenPrepare?["error"] as? String ?? "no_result"
    let workComposer = lastHiddenPrepare?["workComposer"] as? Bool ?? false
    let hasInput = lastHiddenPrepare?["hasInput"] as? Bool ?? false
    let chatModel = lastHiddenPrepare?["chatModel"] as? Bool ?? false
    prewarmFailure = [
      "prewarm_hidden_target_not_chat",
      "selection=\(selectionError)",
      "selectionLabels=\(selectionLabels)",
      "prepare=\(prepareError)",
      "hasInput=\(hasInput)",
      "chatModel=\(chatModel)",
      "workComposer=\(workComposer)",
    ].joined(separator: ":")
  }
  let prewarmCreationFailure = prewarmFailure ?? "prewarm_controller_unavailable"
  queueTrace("worker-create stage=prewarm-failed error=\(prewarmCreationFailure)")
  state.lastError = prewarmCreationFailure

  // A fresh parallel task must never fall back to a renderer that already
  // belongs to another running Chat. That fallback was the reason task B
  // tried to press New Chat inside task A's streaming page.
  guard reuseExisting else {
    state.lastError = prewarmCreationFailure
    return nil
  }
  let fallback = ensureHiddenChatTarget(&state)
  guard let prepared = fallback,
        prepared["ok"] as? Bool == true,
        let preparedPort = prepared["port"] as? Int,
        let targetId = prepared["targetId"] as? String,
        queueTargetIsReady(port: preparedPort, targetId: targetId) else {
    state.lastError = prewarmCreationFailure
    return nil
  }
  let preparedProfilePath = prepared["profilePath"] as? String ?? profilePath
  state.queueWorkerPort = preparedPort
  state.queueWorkerTargetId = targetId
  state.queueWorkerProfilePath = preparedProfilePath
  state.queueWorkerMode = sharedConversationQueueWorkerMode
  return (preparedPort, targetId, preparedProfilePath)
}

func existingHeadlessParallelQueueTarget(
  _ state: inout PluginState,
  port: Int,
  controllerTargetId: String
) -> String? {
  let queueOwnedTargetIds = Set(
    (state.automationTasks ?? []).compactMap(\.workerTargetId)
      + [state.queueWorkerTargetId].compactMap { $0 }
  )
  let candidates = CDPClient.fetchTargets(portOverride: port)
    .filter { target in
      guard let targetId = target["id"] as? String else { return false }
      return target["type"] as? String == "page"
        && (target["url"] as? String ?? "").hasPrefix("app://-/index.html")
        && !queueOwnedTargetIds.contains(targetId)
        // The controller renderer owns the authenticated desktop session and
        // must never become a task renderer. Closing it during task cleanup
        // leaves the next retry with only an empty bridge-less shell.
        && targetId != controllerTargetId
        && target["webSocketDebuggerUrl"] as? String != nil
    }
    .sorted { lhs, rhs in
      // Prefer a normal primary renderer over the queue's prewarm controller;
      // use the controller only when no other authenticated renderer remains.
      let lhsIsController = lhs["id"] as? String == controllerTargetId
      let rhsIsController = rhs["id"] as? String == controllerTargetId
      if lhsIsController != rhsIsController { return !lhsIsController }
      return (lhs["id"] as? String ?? "") < (rhs["id"] as? String ?? "")
    }
  for candidate in candidates {
    guard let targetId = candidate["id"] as? String else { continue }
    let probe = cdpValue(
      port: port,
      targetId: targetId,
      expression: """
      (() => ({
        bridge: !!window.electronBridge,
        ready: document.readyState,
        visibility: document.visibilityState,
        text: (document.body?.innerText || '').length,
        href: location.href
      }))()
      """,
      timeout: 3.0
    )
    let bridge = (probe?["bridge"] as? NSNumber)?.boolValue ?? false
    let ready = probe?["ready"] as? String ?? "none"
    let visibility = probe?["visibility"] as? String ?? "none"
    let textLength = (probe?["text"] as? NSNumber)?.intValue ?? 0
    queueTrace(
      "worker-create stage=headless-existing-window-probe "
        + "target=\(targetId) visibility=\(visibility) "
        + "bridge=\(bridge) ready=\(ready) text=\(textLength)"
    )
    guard bridge, ready == "complete" else { continue }

    var chatSelection: [String: Any]?
    for _ in 0..<12 {
      chatSelection = cdpValue(
        port: port,
        targetId: targetId,
        expression: clickChatJS(),
        timeout: 4.0
      )
      if chatSelection?["ok"] as? Bool == true
          || chatSelection?["alreadySelected"] as? Bool == true {
        break
      }
      Thread.sleep(forTimeInterval: 0.25)
    }

    var prepared: [String: Any]?
    for _ in 0..<24 {
      prepared = cdpValue(
        port: port,
        targetId: targetId,
        expression: prepareBackgroundChatJS(
          newChat: false,
          confirmedChatMode: chatSelection?["alreadySelected"] as? Bool == true
        ),
        timeout: 5.0
      )
      let runtimeState = queueTargetRuntimeState(
        port: port,
        targetId: targetId,
        refreshLifecycle: true
      )
      if prepared?["ok"] as? Bool == true,
         queueTargetStateIsUsableForQueue(
           runtimeState,
           workerMode: parallelHeadlessWindowQueueWorkerMode
         ) {
        queueTrace(
          "worker-create stage=headless-existing-window-ready "
            + "target=\(targetId) "
            + "visibility=\(queueTargetRuntimeStateName(runtimeState))"
        )
        return targetId
      }
      _ = cdpValue(
        port: port,
        targetId: targetId,
        expression: clickChatJS(),
        timeout: 4.0
      )
      Thread.sleep(forTimeInterval: 0.25)
    }
    queueTrace(
      "worker-create stage=headless-existing-window-rejected "
        + "target=\(targetId) error=\(prepared?["error"] as? String ?? "no_result")"
    )
  }
  return nil
}

func createHeadlessParallelQueueWorkerTarget(
  _ state: inout PluginState
) -> (port: Int, targetId: String, profilePath: String)? {
  guard let controller = sharedChatController(&state) else {
    state.lastError = "headless_window_controller_unavailable"
    return nil
  }
  if let existingTargetId = existingHeadlessParallelQueueTarget(
    &state,
    port: controller.port,
    controllerTargetId: controller.targetId
  ) {
    let profilePath = configuredHiddenChatProfilePath()
      ?? state.backgroundProfilePath
      ?? hiddenChatProfilePath()
    state.queueWorkerPort = controller.port
    state.queueWorkerTargetId = existingTargetId
    state.queueWorkerProfilePath = profilePath
    state.queueWorkerMode = parallelHeadlessWindowQueueWorkerMode
    state.lastError = nil
    queueTrace(
      "worker-create stage=headless-parallel-existing-window-complete "
        + "target=\(existingTargetId)"
    )
    return (controller.port, existingTargetId, profilePath)
  }
  var failure: String?
  guard let targetId = openHeadlessParallelQueueWindow(
    port: controller.port,
    controllerTargetId: controller.targetId,
    failure: &failure
  ) else {
    state.lastError = failure ?? "headless_window_target_unavailable"
    queueTrace(
      "worker-create stage=headless-window-target-failed "
        + "error=\(state.lastError ?? "unknown")"
    )
    return nil
  }

  var chatSelection: [String: Any]?
  for _ in 0..<20 {
    chatSelection = cdpValue(
      port: controller.port,
      targetId: targetId,
      expression: clickChatJS(),
      timeout: 4.0
    )
    if chatSelection?["ok"] as? Bool == true
        || chatSelection?["alreadySelected"] as? Bool == true {
      break
    }
    Thread.sleep(forTimeInterval: 0.35)
  }

  var lastPrepared: [String: Any]?
  for _ in 0..<80 {
    lastPrepared = cdpValue(
      port: controller.port,
      targetId: targetId,
      expression: prepareBackgroundChatJS(
        newChat: false,
        confirmedChatMode: chatSelection?["alreadySelected"] as? Bool == true
      ),
      timeout: 5.0
    )
    let runtimeState = queueTargetRuntimeState(
      port: controller.port,
      targetId: targetId,
      refreshLifecycle: true
    )
    if lastPrepared?["ok"] as? Bool == true,
       queueTargetStateIsUsableForQueue(
         runtimeState,
         workerMode: parallelHeadlessWindowQueueWorkerMode
       ) {
      let profilePath = configuredHiddenChatProfilePath()
        ?? state.backgroundProfilePath
        ?? hiddenChatProfilePath()
      state.queueWorkerPort = controller.port
      state.queueWorkerTargetId = targetId
      state.queueWorkerProfilePath = profilePath
      state.queueWorkerMode = parallelHeadlessWindowQueueWorkerMode
      state.lastError = nil
      queueTrace(
        "worker-create stage=headless-parallel-window-chat-ready "
          + "port=\(controller.port) target=\(targetId) "
          + "visibility=\(queueTargetRuntimeStateName(runtimeState))"
      )
      return (controller.port, targetId, profilePath)
    }
    _ = cdpValue(
      port: controller.port,
      targetId: targetId,
      expression: clickChatJS(),
      timeout: 4.0
    )
    Thread.sleep(forTimeInterval: 0.25)
  }
  state.lastError = "headless_window_not_chat:\(lastPrepared?["error"] as? String ?? "no_result")"
  _ = CDPClient.closeTarget(targetId, portOverride: controller.port)
  return nil
}

func createSharedControllerQueueWorkerTarget(
  _ state: inout PluginState
) -> (port: Int, targetId: String, profilePath: String)? {
  // A single-task runner may use the already authenticated primary renderer
  // while no task is running. Local desktop fallback is allowed only after
  // the dedicated controller is verified hidden; Actions/headless runners may
  // also accept a visible renderer because they have no user-facing window.
  // Mark it shared so cleanup never closes ChatGPT's primary window.
  guard !(state.automationTasks ?? []).contains(where: { $0.status == "running" }),
        var controller = sharedChatController(&state) else {
    state.lastError = "hosted_controller_unavailable_or_busy"
    return nil
  }

  queueTrace(
    "worker-create stage=hosted-controller-fallback-prepare-begin "
      + "port=\(controller.port) target=\(controller.targetId)"
  )
  var selection = selectChatOnPrimaryController(
    port: controller.port,
    targetId: controller.targetId
  )
  // A top-level Chat/Work transition can replace the Electron renderer. The
  // old target may stay in /json briefly, but further Runtime.evaluate calls
  // against it observe the stale Work shell. Re-discover the authenticated
  // controller after every selection boundary before probing the composer.
  if let refreshed = sharedChatController(&state) {
    controller = refreshed
  }
  var lastPrepared: [String: Any]?
  for _ in 0..<40 {
    let confirmedChatMode = selection?["alreadySelected"] as? Bool == true
    lastPrepared = cdpValue(
      port: controller.port,
      targetId: controller.targetId,
      expression: prepareBackgroundChatJS(
        newChat: false,
        confirmedChatMode: confirmedChatMode
      ),
      timeout: 5.0
    )
    let runtimeState = queueTargetRuntimeState(
      port: controller.port,
      targetId: controller.targetId,
      refreshLifecycle: true
    )
    let controllerIsSafe = runtimeState == .hidden
      || ((runningOnGitHubActions() || queueAllowsVisibleDedicatedRenderer())
        && runtimeState == .visible)
    if lastPrepared?["ok"] as? Bool == true, controllerIsSafe {
      state.backgroundAppPort = controller.port
      state.backgroundChatTargetId = controller.targetId
      state.backgroundProfilePath = controller.profilePath
      state.queueWorkerPort = controller.port
      state.queueWorkerTargetId = controller.targetId
      state.queueWorkerProfilePath = controller.profilePath
      state.queueWorkerMode = sharedConversationQueueWorkerMode
      state.lastError = nil
      queueTrace(
        "worker-create stage=hosted-controller-fallback-prepare-complete "
          + "target=\(controller.targetId) "
          + "visibility=\(queueTargetRuntimeStateName(runtimeState))"
      )
      return (controller.port, controller.targetId, controller.profilePath)
    }
    if lastPrepared?["error"] as? String == "not_chat_surface" {
      selection = selectChatOnPrimaryController(
        port: controller.port,
        targetId: controller.targetId
      )
      Thread.sleep(forTimeInterval: 0.5)
      if let refreshed = sharedChatController(&state) {
        controller = refreshed
      }
    }
    Thread.sleep(forTimeInterval: 0.35)
  }

  let diagnosticScreenshot = captureHiddenChatScreenshot(
    port: controller.port,
    targetId: controller.targetId,
    label: "hosted-controller-not-chat"
  ) ?? "none"
  state.lastError = [
    "hosted_controller_not_chat",
    "prepare=\(lastPrepared?["error"] as? String ?? "no_result")",
    "hasInput=\(lastPrepared?["hasInput"] as? Bool ?? false)",
    "workComposer=\(lastPrepared?["workComposer"] as? Bool ?? false)",
    "screenshot=\(diagnosticScreenshot)",
  ].joined(separator: ":")
  queueTrace(
    "worker-create stage=hosted-controller-fallback-prepare-failed "
      + "error=\(state.lastError ?? "unknown")"
  )
  return nil
}

func createIndependentQueueWorkerTarget(
  _ state: inout PluginState,
  accountId: String? = nil
) -> (port: Int, targetId: String, profilePath: String)? {
  // Serial continuations already own an authenticated controller in the
  // queue-only background profile. Reusing that exact renderer avoids opening
  // another prewarm window while the completed Chat is still mounted; the
  // continuation flow below will branch it into a fresh Chat before sending.
  if state.queueWorkerMode == sharedConversationQueueWorkerMode,
     !(state.automationTasks ?? []).contains(where: { $0.status == "running" }),
     let port = state.queueWorkerPort,
     let targetId = state.queueWorkerTargetId,
     let profilePath = state.queueWorkerProfilePath,
     profilePath == hiddenChatProfilePath(),
     state.backgroundAppPort == port,
     state.backgroundChatTargetId == targetId,
     state.backgroundProfilePath == profilePath,
     queueTargetIsReady(port: port, targetId: targetId) {
    queueTrace(
      "worker-create stage=serial-shared-controller-reuse "
        + "target=\(targetId)"
    )
    return (port, targetId, profilePath)
  }
  let explicitAccountValue = accountId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  let explicitAccountId = explicitAccountValue.isEmpty ? nil : explicitAccountValue
  let hostedAccountValue = ProcessInfo.processInfo.environment["CHATGPT_ACCOUNT_ID"]?
    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  let hostedAccountId = hostedAccountValue.isEmpty ? nil : hostedAccountValue
  if let effectiveAccountId = explicitAccountId ?? hostedAccountId {
    if hostedPersistentQueueUsesPrewarmWorker() {
      // The authenticated controller and the hidden prewarm renderer are
      // created and verified by verify_chatgpt_login in this same process.
      // A copied second ChatGPT process is not needed for the persistent
      // runner, and on hosted macOS it can stop at an avatar-overlay page
      // without mounting electronBridge. Never use the shared process for a
      // task assigned to a different account.
      guard let hostedAccountId,
            effectiveAccountId == hostedAccountId else {
        state.lastError = "hosted_account_mismatch"
        queueTrace(
          "worker-create stage=hosted-prewarm-worker-rejected "
            + "account=\(effectiveAccountId) hostedAccount=\(hostedAccountId ?? "none")"
        )
        return nil
      }
      queueTrace(
        "worker-create stage=hosted-prewarm-worker-begin "
          + "account=\(effectiveAccountId)"
      )
      if let worker = createQueueWorkerTarget(&state, reuseExisting: false) {
        state.queueWorkerMode = sharedConversationQueueWorkerMode
        queueTrace(
          "worker-create stage=hosted-prewarm-worker-complete "
            + "account=\(effectiveAccountId) target=\(worker.targetId)"
        )
        return worker
      }
      let prewarmError = state.lastError ?? "unknown"
      queueTrace(
        "worker-create stage=hosted-prewarm-worker-failed "
          + "account=\(effectiveAccountId) error=\(prewarmError)"
      )
      // If the official quick-chat prewarm window cannot mount a Chat surface,
      // try a normal independently owned BrowserWindow in the same verified
      // dual-credential process. The caller has already forced a real
      // Work-to-Chat transition; this fallback preserves task isolation and
      // never treats a Work usage page as a valid Chat surface.
      queueTrace(
        "worker-create stage=hosted-headless-window-fallback-begin "
          + "account=\(effectiveAccountId)"
      )
      if let fallback = createHeadlessParallelQueueWorkerTarget(&state) {
        state.queueWorkerMode = parallelHeadlessWindowQueueWorkerMode
        queueTrace(
          "worker-create stage=hosted-headless-window-fallback-complete "
            + "account=\(effectiveAccountId) target=\(fallback.targetId)"
        )
        return fallback
      }
      let fallbackError = state.lastError ?? "unknown"
      state.lastError = "\(prewarmError); hosted_headless_fallback=\(fallbackError)"
      queueTrace(
        "worker-create stage=hosted-headless-window-fallback-failed "
          + "account=\(effectiveAccountId) error=\(fallbackError)"
      )
      queueTrace(
        "worker-create stage=hosted-controller-fallback-begin "
          + "account=\(effectiveAccountId)"
      )
      if let controllerFallback = createSharedControllerQueueWorkerTarget(&state) {
        queueTrace(
          "worker-create stage=hosted-controller-fallback-complete "
            + "account=\(effectiveAccountId) target=\(controllerFallback.targetId)"
        )
        return controllerFallback
      }
      let controllerFallbackError = state.lastError ?? "unknown"
      state.lastError = "\(prewarmError); hosted_headless_fallback=\(fallbackError); hosted_controller_fallback=\(controllerFallbackError)"
      queueTrace(
        "worker-create stage=hosted-controller-fallback-failed "
          + "account=\(effectiveAccountId) error=\(controllerFallbackError)"
      )
      return nil
    }
    // A local headless desktop run can create an independent BrowserWindow in
    // the authenticated process. The parallel Actions smoke keeps the
    // dedicated-process path below so each overlapping task owns a separate
    // profile and renderer; persistent hosted runs use the verified prewarm
    // path above.
    if queueAllowsVisibleDedicatedRenderer() && !runningOnGitHubActions() {
      // The official quick-chat prewarm service is the only local path that
      // guarantees Electron's preload bridge on a newly-created hidden
      // BrowserWindow. Browser-level Target.createTarget can return a valid
      // app:// document without electronBridge, so prefer prewarm whenever no
      // other queue task is already using its single hidden window. Overlap
      // still falls through to the isolated parallel-window implementation.
      let hasRunningTask = (state.automationTasks ?? []).contains {
        $0.status == "running"
      }
      if !hasRunningTask {
        queueTrace(
          "worker-create stage=local-prewarm-hidden-window-begin "
            + "account=\(effectiveAccountId)"
        )
        if let worker = createQueueWorkerTarget(&state, reuseExisting: false) {
          queueTrace(
            "worker-create stage=local-prewarm-hidden-window-complete "
              + "account=\(effectiveAccountId) target=\(worker.targetId)"
          )
          return worker
        }
        queueTrace(
          "worker-create stage=local-prewarm-hidden-window-failed "
            + "account=\(effectiveAccountId) error=\(state.lastError ?? "unknown")"
        )
        queueTrace(
          "worker-create stage=local-controller-fallback-begin "
            + "account=\(effectiveAccountId)"
        )
        if let controllerFallback = createSharedControllerQueueWorkerTarget(&state) {
          queueTrace(
            "worker-create stage=local-controller-fallback-complete "
              + "account=\(effectiveAccountId) target=\(controllerFallback.targetId)"
          )
          return controllerFallback
        }
        queueTrace(
          "worker-create stage=local-controller-fallback-failed "
            + "account=\(effectiveAccountId) error=\(state.lastError ?? "unknown")"
        )
      }
      queueTrace(
        "worker-create stage=headless-parallel-hidden-window-begin "
          + "account=\(effectiveAccountId)"
      )
      guard let worker = createHeadlessParallelQueueWorkerTarget(&state) else {
        queueTrace(
          "worker-create stage=headless-parallel-hidden-window-failed "
            + "account=\(effectiveAccountId)"
        )
        return nil
      }
      queueTrace(
        "worker-create stage=headless-parallel-hidden-window-complete "
          + "account=\(effectiveAccountId) target=\(worker.targetId)"
      )
      return worker
    }
    // Local account records carry their own profile and CODEX_HOME paths. A
    // hosted runner intentionally has no local account registry: it restores
    // the encrypted account bundle into the workflow's private profile and
    // ~/.codex before starting this runtime. Use that profile only when the
    // requested task account is the same hosted account; an explicitly
    // different account still fails closed instead of borrowing a renderer.
    let dedicatedSource: (profilePath: String, codexHomePath: String?, traceStage: String)?
    if let account = resolveAccount(effectiveAccountId),
       FileManager.default.fileExists(atPath: account.profilePath) {
      dedicatedSource = (
        profilePath: account.profilePath,
        codexHomePath: account.codexHomePath,
        traceStage: "dedicated-account"
      )
    } else if let hostedAccountId,
              effectiveAccountId == hostedAccountId,
              let profilePath = configuredHiddenChatProfilePath(),
              FileManager.default.fileExists(atPath: profilePath) {
      let codexHomeValue = ProcessInfo.processInfo.environment["CODEX_HOME"]?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      let codexHomePath = codexHomeValue.isEmpty ? nil : codexHomeValue
      dedicatedSource = (
        profilePath: profilePath,
        codexHomePath: codexHomePath,
        traceStage: "dedicated-hosted-profile"
      )
    } else {
      dedicatedSource = nil
    }
    guard let dedicatedSource else {
      // Hosted account runners and explicitly assigned tasks must never fall
      // back to the shared desktop renderer. The official prewarm window is
      // account-feature-gated and repeatedly disappeared on macOS runners
      // before a message could be sent. A dedicated process is deterministic
      // and keeps each account and parallel task isolated.
      queueTrace(
        "worker-create stage=dedicated-account-missing account=\(effectiveAccountId)"
      )
      return nil
    }
    queueTrace(
      "worker-create stage=\(dedicatedSource.traceStage)-begin account=\(effectiveAccountId)"
    )
    guard let worker = createDedicatedParallelQueueWorkerTarget(
      &state,
      sourceProfilePath: dedicatedSource.profilePath,
      codexHomePath: dedicatedSource.codexHomePath
    ) else {
      queueTrace(
        "worker-create stage=\(dedicatedSource.traceStage)-failed account=\(effectiveAccountId)"
      )
      return nil
    }
    state.queueWorkerMode = parallelDedicatedProcessQueueWorkerMode
    queueTrace(
      "worker-create stage=\(dedicatedSource.traceStage)-complete account=\(effectiveAccountId) target=\(worker.targetId)"
    )
    return worker
  }
  // Reuse the authenticated ChatGPT desktop process and ask its official
  // prewarm service to create a fresh hidden app renderer.
  if let worker = createQueueWorkerTarget(&state, reuseExisting: false) {
    state.queueWorkerMode = parallelHiddenWindowQueueWorkerMode
    return worker
  }
  let prewarmError = state.lastError ?? "unknown"
  queueTrace(
    "worker-create stage=unassigned-prewarm-worker-failed error=\(prewarmError)"
  )

  // Tasks imported before account routing was introduced may not have an
  // accountId. They still run inside the already prepared, hidden ChatGPT
  // controller. When the official quick-chat prewarm renderer lands on its
  // transient error page, recover through that authenticated controller just
  // like an explicitly assigned local task instead of failing before the
  // fallback branch above can run.
  queueTrace("worker-create stage=unassigned-controller-fallback-begin")
  if let controllerFallback = createSharedControllerQueueWorkerTarget(&state) {
    queueTrace(
      "worker-create stage=unassigned-controller-fallback-complete "
        + "target=\(controllerFallback.targetId)"
    )
    return controllerFallback
  }
  let controllerError = state.lastError ?? "unknown"
  state.lastError = "\(prewarmError); unassigned_controller_fallback=\(controllerError)"
  queueTrace(
    "worker-create stage=unassigned-controller-fallback-failed error=\(controllerError)"
  )
  return nil
}

func stopQueueWorker(_ state: inout PluginState) {
  // Close only queue-owned hidden windows. The primary window and the shared
  // ChatGPT process remain available to the user and the general confirmer.
  if state.queueWorkerMode == parallelDedicatedProcessQueueWorkerMode {
    for task in state.automationTasks ?? [] {
      if let targetId = task.workerTargetId {
        _ = CDPClient.closeTarget(targetId, portOverride: task.workerPort)
      }
      if let profilePath = task.workerProfilePath {
        terminateDedicatedChatProcess(profilePath: profilePath)
      }
    }
    if let profilePath = state.queueWorkerProfilePath,
       !(state.automationTasks ?? []).contains(where: {
         $0.workerProfilePath == profilePath
       }) {
      terminateDedicatedChatProcess(profilePath: profilePath)
    }
  } else if state.queueWorkerMode == parallelHiddenWindowQueueWorkerMode {
    let taskTargets = Set((state.automationTasks ?? []).compactMap { task -> String? in
      guard let port = task.workerPort,
            let targetId = task.workerTargetId,
            queueTargetIsHidden(port: port, targetId: targetId) else { return nil }
      _ = CDPClient.closeTarget(targetId, portOverride: port)
      return targetId
    })
    if let targetId = state.queueWorkerTargetId,
       !taskTargets.contains(targetId),
       let port = state.queueWorkerPort,
       queueTargetIsHidden(port: port, targetId: targetId) {
      _ = CDPClient.closeTarget(targetId, portOverride: port)
    }
  } else if state.queueWorkerMode == parallelHeadlessWindowQueueWorkerMode {
    let taskTargets = Set((state.automationTasks ?? []).compactMap { task -> String? in
      guard let port = task.workerPort, let targetId = task.workerTargetId else { return nil }
      _ = CDPClient.closeTarget(targetId, portOverride: port)
      return targetId
    })
    if let targetId = state.queueWorkerTargetId,
       !taskTargets.contains(targetId),
       let port = state.queueWorkerPort {
      _ = CDPClient.closeTarget(targetId, portOverride: port)
    }
  } else if state.queueWorkerMode == backgroundWindowQueueWorkerMode {
    if let targetId = state.queueWorkerTargetId {
      _ = CDPClient.closeTarget(targetId, portOverride: state.queueWorkerPort)
    }
  } else if state.queueWorkerMode == legacyIsolatedQueueWorkerMode,
            let profilePath = state.queueWorkerProfilePath {
    terminateDedicatedChatProcess(profilePath: profilePath)
  }
  state.queueWorkerPort = nil
  state.queueWorkerTargetId = nil
  state.queueWorkerProfilePath = nil
  state.queueWorkerMode = nil
}

func startAutomationTask(
  _ task: inout AutomationTask,
  state: inout PluginState
) throws {
  // Each parallel task owns a fresh hidden Chat BrowserWindow inside the same
  // authenticated ChatGPT process. This preserves the proven real Chat UI path
  // without navigating away from another task's streaming conversation.
  var prepared: [String: Any]?
  var preparationFailure: String?
  var port: Int?
  var targetId: String?
  var workerProfilePath: String?
  var taskOwnsTarget = false
  // Normal task rounds branch from the latest task conversation. A dispatch
  // that created a user bubble but never produced any assistant/tool activity
  // has no response turn to branch from, so recovery must create a genuinely
  // fresh Chat while leaving the stalled Chat untouched.
  let freshChatRecoveryReasons = ["chat_start_no_reply", "page_stalled"]
  let requiresFreshRecoveryChat = freshChatRecoveryReasons.contains(task.lastError ?? "")
  var forceFullGoalPrompt = requiresFreshRecoveryChat
  let previousConversationId = requiresFreshRecoveryChat
    ? nil
    : normalizedConversationId(task.conversationId)
  defer {
    if !taskOwnsTarget,
       state.queueWorkerMode != sharedConversationQueueWorkerMode,
       let port, let targetId {
      _ = CDPClient.closeTarget(targetId, portOverride: port)
    }
    if !taskOwnsTarget, let workerProfilePath {
      terminateDedicatedChatProcess(profilePath: workerProfilePath)
    }
  }
  let preserveStalledChat = [
    "chat_start_no_reply", "page_stalled", "page_stalled_but_response_active",
  ].contains(task.lastError ?? "")
  if !preserveStalledChat,
     state.queueWorkerMode == parallelDedicatedProcessQueueWorkerMode,
     let staleProfilePath = task.workerProfilePath {
    terminateDedicatedChatProcess(profilePath: staleProfilePath)
  } else if !preserveStalledChat,
            (state.queueWorkerMode == parallelHiddenWindowQueueWorkerMode
              || state.queueWorkerMode == parallelHeadlessWindowQueueWorkerMode),
            let staleTargetId = task.workerTargetId,
            let stalePort = task.workerPort,
     queueTargetIsReady(port: stalePort, targetId: staleTargetId) {
    _ = CDPClient.closeTarget(staleTargetId, portOverride: stalePort)
  }
  task.workerPort = nil
  task.workerTargetId = nil
  task.workerProfilePath = nil
  queueTrace("task=\(task.id) stage=create-worker begin")
  guard let worker = createIndependentQueueWorkerTarget(&state, accountId: task.accountId) else {
    let detail = state.lastError ?? "unknown"
    throw NSError(
      domain: "chatgpt-auto-confirm",
      code: 33,
      userInfo: [
        NSLocalizedDescriptionKey: "当前 ChatGPT 实例没有可用的 Chat 页面（\(detail)）"
      ]
    )
  }
  queueTrace("task=\(task.id) stage=create-worker complete target=\(worker.targetId)")
  port = worker.port
  targetId = worker.targetId
  workerProfilePath = worker.profilePath
  if let previousConversationId {
    queueTrace(
      "task=\(task.id) stage=prepare-continuation begin "
        + "previousConversation=\(previousConversationId)"
    )
    let restoration = restoreHiddenConversation(
      port: worker.port,
      targetId: worker.targetId,
      conversationId: previousConversationId,
      allowVisible: queueTargetStateIsUsableForQueue(
        .visible,
        workerMode: state.queueWorkerMode
      ),
      dispatchMarker: "任务发送轮次：\(task.attempts)"
    )
    let restorationSucceeded = restoration["ok"] as? Bool == true
    let restoredConversationId = normalizedConversationId(
      restoration["conversationId"] as? String
    )
    let restorationStrategy = restoration["strategy"] as? String ?? "none"
    let markerConfirmedCurrentConversation = restorationStrategy == "current-dispatch-marker"
      && restoration["dispatchMarkerConfirmed"] as? Bool == true
    let continuationConversationId = markerConfirmedCurrentConversation
      ? restoredConversationId
      : previousConversationId
    let restorationMatchesExpectedConversation = restoredConversationId == previousConversationId
    if restorationSucceeded || restorationMatchesExpectedConversation {
      if !restorationSucceeded {
        queueTrace(
          "task=\(task.id) stage=prepare-continuation "
            + "route-failed-but-conversation-confirmed conversation=\(previousConversationId)"
        )
      }
      if markerConfirmedCurrentConversation,
         let continuationConversationId,
         continuationConversationId != previousConversationId {
        task.conversationId = continuationConversationId
        queueTrace(
          "task=\(task.id) stage=prepare-continuation "
            + "promoted-marker-conversation from=\(previousConversationId) "
            + "to=\(continuationConversationId)"
        )
      }
      prepared = cdpValue(
        port: worker.port,
        targetId: worker.targetId,
        expression: continueInNewTaskJS(expectedConversationId: continuationConversationId),
        timeout: 35.0
      )
    } else {
      prepared = [
        "ok": false,
        "error": restoration["error"] as? String
          ?? "continuation_conversation_click_failed",
        "conversationId": previousConversationId,
      ]
    }
    queueTrace(
        "task=\(task.id) stage=prepare-continuation "
        + "restored=\(restorationSucceeded || restorationMatchesExpectedConversation) "
        + "strategy=\(restorationStrategy) "
        + "restoredConversation=\(restoredConversationId ?? "none") "
        + "markerConfirmed=\(markerConfirmedCurrentConversation) "
        + "conversationClick=\(restoration["clickStrategy"] as? String ?? "none") "
        + "clicked=\(prepared?["continuationClicked"] as? Bool == true) "
        + "continuationLabel=\(prepared?["continuationLabel"] as? String ?? "none") "
        + "newConversation=\(prepared?["conversationId"] as? String ?? "none") "
        + "error=\(prepared?["error"] as? String ?? "none")"
    )
    if prepared?["ok"] as? Bool != true, preserveStalledChat {
      let firstError = prepared?["error"] as? String ?? "continuation_no_result"
      queueTrace(
        "task=\(task.id) stage=prepare-continuation branch-retry-after-stall "
          + "reason=\(firstError)"
      )
      _ = cdpValue(
        port: worker.port,
        targetId: worker.targetId,
        expression: stopCurrentResponseJS(),
        timeout: 15.0
      )
      Thread.sleep(forTimeInterval: 0.8)
      prepared = cdpValue(
        port: worker.port,
        targetId: worker.targetId,
        expression: continueInNewTaskJS(expectedConversationId: continuationConversationId),
        timeout: 35.0
      )
    }
    if prepared?["ok"] as? Bool != true {
      let continuationError = prepared?["error"] as? String ?? "continuation_no_result"
      let assistantResponseCount = prepared?["assistantResponseCount"] as? Int ?? -1
      if continuationError == "continue_in_new_task_button_not_found",
         assistantResponseCount == 0 {
        // A dispatch that created only a user bubble has no assistant turn to
        // branch from. Operator recovery may replace task.lastError, so use the
        // live CDP result as the source of truth and create a genuinely fresh
        // Chat while leaving the unanswered conversation untouched.
        queueTrace(
          "task=\(task.id) stage=prepare-continuation no-assistant-response "
            + "action=prepare-fresh-chat oldChat=preserved"
        )
        prepared = prepareNewChatTarget(
          port: worker.port,
          targetId: worker.targetId,
          timeout: 4.0,
          // The renderer can temporarily report zero mounted messages while
          // it is still routed to the unanswered durable conversation. Force
          // an actual New Chat click so the recovery prompt cannot be written
          // back into (or mistaken for) that stale 429 conversation.
          allowBlankConversationReuse: false
        )
        forceFullGoalPrompt = true
        if prepared?["ok"] as? Bool != true {
          preparationFailure = "fresh_chat_after_unanswered_dispatch_not_confirmed:"
            + (prepared?["error"] as? String ?? "unknown")
        }
      } else {
        preparationFailure = "same_task_branch_not_confirmed:\(continuationError)"
        let screenshot = captureHiddenChatScreenshot(
          port: worker.port,
          targetId: worker.targetId,
          label: "same-task-branch-failed"
        )
        queueTrace(
          "task=\(task.id) stage=prepare-continuation branch-required "
            + "reason=\(continuationError) "
            + "assistantResponses=\(assistantResponseCount) "
            + "screenshot=\(screenshot ?? "none") "
            + "action=retry-without-fresh-chat"
        )
        prepared = nil
      }
    }
  } else {
    if preserveStalledChat {
      queueTrace(
        "task=\(task.id) stage=prepare-fresh-chat-after-stall "
          + "previousConversation=\(previousConversationId ?? "none") oldChat=preserved"
      )
    }
    queueTrace("task=\(task.id) stage=prepare-new-chat begin")
    prepared = prepareNewChatTarget(
      port: worker.port,
      targetId: worker.targetId,
      timeout: 4.0,
      // `conversationId == nil` means a true first round (including an
      // updated goal). Force a real New Chat transition; an old renderer can
      // transiently report zero mounted messages and must not be reused.
      allowBlankConversationReuse: false
    )
  }
  guard let prepared,
        prepared["ok"] as? Bool == true,
        let port,
        let targetId else {
    throw NSError(
      domain: "chatgpt-auto-confirm",
      code: 22,
      userInfo: [
        NSLocalizedDescriptionKey:
          "无法为任务 \(task.id) 准备已登录 Chat（\(preparationFailure ?? "unknown")）"
      ]
    )
  }
  queueTrace(
    "task=\(task.id) stage=\(previousConversationId == nil ? "prepare-new-chat" : "prepare-continuation") complete"
  )
  let modelSelectionBeforeScreenshot = captureHiddenChatScreenshot(
    port: port,
    targetId: targetId,
    label: "model-selection-before"
  )
  queueTrace(
    "task=\(task.id) stage=model-selection-before "
      + "screenshot=\(modelSelectionBeforeScreenshot ?? "none")"
  )
  let attempt = task.attempts + 1
  // This round is now queue-owned again. Do not let a previous manual attach
  // or verified send authorize a different composer if this send fails.
  task.dispatchMarkerVerifiedAt = nil
  task.dispatchLocalConversationId = nil
  task.attachedConversationWithoutDispatchMarker = nil
  let outbound = messageWithTaskReportContract(
    automationTaskMessage(task, forceFullGoal: forceFullGoalPrompt),
    taskId: task.id,
    appliedRevision: task.currentRevision,
    appliedDigest: task.specDigest
  )
  task.appliedRevision = max(1, task.currentRevision ?? 1)
  task.appliedSpecDigest = task.specDigest
  task.pendingRevision = nil
  let dispatchMarker = "任务发送轮次：\(attempt)"
  queueTrace("task=\(task.id) stage=send begin")
  guard let sendResult = cdpValue(
    port: port,
    targetId: targetId,
    expression: sendMessageJS(
      message: outbound,
      connector: task.connector,
      newChat: false,
      expectedConversationId: normalizedConversationId(prepared["conversationId"] as? String),
      optionalConnectors: ["Gmail"]
    ),
    timeout: 65.0
  ) else {
    throw NSError(
      domain: "chatgpt-auto-confirm",
      code: 23,
      userInfo: [NSLocalizedDescriptionKey: "任务 \(task.id) 未能取得页面发送结果（CDP 上下文可能正在切换）"]
    )
  }
  guard sendResult["ok"] as? Bool == true else {
    let stage = sendResult["failedStage"] as? String ?? "unknown"
    let error = sendResult["error"] as? String ?? "unknown"
    let candidates = (sendResult["candidateTexts"] as? [String])?.joined(separator: ", ") ?? ""
    let stageDetails: String
    if let stages = sendResult["stages"],
       JSONSerialization.isValidJSONObject(stages),
       let data = try? JSONSerialization.data(withJSONObject: stages),
       let json = String(data: data, encoding: .utf8) {
      stageDetails = json
    } else {
      stageDetails = "[]"
    }
    let failureScreenshot = captureHiddenChatScreenshot(
      port: port,
      targetId: targetId,
      label: "model-selection-failed"
    )
    let pageDiagnostic = cdpValue(
      port: port,
      targetId: targetId,
      expression: pageDiagnosticJS(),
      timeout: 5.0
    )
    var failureEvidence = sendResult
    failureEvidence["screenshotPath"] = failureScreenshot as Any
    failureEvidence["modelSelectionBeforeScreenshot"] = modelSelectionBeforeScreenshot as Any
    failureEvidence["pageDiagnostic"] = pageDiagnostic as Any
    task.lastResultJSON = jsonString(failureEvidence)
    writeQueueConversationDiagnostic(task, finalReason: "start_failed")
    queueTrace(
      "task=\(task.id) stage=model-selection diagnostics "
        + "screenshot=\(failureScreenshot ?? "none") "
        + "beforeScreenshot=\(modelSelectionBeforeScreenshot ?? "none")"
    )
    throw NSError(
      domain: "chatgpt-auto-confirm",
      code: 23,
      userInfo: [
        NSLocalizedDescriptionKey: "任务 \(task.id) 页面发送失败（\(stage): \(error)） candidates: \(candidates) stages: \(stageDetails) screenshot: \(failureScreenshot ?? "none")"
      ]
    )
  }
  queueTrace(
    "task=\(task.id) stage=model-selection-confirmed "
      + "model=\(sendResult["model"] as? String ?? "unknown") "
      + "reasoning=\(sendResult["reasoning"] as? String ?? "unknown")"
  )
  var dispatchVerified = false
  var dispatchVerification: [String: Any] = [:]
  for _ in 0..<24 {
    if let verification = cdpValue(
      port: port,
      targetId: targetId,
      expression: verifyDispatchMarkerJS(dispatchMarker: dispatchMarker),
      timeout: 5.0
    ) {
      dispatchVerification = verification
      if verification["markerConfirmed"] as? Bool == true {
        dispatchVerified = true
        break
      }
    }
    Thread.sleep(forTimeInterval: 0.5)
  }
  guard dispatchVerified else {
    task.lastResultJSON = jsonString([
      "sendResult": sendResult,
      "dispatchVerification": dispatchVerification,
      "dispatchMarker": dispatchMarker,
    ])
    throw NSError(
      domain: "chatgpt-auto-confirm",
      code: 23,
      userInfo: [NSLocalizedDescriptionKey:
        "任务 \(task.id) 点击发送后未出现精确用户消息标记（\(dispatchMarker)）"]
    )
  }
  queueTrace("task=\(task.id) stage=send complete")
  _ = cdpValue(
    port: port,
    targetId: targetId,
    expression: autoConfirmChatContinuationJS(),
    timeout: 4.0
  )
  queueTrace("task=\(task.id) stage=resolve-conversation begin")
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
  Thread.sleep(forTimeInterval: 0.5)
  let liveStatus = cdpValue(
    port: port, targetId: targetId, expression: chatStatusJS(), timeout: 5.0
  ) ?? [:]
  // The freshly prepared blank Chat owns a stable local id before the sidebar
  // title appears. Prefer it over transitional active-row data after send.
  let conversationId = resolvedConversationId
    ?? (prepared["conversationId"] as? String)
    ?? (sendResult["conversationId"] as? String)
    ?? (liveStatus["conversationId"] as? String)
  guard let conversationId = normalizedConversationId(conversationId) else {
    throw NSError(
      domain: "chatgpt-auto-confirm",
      code: 32,
      userInfo: [NSLocalizedDescriptionKey: "任务 \(task.id) 已发送但未取得会话 ID"]
    )
  }

  let now = isoFormatter.string(from: Date())
  task.attempts = attempt
  task.status = "running"
  task.updatedAt = now
  task.startedAt = now
  task.finishedAt = nil
  task.workerPid = nil
  task.workerPort = port
  task.workerTargetId = targetId
  task.workerStatePath = nil
  task.workerProfilePath = workerProfilePath
  task.reviewConversationId = nil
  task.reviewStatus = nil
  task.reviewReport = nil
  task.resultPath = nil
  task.conversationId = conversationId
  task.dispatchMarkerVerifiedAt = now
  task.dispatchLocalConversationId = normalizedConversationId(
    prepared["conversationId"] as? String
  ) ?? normalizedConversationId(sendResult["conversationId"] as? String)
    ?? normalizedConversationId(liveStatus["portalConversationId"] as? String)
    ?? normalizedConversationId(liveStatus["conversationId"] as? String)
  task.attachedConversationWithoutDispatchMarker = nil
  task.chatURL = conversationId.hasPrefix("local-chatgpt:")
    ? nil
    : liveStatus["chatUrl"] as? String
  task.lastError = nil
  task.waitingUntil = nil
  task.waitReason = nil
  task.report = nil
  task.lastResultJSON = jsonString(sendResult)
  task.lastActivitySignature = nil
  task.lastProgressAt = now
  taskOwnsTarget = true
  queueTrace("task=\(task.id) stage=running conversation=\(conversationId)")
}

func terminateDedicatedChatProcess(profilePath: String) {
  guard profilePath.contains("/task-queue/workers/") else { return }

  func matchingProcessIds() -> [pid_t] {
    let chatProcessIds = dedicatedTaskWorkerProcessRecords()
      .filter { $0.profilePath == profilePath }
      .map(\.pid)
    return Array(Set(chatProcessIds + dedicatedTaskWorkerHelperProcessIds(profilePath: profilePath)))
      .sorted()
  }

  let trackedPorts = dedicatedQueueChatLaunchers.compactMap { port, launcher -> Int? in
    let marker = "--user-data-dir=\(profilePath)"
    return launcher.arguments?.contains(marker) == true ? port : nil
  }
  var processIds = matchingProcessIds()
  for pid in processIds where watcherIsAlive(pid) {
    _ = kill(pid, SIGTERM)
  }

  let gracefulDeadline = Date().addingTimeInterval(2.0)
  while Date() < gracefulDeadline {
    processIds = matchingProcessIds().filter { watcherIsAlive($0) }
    if processIds.isEmpty { break }
    Thread.sleep(forTimeInterval: 0.1)
  }

  processIds = matchingProcessIds().filter { watcherIsAlive($0) }
  if !processIds.isEmpty {
    queueTrace(
      "worker-create stage=dedicated-process-terminate-force "
        + "count=\(processIds.count)"
    )
    for pid in processIds {
      _ = kill(pid, SIGKILL)
    }
    let forcedDeadline = Date().addingTimeInterval(1.0)
    while Date() < forcedDeadline {
      processIds = matchingProcessIds().filter { watcherIsAlive($0) }
      if processIds.isEmpty { break }
      Thread.sleep(forTimeInterval: 0.1)
    }
  }

  for port in trackedPorts {
    dedicatedQueueChatLaunchers.removeValue(forKey: port)
  }
  dedicatedQueueChatLaunchers = dedicatedQueueChatLaunchers.filter { _, launcher in
    launcher.isRunning
  }

  let remaining = matchingProcessIds().filter { watcherIsAlive($0) }
  if remaining.isEmpty {
    try? FileManager.default.removeItem(atPath: profilePath)
    queueTrace("worker-create stage=dedicated-process-terminated")
  } else {
    queueTrace(
      "worker-create stage=dedicated-process-terminate-failed "
        + "count=\(remaining.count)"
    )
  }
}

func cleanupOrphanedDedicatedTaskWorkerArtifacts(
  _ state: PluginState,
  olderThan age: TimeInterval = 60.0 * 60.0
) {
  let workerDirectory = queueDirectoryURL().appendingPathComponent("workers", isDirectory: true)
  guard let entries = try? FileManager.default.contentsOfDirectory(
    at: workerDirectory,
    includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
    options: [.skipsHiddenFiles]
  ) else { return }

  let activeStatuses: Set<String> = ["running", "awaiting_review", "reviewing"]
  var protectedPaths = Set<String>()
  for task in state.automationTasks ?? [] where activeStatuses.contains(task.status) {
    if let profilePath = task.workerProfilePath,
       profilePath.contains("/task-queue/workers/") {
      protectedPaths.insert(URL(fileURLWithPath: profilePath).standardizedFileURL.path)
    }
  }
  if state.queueEnabled == true,
     state.queueWorkerMode != nil,
     let profilePath = state.queueWorkerProfilePath,
     profilePath.contains("/task-queue/workers/") {
    protectedPaths.insert(URL(fileURLWithPath: profilePath).standardizedFileURL.path)
  }

  let cutoff = Date().addingTimeInterval(-max(60.0, age))
  for entry in entries {
    guard let values = try? entry.resourceValues(
      forKeys: [.isDirectoryKey, .contentModificationDateKey]
    ),
          values.isDirectory == true,
          let modifiedAt = values.contentModificationDate,
          modifiedAt < cutoff else { continue }
    let profilePath = entry.standardizedFileURL.path
    guard !protectedPaths.contains(profilePath) else { continue }
    terminateDedicatedChatProcess(profilePath: profilePath)
  }
}

func stopAutomationWorker(_ task: AutomationTask, state: PluginState) {
  if let statePath = task.workerStatePath,
     let data = FileManager.default.contents(atPath: statePath),
     let workerState = try? decoder.decode(PluginState.self, from: data),
     watcherIsAlive(workerState.watcherPid),
     let pid = workerState.watcherPid {
    kill(pid, SIGTERM)
  }
  if state.queueWorkerMode != sharedConversationQueueWorkerMode,
     let targetId = task.workerTargetId {
    _ = CDPClient.closeTarget(targetId, portOverride: task.workerPort)
  }
  if let profilePath = task.workerProfilePath {
    terminateDedicatedChatProcess(profilePath: profilePath)
  }
}

func closeDedicatedAutomationTarget(
  _ task: AutomationTask,
  state: PluginState
) {
  // Parallel tasks own separate hidden windows, so a task may close only the
  // target recorded on that task. Keep the legacy shared-renderer guard for
  // queues created by an older runtime during migration.
  if state.queueWorkerMode != sharedConversationQueueWorkerMode,
     let targetId = task.workerTargetId {
    _ = CDPClient.closeTarget(targetId, portOverride: task.workerPort)
  }
  if state.queueWorkerMode == parallelDedicatedProcessQueueWorkerMode,
     let profilePath = task.workerProfilePath {
    terminateDedicatedChatProcess(profilePath: profilePath)
  }
}

func finishAutomationTask(_ task: inout AutomationTask, state: PluginState) {
  let now = isoFormatter.string(from: Date())
  defer {
    stopAutomationWorker(task, state: state)
    task.workerPid = nil
    task.updatedAt = now
    task.finishedAt = task.status == "queued" ? nil : now
  }
  guard let (raw, result) = decodeLastJSONLine(at: task.resultPath) else {
    if task.attempts <= task.maxRuntimeRetries {
      task.status = "queued"
      task.finishedAt = nil
      task.lastError = "worker_exited_without_result"
    } else {
      task.status = "failed"
      task.lastError = "worker_exited_without_result"
    }
    return
  }
  task.lastResultJSON = raw
  task.report = automationReport(result["taskReport"])
  task.conversationId = result["conversationId"] as? String
  task.chatURL = result["chatUrl"] as? String
  let taskStatus = result["taskStatus"] as? String ?? task.report?.status
  if result["ok"] as? Bool == true && taskStatus == "complete" {
    task.status = "awaiting_review"
    task.lastError = nil
    return
  }
  if taskStatus == "incomplete" || taskStatus == "blocked" {
    task.status = "blocked"
    task.lastError = result["message"] as? String
      ?? result["errorCode"] as? String
      ?? "任务总结报告未完成"
    return
  }
  if task.attempts <= task.maxRuntimeRetries {
    task.status = "queued"
    task.finishedAt = nil
    task.lastError = result["message"] as? String
      ?? result["errorCode"] as? String
      ?? "worker_runtime_failed"
  } else {
    task.status = "failed"
    task.lastError = result["message"] as? String
      ?? result["errorCode"] as? String
      ?? "worker_runtime_failed"
  }
}
