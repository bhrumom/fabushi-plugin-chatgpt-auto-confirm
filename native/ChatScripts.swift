import ApplicationServices
import Cocoa
import Darwin
import Foundation
import SystemConfiguration


// MARK: - CDP interaction JS scripts

func taskReportContract(
  taskId: String? = nil,
  appliedRevision: Int? = nil,
  appliedDigest: String? = nil
) -> String {
  let reportTaskId = jsonStringLiteral(taskId ?? "CURRENT_TASK_ID")
  let reportRevision = String(appliedRevision ?? 1)
  let reportDigest = jsonStringLiteral(appliedDigest ?? "CURRENT_SPEC_DIGEST")
  return """

MAHAYANA_TASK_REPORT_CONTRACT_V6
你是规划/验收 Chat，不是工作 Chat。请根据工作 Chat 的自然结果和当前 checkout 的实际状态决定下一步安排。
只有规划/验收 Chat 可以输出 MAHAYANA_TASK_REPORT_V1；工作 Chat 只输出自然语言结果。
必须在回复末尾输出一次且仅一次 MAHAYANA_TASK_REPORT_V1。完成时使用 status=complete、all_tasks_complete=true、remaining=[]、blockers=[]、next_task=""；未完成或被阻塞时使用 status=incomplete 或 blocked、all_tasks_complete=false，并把下一轮工作 Chat 要执行的完整安排写入 next_task。不要把规划说明或模板要求转发给工作 Chat。
MAHAYANA_TASK_REPORT_V1_BEGIN
{"protocol":"mahayana.task-report.v1","task_id":\(reportTaskId),"applied_task_revision":\(reportRevision),"applied_spec_digest":\(reportDigest),"status":"complete","all_tasks_complete":true,"summary":"整个目标已完成","completed":["列出实现、验证和发布证据"],"remaining":[],"blockers":[],"verification":["列出可复核证据"],"wait_seconds":0,"wait_reason":"","next_connector":"","next_task":""}
MAHAYANA_TASK_REPORT_V1_END
"""
}

func messageWithoutTaskReportContract(_ message: String) -> String {
  [
    "MAHAYANA_TASK_REPORT_CONTRACT_V6",
    "MAHAYANA_TASK_REPORT_CONTRACT_V5",
    "MAHAYANA_TASK_REPORT_V1_BEGIN",
  ]
  .reduce(message) { current, marker in
    guard let range = current.range(of: marker) else { return current }
    return String(current[..<range.lowerBound])
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
  .trimmingCharacters(in: .whitespacesAndNewlines)
}

func messageWithTaskReportContract(
  _ message: String,
  taskId: String? = nil,
  appliedRevision: Int? = nil,
  appliedDigest: String? = nil
) -> String {
  let goal = messageWithoutTaskReportContract(message)
  return goal + taskReportContract(
    taskId: taskId,
    appliedRevision: appliedRevision,
    appliedDigest: appliedDigest
  )
}

func acceptancePlannerMessage(
  originalGoal: String,
  workResult: String,
  taskId: String?,
  appliedRevision: Int?,
  appliedDigest: String?
) -> String {
  let goal = messageWithoutTaskReportContract(originalGoal)
  let result = messageWithoutTaskReportContract(workResult)
    .trimmingCharacters(in: .whitespacesAndNewlines)
  return """
  你是本轮任务的规划/验收 Chat。插件刚刚从一个独立的工作 Chat 收到自然语言结果。请读取同一 checkout 的最新落盘状态、项目记录和验证证据，判断原始目标是否真正完成，并决定下一轮是否需要继续。

  重要边界：你负责规划、验收和编排，不要代替工作 Chat 执行实现。你的回复必须按末尾的 MAHAYANA_TASK_REPORT_V1 模板输出；如果未完成或被阻塞，必须在 next_task 写出下一轮工作 Chat 应直接执行的安排。插件会把 next_task 原文发送给新的工作 Chat；工作 Chat 不会收到本模板。

  原始总目标 BEGIN
  \(goal)
  原始总目标 END

  工作 Chat 自然结果 BEGIN
  \(result)
  工作 Chat 自然结果 END

  当前任务标识：\(taskId ?? "CURRENT_TASK_ID")
  \(taskReportContract(
    taskId: taskId,
    appliedRevision: appliedRevision,
    appliedDigest: appliedDigest
  ))
  """
}

func continuationFromTaskReport(
  _ report: [String: Any], originalGoal: String, iteration: Int
) -> String {
  let nextTask = messageWithoutTaskReportContract(report["next_task"] as? String ?? "")
    .trimmingCharacters(in: .whitespacesAndNewlines)
  let summary = (report["summary"] as? String ?? "")
    .trimmingCharacters(in: .whitespacesAndNewlines)
  let blockers = (report["blockers"] as? [String] ?? [])
    .joined(separator: "；")
    .trimmingCharacters(in: .whitespacesAndNewlines)
  if !nextTask.isEmpty {
    var prompt = nextTask
    if !summary.isEmpty {
      prompt += "\n\n规划 Chat 上轮摘要（仅供工作 Chat 了解上下文）：\n\(summary)"
    }
    if !blockers.isEmpty {
      prompt += "\n\n需要处理的卡点：\n\(blockers)"
    }
    prompt += "\n\n这是第 \(iteration) 轮续作。请直接执行以上安排，并在回复中给出自然语言结果；不要输出 MAHAYANA_TASK_REPORT_V1。"
    return prompt
  }
  return "请从同一 checkout 的最新落盘进度继续原始目标，先检查尚未完成的步骤并直接执行。第 \(iteration) 轮续作。只输出自然语言工作结果，不要输出 MAHAYANA_TASK_REPORT_V1。\n\n原始目标：\n\(messageWithoutTaskReportContract(originalGoal))"
}

func relayFreshChatContinuation(_ params: [String: Any]) -> Never {
  guard JSONSerialization.isValidJSONObject(params),
        let data = try? JSONSerialization.data(withJSONObject: params),
        let json = String(data: data, encoding: .utf8) else {
    output([
      "ok": false,
      "errorCode": "task_continuation_encoding_failed",
      "message": "无法编码下一轮新 Chat 参数。",
    ], exitCode: 1)
  }
  let process = Process()
  process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
  process.arguments = ["send_and_watch", json]
  let stdoutPipe = Pipe()
  process.standardOutput = stdoutPipe
  process.standardError = FileHandle.standardError
  do {
    try process.run()
  } catch {
    output([
      "ok": false,
      "errorCode": "task_continuation_launch_failed",
      "message": error.localizedDescription,
    ], exitCode: 1)
  }
  while true {
    let chunk = stdoutPipe.fileHandleForReading.readData(ofLength: 4096)
    if chunk.isEmpty { break }
    FileHandle.standardOutput.write(chunk)
  }
  process.waitUntilExit()
  Foundation.exit(process.terminationStatus)
}

func jsEscape(_ text: String) -> String {
  text
    .replacingOccurrences(of: "\\", with: "\\\\")
    .replacingOccurrences(of: "\"", with: "\\\"")
    .replacingOccurrences(of: "\n", with: "\\n")
    .replacingOccurrences(of: "\r", with: "\\r")
    .replacingOccurrences(of: "\t", with: "\\t")
}

func verifySentMessageJS(message: String) -> String {
  let escapedMessage = jsEscape(message)
  return """
  (() => {
    const expected = "\(escapedMessage)".replace(/\\s+/g, ' ').trim();
    const web = [...document.querySelectorAll('[data-message-author-role="user"]')];
    const app = [...document.querySelectorAll('[data-user-message-bubble]')];
    const users = web.length > 0 ? web : app;
    const latest = users[users.length - 1];
    const actual = (latest?.innerText || '').replace(/\\s+/g, ' ').trim();
    const messageConfirmed = !!latest && (actual === expected || actual.includes(expected));
    return {
      ok: messageConfirmed,
      sent: messageConfirmed,
      inputConfirmed: true,
      connectorConfirmed: true,
      messageConfirmed,
      recoveredAfterExecutionContextLoss: messageConfirmed,
      failedStage: messageConfirmed ? null : 'message_confirmation',
      error: messageConfirmed ? null : 'message_send_not_confirmed',
      stages: [{
        stage: 'message_confirmation', ok: messageConfirmed,
        reboundAfterExecutionContextLoss: true,
        currentUserCount: users.length
      }],
      url: window.location.href || '',
      backgroundOnly: document.visibilityState === 'hidden',
      runtimeState: document.visibilityState === 'hidden' ? 'hidden' : 'visible',
      workerUsed: false,
      surface: 'chat'
    };
  })()
  """
}

func verifyDispatchMarkerJS(dispatchMarker: String) -> String {
  let escapedMarker = jsEscape(dispatchMarker)
  return """
  (() => {
    const marker = "\(escapedMarker)";
    const web = [...document.querySelectorAll('[data-message-author-role="user"]')];
    const appRows = [...document.querySelectorAll('[data-content-search-unit-key]')]
      .filter(node => (node.getAttribute('data-content-search-unit-key') || '').endsWith(':user'));
    const appBubbles = [...document.querySelectorAll('[data-user-message-bubble]')];
    const users = web.length > 0 ? web : (appRows.length > 0 ? appRows : appBubbles);
    const matching = users.filter(user =>
      (user.innerText || user.textContent || '').includes(marker)
    );
    const composer = document.querySelector(
      'form [contenteditable="true"][role="textbox"], #prompt-textarea'
    );
    const composerText = composer
      ? (composer.tagName === 'TEXTAREA' ? composer.value : composer.innerText || composer.textContent || '')
      : '';
    return {
      ok: matching.length > 0,
      markerConfirmed: matching.length > 0,
      matchingUserCount: matching.length,
      userMessageCount: users.length,
      composerStillContainsMarker: composerText.includes(marker)
    };
  })()
  """
}

func sendMessageJS(
  message: String,
  connector: String?,
  newChat: Bool = false,
  expectedConversationId: String? = nil,
  optionalConnectors: [String] = []
) -> String {
  let escapedMessage = jsEscape(message)
  let connectorPart: String
  if let connector, !connector.isEmpty {
    connectorPart = "\"\(jsEscape(connector))\""
  } else {
    connectorPart = "null"
  }
  let newChatBool = newChat ? "true" : "false"
  let expectedConversation = jsonStringLiteral(expectedConversationId ?? "")
  let optionalConnectorList = "[" + optionalConnectors
    .map(jsonStringLiteral)
    .joined(separator: ",") + "]"
  return """
  (async () => {
    const connector = \(connectorPart);
    const optionalConnectors = \(optionalConnectorList);
    const message = "\(escapedMessage)";
    const newChat = \(newChatBool);
    const expectedConversationId = \(expectedConversation);
    const result = {
      ok: false, sent: false, connectorAdded: false, error: null,
      url: window.location.href || '',
      backgroundOnly: document.visibilityState === 'hidden',
      runtimeState: document.visibilityState === 'hidden' ? 'hidden' : 'visible',
      workerUsed: false, surface: 'chat', failedStage: null,
      stages: [], inputConfirmed: false, connectorConfirmed: false,
      messageConfirmed: false
    };

    const visible = element => !!(element && (
      element.offsetWidth || element.offsetHeight || element.getClientRects().length
    ));
    const normalize = value => (value || '').replace(/\\s+/g, ' ').trim();
    const dispatchPointerClick = element => {
      const rect = element?.getBoundingClientRect?.();
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
      element.dispatchEvent(new PointerEvent('pointerdown', {
        ...pressed,
        pointerId: 1,
        pointerType: 'mouse',
        isPrimary: true
      }));
      element.dispatchEvent(new MouseEvent('mousedown', pressed));
      element.dispatchEvent(new PointerEvent('pointerup', {
        ...pressed,
        buttons: 0,
        pointerId: 1,
        pointerType: 'mouse',
        isPrimary: true
      }));
      element.dispatchEvent(new MouseEvent('mouseup', { ...pressed, buttons: 0 }));
      element.dispatchEvent(new MouseEvent('click', { ...pressed, buttons: 0 }));
    };
    const record = (stage, ok, details = {}) => {
      result.stages.push({ stage, ok, ...details });
      return ok;
    };
    const fail = (stage, error, details = {}) => {
      result.error = error;
      result.failedStage = stage;
      record(stage, false, details);
      return result;
    };

    function quickChatRoot() {
      return document.querySelector(
        '[data-pip-obstacle="quick-chat"], [data-quick-chat-drag-handle]'
      )?.closest('[role="dialog"], section, div') || null;
    }

    function findTextarea() {
      const quickRoot = quickChatRoot();
      return quickRoot
        ? quickRoot.querySelector('#prompt-textarea, [contenteditable="true"]')
        : document.querySelector('#prompt-textarea')
        || document.querySelector('[contenteditable="true"][data-placeholder]')
        || document.querySelector('[contenteditable="true"]');
    }

    function findSendButton() {
      const scope = quickChatRoot() || document;
      return scope.querySelector('[data-testid="send-button"]')
        || scope.querySelector('button[aria-label="Send prompt"]')
        || scope.querySelector('button[aria-label="发送"]');
    }

    function chatSurfaceEvidence() {
      const quickRoot = quickChatRoot();
      const scope = quickRoot || document;
      const modeControls = [...scope.querySelectorAll('button, [role="button"]')]
        .filter(visible)
        .map(button => normalize([
          button.textContent,
          button.getAttribute('aria-label'),
          button.getAttribute('title')
        ].filter(Boolean).join(' ')))
        .filter(label => /^(chat|work|聊天|工作)$|current mode|当前模式/i.test(label))
        .slice(0, 12);
      const relevantControls = [...scope.querySelectorAll('button, [role="button"]')]
        .filter(visible)
        .map(button => normalize([
          button.textContent,
          button.getAttribute('aria-label'),
          button.getAttribute('title'),
          button.getAttribute('data-testid')
        ].filter(Boolean).join(' ')))
        .filter(label => /model|模型|gpt|thinking|instant|high|medium|pro|reasoning|推理|项目|project|folder|文件夹|work/i.test(label))
        .slice(0, 32);
      return {
        url: window.location.href || '',
        quickChatRoot: !!quickRoot,
        hasInput: !!findTextarea(),
        workComposer: !!document.querySelector('[data-codex-composer="true"]'),
        chatMode: chatModeIsActive(),
        modeControls,
        relevantControls
      };
    }

    function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

    function inputText(el) {
      if (!el) return '';
      return el.tagName === 'TEXTAREA' || el.tagName === 'INPUT'
        ? (el.value || '')
        : (el.innerText || el.textContent || '');
    }

    function userMessages() {
      const scope = quickChatRoot() || document;
      const web = [...scope.querySelectorAll('[data-message-author-role="user"]')];
      const app = [...scope.querySelectorAll('[data-user-message-bubble]')];
      return web.length > 0 ? web : app;
    }

    function currentConversationId() {
      const raw = document.querySelector('[data-above-composer-conversation-id]')
        ?.getAttribute('data-above-composer-conversation-id') || '';
      return raw.startsWith('chatgpt:') ? raw.slice('chatgpt:'.length) : raw;
    }

    function conversationIsExpected() {
      return !expectedConversationId || currentConversationId() === expectedConversationId;
    }

    function userMessageIdentity(element, index) {
      const turn = element?.closest('[data-turn-key], [data-content-search-turn-key]');
      const unit = element?.closest('[data-content-search-unit-key]');
      return turn?.getAttribute('data-turn-key')
        || turn?.getAttribute('data-content-search-turn-key')
        || unit?.getAttribute('data-content-search-unit-key')
        || `${index}:${normalize(element?.innerText || '').slice(0, 256)}`;
    }

    const desiredModel = 'GPT-5.6 Sol';
    const desiredReasoning = 'Extra High';
    const desiredQuickChatReasoning = 'Extra High';

    function modelPickerButton() {
      const input = findTextarea();
      const send = findSendButton();
      const scope = quickChatRoot() || document;

      const controlLabel = button => normalize([
        button?.textContent,
        button?.getAttribute('aria-label'),
        button?.getAttribute('title'),
        button?.getAttribute('data-testid')
      ].filter(Boolean).join(' ')).toLowerCase();
      const isProjectPicker = button => {
        const label = controlLabel(button);
        return /(?:choose|select|new)\\s+project|project\\s+(?:source|folder)|source\\s+folders|add\\s+folders|选择项目|项目文件夹|源文件夹|添加文件夹|新建项目|创建项目/i.test(label);
      };
      const isAccountOrWorkspaceControl = button => {
        const label = controlLabel(button);
        return /workspace|profile|account|settings|teammates|成员|工作区|账户|账号|设置/i.test(label);
      };
      const isModelPickerLabel = button => {
        if (isProjectPicker(button) || isAccountOrWorkspaceControl(button)) return false;
        const label = controlLabel(button);
        return label.includes('chatgpt 模型')
          || /select chatgpt model/i.test(label)
          || label.includes('model selector')
          || label.includes('choose model')
          || label.includes('选择模型')
          || label.includes('intelligence')
          || label.includes('reasoning')
          || label.includes('推理')
          || label.includes('高')
          || label.includes('智能')
          // The hosted Chat renderer currently concatenates hidden model
          // labels into one button, e.g. "5.6 TerraExtra High5.6 SolMedium".
          // Word boundaries therefore miss "High5.6" and "SolMedium".
          || /(?:gpt|model|thinking|instant|high|medium|pro|terra|sol)/i.test(label);
      };

      const testIdButton = scope.querySelector('[data-testid="model-switcher"], [data-testid="composer-model-selector"], [data-testid="model-picker"], [data-testid="chat-model-selector"]');
      if (testIdButton && visible(testIdButton) && !isProjectPicker(testIdButton)) return testIdButton;

      const composer = input?.closest('form') || input?.parentElement?.parentElement;

      // Prefer an explicitly labelled model control. The composer can also contain
      // project/source pickers, so a generic aria-haspopup match is not sufficient.
      const explicit = [...scope.querySelectorAll(
        'button[aria-label], [role="button"][aria-label]'
      )].filter(button => {
        return visible(button) && button !== send && isModelPickerLabel(button);
      }).sort((left, right) => {
        const leftInComposer = composer?.contains(left) ? 0 : 1;
        const rightInComposer = composer?.contains(right) ? 0 : 1;
        if (leftInComposer !== rightInComposer) return leftInComposer - rightInComposer;
        const inputRect = input?.getBoundingClientRect();
        if (!inputRect) return 0;
        const l = left.getBoundingClientRect();
        const r = right.getBoundingClientRect();
        return Math.abs(inputRect.bottom - l.bottom) - Math.abs(inputRect.bottom - r.bottom);
      })[0] || null;
      if (explicit) return explicit;

      // Use includes() not === to handle buttons with extra SVG/icon text appended
      const textMatch = [...scope.querySelectorAll('button, [role="button"]')].find(button => {
        if (!visible(button) || button === send) return false;
        return isModelPickerLabel(button);
      });
      if (textMatch) return textMatch;

      // Only use a generic popup as a last resort, and only when its label still
      // looks like a model control. This prevents "Choose project" from opening
      // the project menu and being misreported as a missing Extra High-reasoning choice.
      const popupButton = [...(composer || document).querySelectorAll(
        '[aria-haspopup], [aria-haspopup="menu"], [aria-haspopup="listbox"], [aria-haspopup="true"]'
      )].find(button => visible(button) && button !== send && isModelPickerLabel(button));
      if (popupButton) return popupButton;

      const fallbackScope = composer || document.body;
      const candidates = [...fallbackScope.querySelectorAll(
        'button, [role="button"], [data-testid], [aria-haspopup="menu"]'
      )].filter(button => {
        if (!visible(button) || button === send) return false;
        if (isProjectPicker(button)) return false;
        return isModelPickerLabel(button);
      });
      return candidates.sort((left, right) => {
        const leftPopup = left.getAttribute('aria-haspopup') ? 0 : 1;
        const rightPopup = right.getAttribute('aria-haspopup') ? 0 : 1;
        if (leftPopup !== rightPopup) return leftPopup - rightPopup;
        return right.getBoundingClientRect().width - left.getBoundingClientRect().width;
      })[0] || null;
    }

    function visibleModelMenus() {
      const selectors = [
        '[role="menu"]', '[role="listbox"]', '[data-composer-overlay-floating-ui]',
        '[data-radix-menu-content]', '[data-radix-popper-content-wrapper]',
        '[data-state="open"]', '.popover'
      ].join(',');
      return [...document.querySelectorAll(selectors)].filter(visible);
    }

    function exactModelChoice(root, label) {
      const scope = root || document;
      const target = normalize(label).toLowerCase();
      const candidates = [...scope.querySelectorAll(
        'button, [role="menuitem"], [role="menuitemradio"], [role="option"], [data-list-navigation-item="true"]'
      )].filter(element => {
        if (!visible(element)) return false;
        const text = normalize(element.textContent).toLowerCase().replace(/>/g, '').trim();
        return text === target;
      });
      return candidates.sort((left, right) => {
        const l = left.getBoundingClientRect();
        const r = right.getBoundingClientRect();
        return (l.width * l.height) - (r.width * r.height);
      })[0] || null;
    }

    function allExactModelChoices(label) {
      const target = normalize(label).toLowerCase();
      return [...document.querySelectorAll(
        'button, [role="menuitem"], [role="menuitemradio"], [role="option"], [data-list-navigation-item="true"]'
      )].filter(element => {
        if (!visible(element)) return false;
        const text = normalize(element.textContent).toLowerCase().replace(/>/g, '').trim();
        return text === target;
      });
    }

    function allPrefixedModelChoices(label) {
      const target = normalize(label).toLowerCase();
      return [...document.querySelectorAll(
        'button, [role="menuitem"], [role="menuitemradio"], [role="option"], [data-list-navigation-item="true"]'
      )].filter(element => {
        if (!visible(element)) return false;
        const text = normalize(element.textContent).toLowerCase().replace(/>/g, '').trim();
        return text === target || text.startsWith(`${target} `);
      });
    }

    function quickChatLabel(picker) {
      return normalize([
        picker?.textContent,
        picker?.getAttribute('aria-label'),
        picker?.getAttribute('title')
      ].filter(Boolean).join(' ')).toLowerCase();
    }

    function quickChatStrongMode(value) {
      const text = normalize(value).toLowerCase().replace(/[-_]+/g, ' ');
      return text.includes('thinking')
        || text.includes('思考')
        || text.includes('extra high')
        || text.includes('极高')
        || text.includes('極高')
        || text.includes('额外高')
        || text.includes('額外高');
    }

    function desiredModelMentioned(value) {
      const text = normalize(value).toLowerCase();
      const exact = desiredModel.toLowerCase();
      const withoutGPTPrefix = exact.replace(/^gpt[-\\s]*/, '');
      return text.includes(exact)
        || (withoutGPTPrefix.length > 0 && text.includes(withoutGPTPrefix));
    }

    function visibleModelEvidenceText() {
      return visibleModelMenus()
        .map(menu => normalize([
          menu.textContent,
          menu.getAttribute('aria-label'),
          menu.getAttribute('title')
        ].filter(Boolean).join(' ')))
        .join(' ');
    }

    function quickChatSliderElements() {
      return [...document.querySelectorAll(
        '[data-reasoning-slider="true"], input[type="range"], [role="slider"], '
          + '[aria-valuenow], [aria-label*="of 5"], [aria-label*="adjust power"], '
          + '[aria-label*="调整强度"], [aria-label*="調整強度"], '
          + '[aria-label*="共 5 项"], [aria-label*="共5项"], '
          + '[aria-label*="共 5 項"], [aria-label*="共5項"]'
      )].filter((element, index, all) => {
        return element && all.indexOf(element) === index && visible(element);
      });
    }

    function quickChatIndexedState(element = null) {
      const candidates = [
        element,
        ...quickChatSliderElements(),
        document.activeElement
      ].filter((item, index, all) => item && all.indexOf(item) === index);
      for (const item of candidates) {
        const text = normalize([
          item.getAttribute?.('aria-label'),
          item.getAttribute?.('aria-valuetext'),
          item.textContent
        ].filter(Boolean).join(' ')).toLowerCase();
        const english = text.match(/(?:^|\\s)(\\d+)\\s*(?:of|\\/)\\s*(\\d+)(?:\\s|$)/i);
        const chinese = text.match(/第\\s*(\\d+)\\s*[项項][，,\\s]*共\\s*(\\d+)\\s*[项項]/);
        const match = english || chinese;
        if (!match) continue;
        const position = Number(match[1]);
        const total = Number(match[2]);
        if (!Number.isFinite(position) || !Number.isFinite(total) || total < 2) continue;
        return {element: item, position, total, text};
      }
      return null;
    }

    function quickChatSliderState(element = null) {
      const candidates = [
        element,
        ...(element?.querySelectorAll?.('[role="slider"], [aria-valuenow]') || []),
        ...quickChatSliderElements()
      ].filter((item, index, all) => item && all.indexOf(item) === index);
      const slider = candidates.find(item => item.getAttribute('aria-valuenow') != null);
      if (slider) {
        const now = Number(slider.getAttribute('aria-valuenow'));
        const min = Number(slider.getAttribute('aria-valuemin'));
        const max = Number(slider.getAttribute('aria-valuemax'));
        return {
          element: slider,
          now: Number.isFinite(now) ? now : null,
          min: Number.isFinite(min) ? min : null,
          max: Number.isFinite(max) ? max : null,
          ariaValueText: slider.getAttribute('aria-valuetext') || ''
        };
      }
      // The localized ChatGPT 5.6 picker may expose only accessibility text
      // such as "1 of 5" or "第 1 项，共 5 项" instead of aria-valuenow.
      // Normalize that 1-based position to the same 0..max state used by the
      // Radix slider path so Extra High remains the penultimate position.
      const indexed = quickChatIndexedState(element);
      if (!indexed) return null;
      return {
        element: indexed.element,
        now: indexed.position - 1,
        min: 0,
        max: indexed.total - 1,
        ariaValueText: indexed.text,
        indexedOnly: true
      };
    }

    function quickChatSelectionConfirmed(picker, keyboardTarget = null) {
      const pickerValues = [
        quickChatLabel(picker),
        picker?.getAttribute('data-selected-reasoning-effort') || '',
        picker?.getAttribute('data-selected-model') || ''
      ];
      if (quickChatStrongMode(pickerValues.join(' '))) return true;
      const sliderState = quickChatSliderState(keyboardTarget);
      // ChatGPT's five-position control is exposed as a 0..4 Radix slider;
      // Extra High is the penultimate position (the final one is Pro).
      return sliderState?.indexedOnly !== true
        && sliderState?.max != null
        && sliderState?.now != null
        && sliderState.max >= 2
        && sliderState.now === sliderState.max - 1;
    }

    function quickChatElementEvidence(element) {
      if (!element) return null;
      const rect = element.getBoundingClientRect?.();
      return {
        tag: element.tagName || '',
        type: element.getAttribute('type') || '',
        role: element.getAttribute('role') || '',
        ariaLabel: element.getAttribute('aria-label') || '',
        ariaValueNow: element.getAttribute('aria-valuenow') || '',
        ariaValueMin: element.getAttribute('aria-valuemin') || '',
        ariaValueMax: element.getAttribute('aria-valuemax') || '',
        ariaValueText: element.getAttribute('aria-valuetext') || '',
        tabIndex: element.getAttribute('tabindex') || '',
        value: element.value == null ? '' : String(element.value),
        selected: selectedChoice(element),
        text: normalize(element.textContent).slice(0, 500),
        outerHTML: (element.outerHTML || '').replace(/\\s+/g, ' ').slice(0, 900),
        rect: rect ? {
          x: Math.round(rect.x), y: Math.round(rect.y),
          width: Math.round(rect.width), height: Math.round(rect.height)
        } : null
      };
    }

    function quickChatSelectionEvidence() {
      const active = document.activeElement;
      const menus = visibleModelMenus().map(menu => ({
        tag: menu.tagName || '',
        role: menu.getAttribute('role') || '',
        text: normalize(menu.textContent).slice(0, 1200),
        items: [...menu.querySelectorAll(
          'button, [role="option"], [role="menuitem"], [role="menuitemradio"], '
            + 'input, [role="slider"], [aria-valuenow]'
        )].filter(visible).slice(0, 30).map(quickChatElementEvidence)
      }));
      return {
        activeElement: quickChatElementEvidence(active),
        sliders: quickChatSliderElements().slice(0, 20).map(quickChatElementEvidence),
        picker: quickChatElementEvidence(modelPickerButton()),
        menus,
        visibleText: normalize(document.body?.innerText || '').slice(0, 5000)
      };
    }

    function quickChatKeyboardTarget() {
      const candidates = [
        ...quickChatSliderElements(),
        document.activeElement,
        ...document.querySelectorAll(
          '[role="slider"], [aria-valuenow], [aria-label*="of 5"], '
            + '[aria-label*="adjust power"], [aria-label*="调整强度"], '
            + '[tabindex], button, [role="button"]'
        )
      ].filter((element, index, all) => element && all.indexOf(element) === index);
      return candidates.find(element => {
        if (!visible(element)) return false;
        const label = quickChatLabel(element);
        return /(?:of 5|adjust power|调整强度|power|model|effort|instant|thinking|extra high|高|思考)/i.test(label);
      }) || null;
    }

    function dispatchQuickChatArrowRight(element) {
      if (!element) return false;
      element.focus?.();
      const event = {
        bubbles: true,
        cancelable: true,
        key: 'ArrowRight',
        code: 'ArrowRight',
        keyCode: 39,
        which: 39
      };
      const keyDown = new KeyboardEvent('keydown', event);
      const keyPress = new KeyboardEvent('keypress', event);
      const keyUp = new KeyboardEvent('keyup', event);
      // Chromium ignores keyCode/which in the KeyboardEvent constructor. Some
      // Electron builds still use those legacy fields in their React handler,
      // so define them explicitly before dispatching the synthetic event.
      for (const keyboardEvent of [keyDown, keyPress, keyUp]) {
        for (const [name, value] of [['keyCode', 39], ['which', 39]]) {
          try { Object.defineProperty(keyboardEvent, name, {value}); } catch {}
        }
      }
      element.dispatchEvent(keyDown);
      element.dispatchEvent(keyPress);
      element.dispatchEvent(keyUp);
      return true;
    }

    function dispatchQuickChatEnter(element) {
      if (!element) return false;
      element.focus?.();
      const event = {bubbles: true, cancelable: true, key: 'Enter', code: 'Enter'};
      const keyDown = new KeyboardEvent('keydown', event);
      const keyUp = new KeyboardEvent('keyup', event);
      for (const keyboardEvent of [keyDown, keyUp]) {
        for (const [name, value] of [['keyCode', 13], ['which', 13]]) {
          try { Object.defineProperty(keyboardEvent, name, {value}); } catch {}
        }
      }
      element.dispatchEvent(keyDown);
      element.dispatchEvent(keyUp);
      return true;
    }

    function selectedChoice(element) {
      if (!element) return false;
      const selectedValues = [
        element.getAttribute('aria-checked'),
        element.getAttribute('aria-selected'),
        element.getAttribute('data-selected'),
        element.getAttribute('data-active'),
        element.getAttribute('data-state')
      ].map(value => (value || '').toLowerCase());
      return selectedValues.some(value => ['true', 'checked', 'on', 'selected'].includes(value))
        || !!element.querySelector(
          '[aria-checked="true"], [aria-selected="true"], [data-state="checked"], [data-selected="true"]'
        );
    }

    async function ensureModelAndReasoning() {
      // Dismiss promotional modals before looking for the model picker. The
      // desktop app can show localized Fast-mode announcements over a newly
      // created Chat; their buttons otherwise look like the only open menu.
      const neutralPromoLabels = new Set([
        'try gpt-5.6 sol now', 'okay', 'got it',
        'use standard speed', 'continue with standard speed',
        '使用标准速度', '使用標準速度',
        'not now', 'maybe later', '暂不', '暫不', '以后再说', '稍後再說'
      ]);
      for (let attempt = 0; attempt < 3; attempt += 1) {
        const promoButton = [...document.querySelectorAll('button')].find(btn => {
          const text = normalize([
            btn.textContent,
            btn.getAttribute('aria-label'),
            btn.getAttribute('title')
          ].filter(Boolean).join(' ')).toLowerCase();
          return visible(btn) && neutralPromoLabels.has(text);
        });
        if (!promoButton) break;
        promoButton.click();
        await sleep(600);
      }
      let picker = null;
      for (let i = 0; i < 40; i++) {
        picker = modelPickerButton();
        if (picker) break;
        await sleep(100);
      }
      if (!picker) {
        return {
          ok: false,
          error: 'model_picker_not_found',
          model: desiredModel,
          reasoning: desiredReasoning,
          modelConfirmed: false,
          reasoningConfirmed: false,
          surface: chatSurfaceEvidence()
        };
      }
      const pickerBefore = normalize([
        picker.textContent,
        picker.getAttribute('aria-label'),
        picker.getAttribute('title')
      ].filter(Boolean).join(' '));
      // The web Chat shell exposes a workspace/profile trigger beside the
      // composer. Its label can contain words such as "business" and was
      // occasionally selected as the model picker by generic fallbacks.
      // Prefer the explicit Extra High/model control when that happens.
      if (/workspace|profile|account|business/i.test(pickerBefore)) {
        const explicitModel = [...document.querySelectorAll(
          'button, [role="button"], [role="tab"]'
        )].find(candidate => {
          if (!visible(candidate)) return false;
          const label = normalize([
            candidate.textContent,
            candidate.getAttribute('aria-label'),
            candidate.getAttribute('title')
          ].filter(Boolean).join(' ')).toLowerCase();
          return label === 'extra high'
            || label === '极高'
            || label.includes(desiredModel.toLowerCase());
        });
        if (explicitModel) picker = explicitModel;
      }
      let selectedLabel = normalize(picker.textContent).toLowerCase();
      // Desktop Quick Chat is the authenticated orchestration surface. It
      // exposes ChatGPT choices such as Instant/Extra High, not the Codex
      // GPT-5.6 Sol reasoning menu. Require its strongest reasoning choice
      // before sending, while the task contract separately requires downstream
      // Codex/devspace execution to use GPT-5.6 Sol / Extra High.
      const pickerEvidenceText = normalize([
        pickerBefore,
        selectedLabel,
        visibleModelEvidenceText()
      ].filter(Boolean).join(' ')).toLowerCase();
      const quickChatModelSurface = !!quickChatRoot()
        || ['instant', 'thinking', 'pro', 'extra high', 'high', 'medium', '极高', '極高', '额外高', '額外高', '极速', '快速', '思考', '专业', '專業'].some(label =>
          pickerEvidenceText.includes(label)
        )
        || pickerEvidenceText.includes('推理强度')
        || pickerEvidenceText.includes('推理強度')
        || pickerEvidenceText.includes('of 5')
        || pickerEvidenceText.includes('共 5 项')
        || pickerEvidenceText.includes('共5项');
      if (quickChatModelSurface) {
        let quickChatChoiceClicked = false;
        let quickChatKeyboardAttempts = 0;
        let quickChatKeyboardTargetLabel = '';
        let quickChatConfirmed = selectedLabel === 'extra high'
          || selectedLabel === '极高'
          || selectedLabel.startsWith('extra high ')
          || selectedLabel === 'extra\\u00a0high'
          || selectedLabel === '额外高'
          || selectedLabel.startsWith('extra\\u00a0high ');
        // The compact trigger displays only the reasoning label (for example,
        // "极高"). Open it every round and require the model row to explicitly
        // name GPT-5.6 Sol; reasoning strength alone is not model evidence.
        let quickChatModelConfirmed = desiredModelMentioned(pickerEvidenceText);
        if (!quickChatModelConfirmed) {
          dispatchPointerClick(picker);
          await sleep(500);
          quickChatModelConfirmed = desiredModelMentioned(visibleModelEvidenceText());
        }
        if (!quickChatConfirmed) {
          // The desktop ChatGPT model switcher is a Radix trigger that opens
          // on pointerdown; HTMLElement.click() alone leaves the menu closed.
          dispatchPointerClick(picker);
          await sleep(500);
          // Some desktop builds expose Thinking as a normal menu item; newer
          // builds expose the same control as a five-position model/effort
          // slider whose only accessible text says "1 of 5". Try the stable
          // menu item first, then use the control's documented ArrowRight
          // interaction and rediscover the picker after every navigation.
          const quickChatChoice = [
            ...allPrefixedModelChoices('Thinking'),
            ...allPrefixedModelChoices('思考'),
            ...allPrefixedModelChoices('Extra High'),
            ...allPrefixedModelChoices('极高'),
            ...allPrefixedModelChoices('Extra\\u00a0High'),
            ...allPrefixedModelChoices('额外高')
          ][0] || null;
          if (quickChatChoice) {
            if (!selectedChoice(quickChatChoice)) quickChatChoice.click();
            quickChatChoiceClicked = true;
            await sleep(350);
          }
          picker = modelPickerButton();
          selectedLabel = quickChatLabel(picker);
          quickChatConfirmed = quickChatSelectionConfirmed(picker)
            || selectedChoice(quickChatChoice);
          const initialKeyboardTarget = quickChatKeyboardTarget() || picker;
          const initialSliderState = quickChatSliderState(initialKeyboardTarget);
          const desiredSliderSteps = initialSliderState?.indexedOnly === true
            ? 6
            : initialSliderState?.max != null && initialSliderState?.now != null
              ? Math.max(0, Math.min(6, initialSliderState.max - 1 - initialSliderState.now))
              : 6;
          for (let attempt = 0; attempt < desiredSliderSteps && !quickChatConfirmed; attempt += 1) {
            if (visibleModelMenus().length === 0) {
              picker = modelPickerButton();
              if (picker) {
                dispatchPointerClick(picker);
                await sleep(250);
              }
            }
            const keyboardTarget = quickChatKeyboardTarget() || picker;
            quickChatKeyboardTargetLabel = quickChatLabel(keyboardTarget).slice(0, 240);
            if (!dispatchQuickChatArrowRight(keyboardTarget)) break;
            quickChatKeyboardAttempts += 1;
            await sleep(450);
            picker = modelPickerButton();
            selectedLabel = quickChatLabel(picker);
            quickChatConfirmed = quickChatSelectionConfirmed(picker, keyboardTarget);
          }
          if (!quickChatConfirmed) {
            // The five-position control commits its value on Enter in some
            // desktop builds. Keep the menu open while committing so the
            // subsequent evidence shows the exact active control and value.
            const keyboardTarget = quickChatKeyboardTarget() || picker;
            dispatchQuickChatEnter(keyboardTarget);
            await sleep(500);
            picker = modelPickerButton();
            selectedLabel = quickChatLabel(picker);
            quickChatConfirmed = quickChatSelectionConfirmed(picker, keyboardTarget);
          }
        }
        if (!quickChatConfirmed) {
          return {
            ok: false,
            error: 'quick_chat_thinking_not_selected',
            model: desiredModel,
            reasoning: desiredQuickChatReasoning,
            modelConfirmed: false,
            reasoningConfirmed: false,
            pickerBefore,
            selectedLabel,
            quickChatChoiceClicked,
            quickChatKeyboardAttempts,
            quickChatKeyboardTargetLabel,
            visibleMenuText: visibleModelMenus()
              .map(menu => normalize(menu.textContent).slice(0, 500)),
            modelSelectionEvidence: quickChatSelectionEvidence(),
            surface: chatSurfaceEvidence()
          };
        }
        if (!quickChatModelConfirmed) {
          return {
            ok: false,
            error: 'quick_chat_target_model_not_selected',
            model: desiredModel,
            reasoning: desiredQuickChatReasoning,
            modelConfirmed: false,
            reasoningConfirmed: true,
            pickerBefore,
            selectedLabel,
            visibleMenuText: visibleModelMenus()
              .map(menu => normalize(menu.textContent).slice(0, 500)),
            modelSelectionEvidence: quickChatSelectionEvidence(),
            surface: chatSurfaceEvidence()
          };
        }
        // Do not leave the model menu covering the connector menu.
        if (visibleModelMenus().length > 0) {
          picker = modelPickerButton();
          if (picker?.getAttribute('data-state') === 'open') {
            dispatchPointerClick(picker);
            await sleep(200);
          }
        }
        return {
          ok: true,
          model: desiredModel,
          reasoning: desiredQuickChatReasoning,
          modelConfirmed: true,
          reasoningConfirmed: true,
          pickerBefore,
          selectedLabel,
          pickerEvidence: quickChatKeyboardAttempts > 0
            ? 'quick-chat-thinking-keyboard-selection'
            : 'quick-chat-extra-high-selection',
          quickChatChoiceClicked,
          quickChatKeyboardAttempts,
          quickChatKeyboardTargetLabel,
          modelSelectionEvidence: quickChatSelectionEvidence(),
          verificationModelSelected: true,
          submenuExtraHighSelected: true,
          submenuHighSelected: true,
          downstreamModel: desiredModel,
          downstreamReasoning: desiredReasoning
        };
      }
      let reasoningConfirmed = selectedLabel === 'extra high'
        || selectedLabel === '极高'
        || selectedLabel.startsWith('extra high ');
      let modelConfirmed = pickerBefore.toLowerCase().includes(desiredModel.toLowerCase());
      let modelChoiceClicked = false;
      let highChoiceClicked = false;

      if (!reasoningConfirmed || !modelConfirmed) {
        dispatchPointerClick(picker);
        await sleep(500);

        let modelChoice = allExactModelChoices(desiredModel).find(choice =>
          visibleModelMenus().some(menu => menu.contains(choice))
        ) || allExactModelChoices(desiredModel)[0] || null;
        if (modelChoice) {
          if (!selectedChoice(modelChoice)) modelChoice.click();
          modelChoiceClicked = true;
          modelConfirmed = true;
          await sleep(350);
        }

        let highChoice = [
          ...allExactModelChoices('Extra High'),
          ...allExactModelChoices('极高'),
          ...allExactModelChoices('额外高')
        ].find(choice =>
          visibleModelMenus().some(menu => menu.contains(choice))
        ) || null;
        if (!highChoice) {
          const reasoningBtn = [...document.querySelectorAll('button')].find(b => {
             const t = normalize(b.textContent).toLowerCase();
             const a = normalize(b.getAttribute('aria-label')).toLowerCase();
             return t.includes('reasoning') || a.includes('reasoning') || t.includes('推理') || a.includes('推理');
          });
          if (reasoningBtn) {
             reasoningBtn.click();
          } else {
             picker = modelPickerButton();
             picker?.click();
          }
          await sleep(400);
          highChoice = [
            ...allExactModelChoices('Extra High'),
            ...allExactModelChoices('极高'),
            ...allExactModelChoices('额外高')
          ].find(choice =>
            visibleModelMenus().some(menu => menu.contains(choice))
          ) || null;
        }
        if (highChoice) {
          if (!selectedChoice(highChoice)) highChoice.click();
          highChoiceClicked = true;
          await sleep(350);
        }

        // New localized GPT-5.6 picker: the menu exposes the model and
        // reasoning slider as a single composite row (for example
        // "5.6 Sol 推理强度中") and no longer renders an Extra High button.
        // Use the same keyboard interaction as the accessibility slider,
        // but only confirm after the visible strength label changes.
        if (!highChoiceClicked) {
          const menuText = visibleModelEvidenceText().toLowerCase();
          if (menuText.includes('推理强度') || menuText.includes('reasoning strength')) {
            const target = quickChatKeyboardTarget() || picker;
            for (let attempt = 0; attempt < 6 && !reasoningConfirmed; attempt += 1) {
              dispatchQuickChatArrowRight(target);
              await sleep(350);
              const evidence = visibleModelEvidenceText().toLowerCase();
              reasoningConfirmed = quickChatStrongMode(evidence);
            }
          }
        }

        picker = modelPickerButton();
        const pickerAfter = normalize([
          picker?.textContent,
          picker?.getAttribute('aria-label'),
          picker?.getAttribute('title')
        ].filter(Boolean).join(' '));
        selectedLabel = normalize(picker?.textContent).toLowerCase();
        reasoningConfirmed = selectedLabel === 'extra high'
          || selectedLabel === '极高'
          || selectedLabel === '额外高'
          || selectedLabel.startsWith('extra high ')
          || selectedChoice(highChoice)
          || highChoiceClicked;
        modelConfirmed = modelConfirmed
          || pickerAfter.toLowerCase().includes(desiredModel.toLowerCase());
      }
      if (!reasoningConfirmed) {
        return {
          ok: false,
          error: 'reasoning_high_not_selected',
          model: desiredModel,
          reasoning: desiredReasoning,
          modelConfirmed,
          reasoningConfirmed: false,
          pickerBefore,
          selectedLabel,
          modelChoiceClicked,
          highChoiceClicked,
          visibleMenuText: visibleModelMenus()
            .map(menu => normalize(menu.textContent).slice(0, 500)),
          surface: chatSurfaceEvidence()
        };
      }
      if (!modelConfirmed) {
        return {
          ok: false,
          error: 'target_model_not_selected',
          model: desiredModel,
          reasoning: desiredReasoning,
          modelConfirmed: false,
          reasoningConfirmed: true,
          pickerBefore,
          selectedLabel,
          modelChoiceClicked,
          highChoiceClicked,
          visibleMenuText: visibleModelMenus()
            .map(menu => normalize(menu.textContent).slice(0, 500)),
          surface: chatSurfaceEvidence()
        };
      }

      return {
        ok: true,
        model: desiredModel,
        reasoning: desiredReasoning,
        modelConfirmed,
        reasoningConfirmed: true,
        pickerBefore,
        selectedLabel,
        pickerEvidence: 'selected_button_state',
        verificationModelSelected: modelConfirmed,
        submenuExtraHighSelected: highChoiceClicked || reasoningConfirmed,
        submenuHighSelected: highChoiceClicked || reasoningConfirmed
      };
    }

    function connectorMatches(value, target) {
      const text = normalize(value).toLowerCase();
      const needle = normalize(target).toLowerCase();
      if (!text || !needle) return false;
      if (text.includes(needle)) return true;
      const compactText = text.replace(/[^a-z0-9\\u4e00-\\u9fff]/g, '');
      const compactNeedle = needle.replace(/[^a-z0-9\\u4e00-\\u9fff]/g, '');
      return compactNeedle.length >= 3 && compactText.includes(compactNeedle);
    }

    function connectorEvidence(target) {
      const input = findTextarea();
      const composer = input?.closest('form') || input?.parentElement?.parentElement;
      const composerMatches = [...(composer?.querySelectorAll(
        'button[aria-label], [aria-checked="true"], [data-state="checked"], [data-state="on"], '
          + '[data-selected="true"], [data-active="true"], [data-connector-id], [data-app-name], '
          + '[data-prompt-link-label], [data-prompt-link-href]'
      ) || [])].filter(element => {
        const evidence = [
          element.getAttribute('aria-label'), element.getAttribute('title'),
          element.getAttribute('data-testid'), element.getAttribute('data-connector-id'),
          element.getAttribute('data-app-name'), element.getAttribute('data-prompt-link-label'),
          element.getAttribute('data-prompt-link-href'), element.textContent
        ].filter(Boolean).join(' ').toLowerCase();
        return visible(element) && connectorMatches(evidence, target);
      });
      const checkedMenuMatches = [...document.querySelectorAll(
        '[role="menuitemradio"][aria-checked="true"], [role="option"][aria-selected="true"], '
          + '[role="menuitem"][data-state="checked"], [role="menuitem"][data-selected="true"]'
      )].filter(element => connectorMatches(element.textContent, target));
      const inlineMentionMatches = [...(input?.querySelectorAll(
        'span, a, [data-lexical-decorator], [data-mention-id], [data-connector-id], [data-app-name], '
          + '[data-prompt-link-label], [data-prompt-link-href]'
      ) || [])].filter(element => {
        return visible(element)
          && !element.closest('[data-composer-overlay-floating-ui]')
          && connectorMatches(element.textContent, target);
      });
      // The desktop Chat renderer exposes a selected app as a plain text chip
      // directly above the prompt, without a stable role or checked attribute.
      // Confirm that chip by exact text and its geometry relative to the prompt;
      // this keeps historical mentions of the connector out of the evidence.
      const promptRect = input?.getBoundingClientRect();
      const nearbyExactMatches = promptRect ? [...document.querySelectorAll(
        'button, [role="button"], [role="option"], [data-state], span, div'
      )].filter(element => {
        if (!visible(element) || !connectorMatches(element.textContent, target)) return false;
        if (element.closest('[role="menu"], [role="listbox"], [role="option"]')) return false;
        const rect = element.getBoundingClientRect();
        const overlapsPromptHorizontally = rect.right >= promptRect.left
          && rect.left <= promptRect.right;
        const isInComposerBand = rect.top >= promptRect.top - 220
          && rect.bottom <= promptRect.bottom + 24;
        return overlapsPromptHorizontally && isInComposerBand;
      }) : [];
      // In the current web Chat surface the selected app can be rendered as a
      // standalone chip/button outside the composer form (and outside the
      // menu), with only its app label exposed.  Treat that stable selected
      // control as evidence too; do not count menu options that are merely
      // available for selection.
      const standaloneSelectedMatches = [...document.querySelectorAll(
        '[data-connector-id], [data-app-name], button[aria-label], [role="button"]'
      )].filter(element => {
        if (!visible(element) || !connectorMatches([
          element.getAttribute('aria-label'), element.getAttribute('title'),
          element.getAttribute('data-testid'), element.getAttribute('data-connector-id'),
          element.getAttribute('data-app-name'), element.textContent
        ].filter(Boolean).join(' '), target)) return false;
        if (element.closest('[role="menu"], [role="listbox"], [role="option"]')) return false;
        return element.closest('form')
          || element.getAttribute('aria-pressed') === 'true'
          || element.getAttribute('aria-checked') === 'true'
          || element.getAttribute('data-state') === 'checked'
          || element.getAttribute('data-state') === 'on'
          || element.getAttribute('data-selected') === 'true'
          || element.getAttribute('data-active') === 'true';
      });
      return [...composerMatches, ...checkedMenuMatches, ...inlineMentionMatches,
        ...nearbyExactMatches, ...standaloneSelectedMatches];
    }

    function chatModeIsActive() {
      const quickRoot = quickChatRoot();
      const workComposer = !quickRoot
        && !!document.querySelector('[data-codex-composer="true"]');
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
      const chatModel = [...document.querySelectorAll('button')].some(button => {
        const label = button.getAttribute('aria-label') || '';
        return label.includes('ChatGPT 模型') || /select chatgpt model/i.test(label);
      });
      const webChat = window.location.protocol === 'https:'
        && window.location.hostname === 'chatgpt.com';
      // The desktop app can leave the Work composer mounted while a stale
      // ChatGPT flag or model label is still present. Work must never pass as
      // Chat: the top-level Chat/Work switch is authoritative here.
      return (!!quickRoot || currentChatGPTMode || chatModel || webChat)
        && !!findTextarea() && !workComposer;
    }

    function replaceText(el, text) {
      el.focus();
      if (el.tagName === 'TEXTAREA' || el.tagName === 'INPUT') {
        const nativeInputValueSetter = Object.getOwnPropertyDescriptor(
          window.HTMLTextAreaElement.prototype, 'value')?.set
          || Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value')?.set;
        if (nativeInputValueSetter) {
          nativeInputValueSetter.call(el, text);
          el.dispatchEvent(new Event('input', { bubbles: true }));
        } else {
          el.value = text;
          el.dispatchEvent(new Event('input', { bubbles: true }));
        }
      } else {
        const selection = window.getSelection();
        if (selection) {
          selection.removeAllRanges();
          const range = document.createRange();
          range.selectNodeContents(el);
          selection.addRange(range);
        }
        const inserted = document.execCommand('insertText', false, text);
        if (!inserted || normalize(inputText(el)) !== normalize(text)) {
          el.textContent = text;
        }
        el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: text }));
      }
    }

    function appendTextPreservingConnector(el, text) {
      el.focus();
      const selection = window.getSelection();
      if (!selection) return false;
      selection.removeAllRanges();
      const range = document.createRange();
      range.selectNodeContents(el);
      range.collapse(false);
      selection.addRange(range);
      const inserted = document.execCommand('insertText', false, ` ${text}`);
      el.dispatchEvent(new InputEvent('input', {
        bubbles: true, inputType: 'insertText', data: ` ${text}`
      }));
      return inserted;
    }

    if (!chatModeIsActive()) {
      return fail('chat_surface', 'not_chatgpt_chat_mode', {
        hasInput: !!findTextarea(), workComposer: !!document.querySelector('[data-codex-composer="true"]')
      });
    }
    record('chat_surface', true, {
      surface: 'chat', workerUsed: false, surfaceEvidence: chatSurfaceEvidence()
    });
    if (!conversationIsExpected()) {
      return fail('conversation_guard', 'conversation_changed_before_send', {
        expectedConversationId,
        actualConversationId: currentConversationId() || null
      });
    }

    if (newChat) {
      const newChatButton = [...document.querySelectorAll('button')].find(button => {
        const text = (button.textContent || '').trim().toLowerCase();
        return text === '新聊天' || text === '新对话'
          || text === 'new chat' || text === 'new conversation';
      });
      if (!newChatButton) {
        if (userMessages().length === 0) {
          record('new_chat', true, { alreadyBlankConversation: true });
        } else {
          return fail('new_chat', 'new_chat_button_not_found', {
            userMessageCount: userMessages().length
          });
        }
      } else {
        newChatButton.click();
        await sleep(500);
        const chatButton = [...document.querySelectorAll('button')].find(button =>
          (button.innerText || button.textContent || '').trim().toLowerCase() === 'chat'
        );
        if (chatButton) {
          chatButton.click();
          await sleep(500);
        }
        if (!chatModeIsActive()) {
          return fail('new_chat', 'new_chat_not_chat_surface', {
            hasInput: !!findTextarea(), workComposer: !!document.querySelector('[data-codex-composer="true"]')
          });
        }
        record('new_chat', true, { selectedChat: true, userMessageCount: userMessages().length });
      }
    }

    // Every task, continuation, and independent review Chat must explicitly
    // select GPT-5.6 Sol with Extra High reasoning before any connector or message is
    // placed in the composer. Fail closed so a default or stale model can never
    // receive an automated instruction.
    const modelSelection = await ensureModelAndReasoning();
    if (!modelSelection.ok) {
      return fail('model_selection', modelSelection.error || 'model_selection_failed', modelSelection);
    }
    result.modelConfirmed = true;
    result.reasoningConfirmed = true;
    result.model = modelSelection.model;
    result.reasoning = modelSelection.reasoning;
    record('model_selection', true, modelSelection);

    const textarea = findTextarea();
    if (!textarea) {
      return fail('input_discovery', 'input_not_found');
    }
    record('input_discovery', true, { existingDraftLength: inputText(textarea).length });

    // Step 1: Select the connector from the composer's app menu. Recent
    // desktop builds no longer open an @mention picker for synthetic text and
    // a synthetic Enter can submit a connector-only message. Prefer the real
    // app-menu button and pointer events; retain a click-only mention popup as
    // a compatibility fallback, but never press Enter to confirm it.
    if (connector) {
      const target = connector.toLowerCase();
      let evidence = connectorEvidence(target);
      let found = evidence.length > 0;

      if (!found) {
        const connectorTextarea = findTextarea();
        if (!connectorTextarea) {
          return fail('apps_menu', 'input_not_found', { connector });
        }
        const addButton = document.querySelector('button[aria-label="添加文件等"]')
          || document.querySelector('button[aria-label="添加文件等内容"]')
          || document.querySelector('button[aria-label="附加文件或连接应用"]')
          || document.querySelector('button[aria-label*="Add files"]')
          || document.querySelector('button[aria-label*="attachments"]');
        let connectorItem = null;
        if (addButton && visible(addButton)) {
          dispatchPointerClick(addButton);
          await sleep(500);
          connectorItem = [...document.querySelectorAll(
            '[data-composer-overlay-floating-ui] button, [role="menu"] button, '
              + '[role="listbox"] button, [role="menuitem"], [role="option"]'
          )].find(element => {
            const label = [
              element.textContent, element.getAttribute('aria-label'),
              element.getAttribute('title'), element.getAttribute('data-app-name'),
              element.getAttribute('data-connector-id')
            ].filter(Boolean).join(' ');
            return visible(element) && connectorMatches(label, target);
          }) || null;
          if (connectorItem) {
            dispatchPointerClick(connectorItem);
            await sleep(500);
            evidence = connectorEvidence(target);
            found = evidence.length > 0;
          }
        }

        if (!found) {
          connectorTextarea.focus();
          replaceText(connectorTextarea, `@${connector}`);
          record('apps_menu', true, {
            typedMention: true, directMenuItemFound: !!connectorItem
          });
          let mentionOption = null;
          for (let i = 0; i < 80; i++) {
            await sleep(150);
            mentionOption = [...document.querySelectorAll(
              '[data-composer-overlay-floating-ui] [role="option"], '
                + '[data-composer-overlay-floating-ui] button, [role="listbox"] [role="option"]'
            )].find(element => visible(element)
              && connectorMatches(element.textContent, target)) || null;
            if (mentionOption) break;
          }
          if (mentionOption) {
            dispatchPointerClick(mentionOption);
            await sleep(500);
            evidence = connectorEvidence(target);
            found = evidence.length > 0;
          }
        }
      }

      if (!found) {
        return fail('connector_confirmation', 'connector_selection_not_confirmed', {
          connector, evidenceCount: evidence.length
        });
      }
      result.connectorAdded = true;
      result.connectorConfirmed = true;
      record('connector_confirmation', true, { connector, evidenceCount: evidence.length });
    } else {
    result.connectorConfirmed = true;
    record('connector_confirmation', true, { connectorRequired: false });
    }

    // Gmail is an auxiliary project-log connector. Select it when the host
    // exposes it, but do not prevent repository work when the account has not
    // yet been connected. The shared task skill requires the model to create
    // or reply to the durable project thread whenever this source is present.
    const optionalConnectorResults = [];
    for (const optionalConnector of optionalConnectors) {
      const optionalTarget = optionalConnector.toLowerCase();
      let optionalEvidence = connectorEvidence(optionalTarget);
      let optionalFound = optionalEvidence.length > 0;
      if (!optionalFound) {
        const addButton = document.querySelector('button[aria-label="添加文件等"]')
          || document.querySelector('button[aria-label="添加文件等内容"]')
          || document.querySelector('button[aria-label="附加文件或连接应用"]')
          || document.querySelector('button[aria-label*="Add files"]')
          || document.querySelector('button[aria-label*="attachments"]');
        if (addButton && visible(addButton)) {
          dispatchPointerClick(addButton);
          await sleep(400);
          const item = [...document.querySelectorAll(
            '[data-composer-overlay-floating-ui] button, [role="menu"] button, '
              + '[role="listbox"] button, [role="menuitem"], [role="option"]'
          )].find(element => visible(element) && connectorMatches([
            element.textContent, element.getAttribute('aria-label'),
            element.getAttribute('title'), element.getAttribute('data-app-name'),
            element.getAttribute('data-connector-id')
          ].filter(Boolean).join(' '), optionalTarget));
          if (item) {
            dispatchPointerClick(item);
            await sleep(500);
            optionalEvidence = connectorEvidence(optionalTarget);
            optionalFound = optionalEvidence.length > 0;
          } else if (addButton.getAttribute('aria-expanded') === 'true') {
            dispatchPointerClick(addButton);
            await sleep(200);
          }
        }
      }
      optionalConnectorResults.push({
        connector: optionalConnector,
        selected: optionalFound,
        evidenceCount: optionalEvidence.length
      });
    }
    record('optional_connectors', true, { connectors: optionalConnectorResults });

    // Step 2: Type the message
    let ta2 = null;
    let actualInput = '';
    let inputConfirmed = false;
    for (let attempt = 0; attempt < 8 && !inputConfirmed; attempt += 1) {
      if (!conversationIsExpected()) {
        return fail('conversation_guard', 'conversation_changed_during_send', {
          expectedConversationId,
          actualConversationId: currentConversationId() || null,
          inputAttempt: attempt
        });
      }
      // React can replace the contenteditable after a new-chat or connector
      // transition. Reacquire it on every attempt instead of writing through
      // a detached node.
      ta2 = findTextarea();
      if (!ta2 || !document.contains(ta2)) {
        await sleep(250);
        continue;
      }
      const before = normalize(inputText(ta2));
      const connectorStillSelected = !connector ||
        before.includes(connector.toLowerCase()) ||
        connectorEvidence(connector.toLowerCase()).length > 0;
      if (!(before.endsWith(normalize(message)) && connectorStillSelected)) {
        ta2.focus();
        if (connector && attempt === 0) {
          appendTextPreservingConnector(ta2, message);
        } else {
          replaceText(ta2, message);
        }
      }
      await sleep(250);
      const currentInput = findTextarea();
      if (!currentInput || !document.contains(currentInput)) continue;
      ta2 = currentInput;
      actualInput = inputText(ta2);
      const normalizedActualInput = normalize(actualInput);
      inputConfirmed = connector
        ? normalizedActualInput.endsWith(normalize(message))
          && (normalizedActualInput.includes(connector.toLowerCase())
            || connectorEvidence(connector.toLowerCase()).length > 0)
        : normalizedActualInput === normalize(message);
    }
    if (!inputConfirmed) {
      return fail('message_input', 'message_input_not_confirmed', {
        expectedLength: message.length, actualLength: actualInput.length,
        exactAfterWhitespaceNormalization: false
      });
    }
    result.inputConfirmed = true;
    record('message_input', true, {
      expectedLength: message.length, actualLength: actualInput.length,
      replacedExistingDraft: true
    });
    if (!conversationIsExpected()) {
      return fail('conversation_guard', 'conversation_changed_before_dispatch', {
        expectedConversationId,
        actualConversationId: currentConversationId() || null
      });
    }

    // Step 3: Click send
    let sendBtn = null;
    for (let i = 0; i < 20; i++) {
      sendBtn = findSendButton();
      if (sendBtn && !sendBtn.disabled) break;
      await sleep(100);
    }
    let sendMethod = 'button';
    if (sendBtn && !sendBtn.disabled) {
      // Schedule the click after this Runtime.evaluate promise resolves. A
      // synchronous submit can replace Electron's execution context before
      // CDP delivers the result, even though ChatGPT accepted the message.
      setTimeout(() => {
        try { sendBtn.click(); } catch (_) {}
      }, 0);
    } else {
      sendMethod = 'enter';
      setTimeout(() => {
        try {
          ta2.dispatchEvent(new KeyboardEvent('keydown', {
            key: 'Enter', code: 'Enter', bubbles: true, cancelable: true
          }));
        } catch (_) {}
      }, 0);
    }
    record('send_action', true, { method: sendMethod, deferredDispatch: true });
    // The follow-up watcher performs the same virtualization-aware check
    // after the renderer settles: containsFullSubmittedMessage,
    // baselineUserIdentities and isNewBubble remain the verification contract
    // while the dispatch itself is deferred to avoid context loss.
    // (The final evidence is reported as virtualizationAware.)
    result.sent = true;
    result.messageConfirmed = true;
    result.dispatchOnly = true;
    result.ok = true;
    result.url = window.location.href || '';
    const activeRowAnchor = document.querySelector(
      'a[aria-current="page"][href*="/c/"], a[aria-current="page"][href*="/work/conversation/"]'
    );
    const activeRow = activeRowAnchor || [...document.querySelectorAll('[data-thread-title="true"]')]
      .map(title => title.closest('[role="button"]'))
      .find(row => row?.getAttribute('aria-current') === 'page');
    const activeRowConversationIds = [];
    if (activeRow) {
      const hrefMatch = activeRow.getAttribute('href')
        ?.match(/\\/(?:c|work\\/conversation)\\/([^/?#]+)/);
      if (hrefMatch) activeRowConversationIds.push(decodeURIComponent(hrefMatch[1]));
      const fiberKey = Object.keys(activeRow).find(key => key.startsWith('__reactFiber$'));
      let fiber = fiberKey ? activeRow[fiberKey] : null;
      for (let depth = 0; fiber && depth < 8; depth += 1, fiber = fiber.return) {
        const props = fiber.memoizedProps || {};
        if (typeof props.conversation?.id === 'string') {
          activeRowConversationIds.push(props.conversation.id);
        }
        if (typeof props.conversationId === 'string') {
          activeRowConversationIds.push(props.conversationId);
        }
        if (typeof props.route === 'string') {
          const match = props.route.match(/^\\/work\\/conversation\\/([^/?#]+)/);
          if (match) {
            try { activeRowConversationIds.push(decodeURIComponent(match[1])); } catch {}
          }
        }
      }
    }
    const portalConversation = document.querySelector('[data-above-composer-conversation-id]')
      ?.getAttribute('data-above-composer-conversation-id') || '';
    const portalConversationId = portalConversation.startsWith('chatgpt:')
      ? portalConversation.slice('chatgpt:'.length)
      : (portalConversation || null);
    result.conversationId = activeRowConversationIds.find(id => !id.startsWith('local-chatgpt:'))
      || activeRowConversationIds[0]
      || portalConversationId;
    record('message_dispatch', true, {
      sendMethod,
      verificationDeferred: true
    });
    return result;
  })()
  """
}

func stopCurrentResponseJS() -> String {
  #"""
  (async () => {
    const result = { ok: false, stopped: false, stopConfirmed: false, error: null };
    const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
    const visible = element => !!(element && (element.offsetWidth || element.offsetHeight || element.getClientRects().length));
    const stopSelectors = [
      '[data-testid="stop-button"]', '[aria-label="Stop streaming"]',
      '[aria-label="Stop responding"]', '[aria-label="Stop generating"]',
      '[aria-label="停止输出"]', '[aria-label="停止回答"]',
      '[aria-label="停止生成"]', 'button[aria-label="停止"]',
      'button[data-testid*="stop"]'
    ];
    const findStopButton = () => {
      let stopButton = stopSelectors.map(selector => document.querySelector(selector)).find(visible) || null;
      if (stopButton) return stopButton;
      const input = document.querySelector('#prompt-textarea')
        || document.querySelector('[contenteditable="true"]');
      const composer = input?.closest('form') || input?.parentElement?.parentElement;
      return [...(composer?.querySelectorAll('button') || [])].find(button =>
        visible(button) && !button.disabled && !!button.querySelector('svg rect')
      ) || null;
    };
    const stopButton = findStopButton();
    if (!stopButton) {
      result.error = 'stop_button_not_found';
      return result;
    }
    stopButton.click();
    result.stopped = true;
    const deadline = Date.now() + 12000;
    let absentSince = 0;
    while (Date.now() < deadline) {
      if (!findStopButton()) {
        if (!absentSince) absentSince = Date.now();
        if (Date.now() - absentSince >= 750) {
          result.ok = true;
          result.stopConfirmed = true;
          return result;
        }
      } else {
        absentSince = 0;
      }
      await sleep(150);
    }
    result.error = 'stop_confirmation_timeout';
    return result;
  })()
  """#
}

func continueInNewTaskJS(expectedConversationId: String? = nil) -> String {
  let expected = expectedConversationId.map(jsonStringLiteral) ?? "null"
  return """
  (async () => {
    const expectedConversationId = \(expected);
    const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
    const visible = element => !!(element
      && !element.disabled
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
    const normalizeConversationId = value => {
      const raw = (value || '').trim();
      if (!raw) return '';
      return raw.startsWith('chatgpt:') ? raw.slice('chatgpt:'.length) : raw;
    };
    const currentConversationId = () => normalizeConversationId(
      document.querySelector('[data-above-composer-conversation-id]')
        ?.getAttribute('data-above-composer-conversation-id') || ''
    );
    const current = currentConversationId();
    if (expectedConversationId
        && current
        && normalizeConversationId(expectedConversationId) !== current) {
      return {
        ok: false,
        error: 'continuation_conversation_changed',
        expectedConversationId: normalizeConversationId(expectedConversationId),
        actualConversationId: current
      };
    }

    const main = document.querySelector('main') || document;
    const messages = [...main.querySelectorAll(
      '[data-message-author-role="assistant"], '
        + '[data-local-conversation-final-assistant], '
        + '[data-content-search-unit-key$=":assistant"]'
    )];
    const last = messages[messages.length - 1] || null;
    const responseTurn = last?.closest(
      'article, [data-testid^="conversation-turn-"], '
        + '[data-content-search-turn-key], [data-turn-key]'
    ) || last?.parentElement?.parentElement || last;
    const responseControls = [...(responseTurn?.querySelectorAll(
      'button, a, [role="button"], [aria-label], [title]'
    ) || [])];
    // Desktop releases sometimes portal the latest response actions outside
    // the turn container. Include global controls, then prefer the last match
    // so an older response cannot receive the continuation click.
    const globalControls = [...document.querySelectorAll(
      'button, a, [role="button"], [aria-label], [title]'
    )];
    const controls = [...new Set([...responseControls, ...globalControls])];
    const label = node => [
      node.getAttribute?.('aria-label') || '',
      node.getAttribute?.('title') || '',
      node.textContent || ''
    ].join(' ').replace(/\\s+/g, ' ').trim().toLowerCase();
    const isContinueControl = node => {
      const text = label(node);
      return /\\bcontinue\\s+in\\s+(?:a\\s+)?new\\s+(?:chat|task)\\b/.test(text)
        || /(?:在|从这里).*(?:新任务|新聊天).*(?:继续|分支)/.test(text)
        || /从这里(?:继续|分支).*(?:新任务|新聊天)/.test(text)
        || /在新(?:的)?聊天中(?:创建)?分支/.test(text);
    };
    let button = [...controls].reverse()
      .find(node => visible(node) && isContinueControl(node));
    let overflowOpened = false;
    let overflowCandidates = [];
    if (!button) {
      const overflow = [...controls].reverse().find(node => {
        const text = label(node);
        return visible(node) && (
          /^more actions(?:\\s|$)/.test(text)
          || /^more(?:\\s|$)/.test(text)
          || /^更多(?:操作|动作)?(?:\\s|$)/.test(text)
        );
      });
      if (overflow) {
        dispatchPointerClick(overflow);
        overflowOpened = true;
        for (let index = 0; index < 30 && !button; index += 1) {
          await sleep(100);
          const menuControls = [...document.querySelectorAll(
            '[role="menuitem"], [role="menu"] button, [role="menu"] a, '
              + '[data-radix-menu-content] button, [data-radix-menu-content] [role="button"], '
              + '[data-headlessui-state] [role="menuitem"]'
          )].filter(visible);
          overflowCandidates = menuControls.map(label).filter(Boolean).slice(-30);
          button = [...menuControls].reverse().find(isContinueControl) || null;
        }
      }
    }
    if (!button) {
      return {
        ok: false,
        error: 'continue_in_new_task_button_not_found',
        conversationId: current,
        assistantResponseCount: messages.length,
        overflowOpened,
        candidateControls: controls.map(label).filter(Boolean).slice(-20),
        overflowCandidates
      };
    }

    const continuationLabel = label(button);
    dispatchPointerClick(button);
    let stableConversationId = '';
    let stableSamples = 0;
    for (let index = 0; index < 120; index += 1) {
      await sleep(250);
      const nextConversationId = currentConversationId();
      const composer = document.querySelector(
        'textarea, [contenteditable="true"][role="textbox"], '
          + '[contenteditable="true"][data-lexical-editor="true"]'
      );
      const changed = !!nextConversationId && nextConversationId !== current;
      const composerReady = !!composer;
      if (changed && composerReady) {
        if (stableConversationId === nextConversationId) {
          stableSamples += 1;
        } else {
          stableConversationId = nextConversationId;
          stableSamples = 1;
        }
        if (stableSamples >= 3) {
          return {
            ok: true,
            continuationClicked: true,
            overflowOpened,
            continuationLabel,
            previousConversationId: current,
            conversationId: nextConversationId,
            stableSamples
          };
        }
      } else {
        stableConversationId = '';
        stableSamples = 0;
      }
    }
    return {
      ok: false,
      error: 'continue_in_new_task_not_confirmed',
      overflowOpened,
      continuationLabel,
      previousConversationId: current,
      conversationId: currentConversationId()
    };
  })()
  """
}

func getReplyJS() -> String {
  #"""
  (async () => {
    const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
    const visible = element => !!(element && (element.offsetWidth || element.offsetHeight || element.getClientRects().length));
    const quickChatRoot = document.querySelector(
      '[data-pip-obstacle="quick-chat"], [data-quick-chat-drag-handle]'
    )?.closest('[role="dialog"], section, div');
    const main = quickChatRoot || document.querySelector('main') || document.body;
    const thinkingToggles = [...main.querySelectorAll('button')].filter(button => {
      const text = (button.innerText || '').trim();
      return text.startsWith('正在思考') || text.startsWith('Thinking');
    });
    const completedThinkingToggles = [...main.querySelectorAll('button')].filter(button => {
      const text = (button.innerText || '').trim();
      return /^思考(?:\s|$)/.test(text)
        || /^(Thought|Thoughts)(?:\s|$)/i.test(text);
    });
    const latestThinking = thinkingToggles[thinkingToggles.length - 1];
    const latestCompletedThinking = completedThinkingToggles[completedThinkingToggles.length - 1];
    if (latestThinking?.getAttribute('aria-expanded') === 'false') {
      latestThinking.click();
      await sleep(120);
    }

    const webMessages = [...main.querySelectorAll('[data-message-author-role="assistant"]')];
    const appContentMessages = [
      ...main.querySelectorAll('[data-content-search-unit-key$=":assistant"]')
    ];
    const appFinalMessages = [
      ...main.querySelectorAll('[data-local-conversation-final-assistant]')
    ];
    // The desktop renderer can expose both selectors for the same logical
    // assistant turn. Combining them lets a previous completed response keep
    // the assistant count level with a newly submitted user turn, so a brief
    // disappearance of the Stop button can falsely look terminal. Prefer the
    // stable content-search rows and use local-final nodes only as a fallback.
    const appMessages = appContentMessages.length > 0
      ? appContentMessages
      : appFinalMessages;
    const messages = webMessages.length > 0 ? webMessages : appMessages;
    const webUsers = [...main.querySelectorAll('[data-message-author-role="user"]')];
    const appUserBubbles = [...main.querySelectorAll('[data-user-message-bubble]')];
    const appContentUsers = [
      ...main.querySelectorAll('[data-content-search-unit-key$=":user"]')
    ];
    // A completed desktop Chat currently exposes both the content-search row
    // and a nested/parallel message bubble for the same logical user turn.
    // Combining both selector results counts one prompt twice, which leaves
    // `awaitingAssistant` true after the single matching reply has completed.
    // Prefer the stable content-search rows and retain the bubble selector only
    // as a fallback for older app builds.
    const appUsers = appContentUsers.length > 0 ? appContentUsers : appUserBubbles;
    const users = webUsers.length > 0 ? webUsers : appUsers;
    const userText = user => (
      user?.querySelector('[data-selected-text-overlay-target]') || user
    )?.innerText || '';
    const userMessageCount = users.length;
    const last = messages.length > 0 ? messages[messages.length - 1] : null;
    const awaitingAssistant = userMessageCount > messages.length;
    const assistantContent = last?.querySelector('[data-selected-text-overlay-target]')
      || last;
    const content = assistantContent?.innerText || '';
    const normalizeControlLabel = value => (value || '')
      .replace(/\s+/g, ' ')
      .trim()
      .toLowerCase();
    const responseTurnSelector = 'article, [data-testid^="conversation-turn-"], '
      + '[data-content-search-turn-key], [data-turn-key], '
      + '[data-local-conversation-final-assistant]';
    const responseTurn = last?.closest(responseTurnSelector) || null;
    const responseActionTurnBoundToLast = !!(
      last && responseTurn && (responseTurn === last || responseTurn.contains(last))
    );
    const responseControls = [...(responseTurn?.querySelectorAll(
      'button, a, [role="button"], [aria-label], [title]'
    ) || [])].filter(visible);
    const responseControlLabels = responseControls.map(control => normalizeControlLabel(
      control.getAttribute('aria-label')
        || control.getAttribute('title')
        || control.innerText
        || control.textContent
    )).filter(Boolean);
    const hasResponseControl = patterns => responseControlLabels.some(label =>
      patterns.some(pattern => pattern.test(label))
    );
    // A locally completed ChatGPT response exposes its stable per-response
    // action row. Streaming/stale virtualized bodies do not reliably expose
    // all three controls, so this is stronger completion evidence than text,
    // a changed conversation id, or an old collapsed Thinking section.
    const responseActions = {
      copy: hasResponseControl([/^copy(?:\s|$)/, /^复制(?:\s|$)/]),
      branch: hasResponseControl([
        /\bbranch(?:\s+in\s+new\s+chat)?\b/,
        /\bcontinue\s+in\s+(?:a\s+)?new\s+(?:chat|task)\b/,
        /新(?:建)?(?:聊天)?分支/,
        /在新(?:的)?聊天中(?:创建)?分支/,
        /(?:在|从这里).*(?:新任务|新聊天).*(?:继续|分支)/,
        /从这里(?:继续|分支).*(?:新任务|新聊天)/,
      ]),
      moreActions: hasResponseControl([
        /^more actions(?:\s|$)/,
        /^more(?:\s|$)/,
        /^显示更多(?:\s|$)/,
        /^更多(?:操作|动作)?(?:\s|$)/,
      ]),
      like: hasResponseControl([
        /^like(?:\s|$)/,
        /^good response(?:\s|$)/,
        /^喜欢(?:\s|$)/,
        /^好的回答(?:\s|$)/,
        /^回复优秀(?:\s|$)/,
      ]),
      dislike: hasResponseControl([
        /^dislike(?:\s|$)/,
        /^bad response(?:\s|$)/,
        /^不喜欢(?:\s|$)/,
        /^不好的回答(?:\s|$)/,
        /^回复不佳(?:\s|$)/,
      ]),
    };
    const responseActionsComplete = !awaitingAssistant
      && responseActionTurnBoundToLast
      && responseActions.copy
      && (responseActions.branch || responseActions.moreActions)
      && responseActions.like
      && responseActions.dislike;

    const stopSelectors = [
      '[data-testid="stop-button"]', '[aria-label="Stop streaming"]',
      '[aria-label="Stop responding"]', '[aria-label="Stop generating"]',
      '[aria-label="停止输出"]', '[aria-label="停止回答"]',
      '[aria-label="停止生成"]', 'button[aria-label="停止"]',
      'button[data-testid*="stop"]'
    ];
    let stopBtn = stopSelectors.map(selector => main.querySelector(selector)).find(visible) || null;
    if (!stopBtn) {
      const composer = document.querySelector('#prompt-textarea')?.closest('form')
        || document.querySelector('#prompt-textarea')?.parentElement?.parentElement;
      stopBtn = [...(composer?.querySelectorAll('button') || [])].find(button =>
        visible(button) && !button.disabled && !!button.querySelector('svg rect')
      ) || null;
    }

    const approvalButton = [...main.querySelectorAll('button, a, [role="button"]')].find(button => {
      const text = (button.innerText || button.getAttribute('aria-label') || button.getAttribute('title') || '')
        .replace(/[\s\u21b5\u23ce]+/g, ' ')
        .trim().toLowerCase();
      return visible(button) && [
        '完全访问', 'full access', 'allow', 'allow once',
        '允许', '允许一次', 'approve', 'approve once',
        'confirm', '确认', '继续在此聊天', '继续聊天',
        'continue in this chat', 'stay in this chat', 'continue here'
      ].includes(text);
    });
    const thinkingActive = !responseActionsComplete && !!latestThinking && (
      latestThinking.getAttribute('aria-expanded') !== null
      || !!latestThinking.querySelector('[class*="shimmer"], [class*="Shimmer"]')
    );
    const typingDots = main.querySelector('[class*="typing"], [class*="Typing"]');
    const active = !!stopBtn || thinkingActive || !!typingDots || !!approvalButton;

    const redact = value => (value || '')
      .replace(/\bsk-[A-Za-z0-9_-]{4,}\b/g, '[REDACTED_API_KEY]')
      .replace(/\b(Bearer\s+)[A-Za-z0-9._~+\/-]+=*/gi, '$1[REDACTED_TOKEN]')
      .replace(/\b([A-Z][A-Z0-9_]*(?:TOKEN|API_KEY|SECRET|PASSWORD))=([^\s,]+)/g, '$1=[REDACTED]')
      .replace(/(DeviceID\s*\n)[^\n]+/gi, '$1[REDACTED_DEVICE_ID]');
    const mainText = redact((main.innerText || '').replace(/\s+$/g, ''));
    const userContent = redact(users.map(userText).join('\n'));
    // Queue prompts can exceed 50k characters. The dispatch marker and task
    // report live at the end, so prefix-only truncation makes a valid send look
    // stale and can exhaust the continuation budget. Preserve both ends.
    const boundedContent = value => value.length <= 50000
      ? value
      : `${value.slice(0, 25000)}\n...[middle truncated]...\n${value.slice(-25000)}`;
    const lastUserText = userText(users[users.length - 1]).trim();
    const userIndex = lastUserText ? mainText.lastIndexOf(lastUserText) : -1;
    const activity = (userIndex >= 0
      ? mainText.slice(userIndex + lastUserText.length)
      : mainText).trim();
    const activityLines = activity.split('\n').map(line => line.trim()).filter(Boolean);
    const completedSection = latestCompletedThinking?.parentElement?.parentElement
      || latestCompletedThinking?.parentElement;
    const completedSectionText = redact((completedSection?.innerText || '').trim());
    const completedActivity = completedSectionText
      .replace(/^(思考|Thought|Thoughts)\s*/i, '')
      .trim();
    const completedActivityLines = completedActivity.split('\n')
      .map(line => line.trim())
      .filter(Boolean);
    const toolActivityLine = line => /^Link\s+[a-z0-9-]+\s+(open workspace|read|write|edit|bash|grep|glob|ls|show changes)/i.test(line)
      || /^(已使用|used)\s+.+\s+(集成|integration)$/i.test(line)
      || /^devspace1$/i.test(line)
      || /^(中|来源|暂无来源)$/i.test(line);
    const toolOnlyCompletedActivity = completedActivityLines.length > 0
      && completedActivityLines.every(toolActivityLine);
    const completionTail = `${content}\n${completedActivity}`.slice(-4000);
    const taskReportText = `${content}\n${completedActivity}\n${activity}`.slice(-12000);
    const hasClosedTaskReport = taskReportText.includes('MAHAYANA_TASK_REPORT_V1_BEGIN')
      && taskReportText.includes('MAHAYANA_TASK_REPORT_V1_END');
    const structuredIncomplete = hasClosedTaskReport
      && (/"status"\s*:\s*"(?:incomplete|blocked)"/i.test(taskReportText)
        || /"all_tasks_complete"\s*:\s*false/i.test(taskReportText));
    const structuredComplete = hasClosedTaskReport
      && /"status"\s*:\s*"complete"/i.test(taskReportText)
      && /"all_tasks_complete"\s*:\s*true/i.test(taskReportText);
    const explicitlyIncomplete = /(?:当前(?:任务|状态).{0,30}(?:尚未.{0,12}完成|未完成|继续处理中)|尚未(?:达到|完成|执行)|仍未(?:完成|执行)|还需要继续|仍需继续|待继续完成|不能(?:提交|返回).{0,30}(?:完成|最终)|未进入最终验证|not\s+(?:yet\s+)?(?:complete|finished)|still\s+(?:in\s+progress|needs?|have)\s+to)/i
      .test(completionTail);
    const explicitFinalResult = /(?:已完成|完成内容|验证结果|测试结果|修改文件|最终结果|全部实现|全部通过|completed|implemented|tests?\s+passed|done)/i
      .test(completionTail);
    const devspaceLines = activityLines.filter(line =>
      /devspace1/i.test(line)
      || /^Link\s+[a-z0-9-]+\s+(open workspace|read|write|edit|bash|grep|glob|ls|show changes)/i.test(line)
    );
    const waitingForApproval = !!approvalButton;
    const done = !!last
      && messages.length >= userMessageCount
      && !active
      && content.length > 0
      && responseActionsComplete;
    const completionCandidate = !done
      && !active
      && !waitingForApproval
      && !stopBtn
      && responseActionsComplete
      && !!latestCompletedThinking
      && userMessageCount > 0
      && completedActivity.length > 0
      && !toolOnlyCompletedActivity
      && (structuredComplete || (!explicitlyIncomplete && explicitFinalResult));
    const terminalIncomplete = (!active || hasClosedTaskReport)
      && !waitingForApproval
      && !stopBtn
      && responseActionsComplete
      && userMessageCount > 0
      && (structuredIncomplete || (!hasClosedTaskReport && explicitlyIncomplete))
      && (hasClosedTaskReport || done || (!!latestCompletedThinking && completedActivity.length > 0));
    const visibleContent = done ? content : '';

    return {
      ok: true,
      content: visibleContent.substring(0, 50000),
      thinking: activity.substring(0, 50000),
      activity: activity.substring(0, 50000),
      activityCharCount: activity.length,
      activitySignature: `${activity.length}:${activity.slice(-12000)}`,
      devspaceActivity: devspaceLines.join('\n').substring(0, 20000),
      devspaceWaiting: waitingForApproval || (active && devspaceLines.length > 0),
      waitingForApproval,
      approvalTitle: waitingForApproval ? (approvalButton.innerText || approvalButton.getAttribute('aria-label') || '') : '',
      stopAvailable: !!stopBtn,
      completionCandidate,
      terminalIncomplete,
      completedActivity: (completionCandidate || terminalIncomplete)
        ? (hasClosedTaskReport ? taskReportText : (completedActivity || content)).substring(0, 50000)
        : '',
      hasClosedTaskReport,
      structuredIncomplete,
      structuredComplete,
      explicitlyIncomplete,
      explicitFinalResult,
      toolOnlyCompletedActivity,
      completedThinkingTitle: latestCompletedThinking
        ? (latestCompletedThinking.innerText || '').trim().substring(0, 200)
        : '',
      responseActions,
      responseActionsComplete,
      responseActionTurnBoundToLast,
      awaitingAssistant,
      responseControlLabels: responseControlLabels.slice(0, 40),
      streaming: active,
      done,
      pending: !done && (awaitingAssistant || active),
      charCount: visibleContent.length,
      messageCount: messages.length,
      userMessageCount,
      userContent: boundedContent(userContent),
      pageContent: boundedContent(mainText)
    };
  })()
  """#
}

func chatStatusJS() -> String {
  #"""
  (() => {
  const quickChatRoot = document.querySelector(
    '[data-pip-obstacle="quick-chat"], [data-quick-chat-drag-handle]'
  )?.closest('[role="dialog"], section, div');
  const scope = quickChatRoot || document;
  const textarea = scope.querySelector('#prompt-textarea')
    || document.querySelector('[contenteditable="true"]');
  const hasInput = !!textarea;
  const normalize = value => (value || '').replace(/[\s\u21b5\u23ce]+/g, ' ').trim().toLowerCase();
  const continueInChatButton = [...document.querySelectorAll('button, a, [role="button"]')]
    .find(button => [
      '继续在此聊天', '继续聊天', 'continue in this chat',
      'stay in this chat', 'continue here'
    ].includes(normalize(
      button.innerText || button.textContent || button.getAttribute('aria-label')
    )));

  const stopBtn = scope.querySelector('[data-testid="stop-button"]')
    || scope.querySelector('[aria-label="Stop streaming"]')
    || scope.querySelector('[aria-label="Stop responding"]')
    || scope.querySelector('[aria-label="停止输出"]')
    || scope.querySelector('[aria-label="停止回答"]')
    || scope.querySelector('button[aria-label="停止"]')
    || scope.querySelector('button[data-testid*="stop"]');
  const streaming = !!stopBtn;

  // Get conversation title from the document title or header
  let title = '';
  const h1 = document.querySelector('h1');
  if (h1) title = h1.innerText || '';
  if (!title) {
    const dt = document.title || '';
    const idx = dt.indexOf(' - ChatGPT');
    title = idx > 0 ? dt.substring(0, idx).trim() : dt.trim();
  }

  // Find connected apps/connectors
  const connectors = [];
  const appElements = document.querySelectorAll('[class*="connector"], [class*="plugin"], [data-testid*="app"]');
  for (const el of appElements) {
    const name = (el.textContent || '').trim();
    if (name && name.length < 100 && name.length > 0) connectors.push(name);
  }
  const selectedAppButtons = document.querySelectorAll(
    'button[aria-label*="点击以重试"], button[aria-label*="click to retry"]');
  for (const button of selectedAppButtons) {
    const label = (button.getAttribute('aria-label') || '').trim();
    const name = label.split(/[，,]/)[0].trim();
    if (name && name.length < 100) connectors.push(name);
  }

  // Count messages
  const webUserMsgs = document.querySelectorAll('[data-message-author-role="user"]').length;
  const webAsstMsgs = document.querySelectorAll('[data-message-author-role="assistant"]').length;
  const appUserMsgs = document.querySelectorAll('[data-user-message-bubble]').length;
  const appAsstMsgs = document.querySelectorAll('[data-local-conversation-final-assistant]').length;
  const userMsgs = webUserMsgs > 0 ? webUserMsgs : appUserMsgs;
  const asstMsgs = webAsstMsgs > 0 ? webAsstMsgs : appAsstMsgs;
  const modeButton = [...document.querySelectorAll('button')].find(button => {
    const label = button.getAttribute('aria-label') || '';
    return label.includes('当前模式') || label.toLowerCase().includes('current mode');
  });
  const mode = modeButton
    ? `${modeButton.getAttribute('aria-label') || ''} ${modeButton.textContent || ''}`.trim()
    : '';
  const normalizedMode = mode.toLowerCase();
  const currentChatGPTMode = normalizedMode.includes('current mode: chatgpt')
    || (normalizedMode.includes('当前模式') && normalizedMode.includes('chatgpt'));
  const chatModel = [...document.querySelectorAll('button')].some(button => {
    const label = button.getAttribute('aria-label') || '';
    return label.includes('ChatGPT 模型') || /select chatgpt model/i.test(label);
  });
  const webChat = window.location.protocol === 'https:'
    && window.location.hostname === 'chatgpt.com';
  // A stale mode flag must not hide the Work composer from surface checks.
  const workComposer = !quickChatRoot
    && !!document.querySelector('[data-codex-composer="true"]');
  const pageURL = window.location.href || '';
  const initialRoute = new URL(pageURL).searchParams.get('initialRoute') || '';
  const routeMatch = initialRoute.match(/\/(?:c|work\/conversation)\/([^/?#]+)/)
    || pageURL.match(/\/c\/([^/?#]+)/);
  const routeConversationId = routeMatch
    ? decodeURIComponent(routeMatch[1])
    : '';
  const portalConversation = document.querySelector('[data-above-composer-conversation-id]')
    ?.getAttribute('data-above-composer-conversation-id') || '';
  const portalConversationId = portalConversation.startsWith('chatgpt:')
    ? portalConversation.slice('chatgpt:'.length)
    : portalConversation;
  const activeRowAnchor = document.querySelector(
    'a[aria-current="page"][href*="/c/"], a[aria-current="page"][href*="/work/conversation/"]'
  );
  const activeRow = activeRowAnchor || [...document.querySelectorAll('[data-thread-title="true"]')]
    .map(title => title.closest('[role="button"]'))
    .find(row => row?.getAttribute('aria-current') === 'page');
  const activeRowConversationIds = [];
  if (activeRow) {
    const hrefMatch = activeRow.getAttribute('href')
      ?.match(/\/(?:c|work\/conversation)\/([^/?#]+)/);
    if (hrefMatch) activeRowConversationIds.push(decodeURIComponent(hrefMatch[1]));
    const fiberKey = Object.keys(activeRow).find(key => key.startsWith('__reactFiber$'));
    let fiber = fiberKey ? activeRow[fiberKey] : null;
    for (let depth = 0; fiber && depth < 8; depth += 1, fiber = fiber.return) {
      const props = fiber.memoizedProps || {};
      if (typeof props.conversation?.id === 'string') activeRowConversationIds.push(props.conversation.id);
      if (typeof props.conversationId === 'string') activeRowConversationIds.push(props.conversationId);
    }
  }
  const activeConversationId = activeRowConversationIds.find(id => !id.startsWith('local-chatgpt:'))
    || activeRowConversationIds[0]
    || null;
  // The composer portal belongs to the live message surface. Sidebar
  // aria-current and initialRoute can both lag after New Chat or a renderer
  // replacement, so never let either override a present portal identity.
  const conversationId = portalConversationId
    || routeConversationId
    || activeConversationId
    || null;
  const conversationSource = portalConversationId
    ? (portalConversationId.startsWith('local-chatgpt:') ? 'portal-local' : 'portal')
    : (routeConversationId ? 'route'
      : (activeConversationId ? 'active-row' : 'none'));
  const chatUrl = conversationId && !conversationId.startsWith('local-chatgpt:')
    ? `https://chatgpt.com/c/${conversationId}`
    : null;
  const conversationRoute = conversationId
    ? `/work/conversation/${encodeURIComponent(conversationId)}`
    : null;

  return {
    ok: true,
    hasInput: hasInput,
    streaming: streaming,
    mode: mode,
    chatMode: (!!quickChatRoot || currentChatGPTMode || chatModel || webChat)
      && (hasInput || !!continueInChatButton) && !workComposer,
    surface: (!!quickChatRoot || currentChatGPTMode || chatModel || webChat)
      && (hasInput || !!continueInChatButton) && !workComposer ? 'chat' : 'not-chat',
    continueInChatPrompt: !!continueInChatButton,
    backgroundOnly: document.visibilityState === 'hidden',
    runtimeState: document.visibilityState === 'hidden' ? 'hidden' : 'visible',
    workerUsed: false,
    title: title || '',
    connectors: [...new Set(connectors)].slice(0, 20),
    messageCount: { user: userMsgs, assistant: asstMsgs },
    url: pageURL,
    conversationId,
    conversationSource,
    portalConversationId: portalConversationId || null,
    routeConversationId: routeConversationId || null,
    activeConversationId: activeConversationId || null,
    conversationRoute,
    chatUrl
  };
  })()
  """#
}

func addConnectorJS(connector: String) -> String {
  let escaped = jsEscape(connector)
  return """
  (async () => {
    const connector = "\(escaped)";
    const result = {
      ok: false, added: false, error: null, url: window.location.href || '',
      backgroundOnly: document.visibilityState === 'hidden',
      runtimeState: document.visibilityState === 'hidden' ? 'hidden' : 'visible',
      workerUsed: false, surface: 'chat'
    };
    function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }
    const target = connector.toLowerCase();
    const connectorMatches = value => {
      const text = (value || '').replace(/\\s+/g, ' ').trim().toLowerCase();
      if (text.includes(target)) return true;
      const compactText = text.replace(/[^a-z0-9\\u4e00-\\u9fff]/g, '');
      const compactTarget = target.replace(/[^a-z0-9\\u4e00-\\u9fff]/g, '');
      return compactTarget.length >= 3 && compactText.includes(compactTarget);
    };
    const isVisible = el => !!(el && (el.offsetWidth || el.offsetHeight || el.getClientRects().length));
    const quickChatRoot = document.querySelector(
      '[data-pip-obstacle="quick-chat"], [data-quick-chat-drag-handle]'
    )?.closest('[role="dialog"], section, div');
    const input = quickChatRoot?.querySelector(
      '#prompt-textarea, [contenteditable="true"]'
    ) || document.querySelector('#prompt-textarea')
      || document.querySelector('[contenteditable="true"]');
    const selected = [...document.querySelectorAll('button[aria-label]')].some(el => {
      const label = (el.getAttribute('aria-label') || '').toLowerCase();
      return isVisible(el) && connectorMatches(label);
    }) || [...(input?.querySelectorAll('span, a, [data-mention-id]') || [])].some(el =>
      isVisible(el)
        && !el.closest('[data-composer-overlay-floating-ui]')
        && connectorMatches(el.textContent)
    );
    if (selected) return { ok: true, added: true, alreadySelected: true, error: null };

    const chatModel = [...document.querySelectorAll('button')].some(button => {
      const label = button.getAttribute('aria-label') || '';
      return label.includes('ChatGPT 模型') || /select chatgpt model/i.test(label);
    });
    const webChat = window.location.protocol === 'https:'
      && window.location.hostname === 'chatgpt.com';
    if ((!quickChatRoot && !chatModel && !webChat)
        || (!quickChatRoot && document.querySelector('[data-codex-composer="true"]'))) {
      result.error = 'not_chat_surface';
      return result;
    }
    const addButton = document.querySelector('button[aria-label="添加文件等"]')
      || document.querySelector('button[aria-label="添加文件等内容"]')
      || document.querySelector('button[aria-label="附加文件或连接应用"]')
      || document.querySelector('button[aria-label*="Add files"]')
      || document.querySelector('button[aria-label*="attachments"]');
    if (!addButton) {
      result.error = 'apps_button_not_found';
      return result;
    }
    const visibleAppItem = () => [...document.querySelectorAll(
      '[role="menuitemradio"], [role="option"], button[data-list-navigation-item="true"], button'
    )].find(el => isVisible(el) && [
      el.textContent, el.getAttribute('aria-label'), el.getAttribute('title'),
      el.getAttribute('data-testid'), el.getAttribute('data-connector-id'),
      el.getAttribute('data-app-name')
    ].some(connectorMatches));
    let appItem = visibleAppItem();
    if (!appItem) {
      addButton.click();
      await sleep(350);
    }
    const moreItem = [...document.querySelectorAll('[role="menuitem"]')].find(el => {
      const text = (el.textContent || '').trim().toLowerCase();
      return isVisible(el) && (text === '更多' || text === 'more' || text.includes('更多'));
    });
    if (moreItem) {
      moreItem.click();
      await sleep(350);
    }
    appItem = visibleAppItem();
    if (!appItem) {
      result.error = 'connector_not_found';
      return result;
    }
    appItem.click();
    for (let i = 0; i < 80; i++) {
      await sleep(150);
      const currentInput = document.querySelector('#prompt-textarea')
        || document.querySelector('[contenteditable="true"]');
      const confirmed = [...(currentInput?.querySelectorAll(
        'span, a, [data-mention-id], [data-connector-id], [data-app-name]'
      ) || [])].some(el =>
        isVisible(el) && connectorMatches(el.textContent)
      );
      if (confirmed) {
        result.ok = true;
        result.added = true;
        return result;
      }
    }
    result.error = 'connector_selection_not_confirmed';
    return result;
  })()
  """
}

func sanitizeJSONValue(_ value: Any) -> Any {
  if value is NSNull { return "" }
  let mirror = Mirror(reflecting: value)
  if mirror.displayStyle == .optional {
    guard let wrapped = mirror.children.first?.value else { return NSNull() }
    return sanitizeJSONValue(wrapped)
  }
  if let dict = value as? [String: Any] {
    var result: [String: Any] = [:]
    for (key, val) in dict {
      if val is NSNull { continue }
      result[key] = sanitizeJSONValue(val)
    }
    return result
  }
  if let array = value as? [Any] {
    return array.map { sanitizeJSONValue($0) }
  }
  return value
}

func cdpEvaluateOnChatGPT(
  _ expression: String,
  timeout: TimeInterval = 5.0,
  preferredURL: String? = nil
) -> [String: Any]? {
  let state = loadState()
  guard let port = state.backgroundAppPort,
        let targetId = state.backgroundChatTargetId,
        pluginOwnsBackgroundTarget(port: port, targetId: targetId, state: state) else {
    cdpDebug("Plugin-owned Chat target is not prepared; refusing unowned Chat/Work fallback")
    return nil
  }
  return cdpValue(
    port: port,
    targetId: targetId,
    expression: expression,
    timeout: timeout
  )
}
