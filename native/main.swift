import ApplicationServices
import Cocoa
import Darwin
import Foundation
import SystemConfiguration

let defaultChatWatchTimeoutSeconds = 21_600
let maxChatWatchTimeoutSeconds = 86_400
let defaultChatStagnationTimeoutSeconds = 10_800


func commandJSONParams() -> [String: Any] {
  guard CommandLine.arguments.count >= 3,
        let data = CommandLine.arguments[2].data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
    return [:]
  }
  return object
}

let nativeCommandSummaries: [String: String] = [
  "account_list": "列出本机账号注册表（仅显示不含凭据的元数据）。",
  "account_add": "在隔离 ChatGPT profile 中登录、验证并上传一个账号。",
  "account_login_link": "生成仅绑定 127.0.0.1、十分钟一次性的本地登录链接。",
  "account_switch": "切换默认账号；已经入队的任务保持原账号。",
  "account_rename": "修改本机账号标签。",
  "account_status": "检查账号的本机凭据和最近云端验证状态。",
  "account_sync": "重新导出指定账号的 renderer Cookie，保存并运行 smoke。",
  "account_remove": "确认后删除账号凭据、profile 和注册表记录。",
  "status": "查看自动确认、ChatGPT、插件页面和任务队列的当前状态。",
  "diagnose": "执行只读诊断，检查辅助功能、ChatGPT 进程和调试连接。",
  "start": "启动后台自动确认；第二个参数可传 JSON 配置。",
  "stop": "停止后台自动确认并关闭插件创建的后台目标。",
  "scan": "立即扫描一次，并允许用 JSON 临时覆盖规则或 approveAll。",
  "sweep": "原地扫描所有已加载 renderer，不导航或切换任何页面。",
  "audit": "读取最近的本地授权审计事件，可指定 1-100 条。",
  "relaunch_and_confirm": "调试端口不可用时重启 ChatGPT，再执行一次确认扫描。",
  "queue_enqueue": "把 1-50 个任务写入可恢复任务队列。",
  "queue_start": "启动任务队列；默认等待下一个待验收任务。",
  "queue_resume": "恢复已暂停的任务队列，不默认阻塞等待验收。",
  "queue_status": "查看任务队列、插件 worker、网络等待和任务状态。",
  "queue_update": "在不停止长期 Action 的情况下更新任务修订和规范，并在下一轮 Chat 生效。",
  "queue_attach": "把已有 ChatGPT conversationId 绑定到指定队列任务。",
  "queue_wait_review": "等待下一个待验收、阻塞或失败的任务。",
  "queue_review": "接受任务验收，或携带 feedback 退回重新执行。",
  "queue_pause": "暂停调度新任务；已落盘状态会保留。",
  "queue_retry": "恢复中断任务，可更新 connector 并附加恢复说明。",
  "queue_cancel": "取消指定任务并停止其插件 worker。",
  "queue_watchdog": "超过阈值仍未完成时安全重建插件 Chat，并重启队列守护。",
  "queue_heartbeat": "检查本地队列 watcher；进程退出或运行时升级时自动重启，不发送任务消息。",
  "start_actions_runner": "刷新加密任务状态与登录 Secret，并启动最长六小时的 GitHub Actions 持续运行器。",
  "sync_actions_credentials": "从已打开的 ChatGPT 桌面 app renderer 实时导出会话并同步到 GitHub Secrets。",
  "login_and_sync_actions": "按需打开 ChatGPT 桌面应用，等待 app renderer 登录完成后实时同步 ChatGPT 与 Codex 凭证，并启动 GitHub Actions。",
  "verify_chatgpt_login": "验证当前 ChatGPT 桌面实例能否创建插件自有的 Chat renderer（可见或隐藏）。",
  "send_message": "在插件自有的 Chat 页面中发送一条消息。",
  "add_connector": "在插件自有的 Chat 页面中选择一个 ChatGPT connector。",
  "get_reply": "读取插件自有 Chat 页面中的最新回复。",
  "chat_status": "读取插件自有 Chat 表面、conversationId 和页面状态。",
  "send_and_watch": "发送工作目标、读取自然结果，再由新规划 Chat 验收并编排下一轮。",
]

func nativeCommandUsage(_ command: String, executable: String) -> String {
  switch command {
  case "status", "diagnose", "stop", "queue_status", "queue_pause", "queue_heartbeat":
    return "\(executable) \(command)"
  case "audit":
    return "\(executable) audit [limit]"
  case "account_add", "account_login_link", "account_switch", "account_rename", "account_status", "account_sync", "account_remove",
       "start", "scan", "sweep", "relaunch_and_confirm", "queue_enqueue",
       "queue_start", "queue_resume", "queue_attach", "queue_wait_review",
       "queue_review", "queue_update", "queue_retry", "queue_cancel", "queue_watchdog",
       "start_actions_runner", "sync_actions_credentials", "login_and_sync_actions", "verify_chatgpt_login", "send_message",
       "add_connector", "get_reply", "chat_status", "send_and_watch":
    return "\(executable) \(command) ['{...JSON...}']"
  default:
    return "\(executable) \(command)"
  }
}

func nativeCommandExample(_ command: String, executable: String) -> String? {
  switch command {
  case "start":
    return "\(executable) start '{\"approveAll\":true,\"intervalMs\":750}'"
  case "account_add":
    return "\(executable) account_add '{\"label\":\"工作账号\",\"start\":true}'"
  case "account_login_link":
    return "\(executable) account_login_link '{\"label\":\"工作账号\"}'"
  case "scan":
    return "\(executable) scan '{\"approveAll\":true}'"
  case "audit":
    return "\(executable) audit 20"
  case "queue_enqueue":
    return "\(executable) queue_enqueue '{\"tasks\":[{\"id\":\"task-1\",\"title\":\"修复问题\",\"prompt\":\"完成实现并验证\"}],\"start\":true}'"
  case "queue_start":
    return "\(executable) queue_start '{\"waitForReview\":false,\"maxConcurrent\":2}'"
  case "queue_review":
    return "\(executable) queue_review '{\"taskId\":\"task-1\",\"accepted\":true}'"
  case "queue_update":
    return "\(executable) queue_update '{\"taskId\":\"task-1\",\"revision\":2,\"specSources\":[\"docs/spec.md\"],\"specDigest\":\"sha256:...\",\"directive\":\"采用更新后的规范\"}'"
  case "queue_retry":
    return "\(executable) queue_retry '{\"taskId\":\"task-1\",\"connector\":\"devspace1\",\"feedback\":\"从当前 checkout 继续\"}'"
  case "queue_watchdog":
    return "\(executable) queue_watchdog '{\"staleAfterSeconds\":21600,\"force\":false}'"
  case "start_actions_runner":
    return "\(executable) start_actions_runner"
  case "sync_actions_credentials":
    return "\(executable) sync_actions_credentials '{\"waitSeconds\":600,\"start\":true}'"
  case "login_and_sync_actions":
    return "\(executable) login_and_sync_actions '{\"waitSeconds\":600,\"start\":true}'"
  case "send_message":
    return "\(executable) send_message '{\"message\":\"检查当前状态\",\"connector\":\"devspace1\"}'"
  case "send_and_watch":
    return "\(executable) send_and_watch '{\"message\":\"完成任务并验证\",\"connector\":\"devspace1\",\"timeout\":21600}'"
  default:
    return nil
  }
}

func nativeHelpText(topic: String? = nil) -> (text: String, known: Bool) {
  let executable = URL(fileURLWithPath: CommandLine.arguments.first ?? "chatgpt-auto-confirm")
    .lastPathComponent
  if let topic, !topic.isEmpty {
    guard let summary = nativeCommandSummaries[topic] else {
      return ("未知公开命令：\(topic)\n运行 \(executable) --help 查看可用命令。\n", false)
    }
    var lines = [
      "ChatGPT 自动确认 · \(topic)",
      "",
      summary,
      "",
      "用法：",
      "  \(nativeCommandUsage(topic, executable: executable))",
      "",
      "说明：",
      "  JSON 参数必须是一个 JSON 对象，并作为第二个位置参数传入。",
      "  也可以运行 \(executable) \(topic) --help 查看本页。",
    ]
    if let example = nativeCommandExample(topic, executable: executable) {
      lines.append(contentsOf: ["", "示例：", "  \(example)"])
    }
    lines.append("")
    return (lines.joined(separator: "\n"), true)
  }

  let text = """
  login_and_sync_actions JSON  open the ChatGPT desktop app, sync both live credentials, and start the runner

ChatGPT 自动确认 macOS 原生运行时

用途：
  在后台扫描 ChatGPT 授权卡、自动确认允许操作，并用插件自有 Chat 页面执行可恢复任务队列；页面可见或隐藏。
  不切换用户页面、不激活窗口、不移动系统鼠标。

用法：
  \(executable) --help
  \(executable) -h
  \(executable) help [command]
  \(executable) <command> --help
  \(executable) <command> [JSON 或参数]

自动确认：
  status                 查看整体状态
  diagnose               执行只读诊断
  start [JSON]           启动后台自动确认
  stop                   停止后台自动确认
  scan [JSON]            立即扫描一次
  sweep [JSON]           原地扫描全部 renderer
  audit [limit]          查看最近 1-100 条审计事件
  relaunch_and_confirm   必要时重启 ChatGPT 后扫描

任务队列：
  queue_enqueue JSON     添加可恢复任务
  queue_start [JSON]     启动队列并可等待验收
  queue_resume [JSON]    恢复队列
  queue_status           查看队列状态
  queue_update JSON      动态更新任务修订和规范
  queue_attach JSON      绑定已有 conversationId
  queue_wait_review JSON 等待待验收任务
  queue_review JSON      提交验收结果
  queue_pause            暂停队列
  queue_retry JSON       恢复中断任务
  queue_cancel JSON      取消任务
  queue_watchdog JSON    检查超时并安全恢复队列
  start_actions_runner   启动六小时 GitHub Actions 持续运行器
  sync_actions_credentials JSON  从已打开的桌面 app renderer 实时抓取当前两份登录凭证并同步，可选启动 Actions
  login_and_sync_actions JSON    按需打开桌面应用后使用相同实时抓取方式同步凭证

插件 Chat：
  send_message JSON      发送消息
  add_connector JSON     选择 connector
  get_reply [JSON]       读取最新回复
  chat_status [JSON]     查看插件 Chat 状态
  send_and_watch JSON    工作自然结果 → 新规划 Chat → 下一轮工作

帮助：
  \(executable) help start
  \(executable) queue_enqueue --help

常用示例：
  \(executable) status
  \(executable) start '{"approveAll":true,"intervalMs":750}'
  \(executable) audit 20
  \(executable) queue_status
  \(executable) send_and_watch '{"message":"完成任务并验证","connector":"devspace1","timeout":21600}'

环境变量：
  CHATGPT_AUTO_CONFIRM_STATE         覆盖自动确认状态文件路径
  CHATGPT_AUTO_CONFIRM_QUEUE_STATE   覆盖任务队列状态文件路径
  CHATGPT_AUTO_CONFIRM_CDP_HOST      覆盖 ChatGPT 调试主机
  CHATGPT_AUTO_CONFIRM_CDP_PORT      覆盖 ChatGPT 调试端口
  CHATGPT_AUTO_CONFIRM_DEBUG=1       输出调试日志

退出码：
  0  命令成功或帮助正常显示
  1  参数、运行时或业务执行失败
  2  未知命令或未知帮助主题

内部命令 watch 和 queue_watch 由运行时自动启动，不建议手动调用。
外层 Mahayana CLI 用法：fabushi-plugin-cli --plugin chatgpt-auto-confirm --help

"""
  return (text, true)
}

func printNativeHelp(_ topic: String? = nil) -> Never {
  let help = nativeHelpText(topic: topic)
  FileHandle.standardOutput.write(Data(help.text.utf8))
  Foundation.exit(help.known ? 0 : 2)
}

struct ActionsLoginTarget {
  let port: Int
  let targetId: String
  let wsURL: String
  let url: String
}

func actionsLoginPorts() -> [Int] {
  let state = loadState()
  var ports = [CDPClient.port()]
  if let backgroundPort = state.backgroundAppPort {
    ports.append(backgroundPort)
  }
  ports.append(9324)
  var seen = Set<Int>()
  return ports.filter { seen.insert($0).inserted }
}

func actionsDesktopTarget() -> ActionsLoginTarget? {
  for port in actionsLoginPorts() {
    let targets = CDPClient.fetchTargets(portOverride: port).filter { target in
      guard isLoadedApprovalRendererTarget(target),
            let url = target["url"] as? String else { return false }
      return !url.contains("avatar-overlay")
        && url.hasPrefix("app://-/index.html")
    }
    for target in targets {
      guard let targetId = target["id"] as? String,
            let wsURL = target["webSocketDebuggerUrl"] as? String,
            let url = target["url"] as? String else { continue }
      return ActionsLoginTarget(
        port: port,
        targetId: targetId,
        wsURL: wsURL,
        url: url
      )
    }
  }
  return nil
}

func ensureChatGPTDesktopRunning() {
  if actionsDesktopTarget() != nil { return }
  let runningApplications = runningChatGptApplications()
  for application in runningApplications {
    application.terminate()
  }
  Thread.sleep(forTimeInterval: 1.0)
  for application in runningApplications where !application.isTerminated {
    application.forceTerminate()
  }
  let applicationURL = URL(fileURLWithPath: "/Applications/ChatGPT.app")
  guard FileManager.default.fileExists(atPath: applicationURL.path) else { return }
  let configuration = NSWorkspace.OpenConfiguration()
  configuration.arguments = ["--remote-debugging-port=\(CDPClient.port())"]
  NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { _, _ in }
}

func actionsDesktopState(_ target: ActionsLoginTarget) -> [String: Any]? {
  cdpValue(
    port: target.port,
    targetId: target.targetId,
    expression: #"""
    (() => {
      const normalize = value => (value || '').replace(/\s+/g, ' ').trim();
      const bodyText = normalize(document.body?.innerText).slice(0, 12000);
      const controls = [...document.querySelectorAll(
        'button, [role="button"], [role="tab"], [aria-label]'
      )];
      // Keep each label source independent. Electron controls commonly expose
      // the same visible value through both innerText and textContent; joining
      // them turns "Chat" into "Chat Chat" and "Try again" into
      // "Try again Try again", defeating exact control recognition.
      const labels = controls.flatMap(element => [
        element.innerText,
        element.textContent,
        element.getAttribute('aria-label'),
        element.getAttribute('title')
      ]).map(normalize).filter(Boolean);
      const exact = label => labels.some(value => value.toLowerCase() === label);
      const hasChat = exact('chat') || exact('聊天');
      const hasWork = exact('work') || exact('工作');
      const currentMode = labels.find(value =>
        /current mode|当前模式|目前模式/i.test(value)
      ) || '';
      const asksForLogin = /(^|\n)(log in|sign up|登录|登入|註冊|注册)(\n|$)/i.test(bodyText);
      const workComposer = !!document.querySelector('[data-codex-composer="true"]');
      const retryAvailable = labels.some(value => {
        const normalized = value.toLowerCase();
        return normalized === 'try again' || normalized === '重试' || normalized === '再试一次';
      }) && /oops|error|出错/i.test(bodyText);
      const appOrigin = location.protocol === 'app:';
      const bridge = !!window.electronBridge;
      const authenticated = appOrigin && bridge && !asksForLogin
        && document.readyState === 'complete' && bodyText.length > 50
        && !!(currentMode || workComposer || hasChat || hasWork);
      return {
        authenticated,
        appOrigin,
        bridge,
        asksForLogin,
        hasChat,
        hasWork,
        workComposer,
        currentMode: currentMode.slice(0, 160),
        retryAvailable,
        bodyLength: bodyText.length,
        url: location.href,
        readyState: document.readyState
      };
    })()
    """#,
    timeout: 5.0
  )
}

func actionsControllerShellIsReady(_ state: [String: Any]) -> Bool {
  state["authenticated"] as? Bool ?? false
}

@discardableResult
func retryActionsDesktopTransientError(_ target: ActionsLoginTarget) -> Bool {
  guard let retry = cdpValue(
    port: target.port,
    targetId: target.targetId,
    expression: #"""
    (() => {
      const normalize = value => (value || '').replace(/\s+/g, ' ').trim().toLowerCase();
      const allowed = new Set(['try again', '重试', '再试一次']);
      const label = node => normalize(
        node.getAttribute('aria-label') || node.innerText || node.textContent
          || node.getAttribute('title')
      );
      const button = [...document.querySelectorAll('button, [role="button"]')]
        .find(node => allowed.has(label(node))
          && !node.disabled
          && node.getAttribute('aria-disabled') !== 'true');
      if (!button) return { found: false };
      const rect = button.getBoundingClientRect();
      return {
        found: true,
        x: rect.left + rect.width / 2,
        y: rect.top + rect.height / 2
      };
    })()
    """#,
    timeout: 4.0
  ), retry["found"] as? Bool == true,
     let x = (retry["x"] as? NSNumber)?.doubleValue,
     let y = (retry["y"] as? NSNumber)?.doubleValue else { return false }
  _ = CDPClient.activateTarget(target.targetId, portOverride: target.port)
  return CDPClient.clickTarget(target.targetId, x: x, y: y, portOverride: target.port)
}

func base64URLDecodedData(_ value: String) -> Data? {
  var normalized = value.replacingOccurrences(of: "-", with: "+")
    .replacingOccurrences(of: "_", with: "/")
  let remainder = normalized.count % 4
  if remainder > 0 {
    normalized.append(String(repeating: "=", count: 4 - remainder))
  }
  return Data(base64Encoded: normalized)
}

func codexChatGPTIdentifiers() -> Set<String> {
  let authURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".codex/auth.json")
  guard let data = try? Data(contentsOf: authURL),
        let auth = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let tokens = auth["tokens"] as? [String: Any],
        let accountId = tokens["account_id"] as? String,
        let idToken = tokens["id_token"] as? String else { return [] }
  var identifiers = Set([accountId])
  let parts = idToken.split(separator: ".", omittingEmptySubsequences: false)
  guard parts.count >= 2,
        let payloadData = base64URLDecodedData(String(parts[1])),
        let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
        let claims = payload["https://api.openai.com/auth"] as? [String: Any] else {
    return identifiers
  }
  for key in ["chatgpt_account_id", "chatgpt_user_id"] {
    if let value = claims[key] as? String, !value.isEmpty {
      identifiers.insert(value)
    }
  }
  return identifiers
}

func actionsSessionCookiesURL() -> URL {
  if let override = ProcessInfo.processInfo.environment["CHATGPT_SESSION_COOKIES_PATH"],
     !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
    return URL(fileURLWithPath: override)
  }
  return stateURL().deletingLastPathComponent().appendingPathComponent("session-cookies.json")
}

func writeActionsSessionCookies(_ cookies: [[String: Any]]) throws -> URL {
  let normalized = cookies.compactMap { cookie -> [String: Any]? in
    guard let name = cookie["name"] as? String,
          let value = cookie["value"] as? String,
          let domain = cookie["domain"] as? String,
          !name.isEmpty, !value.isEmpty, !domain.isEmpty else { return nil }
    let lowerDomain = domain.lowercased().hasPrefix(".")
      ? String(domain.lowercased().dropFirst())
      : domain.lowercased()
    let allowedDomain = lowerDomain == "chatgpt.com"
      || lowerDomain.hasSuffix(".chatgpt.com")
      || lowerDomain == "openai.com"
      || lowerDomain.hasSuffix(".openai.com")
    guard allowedDomain else {
      return nil
    }
    var result: [String: Any] = [
      "name": name,
      "value": value,
      "domain": domain,
      "path": cookie["path"] as? String ?? "/",
      "secure": cookie["secure"] as? Bool ?? true,
      "httpOnly": cookie["httpOnly"] as? Bool ?? false,
    ]
    if let sameSite = cookie["sameSite"] as? String, !sameSite.isEmpty {
      result["sameSite"] = sameSite
    }
    if let expires = cookie["expires"] as? NSNumber {
      result["expires"] = expires
    }
    return result
  }
  guard !normalized.isEmpty else {
    throw NSError(
      domain: "chatgpt-auto-confirm",
      code: 41,
      userInfo: [NSLocalizedDescriptionKey: "没有捕获到有效的 ChatGPT 会话凭证"]
    )
  }
  let payload: [String: Any] = ["cookies": normalized]
  guard JSONSerialization.isValidJSONObject(payload),
        let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
    throw NSError(
      domain: "chatgpt-auto-confirm",
      code: 42,
      userInfo: [NSLocalizedDescriptionKey: "ChatGPT 会话凭证无法编码"]
    )
  }
  let url = actionsSessionCookiesURL()
  try FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  try data.write(to: url, options: .atomic)
  try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  return url
}

func actionsRunnerScriptURL() -> URL {
  let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
  return executableURL
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("scripts")
    .appendingPathComponent("dispatch-actions-runner.sh")
}

func runActionsRunnerDispatch(
  sessionCookiesPath: String? = nil,
  authPath: String? = nil,
  accountId: String? = nil,
  startRunner: Bool = true
) -> (ok: Bool, message: String) {
  let scriptURL = actionsRunnerScriptURL()
  guard FileManager.default.fileExists(atPath: scriptURL.path) else {
    return (false, "actions_dispatch_script_missing")
  }
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/bin/sh")
  process.arguments = [scriptURL.path]
  var environment = ProcessInfo.processInfo.environment
  if let sessionCookiesPath {
    environment["CHATGPT_SESSION_COOKIES_PATH"] = sessionCookiesPath
  }
  if let authPath {
    environment["CHATGPT_CODEX_AUTH_PATH"] = authPath
  }
  if let accountId {
    environment["CHATGPT_ACCOUNT_ID"] = accountId
  }
  environment["CHATGPT_AUTO_CONFIRM_DISPATCH"] = startRunner ? "true" : "false"
  process.environment = environment
  let stdout = Pipe()
  let stderr = Pipe()
  process.standardOutput = stdout
  process.standardError = stderr
  do {
    try process.run()
    process.waitUntilExit()
    let outputText = String(
      data: stdout.fileHandleForReading.readDataToEndOfFile(),
      encoding: .utf8
    )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let errorText = String(
      data: stderr.fileHandleForReading.readDataToEndOfFile(),
      encoding: .utf8
    )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return (
      process.terminationStatus == 0,
      process.terminationStatus == 0
        ? (outputText.isEmpty ? "GitHub Actions 已启动" : outputText)
        : (errorText.isEmpty ? "github_cli_failed" : errorText)
    )
  } catch {
    return (false, error.localizedDescription)
  }
}

func finishActionsCredentialSync(
  cookieURL: URL,
  cookieCount: Int,
  startRunner: Bool
) -> Never {
  let dispatch = runActionsRunnerDispatch(
    sessionCookiesPath: cookieURL.path,
    startRunner: startRunner
  )
  guard dispatch.ok else {
    output([
      "ok": false,
      "errorCode": "github_cli_failed",
      "message": dispatch.message,
      "cookieCount": cookieCount,
    ], exitCode: 1)
  }
  output([
    "ok": true,
    "credentialsSynchronized": true,
    "accountVerified": true,
    "cookieCount": cookieCount,
    "credentialSource": "live-desktop-renderer",
    "started": startRunner,
    "secrets": [
      "CHATGPT_CODEX_AUTH_B64",
      "CHATGPT_SESSION_COOKIES_B64",
    ],
    "repository": "bhrumom/fabushi",
    "workflow": startRunner ? "chatgpt-auto-confirm-runner.yml" : "",
    "message": startRunner
      ? "已验证并同步当前 ChatGPT 桌面 app renderer 会话，GitHub Actions 已启动。"
      : "已验证并同步当前 ChatGPT 桌面 app renderer 会话。",
  ])
}

func syncLiveActionsCredentials(
  waitSeconds: Int,
  startRunner: Bool,
  openDesktopIfNeeded: Bool = false
) -> Never {
  guard !codexChatGPTIdentifiers().isEmpty else {
    output([
      "ok": false,
      "errorCode": "codex_auth_missing",
      "message": "本机 Codex 凭证不存在或不完整，请先登录 ChatGPT。",
    ], exitCode: 1)
  }
  let deadline = Date().addingTimeInterval(TimeInterval(waitSeconds))
  var lastState: [String: Any] = [:]
  var verifiedTarget: ActionsLoginTarget?
  var target = actionsDesktopTarget()
  if target == nil && openDesktopIfNeeded {
    ensureChatGPTDesktopRunning()
  }
  while Date() < deadline {
    if let currentTarget = target,
       let state = actionsDesktopState(currentTarget) {
      lastState = state
      if state["authenticated"] as? Bool == true {
        verifiedTarget = currentTarget
        break
      }
    }
    target = actionsDesktopTarget() ?? target
    Thread.sleep(forTimeInterval: 2)
  }
  guard let verifiedTarget else {
    output([
      "ok": false,
      "errorCode": lastState.isEmpty
        ? "chatgpt_desktop_state_unavailable"
        : "chatgpt_desktop_session_required",
      "message": "没有找到已登录的 ChatGPT 桌面 app renderer；没有上传任何凭证。",
    ], exitCode: 1)
  }
  let cookies = CDPClient.allCookies(wsURLString: verifiedTarget.wsURL, timeout: 8.0)
  do {
    let cookieURL = try writeActionsSessionCookies(cookies)
    finishActionsCredentialSync(
      cookieURL: cookieURL,
      cookieCount: cookies.count,
      startRunner: startRunner
    )
  } catch {
    output([
      "ok": false,
      "errorCode": "actions_credentials_sync_failed",
      "message": error.localizedDescription,
    ], exitCode: 1)
  }
}

func captureLiveDesktopAccountCredentials() throws -> (auth: Data, cookies: Data) {
  let authURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".codex/auth.json")
  guard let auth = try? Data(contentsOf: authURL), accountAuthDataIsUsable(auth) else {
    throw NSError(domain: "chatgpt-auto-confirm", code: 706,
      userInfo: [NSLocalizedDescriptionKey: "当前桌面会话没有可用 Codex 凭据"])
  }
  guard let target = actionsDesktopTarget(),
        let state = actionsDesktopState(target),
        state["authenticated"] as? Bool == true else {
    throw NSError(domain: "chatgpt-auto-confirm", code: 707,
      userInfo: [NSLocalizedDescriptionKey: "当前 ChatGPT renderer 未登录"])
  }
  let cookies = CDPClient.allCookies(wsURLString: target.wsURL, timeout: 8.0)
  guard !cookies.isEmpty,
        let cookieData = try? JSONSerialization.data(withJSONObject: ["cookies": cookies], options: [.sortedKeys]) else {
    throw NSError(domain: "chatgpt-auto-confirm", code: 708,
      userInfo: [NSLocalizedDescriptionKey: "当前 renderer 没有可导出的 Cookie"])
  }
  return (auth, cookieData)
}

func accountStatusPayload(_ account: AccountRecord) -> [String: Any] {
  let hasAuth = accountAuthData(account) != nil
  let hasCookies = accountCookieData(account) != nil
  var payload = accountPublicPayload(account)
  payload["hasCodexCredential"] = hasAuth
  payload["hasSessionCookies"] = hasCookies
  if account.status == "active" && (!hasAuth || !hasCookies) {
    payload["status"] = "needs_login"
  }
  return payload
}

func accountTemporaryCookieURL(_ account: AccountRecord, data: Data) throws -> URL {
  let url = accountsRootURL().appendingPathComponent(".\(account.id)-cookies-\(UUID().uuidString).json")
  try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  try data.write(to: url, options: .atomic)
  try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  return url
}

func accountDispatch(_ account: AccountRecord, authData: Data, cookieData: Data, startRunner: Bool) -> (ok: Bool, message: String) {
  do {
    let authURL = accountCodexAuthURL(account)
    try accountCreateDirectories(account)
    try authData.write(to: authURL, options: .atomic)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authURL.path)
    let cookieURL = try accountTemporaryCookieURL(account, data: cookieData)
    defer { try? FileManager.default.removeItem(at: cookieURL) }
    return runActionsRunnerDispatch(
      sessionCookiesPath: cookieURL.path,
      authPath: authURL.path,
      accountId: account.id,
      startRunner: startRunner
    )
  } catch {
    return (false, error.localizedDescription)
  }
}

func accountCleanupUnregisteredProfile(_ account: AccountRecord) {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
  process.arguments = ["-TERM", "-f", "--user-data-dir=\(accountProfileURL(account).path)"]
  process.standardInput = FileHandle.nullDevice
  process.standardOutput = FileHandle.nullDevice
  process.standardError = FileHandle.nullDevice
  try? process.run()
  process.waitUntilExit()
  try? FileManager.default.removeItem(at: accountsRootURL().appendingPathComponent(account.id, isDirectory: true))
}

func removeGitHubAccountEnvironment(_ accountId: String) {
  let script = accountScriptURL("remove-account-environment.sh")
  guard FileManager.default.fileExists(atPath: script.path) else { return }
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/bin/sh")
  process.arguments = [script.path, accountId]
  process.standardInput = FileHandle.nullDevice
  process.standardOutput = FileHandle.nullDevice
  process.standardError = FileHandle.nullDevice
  try? process.run()
  process.waitUntilExit()
}

func accountCommitSession(_ session: AccountLoginSession, label: String, startRunner: Bool) -> Never {
  var records = loadAccounts()
  guard let fingerprint = accountFingerprint(data: session.authData) else {
    accountCleanupUnregisteredProfile(session.account)
    output(["ok": false, "errorCode": "account_identity_missing", "message": "登录凭据没有可验证的账号标识；没有保存凭据。"], exitCode: 1)
  }
  let now = isoFormatter.string(from: Date())
  let existingIndex = records.firstIndex(where: { $0.fingerprint == fingerprint })
  let account: AccountRecord
  if let existingIndex {
    account = records[existingIndex]
    // A re-login refreshes the existing account rather than creating a
    // duplicate.  Keep its opaque id and GitHub Environment stable.
    _ = copyProfileForDedicatedQueueWorker(
      source: accountProfileURL(session.account).path,
      destination: accountProfileURL(account).path
    )
    var updated = account
    updated.label = label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? account.label : String(label.prefix(80))
    updated.status = "active"
    updated.lastLocalVerifiedAt = now
    records[existingIndex] = updated
  } else {
    guard records.count < maximumAccountCount else {
      accountCleanupUnregisteredProfile(session.account)
      output(["ok": false, "errorCode": "account_limit_reached", "message": "最多支持 \(maximumAccountCount) 个账号。"], exitCode: 1)
    }
    var added = session.account
    added.label = defaultAccountLabel(AccountRecord(
      id: added.id, label: label, fingerprint: fingerprint, status: "active",
      isDefault: records.isEmpty, lastLocalVerifiedAt: now, lastCloudVerifiedAt: nil,
      githubEnvironment: added.githubEnvironment, latestActionId: nil,
      profilePath: added.profilePath, codexHomePath: added.codexHomePath
    ))
    added.fingerprint = fingerprint
    added.status = "active"
    added.isDefault = records.isEmpty
    added.lastLocalVerifiedAt = now
    records.append(added)
    account = added
  }
  guard accountHiddenSmoke(session) else {
    if existingIndex == nil { accountCleanupUnregisteredProfile(account) }
    output(["ok": false, "errorCode": "account_credential_validation_failed", "message": "账号登录成功，但凭据验证未通过；没有保存半套凭据。"], exitCode: 1)
  }
  do {
    try accountStoreCredentials(account, authData: session.authData, cookieData: session.cookieData)
    try saveAccounts(records)
  } catch {
    if existingIndex == nil { accountCleanupUnregisteredProfile(account) }
    output(["ok": false, "errorCode": "account_store_failed", "message": "账号凭据保存失败；没有完成账号注册。"], exitCode: 1)
  }
  let dispatch = accountDispatch(account, authData: session.authData, cookieData: session.cookieData, startRunner: startRunner)
  guard dispatch.ok else {
    output(["ok": false, "errorCode": "account_github_sync_failed", "account": accountPublicPayload(account), "message": dispatch.message], exitCode: 1)
  }
  var payload = accountStatusPayload(account)
  payload["ok"] = true
  payload["credentialsSynchronized"] = true
  payload["started"] = startRunner
  payload["message"] = startRunner ? "账号已保存、上传并通过登录凭据验证。" : "账号已保存并上传。"
  output(payload)
}

func accountScriptURL(_ name: String) -> URL {
  let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
  return executableURL.deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("scripts").appendingPathComponent(name)
}

func startAccountLoginLink(label: String) -> Never {
  let script = accountScriptURL("account-login-link.mjs")
  guard FileManager.default.fileExists(atPath: script.path) else {
    output(["ok": false, "errorCode": "account_login_link_script_missing", "message": "登录链接服务不可用。"], exitCode: 1)
  }
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  process.arguments = ["node", script.path, "--runtime", URL(fileURLWithPath: CommandLine.arguments[0]).path, "--label", String(label.prefix(80))]
  let pipe = Pipe()
  process.standardOutput = pipe
  process.standardError = FileHandle.nullDevice
  do {
    try process.run()
    let data = (try? pipe.fileHandleForReading.read(upToCount: 16_384)) ?? Data()
    guard let line = String(data: data, encoding: .utf8),
          let first = line.split(whereSeparator: \.isNewline).first,
          let raw = first.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
          object["ok"] as? Bool == true else {
      output(["ok": false, "errorCode": "account_login_link_start_failed", "message": "无法启动本地一次性登录链接。"], exitCode: 1)
    }
    var payload = object
    payload["message"] = "登录链接已生成，仅绑定本机 127.0.0.1，十分钟内只能使用一次。"
    output(payload)
  } catch {
    output(["ok": false, "errorCode": "account_login_link_start_failed", "message": "无法启动本地一次性登录链接。"], exitCode: 1)
  }
}

let commandArguments = Array(CommandLine.arguments.dropFirst())
let command = commandArguments.first ?? "status"
if ["help", "--help", "-h"].contains(command) {
  printNativeHelp(commandArguments.dropFirst().first)
}
if commandArguments.dropFirst().contains(where: { ["--help", "-h"].contains($0) }) {
  printNativeHelp(command)
}
switch command {
case "status":
  output(statusPayload(loadState()))
case "diagnose":
  output(diagnosticPayload())
case "tabs", "mode", "mode-options", "e2e":
  output([
    "ok": false,
    "errorCode": "background_only",
    "message": "严格后台模式不会切换页面、激活 ChatGPT、移动鼠标或向任务输入内容。",
  ], exitCode: 1)
case "start":
  do {
    try withWatcherLifecycleLock {
    let (rules, interval, chatTitles, chatURLs, approveAll) = try parseStartPayload()
    var state = loadState()
    if watcherIsAlive(state.watcherPid), let pid = state.watcherPid {
      kill(pid, SIGTERM)
      state.watcherPid = nil
    }
    // A retry starts from a clean plugin-owned ChatGPT instance. This closes
    // only the exact renderer/profile recorded by the plugin; the user's main
    // ChatGPT window is never selected as a cleanup target.
    closeBackgroundTargets(&state)
    state.enabled = true
    state.rules = rules
    state.approveAll = approveAll
    state.chatTitles = chatTitles
    if !chatURLs.isEmpty {
      let desiredURLs = Set(chatURLs)
      for (url, targetId) in state.backgroundTargets ?? [:] where !desiredURLs.contains(url) {
        _ = CDPClient.closeTarget(targetId)
      }
      state.backgroundTargets = (state.backgroundTargets ?? [:]).filter {
        desiredURLs.contains($0.key)
      }
      state.trackedChatURLs = []
    }
    for chatURL in chatURLs { rememberChatURL(chatURL, in: &state) }
    state.intervalMs = interval
    state.startedAt = isoFormatter.string(from: Date())
    // Keep a plugin-owned background endpoint available for IPC scanning.
    // This process is launched behind the user's app and is never activated;
    // separately, scanIPC also inspects every already-loaded renderer on the
    // normal debugging endpoint without navigating any of them.
    _ = ensureHiddenChatTarget(&state)
    let initial = scan(&state)
    try saveState(state)
    try startWatcher(&state)
    try saveState(state)
    var payload = statusPayload(state)
    payload["initialScan"] = initial
    output(payload)
    }
  } catch {
    output(["ok": false, "errorCode": "start_failed", "message": error.localizedDescription], exitCode: 1)
  }
case "scan":
  var state = loadState()
  if CommandLine.arguments.count >= 3,
     let data = CommandLine.arguments[2].data(using: .utf8),
     let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
    if let approveAll = object["approveAll"] as? Bool {
      state.approveAll = approveAll
    }
    for chatURL in object["chatUrls"] as? [String] ?? [] {
      rememberChatURL(chatURL, in: &state)
    }
    if let rawRules = object["rules"] as? [[String: Any]] {
      state.rules = rawRules.enumerated().compactMap { index, raw -> ApprovalRule? in
        guard let app = (raw["application"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !app.isEmpty,
              let act = (raw["action"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !act.isEmpty,
              let res = (raw["resource"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !res.isEmpty else { return nil }
        return ApprovalRule(
          id: (raw["id"] as? String) ?? "rule-\(index + 1)",
          application: app, action: act, resource: res
        )
      }
    }
  }
  let result = scan(&state)
  try? saveState(state)
  output(result, exitCode: result["ok"] as? Bool == true ? 0 : 1)
case "sweep":
  var state = loadState()
  if CommandLine.arguments.count >= 3,
     let data = CommandLine.arguments[2].data(using: .utf8),
     let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
    if let approveAll = object["approveAll"] as? Bool {
      state.approveAll = approveAll
    }
    if let rawRules = object["rules"] as? [[String: Any]] {
      state.rules = rawRules.enumerated().compactMap { index, raw -> ApprovalRule? in
        guard let app = (raw["application"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !app.isEmpty,
              let act = (raw["action"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !act.isEmpty,
              let res = (raw["resource"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !res.isEmpty else { return nil }
        return ApprovalRule(
          id: (raw["id"] as? String) ?? "rule-\(index + 1)",
          application: app, action: act, resource: res
        )
      }
    }
  }
  var result = scan(&state)
  result["navigationSkipped"] = true
  try? saveState(state)
  output(result, exitCode: result["ok"] as? Bool == true ? 0 : 1)
case "audit":
  let state = loadState()
  let limit = min(100, max(1, CommandLine.arguments.dropFirst(2).first.flatMap(Int.init) ?? 20))
  let events = state.audit.suffix(limit).reversed().map { event -> [String: Any] in
    [
      "at": event.at, "decision": event.decision, "reason": event.reason,
      "clicked": event.clicked, "ruleId": event.ruleId as Any,
      "buttonTitle": event.buttonTitle, "promptText": event.promptText,
      "error": event.error as Any,
    ]
  }
  output(["ok": true, "events": events])
case "relaunch_and_confirm":
  var state = loadState()
  if CommandLine.arguments.count >= 3,
     let data = CommandLine.arguments[2].data(using: .utf8),
     let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
    if let approveAll = object["approveAll"] as? Bool {
      state.approveAll = approveAll
    }
    if let rawRules = object["rules"] as? [[String: Any]] {
      state.rules = rawRules.enumerated().compactMap { index, raw -> ApprovalRule? in
        guard let app = (raw["application"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !app.isEmpty,
              let act = (raw["action"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !act.isEmpty,
              let res = (raw["resource"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !res.isEmpty else { return nil }
        return ApprovalRule(
          id: (raw["id"] as? String) ?? "rule-\(index + 1)",
          application: app, action: act, resource: res
        )
      }
    }
  }
  var relaunchPerformed = false
  if CDPClient.fetchTargets().isEmpty {
    relaunchPerformed = true
    let apps = NSWorkspace.shared.runningApplications.filter {
      $0.bundleIdentifier == "com.openai.chat" || $0.localizedName == "ChatGPT"
    }
    for app in apps {
      app.terminate()
    }
    Thread.sleep(forTimeInterval: 1.0)
    for app in apps where !app.isTerminated {
      app.forceTerminate()
    }
    Thread.sleep(forTimeInterval: 0.5)
    let url = URL(fileURLWithPath: "/Applications/ChatGPT.app")
    let port = CDPClient.port()
    let config = NSWorkspace.OpenConfiguration()
    config.arguments = ["--remote-debugging-port=\(port)"]
    let semaphore = DispatchSemaphore(value: 0)
    NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
      semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 5.0)
    var waited = 0
    while waited < 30 && CDPClient.fetchTargets().isEmpty {
      Thread.sleep(forTimeInterval: 0.25)
      waited += 1
    }
  }
  var result = scan(&state)
  result["relaunchPerformed"] = relaunchPerformed
  try? saveState(state)
  output(result, exitCode: result["ok"] as? Bool == true ? 0 : 1)
case "stop":
  var state = loadState()
  if watcherIsAlive(state.watcherPid), let pid = state.watcherPid { kill(pid, SIGTERM) }
  closeBackgroundTargets(&state)
  state.enabled = false
  state.watcherPid = nil
  try? saveState(state)
  var queueState = loadQueueState()
  stopQueueWorker(&queueState)
  cleanupOrphanedDedicatedTaskWorkerArtifacts(queueState)
  try? saveQueueState(queueState)
  output(statusPayload(state))
case "watch":
  let activity = beginWatcherActivity(
    preventIdleSystemSleep: false,
    reason: "ChatGPT 自动确认后台 watcher"
  )
  defer { ProcessInfo.processInfo.endActivity(activity) }
  while true {
    autoreleasepool {
      var state = loadState()
      guard state.enabled else { Foundation.exit(0) }
      state.watcherPid = getpid()
      keepApprovalBackgroundEndpointAlive(&state)
      _ = scan(&state)
      try? saveState(state)
      Thread.sleep(forTimeInterval: Double(state.intervalMs) / 1_000.0)
    }
  }
case "queue_enqueue":
  let params = commandJSONParams()
  let rawTasks = params["tasks"] as? [[String: Any]] ?? []
  guard !rawTasks.isEmpty, rawTasks.count <= 50 else {
    output(["ok": false, "errorCode": "invalid_tasks", "message": "tasks 必须包含 1-50 个任务"], exitCode: 1)
  }
  let accountRecords = loadAccounts()
  let requestedAccountId = (params["accountId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
  if let requestedAccountId,
     !requestedAccountId.isEmpty,
     accountById(requestedAccountId, records: accountRecords) == nil {
    output(["ok": false, "errorCode": "account_not_found", "message": "入队指定的账号不存在。"], exitCode: 1)
  }
  let defaultAccountId = resolveAccount(requestedAccountId, records: accountRecords)?.id
  do {
    let payload = try withQueueStateLock { state -> [String: Any] in
      var tasks = state.automationTasks ?? []
      var knownIds = Set(tasks.map(\.id))
      let now = isoFormatter.string(from: Date())
      var appendedIds: [String] = []
      for (index, raw) in rawTasks.enumerated() {
        let prompt = (raw["prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = (raw["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !prompt.isEmpty, prompt.count <= 10_000,
              !title.isEmpty, title.count <= 160 else {
          throw NSError(
            domain: "chatgpt-auto-confirm",
            code: 24,
            userInfo: [NSLocalizedDescriptionKey: "第 \(index + 1) 个任务的 title 或 prompt 无效"]
          )
        }
        let requestedId = raw["id"] as? String
        let id = requestedId == nil
          ? "task-\(UUID().uuidString.lowercased())"
          : normalizedTaskId(requestedId)
        guard let id, knownIds.insert(id).inserted else {
          throw NSError(
            domain: "chatgpt-auto-confirm",
            code: 25,
            userInfo: [NSLocalizedDescriptionKey: "任务 id 无效或重复：\(requestedId ?? "")"]
          )
        }
        let taskAccountId = (raw["accountId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
          ?? defaultAccountId
        if let taskAccountId,
           accountById(taskAccountId, records: accountRecords) == nil {
          throw NSError(
            domain: "chatgpt-auto-confirm",
            code: 35,
            userInfo: [NSLocalizedDescriptionKey: "任务 \(id) 引用的账号不存在"]
          )
        }
        let task = AutomationTask(
          id: id,
          accountId: taskAccountId,
          title: title,
          prompt: prompt,
          originalPrompt: prompt,
          promptTemplate: raw["promptTemplate"] as? String ?? "continue-to-complete",
          currentRevision: max(1, raw["revision"] as? Int ?? 1),
          appliedRevision: nil,
          pendingRevision: nil,
          specSources: raw["specSources"] as? [String] ?? [],
          specSnapshot: raw["specSnapshot"] as? String,
          specDigest: raw["specDigest"] as? String,
          repository: raw["repository"] as? String,
          codeDirectory: raw["codeDirectory"] as? String,
          appliedSpecDigest: nil,
          pendingDirective: raw["directive"] as? String,
          applyMode: "next_chat",
          taskUpdates: [],
          specUpdatedAt: now,
          connector: raw["connector"] as? String ?? "devspace1",
          dependsOn: raw["dependsOn"] as? [String] ?? [],
          resourceLocks: raw["resourceLocks"] as? [String] ?? [],
          priority: min(100, max(-100, raw["priority"] as? Int ?? 0)),
          timeout: min(maxChatWatchTimeoutSeconds, max(60, raw["timeout"] as? Int ?? defaultChatWatchTimeoutSeconds)),
          maxTaskContinuations: min(
            20,
            max(0, raw["maxTaskContinuations"] as? Int ?? defaultMaxTaskContinuations)
          ),
          maxRuntimeRetries: min(5, max(0, raw["maxRuntimeRetries"] as? Int ?? 2)),
          attempts: 0,
          reviewRound: 0,
          status: "queued",
          createdAt: now,
          updatedAt: now,
          startedAt: nil,
          finishedAt: nil,
          workerPid: nil,
          workerPort: nil,
          workerTargetId: nil,
          workerStatePath: nil,
          workerProfilePath: nil,
          resultPath: nil,
          conversationId: nil,
          chatURL: nil,
          report: nil,
          lastResultJSON: nil,
          lastError: nil,
          reviewFeedback: nil,
          reviewedAt: nil,
          continuationDepth: 0,
          reportFingerprints: [],
          lastActivitySignature: nil,
          lastProgressAt: nil
        )
        tasks.append(task)
        appendedIds.append(id)
      }
      let allIds = Set(tasks.map(\.id))
      for task in tasks where !task.dependsOn.allSatisfy({ allIds.contains($0) }) {
        throw NSError(
          domain: "chatgpt-auto-confirm",
          code: 26,
          userInfo: [NSLocalizedDescriptionKey: "任务 \(task.id) 引用了不存在的 dependsOn"]
        )
      }
      if let cycle = dependencyCycle(in: tasks) {
        throw NSError(
          domain: "chatgpt-auto-confirm",
          code: 31,
          userInfo: [NSLocalizedDescriptionKey: "任务依赖形成循环：\(cycle.joined(separator: " -> "))"]
        )
      }
      state.automationTasks = tasks
      state.queueMaxConcurrent = min(4, max(1, params["maxConcurrent"] as? Int ?? state.queueMaxConcurrent ?? 2))
      state.queueReviewGate = params["reviewGate"] as? Bool ?? true
      if params["start"] as? Bool ?? true {
        state.queueEnabled = true
        state.queuePaused = false
        try startQueueWatcher(&state)
      }
      var result = queueStatusPayload(state)
      result["enqueuedTaskIds"] = appendedIds
      return result
    }
    output(payload)
  } catch {
    output(["ok": false, "errorCode": "queue_enqueue_failed", "message": error.localizedDescription], exitCode: 1)
  }
case "queue_start", "queue_resume":
  let params = commandJSONParams()
  do {
    let payload = try withQueueStateLock { state -> [String: Any] in
      state.queueEnabled = true
      state.queuePaused = false
      if let maxConcurrent = params["maxConcurrent"] as? Int {
        state.queueMaxConcurrent = min(4, max(1, maxConcurrent))
      }
      try startQueueWatcher(&state)
      return queueStatusPayload(state)
    }
    if command == "queue_start", params["waitForReview"] as? Bool ?? true {
      output(waitForAutomationReview(timeout: params["waitTimeout"] as? Int ?? 3600))
    }
    output(payload)
  } catch {
    output(["ok": false, "errorCode": "queue_start_failed", "message": error.localizedDescription], exitCode: 1)
  }
case "queue_status":
  output(queueStatusPayload(loadQueueState()))
case "queue_update":
  let params = commandJSONParams()
  let taskId = normalizedTaskId(params["taskId"] as? String)
  let revision = params["revision"] as? Int ?? 0
  let expectedRevision = params["expectedRevision"] as? Int
  let specSources = params["specSources"] as? [String] ?? []
  let specSnapshot = (params["specSnapshot"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
  let specDigest = (params["specDigest"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
  let directive = (params["directive"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
  let updatedPrompt = (params["prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
  let updatedTitle = (params["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
  let applyMode = (params["applyMode"] as? String) ?? "next_chat"
  let updateSource = ((params["source"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "operator"
  guard let taskId, revision >= 1,
        ["next_chat", "interrupt"].contains(applyMode),
        specSources.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
        (specSnapshot?.count ?? 0) <= 120_000,
        (directive?.count ?? 0) <= 10_000,
        (updatedPrompt?.count ?? 0) <= 10_000,
        (updatedTitle?.count ?? 0) <= 160 else {
    output([
      "ok": false,
      "errorCode": "invalid_task_update",
      "message": "taskId、revision 或规范内容无效",
    ], exitCode: 1)
  }
  do {
    let payload = try withQueueStateLock { state -> [String: Any] in
      var tasks = state.automationTasks ?? []
      let queueWasEnabled = state.queueEnabled == true
      guard let index = tasks.firstIndex(where: { $0.id == taskId }) else {
        throw NSError(
          domain: "chatgpt-auto-confirm",
          code: 36,
          userInfo: [NSLocalizedDescriptionKey: "没有找到任务 \(taskId)"]
        )
      }
      let existingRevision = max(1, tasks[index].currentRevision ?? 1)
      if let expectedRevision, expectedRevision != existingRevision {
        throw NSError(
          domain: "chatgpt-auto-confirm",
          code: 37,
          userInfo: [NSLocalizedDescriptionKey:
            "任务 \(taskId) 当前修订为 \(existingRevision)，与 expectedRevision 不一致"]
        )
      }
      let incomingDigest = specDigest.flatMap { $0.isEmpty ? nil : $0 }
      if revision == existingRevision,
         (incomingDigest != tasks[index].specDigest
           || specSnapshot != tasks[index].specSnapshot
           || specSources != (tasks[index].specSources ?? [])
           || directive != tasks[index].pendingDirective
           || applyMode != (tasks[index].applyMode ?? "next_chat")
           || (updatedPrompt != nil && updatedPrompt != tasks[index].prompt)
           || (updatedTitle != nil && updatedTitle != tasks[index].title)) {
        throw NSError(
          domain: "chatgpt-auto-confirm",
          code: 38,
          userInfo: [NSLocalizedDescriptionKey:
            "任务 \(taskId) 的 revision \(revision) 已存在且内容不同；必须递增 revision"]
        )
      }
      let changed = revision > existingRevision
        || incomingDigest != tasks[index].specDigest
        || specSnapshot != tasks[index].specSnapshot
        || specSources != (tasks[index].specSources ?? [])
        || directive != tasks[index].pendingDirective
        || applyMode != (tasks[index].applyMode ?? "next_chat")
        || (updatedPrompt != nil && updatedPrompt != tasks[index].prompt)
        || (updatedTitle != nil && updatedTitle != tasks[index].title)
      if revision < existingRevision || !changed {
        var result = queueStatusPayload(state)
        result["updatedTask"] = taskPublicPayload(tasks[index])
        result["updateApplied"] = false
        result["updateReason"] = revision < existingRevision ? "stale_revision" : "unchanged"
        return result
      }
      let now = isoFormatter.string(from: Date())
      tasks[index].originalPrompt = tasks[index].originalPrompt ?? tasks[index].prompt
      tasks[index].currentRevision = revision
      tasks[index].pendingRevision = revision
      tasks[index].specSources = specSources
      tasks[index].specSnapshot = specSnapshot
      tasks[index].specDigest = incomingDigest
      tasks[index].pendingDirective = directive
      tasks[index].applyMode = applyMode
      var updates = tasks[index].taskUpdates ?? []
      updates.append(AutomationTaskUpdate(
        id: UUID().uuidString.lowercased(),
        revision: revision,
        createdAt: now,
        source: updateSource,
        directive: directive ?? "",
        specDigest: incomingDigest ?? "",
        applyMode: applyMode
      ))
      tasks[index].taskUpdates = Array(updates.suffix(100))
      if let updatedPrompt, !updatedPrompt.isEmpty { tasks[index].prompt = updatedPrompt }
      if let updatedTitle, !updatedTitle.isEmpty { tasks[index].title = updatedTitle }
      tasks[index].specUpdatedAt = now
      tasks[index].updatedAt = now
      let updateNotice = "任务规范已动态更新到 revision \(revision)。下一轮必须读取最新规范，旧修订的完成结果无效。"
      if tasks[index].status == "running", applyMode == "next_chat" {
        tasks[index].reviewFeedback = [tasks[index].reviewFeedback, updateNotice]
          .compactMap { $0 }
          .filter { !$0.isEmpty }
          .joined(separator: "\n\n")
      } else if tasks[index].status != "cancelled" {
        if tasks[index].status == "running", applyMode == "interrupt" {
          let port = tasks[index].workerPort ?? state.queueWorkerPort
          let targetId = tasks[index].workerTargetId ?? state.queueWorkerTargetId
          if let port, let targetId,
             queueTargetStateIsUsableForQueue(
               queueTargetRuntimeState(
                 port: port,
                 targetId: targetId,
                 refreshLifecycle: false
               ),
               workerMode: state.queueWorkerMode
             ) {
            _ = cdpValue(
              port: port,
              targetId: targetId,
              expression: stopCurrentResponseJS(),
              timeout: 12.0
            )
          }
          closeDedicatedAutomationTarget(tasks[index], state: state)
        }
        tasks[index].status = "queued"
        tasks[index].startedAt = nil
        tasks[index].finishedAt = nil
        tasks[index].workerPid = nil
        tasks[index].workerPort = nil
        tasks[index].workerTargetId = nil
        tasks[index].workerStatePath = nil
        tasks[index].workerProfilePath = nil
        tasks[index].resultPath = nil
        tasks[index].report = nil
        // A revised goal starts a true first round. Never inherit the old
        // conversation merely because the logical task id stayed stable.
        tasks[index].conversationId = nil
        tasks[index].chatURL = nil
        tasks[index].attempts = 0
        tasks[index].continuationDepth = 0
        tasks[index].reviewConversationId = nil
        tasks[index].reviewStatus = nil
        tasks[index].reviewReport = nil
        tasks[index].lastError = "task_revision_updated"
        tasks[index].reviewFeedback = updateNotice
        tasks[index].waitingUntil = nil
        tasks[index].waitReason = nil
      }
      state.automationTasks = tasks
      if queueWasEnabled {
        state.queueEnabled = true
        state.queuePaused = false
        try startQueueWatcher(&state)
      }
      var result = queueStatusPayload(state)
      result["updatedTask"] = taskPublicPayload(tasks[index])
      result["updateApplied"] = true
      result["applyMode"] = applyMode
      return result
    }
    output(payload)
  } catch {
    output([
      "ok": false,
      "errorCode": "queue_update_failed",
      "message": error.localizedDescription,
    ], exitCode: 1)
  }
case "queue_watchdog":
  let params = commandJSONParams()
  let staleAfterSeconds = min(
    604_800,
    max(300, params["staleAfterSeconds"] as? Int ?? 21_600)
  )
  let force = params["force"] as? Bool ?? false
  let dryRun = params["dryRun"] as? Bool ?? false
  do {
    let payload = try withQueueStateLock { state in
      try recoverQueueWithWatchdog(
        &state,
        staleAfterSeconds: staleAfterSeconds,
        force: force,
        dryRun: dryRun
      )
    }
    output(payload)
  } catch {
    output([
      "ok": false,
      "errorCode": "queue_watchdog_failed",
      "message": error.localizedDescription,
    ], exitCode: 1)
  }
case "queue_heartbeat":
  do {
    let payload = try withQueueStateLock { state -> [String: Any] in
      let watcherWasAlive = watcherIsAlive(state.queueWatcherPid)
      let revisionWasCurrent = state.queueRuntimeRevision == currentQueueRuntimeRevision
      var restarted = false
      if state.queueEnabled == true && (!watcherWasAlive || !revisionWasCurrent) {
        try startQueueWatcher(&state)
        restarted = true
      }
      return [
        "ok": true,
        "queueEnabled": state.queueEnabled == true,
        "queuePaused": state.queuePaused == true,
        "watcherWasAlive": watcherWasAlive,
        "revisionWasCurrent": revisionWasCurrent,
        "restarted": restarted,
        "watcherPid": state.queueWatcherPid as Any,
        "runtimeRevision": state.queueRuntimeRevision as Any,
      ]
    }
    output(payload)
  } catch {
    output([
      "ok": false,
      "errorCode": "queue_heartbeat_failed",
      "message": error.localizedDescription,
    ], exitCode: 1)
  }
case "verify_chatgpt_login":
  let authenticationDeadline = Date().addingTimeInterval(45)
  var lastControllerState: [String: Any] = [:]
  var controllerVerified = false
  var desktopTarget = actionsDesktopTarget()
  while Date() < authenticationDeadline {
    if let target = desktopTarget,
       let controllerState = actionsDesktopState(target) {
      lastControllerState = controllerState
      if actionsControllerShellIsReady(controllerState) {
        controllerVerified = true
        break
      }
      if controllerState["retryAvailable"] as? Bool == true,
         retryActionsDesktopTransientError(target) {
        Thread.sleep(forTimeInterval: 2)
        continue
      }
    }
    desktopTarget = actionsDesktopTarget() ?? desktopTarget
    Thread.sleep(forTimeInterval: 2)
  }
  guard controllerVerified else {
    let loginPrompt = lastControllerState["asksForLogin"] as? Bool ?? false
    output([
      "ok": false,
      "authenticated": false,
      "loginPrompt": loginPrompt,
      "hasComposer": lastControllerState["workComposer"] as? Bool ?? false,
      "bodyLength": lastControllerState["bodyLength"] as? Int ?? 0,
      "url": lastControllerState["url"] as? String ?? "",
      "errorCode": lastControllerState.isEmpty
        ? "chatgpt_login_state_unavailable"
        : (loginPrompt ? "chatgpt_login_required" : "chatgpt_controller_shell_unavailable"),
      "message": lastControllerState.isEmpty
        ? "无法读取 ChatGPT 桌面实例状态"
        : (loginPrompt ? "ChatGPT 桌面实例要求重新登录" : "ChatGPT 桌面控制器未完成初始化"),
    ], exitCode: 1)
  }

  var queueState = loadState()
  guard let hiddenChat = createQueueWorkerTarget(&queueState, reuseExisting: true) else {
    output([
      "ok": false,
      "authenticated": false,
      "loginPrompt": false,
      "hasComposer": false,
      "bodyLength": lastControllerState["bodyLength"] as? Int ?? 0,
      "url": lastControllerState["url"] as? String ?? "",
      "errorCode": "chatgpt_hidden_chat_unavailable",
      "reason": queueState.lastError ?? "hidden_chat_verification_failed",
      "message": "恢复后的 ChatGPT 会话无法创建已认证的隐藏 Chat 页面",
    ], exitCode: 1)
  }
  do {
    try saveState(queueState)
  } catch {
    output([
      "ok": false,
      "authenticated": false,
      "loginPrompt": false,
      "hasComposer": true,
      "bodyLength": lastControllerState["bodyLength"] as? Int ?? 0,
      "url": lastControllerState["url"] as? String ?? "",
      "errorCode": "chatgpt_hidden_chat_state_persist_failed",
      "message": error.localizedDescription,
    ], exitCode: 1)
  }
  output([
    "ok": true,
    "authenticated": true,
    "loginPrompt": false,
    "hasComposer": true,
    "bodyLength": lastControllerState["bodyLength"] as? Int ?? 0,
    "url": lastControllerState["url"] as? String ?? "",
    "hiddenChatPort": hiddenChat.port,
    "hiddenChatTargetId": hiddenChat.targetId,
    "errorCode": "",
    "message": "ChatGPT 插件 Chat 页面已创建并通过认证预检（可见或隐藏）",
  ])
case "account_list":
  let records = loadAccounts()
  output([
    "ok": true,
    "accounts": records.map(accountPublicPayload),
    "defaultAccountId": records.first(where: { $0.isDefault })?.id as Any,
    "count": records.count,
    "max": maximumAccountCount,
  ])
case "account_status":
  let params = commandJSONParams()
  let records = loadAccounts()
  if let account = resolveAccount(params["accountId"] as? String, records: records) {
    var payload = accountStatusPayload(account)
    payload["ok"] = true
    output(payload)
  }
  output(["ok": false, "errorCode": "account_not_found", "message": "没有找到指定账号。"], exitCode: 1)
case "account_switch":
  let params = commandJSONParams()
  let requested = (params["accountId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  var records = loadAccounts()
  guard let index = records.firstIndex(where: { $0.id == requested }) else {
    output(["ok": false, "errorCode": "account_not_found", "message": "没有找到指定账号。"], exitCode: 1)
  }
  for item in records.indices { records[item].isDefault = item == index }
  do {
    try saveAccounts(records)
    output(["ok": true, "defaultAccountId": requested, "message": "默认账号已切换；现有任务的账号不变。"])
  } catch {
    output(["ok": false, "errorCode": "account_switch_failed", "message": "默认账号保存失败。"], exitCode: 1)
  }
case "account_rename":
  let params = commandJSONParams()
  let requested = (params["accountId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  let label = (params["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  guard !label.isEmpty, label.count <= 80 else {
    output(["ok": false, "errorCode": "invalid_account_label", "message": "账号名称不能为空且不能超过 80 个字符。"], exitCode: 1)
  }
  var records = loadAccounts()
  guard let index = records.firstIndex(where: { $0.id == requested }) else {
    output(["ok": false, "errorCode": "account_not_found", "message": "没有找到指定账号。"], exitCode: 1)
  }
  records[index].label = label
  do {
    try saveAccounts(records)
    output(["ok": true, "account": accountPublicPayload(records[index])])
  } catch {
    output(["ok": false, "errorCode": "account_rename_failed", "message": "账号名称保存失败。"], exitCode: 1)
  }
case "account_login_link":
  let params = commandJSONParams()
  startAccountLoginLink(label: (params["label"] as? String) ?? "")
case "account_add":
  let params = commandJSONParams()
  let waitSeconds = min(1_800, max(60, params["waitSeconds"] as? Int ?? 600))
  let startRunner = params["start"] as? Bool ?? true
  let label = (params["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  let records = loadAccounts()
  guard records.count < maximumAccountCount else {
    output(["ok": false, "errorCode": "account_limit_reached", "message": "最多支持 \(maximumAccountCount) 个账号。"], exitCode: 1)
  }
  let id = randomAccountId(Set(records.map(\.id)))
  let account = AccountRecord(
    id: id,
    label: label.isEmpty ? "账号 \(id.suffix(4))" : String(label.prefix(80)),
    fingerprint: "pending",
    status: "needs_login",
    isDefault: records.isEmpty,
    lastLocalVerifiedAt: nil,
    lastCloudVerifiedAt: nil,
    githubEnvironment: accountEnvironmentName(id),
    latestActionId: nil,
    profilePath: accountsRootURL().appendingPathComponent(id, isDirectory: true).appendingPathComponent("profile", isDirectory: true).path,
    codexHomePath: accountsRootURL().appendingPathComponent(id, isDirectory: true).appendingPathComponent("codex-home", isDirectory: true).path
  )
  do {
    let session = try accountCredentialSession(account, waitSeconds: waitSeconds, openLoginWindow: true)
    accountCommitSession(session, label: label, startRunner: startRunner)
  } catch {
    accountCleanupUnregisteredProfile(account)
    output(["ok": false, "errorCode": "account_login_failed", "message": "账号登录未完成；没有保存凭据。"], exitCode: 1)
  }
case "account_sync":
  let params = commandJSONParams()
  let records = loadAccounts()
  guard let account = resolveAccount(params["accountId"] as? String, records: records) else {
    output(["ok": false, "errorCode": "account_not_found", "message": "没有找到指定账号。"], exitCode: 1)
  }
  let waitSeconds = min(1_800, max(30, params["waitSeconds"] as? Int ?? 600))
  let startRunner = params["start"] as? Bool ?? true
  do {
    // Always prefer the currently open ChatGPT desktop session. Do not
    // bootstrap an expired isolated profile: doing that caused repeated
    // Keychain prompts and stale account recovery loops.
    let live = try captureLiveDesktopAccountCredentials()
    try accountStoreCredentials(account, authData: live.auth, cookieData: live.cookies)
    try accountCreateDirectories(account)
    try live.auth.write(to: accountCodexAuthURL(account), options: .atomic)
    let session = AccountLoginSession(
      account: account,
      port: 0,
      target: actionsDesktopTarget()!,
      authData: live.auth,
      cookieData: live.cookies
    )
    accountCommitSession(session, label: account.label, startRunner: startRunner)
  } catch {
    output(["ok": false, "errorCode": "account_sync_failed", "message": "账号同步未完成；没有覆盖现有凭据。"], exitCode: 1)
  }
case "account_remove":
  let params = commandJSONParams()
  let requested = (params["accountId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  guard params["confirm"] as? Bool == true else {
    output(["ok": false, "errorCode": "confirmation_required", "message": "删除账号必须显式确认。"], exitCode: 1)
  }
  var records = loadAccounts()
  guard let index = records.firstIndex(where: { $0.id == requested }) else {
    output(["ok": false, "errorCode": "account_not_found", "message": "没有找到指定账号。"], exitCode: 1)
  }
  let activeStatuses = Set(["queued", "running", "awaiting_review", "blocked"])
  if let task = (loadQueueState().automationTasks ?? []).first(where: {
    ($0.accountId ?? records[index].id) == requested && activeStatuses.contains($0.status)
  }) {
    output(["ok": false, "errorCode": "account_in_use", "taskId": task.id, "message": "账号仍有运行中的任务，暂不能删除。"], exitCode: 1)
  }
  let removed = records.remove(at: index)
  if removed.isDefault, !records.isEmpty { records[0].isDefault = true }
  do {
    accountRemoveCredentials(removed)
    try saveAccounts(records)
    try? FileManager.default.removeItem(at: accountsRootURL().appendingPathComponent(removed.id, isDirectory: true))
    removeGitHubAccountEnvironment(removed.id)
    output(["ok": true, "removedAccountId": removed.id, "message": "账号及本机凭据已删除。"])
  } catch {
    output(["ok": false, "errorCode": "account_remove_failed", "message": "账号删除失败。"], exitCode: 1)
  }
case "sync_actions_credentials":
  let params = commandJSONParams()
  if let account = resolveAccount(params["accountId"] as? String),
     !ProcessInfo.processInfo.environment.keys.contains("CHATGPT_AUTO_CONFIRM_FORCE_LEGACY_SYNC") {
    let waitSeconds = min(1_800, max(30, params["waitSeconds"] as? Int ?? 600))
    let startRunner = params["start"] as? Bool ?? false
    do {
      guard let storedAuth = accountAuthData(account) else {
        throw NSError(domain: "chatgpt-auto-confirm", code: 705, userInfo: [NSLocalizedDescriptionKey: "默认账号没有可恢复的 Codex 凭据，请重新登录。"])
      }
      try accountCreateDirectories(account)
      try storedAuth.write(to: accountCodexAuthURL(account), options: .atomic)
      let session = try accountCredentialSession(account, waitSeconds: waitSeconds, openLoginWindow: false)
      accountCommitSession(session, label: account.label, startRunner: startRunner)
    } catch {
      output(["ok": false, "errorCode": "account_sync_failed", "message": "默认账号同步未完成；没有覆盖现有凭据。"], exitCode: 1)
    }
  }
  let waitSeconds = min(1_800, max(30, params["waitSeconds"] as? Int ?? 600))
  let startRunner = params["start"] as? Bool ?? false
  syncLiveActionsCredentials(
    waitSeconds: waitSeconds,
    startRunner: startRunner,
    openDesktopIfNeeded: false
  )
case "login_and_sync_actions":
  let params = commandJSONParams()
  if let account = resolveAccount(params["accountId"] as? String),
     !ProcessInfo.processInfo.environment.keys.contains("CHATGPT_AUTO_CONFIRM_FORCE_LEGACY_SYNC") {
    let waitSeconds = min(1_800, max(60, params["waitSeconds"] as? Int ?? 600))
    let startRunner = params["start"] as? Bool ?? true
    do {
      let session = try accountCredentialSession(account, waitSeconds: waitSeconds, openLoginWindow: true)
      accountCommitSession(session, label: account.label, startRunner: startRunner)
    } catch {
      output(["ok": false, "errorCode": "account_login_failed", "message": "默认账号登录未完成；没有保存半套凭据。"], exitCode: 1)
    }
  }
  let waitSeconds = min(1_800, max(30, params["waitSeconds"] as? Int ?? 600))
  let startRunner = params["start"] as? Bool ?? true
  syncLiveActionsCredentials(
    waitSeconds: waitSeconds,
    startRunner: startRunner,
    openDesktopIfNeeded: true
  )
case "start_actions_runner":
  let runnerParams = commandJSONParams()
  let requestedRunnerAccount = (runnerParams["accountId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
  let resolvedRunnerAccount: AccountRecord?
  if let requestedRunnerAccount, !requestedRunnerAccount.isEmpty {
    guard let account = resolveAccount(requestedRunnerAccount) else {
      output(["ok": false, "errorCode": "account_not_found", "message": "指定账号不存在。"], exitCode: 1)
    }
    resolvedRunnerAccount = account
  } else {
    resolvedRunnerAccount = resolveAccount(nil)
  }
  if let account = resolvedRunnerAccount {
    guard let credentials = accountCredentialData(account) else {
      output(["ok": false, "errorCode": "account_credentials_missing", "message": "账号没有可上传的完整凭据，请先重新登录或同步。"], exitCode: 1)
    }
    let dispatch = accountDispatch(
      account,
      authData: credentials.auth,
      cookieData: credentials.cookies,
      startRunner: true
    )
    guard dispatch.ok else {
      output(["ok": false, "errorCode": "github_cli_failed", "accountId": account.id, "message": dispatch.message], exitCode: 1)
    }
    output([
      "ok": true,
      "dispatched": true,
      "accountId": account.id,
      "repository": "bhrumom/fabushi",
      "workflow": "chatgpt-auto-confirm-runner.yml",
      "ref": "main",
      "message": dispatch.message,
    ])
  }
  let executableURL = URL(
    fileURLWithPath: CommandLine.arguments[0]
  ).resolvingSymlinksInPath()
  let pluginDirectory = executableURL
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  let scriptURL = pluginDirectory
    .appendingPathComponent("scripts")
    .appendingPathComponent("dispatch-actions-runner.sh")
  guard FileManager.default.fileExists(atPath: scriptURL.path) else {
    output([
      "ok": false,
      "errorCode": "actions_dispatch_script_missing",
      "message": "安装包缺少 GitHub Actions 启动脚本。",
    ], exitCode: 1)
  }
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/bin/sh")
  process.arguments = [scriptURL.path]
  let stdout = Pipe()
  let stderr = Pipe()
  process.standardOutput = stdout
  process.standardError = stderr
  var runnerEnvironment = ProcessInfo.processInfo.environment
  if let requestedRunnerAccount, !requestedRunnerAccount.isEmpty {
    runnerEnvironment["CHATGPT_ACCOUNT_ID"] = requestedRunnerAccount
  }
  process.environment = runnerEnvironment
  do {
    try process.run()
    process.waitUntilExit()
    let outputText = String(
      data: stdout.fileHandleForReading.readDataToEndOfFile(),
      encoding: .utf8
    )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let errorText = String(
      data: stderr.fileHandleForReading.readDataToEndOfFile(),
      encoding: .utf8
    )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard process.terminationStatus == 0 else {
      output([
        "ok": false,
        "errorCode": "github_cli_failed",
        "message": errorText.isEmpty ? "gh 执行失败" : errorText,
      ], exitCode: 1)
    }
    output([
      "ok": true,
      "dispatched": true,
      "repository": "bhrumom/fabushi",
      "workflow": "chatgpt-auto-confirm-runner.yml",
      "ref": "main",
      "message": outputText,
    ])
  } catch {
    output([
      "ok": false,
      "errorCode": "github_cli_launch_failed",
      "message": error.localizedDescription,
    ], exitCode: 1)
  }
case "queue_attach":
  let params = commandJSONParams()
  let taskId = normalizedTaskId(params["taskId"] as? String)
  let conversationId = normalizedConversationId(params["conversationId"] as? String)
  guard let taskId, let conversationId else {
    output(["ok": false, "errorCode": "invalid_queue_attachment", "message": "taskId 或 conversationId 无效"], exitCode: 1)
  }
  do {
    let payload = try withQueueStateLock { state -> [String: Any] in
      var tasks = state.automationTasks ?? []
      guard let index = tasks.firstIndex(where: { $0.id == taskId }) else {
        throw NSError(
          domain: "chatgpt-auto-confirm",
          code: 33,
          userInfo: [NSLocalizedDescriptionKey: "没有找到任务 \(taskId)"]
        )
      }
      let now = isoFormatter.string(from: Date())
      let previousTaskConversationId = tasks[index].conversationId
      tasks[index].status = "running"
      tasks[index].chatURL = params["chatUrl"] as? String
      tasks[index].workerPid = nil
      tasks[index].workerStatePath = nil
      tasks[index].resultPath = nil
      tasks[index].startedAt = tasks[index].startedAt ?? now
      tasks[index].finishedAt = nil
      tasks[index].updatedAt = now
      tasks[index].lastError = nil
      tasks[index].report = nil
      guard let controller = sharedChatController(&state),
            let attachedStatus = cdpValue(
              port: controller.port,
              targetId: controller.targetId,
              expression: chatStatusJS(),
              timeout: 5.0
            ) else {
        throw NSError(
          domain: "chatgpt-auto-confirm",
          code: 36,
          userInfo: [NSLocalizedDescriptionKey:
            "没有找到与 conversationId 匹配的队列专用 Chat renderer"]
        )
      }
      let attachedDispatch = cdpValue(
        port: controller.port,
        targetId: controller.targetId,
        expression: """
        (() => {
          const text = document.body?.innerText || '';
          const matches = [...text.matchAll(/任务发送轮次：(\\d+)/g)];
          const value = matches.length ? Number(matches[matches.length - 1][1]) : 0;
          return {
            attempt: Number.isInteger(value) && value > 0 ? value : 0,
            hasTaskMarker: text.includes(\(jsonStringLiteral(taskId)))
          };
        })()
        """,
        timeout: 5.0
      )
      let attachedAttempt = attachedDispatch?["attempt"] as? Int ?? 0
      let requestedAttempt = params["attempt"] as? Int
      let attachedLiveConversationId = normalizedConversationId(
        attachedStatus["conversationId"] as? String
      )
      let attachedRouteConversationId = normalizedConversationId(
        attachedStatus["routeConversationId"] as? String
      )
      let attachedActiveConversationId = normalizedConversationId(
        attachedStatus["activeConversationId"] as? String
      )
      let identityMatches = attachedLiveConversationId == conversationId
      let durableTaskBindingMatches = previousTaskConversationId == conversationId
        && attachedDispatch?["hasTaskMarker"] as? Bool == true
        && attachedAttempt > 0
      // An explicit operator attach may point at the durable sidebar/route id
      // while the live composer has already moved to a local id. Accept that
      // only when the current page itself names this task, then persist the
      // composer id as the runtime identity instead of the stale sidebar id.
      let operatorTaskBindingMatches = attachedDispatch?["hasTaskMarker"] as? Bool == true
        && attachedAttempt == 0
        && (attachedRouteConversationId == conversationId
          || attachedActiveConversationId == conversationId)
      guard identityMatches || durableTaskBindingMatches || operatorTaskBindingMatches else {
        throw NSError(
          domain: "chatgpt-auto-confirm",
          code: 36,
          userInfo: [NSLocalizedDescriptionKey:
            "没有找到与 conversationId 匹配的队列专用 Chat renderer"]
        )
      }
      // Keep the requested durable id as task identity. The live composer can
      // temporarily use a local id before ChatGPT promotes it, so retain that
      // exact local identity as a secondary binding for both verified sends
      // and explicit markerless attachments.
      tasks[index].conversationId = conversationId
      if previousTaskConversationId != conversationId
          || tasks[index].lastProgressAt == nil {
        tasks[index].lastProgressAt = tasks[index].startedAt ?? now
      }
      let markerlessAttachment = attachedAttempt == 0
        && (identityMatches || operatorTaskBindingMatches)
      tasks[index].attachedConversationWithoutDispatchMarker = markerlessAttachment
      tasks[index].dispatchMarkerVerifiedAt = attachedAttempt > 0 ? now : nil
      tasks[index].dispatchLocalConversationId = attachedLiveConversationId
      tasks[index].workerPort = controller.port
      tasks[index].workerTargetId = controller.targetId
      tasks[index].workerProfilePath = controller.profilePath
      if let requestedAttempt, requestedAttempt > 0 {
        tasks[index].attempts = requestedAttempt
      } else if attachedAttempt > 0 {
        tasks[index].attempts = attachedAttempt
      }
      state.backgroundAppPort = controller.port
      state.backgroundChatTargetId = controller.targetId
      state.backgroundProfilePath = controller.profilePath
      state.queueWorkerPort = controller.port
      state.queueWorkerTargetId = controller.targetId
      state.queueWorkerProfilePath = controller.profilePath
      state.queueWorkerMode = sharedConversationQueueWorkerMode
      state.automationTasks = tasks
      state.queueEnabled = true
      state.queuePaused = false
      try startQueueWatcher(&state)
      var result = queueStatusPayload(state)
      result["attachedTask"] = taskPublicPayload(tasks[index])
      return result
    }
    output(payload)
  } catch {
    output(["ok": false, "errorCode": "queue_attach_failed", "message": error.localizedDescription], exitCode: 1)
  }
case "queue_wait_review":
  let params = commandJSONParams()
  output(waitForAutomationReview(timeout: params["timeout"] as? Int ?? 3600))
case "queue_review":
  let params = commandJSONParams()
  let taskId = normalizedTaskId(params["taskId"] as? String)
  let accepted = params["accepted"] as? Bool ?? false
  let feedback = (params["feedback"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  guard let taskId else {
    output(["ok": false, "errorCode": "invalid_task_id", "message": "taskId 无效"], exitCode: 1)
  }
  do {
    let payload = try withQueueStateLock { state -> [String: Any] in
      var tasks = state.automationTasks ?? []
      guard let index = tasks.firstIndex(where: { $0.id == taskId }) else {
        throw NSError(
          domain: "chatgpt-auto-confirm",
          code: 27,
          userInfo: [NSLocalizedDescriptionKey: "没有找到任务 \(taskId)"]
        )
      }
      guard ["awaiting_review", "blocked", "failed"].contains(tasks[index].status) else {
        throw NSError(
          domain: "chatgpt-auto-confirm",
          code: 28,
          userInfo: [NSLocalizedDescriptionKey: "任务 \(taskId) 当前不在可验收状态"]
        )
      }
      let now = isoFormatter.string(from: Date())
      tasks[index].reviewedAt = now
      tasks[index].updatedAt = now
      tasks[index].reviewFeedback = feedback
      if accepted {
        tasks[index].status = "completed"
        tasks[index].lastError = nil
      } else {
        guard !feedback.isEmpty else {
          throw NSError(
            domain: "chatgpt-auto-confirm",
            code: 29,
            userInfo: [NSLocalizedDescriptionKey: "验收未通过时必须提供 feedback"]
          )
        }
        tasks[index].status = "queued"
        tasks[index].reviewRound += 1
        tasks[index].attempts = 0
        tasks[index].startedAt = nil
        tasks[index].finishedAt = nil
        tasks[index].workerPid = nil
        tasks[index].report = nil
        tasks[index].lastResultJSON = nil
        tasks[index].lastError = nil
      }
      state.automationTasks = tasks
      state.queueEnabled = true
      state.queuePaused = false
      try startQueueWatcher(&state)
      var result = queueStatusPayload(state)
      result["reviewedTask"] = taskPublicPayload(tasks[index])
      result["accepted"] = accepted
      return result
    }
    output(payload)
  } catch {
    output(["ok": false, "errorCode": "queue_review_failed", "message": error.localizedDescription], exitCode: 1)
  }
case "queue_pause":
  do {
    let payload = try withQueueStateLock { state -> [String: Any] in
      state.queuePaused = true
      return queueStatusPayload(state)
    }
    output(payload)
  } catch {
    output(["ok": false, "errorCode": "queue_pause_failed", "message": error.localizedDescription], exitCode: 1)
  }
case "queue_retry":
  let params = commandJSONParams()
  let taskId = normalizedTaskId(params["taskId"] as? String)
  let feedback = (params["feedback"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  let connectorParameter = params["connector"] as? String
  guard connectorParameter == nil || normalizedConnector(connectorParameter) != nil else {
    output(["ok": false, "errorCode": "invalid_connector", "message": "connector 必须是 1-256 字符且不能包含换行"], exitCode: 1)
  }
  let requestedConnector = normalizedConnector(connectorParameter)
  guard let taskId else {
    output(["ok": false, "errorCode": "invalid_task_id", "message": "taskId 无效"], exitCode: 1)
  }
  do {
    let payload = try withQueueStateLock { state -> [String: Any] in
      var tasks = state.automationTasks ?? []
      guard let index = tasks.firstIndex(where: { $0.id == taskId }) else {
        throw NSError(
          domain: "chatgpt-auto-confirm",
          code: 34,
          userInfo: [NSLocalizedDescriptionKey: "没有找到任务 \(taskId)"]
        )
      }
      guard ["queued", "running", "waiting", "blocked", "failed", "cancelled"].contains(tasks[index].status) else {
        throw NSError(
          domain: "chatgpt-auto-confirm",
          code: 35,
          userInfo: [NSLocalizedDescriptionKey: "任务 \(taskId) 当前不需要中断恢复"]
        )
      }
      if let requestedConnector {
        tasks[index].connector = requestedConnector
      }
      if tasks[index].status == "queued" {
        if !feedback.isEmpty {
          tasks[index].reviewFeedback = "任务连接器已更新。请从同一 checkout 的最新落盘进度继续：\n\(feedback)"
        }
        tasks[index].lastError = "connector_updated"
        tasks[index].updatedAt = isoFormatter.string(from: Date())
      } else if tasks[index].status == "running" {
        // Stop only a response inside the plugin-owned queue target. A legacy or
        // attached target is deliberately left untouched because it may be the
        // page where the user is composing a new task.
        let port = tasks[index].workerPort ?? state.queueWorkerPort
        let targetId = tasks[index].workerTargetId ?? state.queueWorkerTargetId
        if queueUsesBackgroundWindow(state),
           let port,
           let targetId {
          _ = cdpValue(
            port: port,
            targetId: targetId,
            expression: stopCurrentResponseJS(),
            timeout: 12.0
          )
        }
        // An operator retry must not inherit its old plugin-owned renderer. Parallel
        // tasks own different windows, so close only this task and leave other
        // running Chats untouched.
        if state.queueWorkerMode == parallelDedicatedProcessQueueWorkerMode {
          if let port, let targetId {
            _ = CDPClient.closeTarget(targetId, portOverride: port)
          }
          if let profilePath = tasks[index].workerProfilePath {
            terminateDedicatedChatProcess(profilePath: profilePath)
          }
          if state.queueWorkerTargetId == targetId {
            state.queueWorkerPort = nil
            state.queueWorkerTargetId = nil
            state.queueWorkerProfilePath = nil
          }
        } else if state.queueWorkerMode == parallelHiddenWindowQueueWorkerMode {
          if let port, let targetId,
             queueTargetIsHidden(port: port, targetId: targetId) {
            _ = CDPClient.closeTarget(targetId, portOverride: port)
          }
          if state.queueWorkerTargetId == targetId {
            state.queueWorkerPort = nil
            state.queueWorkerTargetId = nil
            state.queueWorkerProfilePath = nil
          }
        } else if state.queueWorkerMode == parallelHeadlessWindowQueueWorkerMode {
          if let port, let targetId {
            _ = CDPClient.closeTarget(targetId, portOverride: port)
          }
          if state.queueWorkerTargetId == targetId {
            state.queueWorkerPort = nil
            state.queueWorkerTargetId = nil
            state.queueWorkerProfilePath = nil
          }
        } else {
          stopQueueWorker(&state)
        }
      }
      if let reviewConversationId = normalizedConversationId(tasks[index].reviewConversationId) {
        // A review Chat is another branch of the same task. If recovery starts
        // from that state, continue the branch chain from the latest review
        // conversation rather than falling back to the older work branch.
        tasks[index].conversationId = reviewConversationId
        tasks[index].chatURL = "https://chatgpt.com/c/\(reviewConversationId)"
      }
      if tasks[index].status != "queued", ["cancelled", "waiting", "blocked", "failed"].contains(tasks[index].status) {
        // An explicit operator retry is a fresh recovery budget. Keep the
        // checkout and audit history, but do not let an old continuation
        // fingerprint prevent the new architecture from making progress.
        tasks[index].reportFingerprints = []
        tasks[index].continuationDepth = 0
        tasks[index].reviewRound += 1
        tasks[index].status = "queued"
        tasks[index].startedAt = nil
        tasks[index].finishedAt = nil
        tasks[index].workerPid = nil
        tasks[index].report = nil
        tasks[index].reviewConversationId = nil
        tasks[index].reviewStatus = nil
        tasks[index].reviewReport = nil
        tasks[index].lastError = "operator_recovery"
        tasks[index].lastProgressAt = nil
        tasks[index].waitingUntil = nil
        tasks[index].waitReason = nil
      } else if tasks[index].status != "queued" {
        queueContinuation(&tasks[index], report: tasks[index].report, reason: "operator_recovery")
      }
      // A retry starts a fresh Chat ownership cycle even when the task was
      // already queued. Keeping a stale per-task target here excludes the
      // otherwise healthy queue-owned controller from discovery and can trap
      // the scheduler on the avatar overlay forever.
      tasks[index].workerPid = nil
      tasks[index].workerPort = nil
      tasks[index].workerTargetId = nil
      tasks[index].workerStatePath = nil
      tasks[index].workerProfilePath = nil
      tasks[index].hiddenWorkerLastError = nil
      if !feedback.isEmpty && tasks[index].status == "queued" {
        tasks[index].reviewFeedback = "任务出现中断迹象。请从同一 checkout 的最新落盘进度继续，不要从头开始或覆盖无关改动：\n\(feedback)"
      }
      state.automationTasks = tasks
      state.queueEnabled = true
      state.queuePaused = false
      try startQueueWatcher(&state)
      var result = queueStatusPayload(state)
      result["retriedTask"] = taskPublicPayload(tasks[index])
      return result
    }
    output(payload)
  } catch {
    output(["ok": false, "errorCode": "queue_retry_failed", "message": error.localizedDescription], exitCode: 1)
  }
case "queue_cancel":
  let params = commandJSONParams()
  let taskId = normalizedTaskId(params["taskId"] as? String)
  guard let taskId else {
    output(["ok": false, "errorCode": "invalid_task_id", "message": "taskId 无效"], exitCode: 1)
  }
  do {
    let payload = try withQueueStateLock { state -> [String: Any] in
      var tasks = state.automationTasks ?? []
      guard let index = tasks.firstIndex(where: { $0.id == taskId }) else {
        throw NSError(
          domain: "chatgpt-auto-confirm",
          code: 30,
          userInfo: [NSLocalizedDescriptionKey: "没有找到任务 \(taskId)"]
        )
      }
      if watcherIsAlive(tasks[index].workerPid), let pid = tasks[index].workerPid {
        kill(pid, SIGTERM)
      }
      stopAutomationWorker(tasks[index], state: state)
      tasks[index].status = "cancelled"
      tasks[index].workerPid = nil
      tasks[index].updatedAt = isoFormatter.string(from: Date())
      tasks[index].finishedAt = tasks[index].updatedAt
      state.automationTasks = tasks
      var result = queueStatusPayload(state)
      result["cancelledTaskId"] = taskId
      return result
    }
    output(payload)
  } catch {
    output(["ok": false, "errorCode": "queue_cancel_failed", "message": error.localizedDescription], exitCode: 1)
  }
case "queue_watch":
  let activity = beginWatcherActivity(
    preventIdleSystemSleep: true,
    reason: "ChatGPT 自动确认任务队列后台处理"
  )
  defer { ProcessInfo.processInfo.endActivity(activity) }
  var queueWatchIteration = 0
  while true {
    autoreleasepool {
      do {
        let shouldContinue = try withQueueStateLock { state -> Bool in
          guard state.queueEnabled == true else { return false }
          state.queueWatcherPid = getpid()
          state.queueRuntimeRevision = currentQueueRuntimeRevision
          if queueUsesBackgroundWindow(state),
             let port = state.queueWorkerPort,
             let targetId = state.queueWorkerTargetId {
            _ = queueTargetRuntimeState(port: port, targetId: targetId, refreshLifecycle: true)
          }
          runQueueIteration(&state)
          queueWatchIteration += 1
          if queueWatchIteration % 60 == 0 {
            cleanupOrphanedDedicatedTaskWorkerArtifacts(state)
          }
          return state.queueEnabled == true
        }
        if !shouldContinue { Foundation.exit(0) }
      } catch {
        cdpDebug("queue watcher iteration failed: \(error.localizedDescription)")
      }
      Thread.sleep(forTimeInterval: 1.0)
    }
  }
case "send_message", "add_connector":
  var params: [String: Any] = [:]
  if CommandLine.arguments.count >= 3,
     let data = CommandLine.arguments[2].data(using: .utf8),
     let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
    params = object
  }
  if command == "add_connector" {
    let connector = (params["connector"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !connector.isEmpty else {
      output(["ok": false, "errorCode": "missing_connector", "message": "请提供 connector 名称"], exitCode: 1)
    }
    let rawConversationId = params["conversationId"] as? String
    let conversationId = normalizedConversationId(rawConversationId)
    if rawConversationId != nil && conversationId == nil {
      output(["ok": false, "errorCode": "invalid_conversation_id", "message": "conversationId 格式无效"], exitCode: 1)
    }
    var state = loadState()
    let prepared = ensureHiddenChatTarget(&state, conversationId: conversationId)
    guard prepared?["ok"] as? Bool == true else {
      try? saveState(state)
      output(prepared ?? ["ok": false, "errorCode": "background_chat_unavailable"], exitCode: 1)
    }
    let rawChatURL = params["chatUrl"] as? String
    let preferredChatURL = ensureChatTarget(rawChatURL, in: &state)
    if rawChatURL != nil && preferredChatURL == nil {
      output(["ok": false, "errorCode": "invalid_chat_url", "message": "chatUrl 必须是 ChatGPT 对话地址"], exitCode: 1)
    }
    try? saveState(state)
    let js = addConnectorJS(connector: connector)
    if let result = cdpEvaluateOnChatGPT(js, timeout: 8.0, preferredURL: preferredChatURL) {
      output(result, exitCode: result["ok"] as? Bool == true ? 0 : 1)
    } else {
      output(["ok": false, "errorCode": "cdp_unavailable", "message": "无法通过 CDP 连接到 ChatGPT。请确保 ChatGPT 已开启调试端口运行。"], exitCode: 1)
    }
  } else {
    let message = (params["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let connector = params["connector"] as? String
    let rawConversationId = params["conversationId"] as? String
    let conversationId = normalizedConversationId(rawConversationId)
    if rawConversationId != nil && conversationId == nil {
      output(["ok": false, "errorCode": "invalid_conversation_id", "message": "conversationId 格式无效"], exitCode: 1)
    }
    let newChat = conversationId == nil ? (params["newChat"] as? Bool ?? true) : false
    guard !message.isEmpty else {
      output(["ok": false, "errorCode": "missing_message", "message": "请提供 message 参数"], exitCode: 1)
    }
    var state = loadState()
    let prepared = ensureHiddenChatTarget(
      &state,
      newChat: newChat,
      conversationId: conversationId
    )
    guard prepared?["ok"] as? Bool == true else {
      try? saveState(state)
      output(prepared ?? ["ok": false, "errorCode": "background_chat_unavailable"], exitCode: 1)
    }
    let rawChatURL = params["chatUrl"] as? String
    let preferredChatURL = ensureChatTarget(rawChatURL, in: &state)
    if rawChatURL != nil && preferredChatURL == nil {
      output(["ok": false, "errorCode": "invalid_chat_url", "message": "chatUrl 必须是 ChatGPT 对话地址"], exitCode: 1)
    }
    try? saveState(state)
    let js = sendMessageJS(message: message, connector: connector, newChat: false)
    if let result = cdpEvaluateOnChatGPT(js, timeout: 18.0, preferredURL: preferredChatURL) {
      if preferredChatURL == nil || normalizedChatURL(result["url"] as? String) == preferredChatURL {
        rememberChatURL(result["url"] as? String, in: &state)
      }
      state.audit.append(AuditEvent(
        at: isoFormatter.string(from: Date()),
        decision: "send_message",
        reason: "通过 CDP 向 ChatGPT 发送消息",
        clicked: result["sent"] as? Bool ?? false,
        ruleId: nil,
        buttonTitle: "send",
        promptText: "send_message: \(String(message.prefix(200)))",
        error: result["error"] as? String
      ))
      if state.audit.count > 100 { state.audit.removeFirst(state.audit.count - 100) }
      try? saveState(state)
      if result["ok"] as? Bool == true {
        output(result)
      } else {
        let diagnostic = cdpEvaluateOnChatGPT(pageDiagnosticJS(), preferredURL: preferredChatURL) ?? [:]
        var failure = result
        failure["errorCode"] = result["error"] as? String ?? "send_stage_failed"
        failure["message"] = "Chat 指令发送阶段未得到页面确认，小程序已退出并保存阶段日志。"
        failure["screenshotPath"] = captureHiddenChatScreenshot(state, label: "send-failed") as Any
        failure["pageContent"] = diagnostic["content"] as Any
        failure["pageButtons"] = diagnostic["buttons"] as Any
        output(failure, exitCode: 1)
      }
    } else {
      output(["ok": false, "errorCode": "cdp_unavailable", "message": "无法通过 CDP 连接到 ChatGPT。请确保 ChatGPT 已开启调试端口运行。"], exitCode: 1)
    }
  }
case "get_reply":
  var params: [String: Any] = [:]
  if CommandLine.arguments.count >= 3,
     let data = CommandLine.arguments[2].data(using: .utf8),
     let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
    params = object
  }
  let rawConversationId = params["conversationId"] as? String
  let conversationId = normalizedConversationId(rawConversationId)
  if rawConversationId != nil && conversationId == nil {
    output(["ok": false, "errorCode": "invalid_conversation_id", "message": "conversationId 格式无效"], exitCode: 1)
  }
  var state = loadState()
  let prepared = ensureHiddenChatTarget(&state, conversationId: conversationId)
  guard prepared?["ok"] as? Bool == true else {
    try? saveState(state)
    output(prepared ?? ["ok": false, "errorCode": "background_chat_unavailable"], exitCode: 1)
  }
  let rawChatURL = params["chatUrl"] as? String
  let preferredChatURL = ensureChatTarget(rawChatURL, in: &state)
  if rawChatURL != nil && preferredChatURL == nil {
    output(["ok": false, "errorCode": "invalid_chat_url", "message": "chatUrl 必须是 ChatGPT 对话地址"], exitCode: 1)
  }
  try? saveState(state)
  if let result = cdpEvaluateOnChatGPT(getReplyJS(), preferredURL: preferredChatURL) {
    var payload = sanitizeJSONValue(result) as? [String: Any] ?? ["ok": false, "errorCode": "sanitize_failed"]
    if payload["conversationId"] == nil {
      payload["conversationId"] = state.backgroundConversationId as Any
    }
    output(payload)
  } else {
    output(["ok": false, "errorCode": "cdp_unavailable", "message": "无法通过 CDP 连接到 ChatGPT"], exitCode: 1)
  }
case "chat_status":
  var params: [String: Any] = [:]
  if CommandLine.arguments.count >= 3,
     let data = CommandLine.arguments[2].data(using: .utf8),
     let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
    params = object
  }
  let rawConversationId = params["conversationId"] as? String
  let conversationId = normalizedConversationId(rawConversationId)
  if rawConversationId != nil && conversationId == nil {
    output(["ok": false, "errorCode": "invalid_conversation_id", "message": "conversationId 格式无效"], exitCode: 1)
  }
  var state = loadState()
  let prepared = ensureHiddenChatTarget(&state, conversationId: conversationId)
  guard prepared?["ok"] as? Bool == true else {
    try? saveState(state)
    output(prepared ?? ["ok": false, "errorCode": "background_chat_unavailable"], exitCode: 1)
  }
  let rawChatURL = params["chatUrl"] as? String
  let preferredChatURL = ensureChatTarget(rawChatURL, in: &state)
  if rawChatURL != nil && preferredChatURL == nil {
    output(["ok": false, "errorCode": "invalid_chat_url", "message": "chatUrl 必须是 ChatGPT 对话地址"], exitCode: 1)
  }
  try? saveState(state)
  if let result = cdpEvaluateOnChatGPT(chatStatusJS(), preferredURL: preferredChatURL) {
    if preferredChatURL == nil || normalizedChatURL(result["url"] as? String) == preferredChatURL {
      rememberChatURL(result["url"] as? String, in: &state)
    }
    try? saveState(state)
    var payload = sanitizeJSONValue(result) as? [String: Any] ?? ["ok": false, "errorCode": "sanitize_failed"]
    payload["trackedChatURLs"] = state.trackedChatURLs ?? []
    let runtimeState = pluginBackgroundRuntimeState(state)
    payload["hiddenTargetCount"] = runtimeState == .hidden ? 1 : 0
    payload["visibleTargetCount"] = runtimeState == .visible ? 1 : 0
    payload["runtimeState"] = runtimeState.map(queueTargetRuntimeStateName) as Any
    payload["backgroundOnly"] = runtimeState == .hidden
    payload["backgroundPort"] = state.backgroundAppPort as Any
    payload["backgroundTargetId"] = state.backgroundChatTargetId as Any
    if payload["conversationId"] == nil {
      payload["conversationId"] = state.backgroundConversationId as Any
    }
    output(payload)
  } else {
    output(["ok": false, "errorCode": "cdp_unavailable", "message": "无法通过 CDP 连接到 ChatGPT"], exitCode: 1)
  }
case "send_and_watch":
  var params: [String: Any] = [:]
  if CommandLine.arguments.count >= 3,
     let data = CommandLine.arguments[2].data(using: .utf8),
     let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
    params = object
  }
  let message = (params["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  let role = (params["role"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) == "planner"
    ? "planner"
    : "work"
  let autoPlanAfterWork = role == "work"
    && (params["autoPlanAfterWork"] as? Bool ?? true)
  let connector = params["connector"] as? String
  let rawChatURL = params["chatUrl"] as? String
  let rawConversationId = params["conversationId"] as? String
  let resumeExisting = params["resumeExisting"] as? Bool ?? false
  let freshTargetPrepared = params["freshTargetPrepared"] as? Bool ?? false
  let conversationId = resumeExisting ? normalizedConversationId(rawConversationId) : nil
  if resumeExisting && rawConversationId != nil && conversationId == nil {
    output(["ok": false, "errorCode": "invalid_conversation_id", "message": "conversationId 格式无效"], exitCode: 1)
  }
  // User policy: every outbound message starts a fresh Chat. An existing
  // conversation can only be attached in read-only resumeExisting mode.
  let newChat = !resumeExisting && !freshTargetPrepared
  let timeout = min(maxChatWatchTimeoutSeconds, max(10, params["timeout"] as? Int ?? defaultChatWatchTimeoutSeconds))
  let stagnationTimeout = min(defaultChatStagnationTimeoutSeconds, max(60, params["stagnationTimeout"] as? Int ?? defaultChatStagnationTimeoutSeconds))
  let maxRecoveryAttempts = min(5, max(0, params["maxRecoveryAttempts"] as? Int ?? 5))
  let autoContinueIncomplete = params["autoContinueIncomplete"] as? Bool ?? true
  let maxTaskContinuations = min(
    20,
    max(0, params["maxTaskContinuations"] as? Int ?? defaultMaxTaskContinuations)
  )
  let continuationDepth = max(0, params["continuationDepth"] as? Int ?? 0)
  let originalGoal = (params["originalGoal"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? message
  let reportFingerprints = params["reportFingerprints"] as? [String] ?? []
  let taskId = (params["taskId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
  let appliedRevision = params["appliedRevision"] as? Int
  let appliedDigest = (params["appliedDigest"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
  let defaultContinuationMessage = role == "planner"
    ? messageWithTaskReportContract(
      originalGoal,
      taskId: taskId,
      appliedRevision: appliedRevision,
      appliedDigest: appliedDigest
    )
    : messageWithoutTaskReportContract(message)
  // A planner retry must retain the planner input (including the Work result),
  // while a Work retry must retain only the original executable goal. This is
  // also the message used when a renderer stalls before producing a terminal
  // response.
  let continuationMessage = role == "planner"
    ? messageWithTaskReportContract(
      message,
      taskId: taskId,
      appliedRevision: appliedRevision,
      appliedDigest: appliedDigest
    )
    : defaultContinuationMessage
  let approveAll = params["approveAll"] as? Bool ?? true
  let pollIntervalMs = min(5000, max(200, params["pollIntervalMs"] as? Int ?? 500))

  guard !message.isEmpty else {
    output(["ok": false, "errorCode": "missing_message", "message": "请提供 message 参数"], exitCode: 1)
  }

  // Capture the existing conversation before sending. Without this baseline,
  // the first poll can mistake the previous assistant message for the reply to
  // the new instruction and return immediately.
  var state = loadState()
  if !resumeExisting && !freshTargetPrepared {
    // Public retries must not accumulate private ChatGPT.app instances or
    // stale renderers. A fresh planner child is already prepared by the
    // current process and therefore skips this cleanup path.
    closeBackgroundTargets(&state)
  }
  let requestedAccountId = (params["accountId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
  let selectedAccount: AccountRecord?
  if let requestedAccountId, !requestedAccountId.isEmpty {
    guard let account = resolveAccount(requestedAccountId) else {
      output(["ok": false, "errorCode": "account_not_found", "message": "指定账号不存在。"], exitCode: 1)
    }
    selectedAccount = account
  } else {
    // An omitted accountId means "continue with the already verified plugin-owned
    // instance", not "silently switch to the registry default". Switching
    // profiles here changes the CDP port after chat_status has proved a
    // specific process/target pair and can route the send to another app.
    selectedAccount = nil
  }
  if let account = selectedAccount {
    state.backgroundProfilePath = account.profilePath
    state.backgroundCodexHomePath = account.codexHomePath
    state.backgroundAppPort = accountAvailableCDPPort()
  }
  let prepared = ensureHiddenChatTarget(
    &state,
    newChat: resumeExisting ? false : newChat,
    conversationId: conversationId
  )
  guard prepared?["ok"] as? Bool == true else {
    try? saveState(state)
    output(prepared ?? ["ok": false, "errorCode": "background_chat_unavailable"], exitCode: 1)
  }
  if !resumeExisting && !freshTargetPrepared && prepared?["newChatClicked"] as? Bool != true {
    try? saveState(state)
    output([
      "ok": false,
      "errorCode": "new_chat_creation_not_confirmed",
      "message": "发送前没有确认创建新的 Chat，小程序已退出。",
      "preparation": prepared as Any,
      "backgroundOnly": false,
      "runtimeState": "unavailable",
      "workerUsed": false,
    ], exitCode: 1)
  }
  let preferredChatURL = ensureChatTarget(rawChatURL, in: &state)
  if rawChatURL != nil && preferredChatURL == nil {
    output(["ok": false, "errorCode": "invalid_chat_url", "message": "chatUrl 必须是 ChatGPT 对话地址"], exitCode: 1)
  }
  state.approveAll = approveAll
  state.enabled = true
  state.intervalMs = min(5_000, max(400, pollIntervalMs))
  if !watcherIsAlive(state.watcherPid) {
    do {
      try withWatcherLifecycleLock {
        let latest = loadState()
        if watcherIsAlive(latest.watcherPid) {
          state.watcherPid = latest.watcherPid
        } else {
          try saveState(state)
          try startWatcher(&state)
        }
      }
    } catch {
      state.lastError = "approval_watcher_start_failed"
      try? saveState(state)
      output([
        "ok": false,
        "errorCode": "approval_watcher_start_failed",
        "message": error.localizedDescription,
        "backgroundOnly": pluginBackgroundRuntimeState(state) == .hidden,
        "runtimeState": pluginBackgroundRuntimeState(state).map(queueTargetRuntimeStateName) as Any,
        "workerUsed": false,
      ], exitCode: 1)
    }
  }
  try? saveState(state)
  var baselineReply = cdpEvaluateOnChatGPT(getReplyJS(), preferredURL: preferredChatURL)
  let currentMessageCount = baselineReply?["messageCount"] as? Int ?? 0
  var baselineMessageCount = resumeExisting ? max(0, currentMessageCount - 1) : currentMessageCount
  if let initialThinking = baselineReply?["thinking"] as? String, !initialThinking.isEmpty {
    emitProgress([
      "event": "thinking_progress",
      "initial": true,
      "thinking": String(initialThinking.suffix(4000)),
      "activityCharCount": baselineReply?["activityCharCount"] as? Int ?? 0,
      "devspaceActivity": String((baselineReply?["devspaceActivity"] as? String ?? "").suffix(2000)),
      "devspaceWaiting": baselineReply?["devspaceWaiting"] as? Bool ?? false,
    ])
  }

  // Step 1: Send message
  var sendResult: [String: Any] = [
    "ok": true,
    "url": "app://-/index.html",
    "resumedExisting": resumeExisting,
  ]
  if !resumeExisting {
    let outboundMessage = role == "planner"
      ? messageWithTaskReportContract(
        message,
        taskId: taskId,
        appliedRevision: appliedRevision,
        appliedDigest: appliedDigest
      )
      : messageWithoutTaskReportContract(message)
    let sendJS = sendMessageJS(
      message: outboundMessage, connector: connector, newChat: false)
    // Connector selection plus virtualization-aware bubble confirmation can
    // legitimately take about 19 seconds in the desktop renderer. Keep the
    // outer CDP deadline safely above the script's bounded inner waits.
    var result = cdpEvaluateOnChatGPT(sendJS, timeout: 35.0, preferredURL: preferredChatURL)
    // Clicking Send can replace the renderer's execution context. CDP then
    // loses the async script result even though the new user bubble exists.
    // Re-attach read-only and verify the exact submitted bubble before calling
    // this a failure; never send the message a second time here.
    if result == nil {
      for _ in 0..<24 {
        Thread.sleep(forTimeInterval: 0.5)
        if let verification = cdpEvaluateOnChatGPT(
          verifySentMessageJS(message: outboundMessage),
          timeout: 5.0,
          preferredURL: preferredChatURL
        ), verification["messageConfirmed"] as? Bool == true {
          result = verification
          break
        }
      }
    }
    guard let result else {
        let diagnostic = cdpEvaluateOnChatGPT(pageDiagnosticJS(), preferredURL: preferredChatURL) ?? [:]
        output([
          "ok": false,
          "errorCode": "cdp_send_failed",
          "message": "发送脚本执行上下文丢失，且重新绑定后仍未找到完整的新用户消息气泡。",
          "screenshotPath": captureHiddenChatScreenshot(state, label: "send-cdp-failed") as Any,
          "pageContent": diagnostic["content"] as Any,
          "pageButtons": diagnostic["buttons"] as Any,
          "backgroundOnly": pluginBackgroundRuntimeState(state) == .hidden,
          "runtimeState": pluginBackgroundRuntimeState(state).map(queueTargetRuntimeStateName) as Any,
          "workerUsed": false,
        ], exitCode: 1)
    }
    guard result["ok"] as? Bool == true else {
      let diagnostic = cdpEvaluateOnChatGPT(pageDiagnosticJS(), preferredURL: preferredChatURL) ?? [:]
      var failure = result
      failure["errorCode"] = result["error"] as? String ?? "send_stage_failed"
      failure["message"] = "Chat 指令未通过页面确认；小程序没有进入等待状态。"
      failure["screenshotPath"] = captureHiddenChatScreenshot(state, label: "send-stage-failed") as Any
      failure["pageContent"] = diagnostic["content"] as Any
      failure["pageButtons"] = diagnostic["buttons"] as Any
      let resultRuntimeState = result["runtimeState"] as? String
      failure["backgroundOnly"] = resultRuntimeState == "hidden-chat"
        || resultRuntimeState == "hidden"
      failure["runtimeState"] = resultRuntimeState ?? "unavailable"
      failure["workerUsed"] = false
      output(failure, exitCode: 1)
    }
    sendResult = result
  }

  // Record audit
  rememberChatURL(sendResult["url"] as? String, in: &state)
  var activeChatURL = normalizedChatURL(sendResult["url"] as? String) ?? preferredChatURL
  if !resumeExisting {
    state.audit.append(AuditEvent(
      at: isoFormatter.string(from: Date()),
      decision: "send_message",
      reason: "send_and_watch 端到端流程：通过 CDP 发送消息",
      clicked: true,
      ruleId: nil,
      buttonTitle: "send",
      promptText: "send_and_watch: \(String(message.prefix(200)))",
      error: nil
    ))
  }

  // Step 2: Poll loop - approve + watch reply
  let deadline = Date().addingTimeInterval(Double(timeout))
  var finalReply: [String: Any] = ["content": "", "streaming": false, "done": false, "charCount": 0]
  var totalApprovals = 0
  var timedOut = false
  var prevCharCount = 0
  var sawNewReply = false
  var stalled = false
  var surfaceDrift = false
  var surfaceDriftStatus: [String: Any] = [:]
  var stalledPageContent = ""
  var stalledButtons: [String] = []
  var screenshotPath: String?
  var recoveryEvents: [[String: Any]] = []
  var recoveryAttempts = 0
  var lastActivitySignature = baselineReply?["activitySignature"] as? String ?? ""
  var lastPageChangeAt = Date()
  var completionCandidateSince: Date?
  var completionCandidateSignature = ""

  // Wait a moment for ChatGPT to start processing
  Thread.sleep(forTimeInterval: 1.5)

  while Date() < deadline {
    // ChatGPT may pause a coding-capable connector behind a routing prompt.
    // The only safe choice for this worker is "Continue in this chat"; make
    // that trusted CDP click before surface validation so the transient lack
    // of a composer is not mistaken for a handoff to Work.
    if let continuation = cdpEvaluateOnChatGPT(
      autoConfirmChatContinuationJS(),
      preferredURL: activeChatURL
    ), continuation["clicked"] as? Bool == true,
       let port = state.backgroundAppPort,
       let targetId = state.backgroundChatTargetId {
      _ = dispatchRecommendedCDPClick(
        continuation,
        port: port,
        targetId: targetId
      )
      lastPageChangeAt = Date()
      emitProgress([
        "event": "continue_in_chat",
        "backgroundOnly": pluginBackgroundRuntimeState(state) == .hidden,
        "runtimeState": pluginBackgroundRuntimeState(state).map(queueTargetRuntimeStateName) as Any,
        "workerUsed": false,
      ])
      Thread.sleep(forTimeInterval: 0.6)
    }
    // The plugin-owned renderer must remain on the real Chat surface for the
    // whole run. A handoff or navigation can otherwise expose a Work composer
    // after the initial send. Abort immediately; never approve or type on Work.
    if let liveSurface = cdpEvaluateOnChatGPT(chatStatusJS(), preferredURL: activeChatURL),
       liveSurface["chatMode"] as? Bool != true || liveSurface["surface"] as? String != "chat" {
      surfaceDrift = true
      surfaceDriftStatus = liveSurface
      let diagnostic = cdpEvaluateOnChatGPT(pageDiagnosticJS(), preferredURL: activeChatURL) ?? [:]
      stalledPageContent = diagnostic["content"] as? String ?? ""
      stalledButtons = diagnostic["buttons"] as? [String] ?? []
      screenshotPath = captureHiddenChatScreenshot(state, label: "chat-surface-drift")
      emitProgress([
        "event": "chat_surface_drift",
        "surfaceStatus": liveSurface,
        "screenshotPath": screenshotPath as Any,
        "backgroundOnly": pluginBackgroundRuntimeState(state) == .hidden,
        "runtimeState": pluginBackgroundRuntimeState(state).map(queueTargetRuntimeStateName) as Any,
        "workerUsed": false,
      ])
      break
    }

    autoreleasepool {
      // 2a: Check and auto-approve any authorization cards
      let scanResult = scanIPC(&state)
      if let approved = scanResult?["approved"] as? Int, approved > 0 {
        totalApprovals += approved
        lastPageChangeAt = Date()
        emitProgress([
          "event": "approval",
          "approved": approved,
          "totalApproved": totalApprovals,
          "backgroundOnly": pluginBackgroundRuntimeState(state) == .hidden,
          "runtimeState": pluginBackgroundRuntimeState(state).map(queueTargetRuntimeStateName) as Any,
          "workerUsed": false,
        ])
      }

      // Also try AX-based approval as fallback
      // (already handled by scanIPC which tries IPC first then falls back)
    }

    // 2b: Check reply
    if let replyResult = cdpEvaluateOnChatGPT(getReplyJS(), preferredURL: activeChatURL) {
      let messageCount = replyResult["messageCount"] as? Int ?? 0
      let isStreaming = replyResult["streaming"] as? Bool ?? false
      finalReply = replyResult
      let activitySignature = replyResult["activitySignature"] as? String ?? ""
      if !activitySignature.isEmpty && activitySignature != lastActivitySignature {
        lastActivitySignature = activitySignature
        lastPageChangeAt = Date()
        let thinking = replyResult["thinking"] as? String ?? ""
        emitProgress([
          "event": "thinking_progress",
          "thinking": String(thinking.suffix(4000)),
          "activityCharCount": replyResult["activityCharCount"] as? Int ?? 0,
          "devspaceActivity": String((replyResult["devspaceActivity"] as? String ?? "").suffix(2000)),
          "devspaceWaiting": replyResult["devspaceWaiting"] as? Bool ?? false,
          "waitingForApproval": replyResult["waitingForApproval"] as? Bool ?? false,
          "messageCount": messageCount,
        ])
      }

      // The desktop Chat surface can keep the completed response inside a
      // collapsed "思考" section without rendering a final-assistant node.
      // Accept that representation only after it is inactive and stable for
      // several seconds, so an old reply or a transient tool pause cannot be
      // mistaken for the result of the current request.
      let isCompletionCandidate = replyResult["completionCandidate"] as? Bool ?? false
      let isTerminalIncomplete = replyResult["terminalIncomplete"] as? Bool ?? false
      if (isCompletionCandidate || isTerminalIncomplete) && !activitySignature.isEmpty {
        if completionCandidateSignature != activitySignature {
          completionCandidateSignature = activitySignature
          completionCandidateSince = Date()
        } else if let candidateSince = completionCandidateSince,
                  Date().timeIntervalSince(candidateSince) >= 4.0 {
          let completedActivity = replyResult["completedActivity"] as? String
            ?? replyResult["content"] as? String
            ?? replyResult["activity"] as? String
            ?? ""
          if !completedActivity.isEmpty {
            finalReply["content"] = completedActivity
            finalReply["charCount"] = completedActivity.count
            finalReply["done"] = true
            finalReply["terminalIncomplete"] = isTerminalIncomplete
            finalReply["pending"] = false
            finalReply["streaming"] = false
            sawNewReply = true
            break
          }
        }
      } else {
        completionCandidateSince = nil
        completionCandidateSignature = ""
      }

      if messageCount <= baselineMessageCount {
        // ChatGPT may be using tools before it creates the new assistant
        // message. Keep waiting and never expose the previous reply as the
        // current task's live content.
        finalReply["content"] = ""
        finalReply["charCount"] = 0
        finalReply["done"] = false
        finalReply["pending"] = true
        finalReply["streaming"] = isStreaming
      } else {
        sawNewReply = true
        finalReply = replyResult
        let currentChars = replyResult["charCount"] as? Int ?? 0

        if replyResult["done"] as? Bool == true {
          // Reply is complete
          break
        }

        // Update progress tracking
        if currentChars > prevCharCount {
          prevCharCount = currentChars
        }
      }
    }

    if Date().timeIntervalSince(lastPageChangeAt) >= Double(stagnationTimeout) {
      let diagnostic = cdpEvaluateOnChatGPT(pageDiagnosticJS(), preferredURL: activeChatURL) ?? [:]
      stalledPageContent = diagnostic["content"] as? String ?? (finalReply["pageContent"] as? String ?? "")
      stalledButtons = diagnostic["buttons"] as? [String] ?? []
      let devspaceWaiting = finalReply["devspaceWaiting"] as? Bool ?? false
      let diagnosticKind = devspaceWaiting ? "devspace-timeout" : "page-stalled"
      screenshotPath = captureHiddenChatScreenshot(state, label: "\(diagnosticKind)-\(recoveryAttempts + 1)")

      if recoveryAttempts < maxRecoveryAttempts {
        recoveryAttempts += 1
        // A stalled round is disposable. Close the exact plugin-owned ChatGPT
        // target and its matching plugin profile before retrying, then launch a
        // genuinely fresh Chat. This prevents late responses and duplicate
        // plugin instances from surviving into the next orchestration round.
        let previousPort = state.backgroundAppPort
        let previousProfilePath = state.backgroundProfilePath
        let previousCodexHomePath = state.backgroundCodexHomePath
        closeBackgroundTargets(&state)
        state.backgroundAppPort = previousPort
        state.backgroundProfilePath = previousProfilePath
        state.backgroundCodexHomePath = previousCodexHomePath
        state.approveAll = approveAll
        state.enabled = true

        let continuationPreparation: [String: Any]
        let continuationMode = "fresh_plugin_chat_after_stall"
        let recoveryResult: [String: Any]
        let freshPreparation = ensureHiddenChatTarget(
          &state,
          newChat: true,
          conversationId: nil
        )
        if let freshPreparation,
           freshPreparation["ok"] as? Bool == true,
           freshPreparation["newChatClicked"] as? Bool == true,
           let freshPort = freshPreparation["port"] as? Int,
           let freshTargetId = freshPreparation["targetId"] as? String {
          // cdpEvaluateOnChatGPT reads persisted state, so persist the new
          // target before sending into its renderer.
          try? saveState(state)
          let freshBaseline = cdpEvaluateOnChatGPT(
            getReplyJS(),
            preferredURL: nil
          )
          let freshSend = cdpEvaluateOnChatGPT(
            sendMessageJS(
              message: continuationMessage,
              connector: connector,
              newChat: false,
              expectedConversationId: normalizedConversationId(
                freshPreparation["conversationId"] as? String
              )
            ),
            timeout: 65.0,
            preferredURL: nil
          ) ?? ["ok": false, "error": "fresh_chat_send_cdp_failed"]
          var freshResult = freshSend
          freshResult["freshPort"] = freshPort
          freshResult["freshTargetId"] = freshTargetId
          freshResult["continuationMode"] = continuationMode
          continuationPreparation = freshPreparation
          recoveryResult = freshResult
          if freshSend["ok"] as? Bool == true {
            activeChatURL = normalizedChatURL(
              freshPreparation["chatUrl"] as? String
            )
            baselineReply = freshBaseline
            baselineMessageCount = freshBaseline?["messageCount"] as? Int ?? 0
            finalReply = freshBaseline ?? [
              "content": "",
              "streaming": false,
              "done": false,
              "charCount": 0,
            ]
            sawNewReply = false
            prevCharCount = 0
            lastActivitySignature = freshBaseline?["activitySignature"] as? String ?? ""
            completionCandidateSince = nil
            completionCandidateSignature = ""
            stalledPageContent = ""
            stalledButtons = []
          }
        } else {
          continuationPreparation = freshPreparation ?? [
            "ok": false,
            "error": "fresh_plugin_chat_not_confirmed",
          ]
          let preparationError = freshPreparation?["error"] as? String
            ?? state.lastError
            ?? "fresh_plugin_chat_not_confirmed"
          recoveryResult = [
            "ok": false,
            "error": preparationError,
          ]
        }
        let recoveryEvent: [String: Any] = [
          "attempt": recoveryAttempts,
          "reason": devspaceWaiting ? "devspace_timeout" : "page_stalled",
          "idleSeconds": stagnationTimeout,
          "screenshotPath": screenshotPath as Any,
          "oldChatClosed": true,
          "oldChatPreserved": false,
          "stopRequested": true,
          "continuationMode": continuationMode,
          "continuedInNewTask": continuationPreparation["continuationClicked"] as? Bool ?? false,
          "continuationPreparation": continuationPreparation,
          "continued": recoveryResult["messageConfirmed"] as? Bool ?? false,
          "sendVerification": recoveryResult,
          "error": recoveryResult["error"] as Any,
        ]
        recoveryEvents.append(recoveryEvent)
        emitProgress(["event": "auto_recovery", "recovery": recoveryEvent])
        if recoveryResult["ok"] as? Bool == true {
          lastPageChangeAt = Date()
          lastActivitySignature = ""
          Thread.sleep(forTimeInterval: 1.0)
        } else {
          closeBackgroundTargets(&state)
          try? saveState(state)
          stalled = true
          break
        }
      } else {
        closeBackgroundTargets(&state)
        try? saveState(state)
        stalled = true
        break
      }
    }

    // 2c: Wait before next poll
    Thread.sleep(forTimeInterval: Double(pollIntervalMs) / 1000.0)
  }

  if Date() >= deadline && (!sawNewReply || finalReply["done"] as? Bool != true) {
    timedOut = true
    let diagnostic = cdpEvaluateOnChatGPT(pageDiagnosticJS(), preferredURL: activeChatURL) ?? [:]
    stalledPageContent = diagnostic["content"] as? String ?? (finalReply["pageContent"] as? String ?? "")
    stalledButtons = diagnostic["buttons"] as? [String] ?? []
    screenshotPath = captureHiddenChatScreenshot(state, label: "watch-timeout")
  }

  // Save state
  if state.audit.count > 100 { state.audit.removeFirst(state.audit.count - 100) }
  try? saveState(state)

  // Build result
  let replyContent = finalReply["content"] as? String ?? ""
  let naturalReplyContent = [
    replyContent,
    finalReply["completedActivity"] as? String ?? "",
    finalReply["activity"] as? String ?? "",
  ]
  .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
  .first { !$0.isEmpty } ?? ""
  var replyPayload: [String: Any] = [:]
  replyPayload["content"] = String(replyContent.prefix(50000))
  replyPayload["thinking"] = String((finalReply["thinking"] as? String ?? "").prefix(50000))
  replyPayload["activity"] = String((finalReply["activity"] as? String ?? "").prefix(50000))
  replyPayload["activityCharCount"] = finalReply["activityCharCount"] as? Int ?? 0
  replyPayload["devspaceActivity"] = String((finalReply["devspaceActivity"] as? String ?? "").prefix(20000))
  replyPayload["devspaceWaiting"] = finalReply["devspaceWaiting"] as? Bool ?? false
  replyPayload["waitingForApproval"] = finalReply["waitingForApproval"] as? Bool ?? false
  replyPayload["stopAvailable"] = finalReply["stopAvailable"] as? Bool ?? false
  replyPayload["completionCandidate"] = finalReply["completionCandidate"] as? Bool ?? false
  replyPayload["terminalIncomplete"] = finalReply["terminalIncomplete"] as? Bool ?? false
  replyPayload["completedThinkingTitle"] = finalReply["completedThinkingTitle"] as? String ?? ""
  replyPayload["charCount"] = finalReply["charCount"] as? Int ?? 0
  replyPayload["streaming"] = finalReply["streaming"] as? Bool ?? false
  replyPayload["done"] = finalReply["done"] as? Bool ?? false
  replyPayload["pending"] = finalReply["pending"] as? Bool ?? false
  replyPayload["messageCount"] = finalReply["messageCount"] as? Int ?? 0
  replyPayload["userMessageCount"] = finalReply["userMessageCount"] as? Int ?? 0

  var resultPayload: [String: Any] = [:]
  let terminalIncomplete = finalReply["terminalIncomplete"] as? Bool ?? false
  let reportSource = [
    replyContent,
    finalReply["completedActivity"] as? String ?? "",
  ].joined(separator: "\n")
  let taskReport = role == "planner" ? parseTaskReport(reportSource) : nil
  let taskStatus = taskReport?["status"] as? String
  let finalChatStatus = cdpEvaluateOnChatGPT(chatStatusJS(), preferredURL: activeChatURL) ?? [:]
  let finalConversationId = finalChatStatus["conversationId"] as? String
    ?? state.backgroundConversationId
  let finalChatURL = finalChatStatus["chatUrl"] as? String
  let finalRuntimeState: QueueTargetRuntimeState? = {
    guard let port = state.backgroundAppPort,
          let targetId = state.backgroundChatTargetId else { return nil }
    return queueTargetRuntimeState(
      port: port,
      targetId: targetId,
      refreshLifecycle: false
    )
  }()
  let explicitlyIncomplete = finalReply["explicitlyIncomplete"] as? Bool ?? false
  let effectiveTaskStatus = taskStatus
  let reportMissing = role == "planner" && !resumeExisting && !surfaceDrift && !stalled && !timedOut
    && finalReply["done"] as? Bool == true && taskReport == nil
    && !terminalIncomplete && !explicitlyIncomplete
  // A finished reply without the certificate is still an unfinished round.
  // Keep this separate from `reportMissing` so an explicit natural-language
  // "not finished" answer is classified as incomplete while both cases enter
  // the same fresh-Chat continuation path below.
  let completionCertificateMissing = role == "planner" && !resumeExisting && !surfaceDrift && !stalled && !timedOut
    && finalReply["done"] as? Bool == true && taskReport == nil
  let workReplyReady = role == "work"
    && !naturalReplyContent.isEmpty
    && finalReply["done"] as? Bool == true
  let workNaturalResultMissing = role == "work"
    && naturalReplyContent.isEmpty
    && finalReply["done"] as? Bool == true
  resultPayload["ok"] = role == "work"
    ? (!stalled && !timedOut && !surfaceDrift && workReplyReady)
    : (!stalled && !timedOut && !surfaceDrift && !terminalIncomplete
      && !reportMissing && effectiveTaskStatus == "complete"
      && (finalReply["done"] as? Bool == true))
  resultPayload["sent"] = resumeExisting ? false : (sendResult["messageConfirmed"] as? Bool ?? false)
  resultPayload["resumedExisting"] = resumeExisting
  resultPayload["preparation"] = prepared as Any
  resultPayload["sendVerification"] = sendResult
  resultPayload["reply"] = replyPayload
  resultPayload["approvals"] = ["totalApproved": totalApprovals]
  resultPayload["connector"] = connector as Any
  resultPayload["role"] = role
  resultPayload["autoPlanAfterWork"] = autoPlanAfterWork
  resultPayload["naturalWorkResult"] = role == "work" ? String(naturalReplyContent.prefix(50000)) : NSNull()
  resultPayload["naturalWorkResultMissing"] = workNaturalResultMissing
  resultPayload["backgroundOnly"] = finalRuntimeState == .hidden
  resultPayload["runtimeState"] = finalRuntimeState.map(queueTargetRuntimeStateName) as Any
  resultPayload["workerUsed"] = false
  resultPayload["surface"] = "chat"
  resultPayload["backgroundPort"] = state.backgroundAppPort as Any
  resultPayload["backgroundTargetId"] = state.backgroundChatTargetId as Any
  resultPayload["conversationId"] = finalConversationId as Any
  resultPayload["chatUrl"] = finalChatURL as Any
  resultPayload["timedOut"] = timedOut
  resultPayload["stalled"] = stalled
  resultPayload["surfaceDrift"] = surfaceDrift
  resultPayload["surfaceStatus"] = surfaceDriftStatus
  resultPayload["stagnationTimeout"] = stagnationTimeout
  resultPayload["maxRecoveryAttempts"] = maxRecoveryAttempts
  resultPayload["recoveryAttempts"] = recoveryAttempts
  resultPayload["recoveries"] = recoveryEvents
  resultPayload["taskReport"] = taskReport as Any
  resultPayload["taskStatus"] = effectiveTaskStatus as Any
  resultPayload["completionCertificateMissing"] = completionCertificateMissing
  resultPayload["taskContinuationDepth"] = continuationDepth
  resultPayload["maxTaskContinuations"] = maxTaskContinuations
  resultPayload["screenshotPath"] = screenshotPath as Any
  resultPayload["pageContent"] = stalledPageContent
  resultPayload["pageButtons"] = stalledButtons
  resultPayload["elapsedSeconds"] = Int(Date().timeIntervalSince(deadline.addingTimeInterval(Double(-timeout))))
  if surfaceDrift {
    resultPayload["errorCode"] = "chat_surface_drift"
    resultPayload["message"] = "插件自有页面已离开 Chat 表面；小程序在批准或发送任何后续操作前立即退出并保存诊断。"
  } else if stalled {
    let devspaceWaiting = finalReply["devspaceWaiting"] as? Bool ?? false
    resultPayload["errorCode"] = devspaceWaiting ? "devspace_timeout" : "page_stalled"
    resultPayload["message"] = "Chat 页面和可见思考连续 \(stagnationTimeout) 秒没有新内容，小程序已用尽自动续作次数并保存截图与页面文本。"
  } else if timedOut {
    resultPayload["errorCode"] = "watch_timeout"
    resultPayload["message"] = "等待 ChatGPT 最终结果超过 \(timeout) 秒，小程序已截图并返回当前可见思考。"
  } else if reportMissing {
    resultPayload["errorCode"] = "task_report_missing"
    resultPayload["message"] = "ChatGPT 已停止生成，但最终回答缺少可解析的 MAHAYANA_TASK_REPORT_V1；小程序不会猜测任务是否完成。"
  } else if workNaturalResultMissing {
    resultPayload["errorCode"] = "work_natural_result_missing"
    resultPayload["message"] = "Work Chat 已停止生成，但没有返回可交给规划 Chat 的自然语言结果；插件将关闭旧 Chat 并重试新的 Work Chat。"
  } else if terminalIncomplete || taskStatus == "incomplete" || taskStatus == "blocked" {
    resultPayload["errorCode"] = "chat_finished_incomplete"
    resultPayload["message"] = role == "work"
      ? "Work Chat 已停止生成；插件会把这次自然结果交给新的规划 Chat 决定下一步。"
      : "规划 Chat 已停止生成，但报告说明任务未完成；插件会把 next_task 交给新的 Work Chat。"
  }

  if role == "work",
     autoPlanAfterWork,
     !resumeExisting,
     !surfaceDrift,
     !stalled,
     !timedOut,
     workReplyReady,
     let port = state.backgroundAppPort,
     let targetId = state.backgroundChatTargetId {
    // Work-to-planner is a real conversation boundary. The old Work reply is
    // read once, copied into the planner prompt, and never converted into a
    // report template for the Work Chat.
    let plannerRound = continuationDepth + 1
    let plannerTaskId = taskId ?? "send-and-watch"
    let plannerMarker = "规划验收 Chat 标识：\(plannerTaskId)-\(plannerRound)"
    let plannerPreparation = prepareNewChatTarget(
      port: port,
      targetId: targetId,
      timeout: 35.0,
      allowBlankConversationReuse: false
    )
    if let plannerPreparation,
       plannerPreparation["ok"] as? Bool == true {
      let plannerMessage = acceptancePlannerMessage(
        originalGoal: originalGoal,
        workResult: naturalReplyContent,
        taskId: taskId,
        appliedRevision: appliedRevision,
        appliedDigest: appliedDigest
      ) + "\n\n插件调度标记：\(plannerMarker)"
      let plannerSend = cdpEvaluateOnChatGPT(
        sendMessageJS(
          message: plannerMessage,
          connector: connector,
          newChat: false,
          expectedConversationId: normalizedConversationId(
            plannerPreparation["conversationId"] as? String
          )
        ),
        timeout: 65.0,
        preferredURL: activeChatURL
      )
      if plannerSend?["ok"] as? Bool == true,
         let plannerConversationId = normalizedConversationId(
           plannerPreparation["conversationId"] as? String
         ) ?? normalizedConversationId(plannerSend?["conversationId"] as? String) {
        var plannerParams = params
        plannerParams["message"] = plannerMessage
        plannerParams["role"] = "planner"
        plannerParams["autoPlanAfterWork"] = false
        plannerParams["originalGoal"] = originalGoal
        plannerParams["taskId"] = taskId ?? NSNull()
        plannerParams["appliedRevision"] = appliedRevision ?? NSNull()
        plannerParams["appliedDigest"] = appliedDigest ?? NSNull()
        plannerParams["continuationDepth"] = continuationDepth + 1
        plannerParams["resumeExisting"] = true
        plannerParams["freshTargetPrepared"] = true
        plannerParams["newChat"] = false
        plannerParams["conversationId"] = plannerConversationId
        plannerParams["chatUrl"] = plannerSend?["url"] as? String
          ?? plannerPreparation["url"] as? String
          ?? NSNull()
        plannerParams["goalOnlyDispatch"] = false
        resultPayload["plannerHandoff"] = [
          "started": true,
          "role": "planner",
          "conversationId": plannerConversationId,
          "preparation": plannerPreparation as Any,
          "sendVerification": plannerSend as Any,
          "plannerMarker": plannerMarker,
        ]
        emitProgress([
          "event": "planner_handoff",
          "status": "started",
          "workResultChars": naturalReplyContent.count,
          "conversationId": plannerConversationId,
          "backgroundOnly": finalRuntimeState == .hidden,
          "runtimeState": finalRuntimeState.map(queueTargetRuntimeStateName) as Any,
        ])
        relayFreshChatContinuation(plannerParams)
      }
      resultPayload["plannerHandoff"] = [
        "started": false,
        "preparation": plannerPreparation,
        "sendVerification": plannerSend as Any,
      ]
    } else {
      resultPayload["plannerHandoff"] = [
        "started": false,
        "preparation": plannerPreparation as Any,
      ]
    }
    resultPayload["ok"] = false
    resultPayload["errorCode"] = "planner_handoff_not_confirmed"
    resultPayload["message"] = "Work Chat 已返回自然结果，但新的规划 Chat 尚未确认发送；插件保留当前结果并返回诊断。"
  }

  if autoContinueIncomplete,
     !surfaceDrift, !stalled, !timedOut,
     (completionCertificateMissing || taskStatus == "incomplete" || taskStatus == "blocked" || workNaturalResultMissing) {
    let fingerprint: String
    let hasNextTask: Bool
    let continuationPrompt: String
    if workNaturalResultMissing {
      fingerprint = "missing-work-natural-result:\(continuationDepth)"
      hasNextTask = true
      continuationPrompt = messageWithoutTaskReportContract(message)
    } else if let report = taskReport {
      let summary = report["summary"] as? String ?? ""
      let remaining = (report["remaining"] as? [String] ?? []).joined(separator: "\n")
      let blockers = (report["blockers"] as? [String] ?? []).joined(separator: "\n")
      let nextTask = report["next_task"] as? String ?? ""
      fingerprint = [summary, remaining, blockers, nextTask]
        .joined(separator: "|")
        .lowercased()
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      hasNextTask = role == "planner"
        ? !nextTask.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        : !nextTask.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      continuationPrompt = role == "planner"
        ? continuationFromTaskReport(
          report, originalGoal: originalGoal, iteration: continuationDepth + 1)
        : continuationFromTaskReport(
          report, originalGoal: originalGoal, iteration: continuationDepth + 1)
    } else {
      // A planner without its report must be followed by a Work Chat, which
      // will produce a new natural result for another planner. A Work Chat
      // without content remains a Work-only recovery and still receives no
      // report contract.
      fingerprint = "missing-planner-report:\(continuationDepth)"
      hasNextTask = true
      continuationPrompt = role == "planner"
        ? continuationFromTaskReport(
          [:], originalGoal: originalGoal, iteration: continuationDepth + 1)
        : messageWithoutTaskReportContract(originalGoal)
    }
    let continuationAllowed = maxTaskContinuations == 0
      || continuationDepth < maxTaskContinuations
    if !hasNextTask {
      resultPayload["errorCode"] = "task_continuation_unavailable"
      resultPayload["message"] = "未完成报告缺少 next_task，小程序无法构造下一轮 Chat 续作。"
    } else if !continuationAllowed {
      resultPayload["errorCode"] = "task_continuation_limit_reached"
      resultPayload["message"] = "未完成任务已达到显式配置的自动续作上限。"
    } else {
      // Every automatic continuation starts with a real fresh Chat. The
      // child watcher must send the raw next_task (or the current Work
      // instruction for a result-less retry) after this preparation, so the
      // Work -> planner boundary remains intact even for legacy
      // goalOnlyDispatch callers.
      let continuationPreparation = cdpEvaluateOnChatGPT(
        continueInNewTaskJS(),
        timeout: 35.0,
        preferredURL: activeChatURL
      ) ?? ["ok": false, "error": "continue_in_new_task_cdp_failed"]
      if continuationPreparation["ok"] as? Bool == true {
        var childParams = params
        childParams["message"] = continuationPrompt
        childParams["role"] = role == "planner" ? "work" : role
        childParams["autoPlanAfterWork"] = role == "planner"
          ? true
          : autoPlanAfterWork
        childParams["originalGoal"] = originalGoal
        childParams["continuationDepth"] = continuationDepth + 1
        childParams["reportFingerprints"] = Array((reportFingerprints + [fingerprint]).suffix(100))
        childParams["resumeExisting"] = false
        childParams["freshTargetPrepared"] = true
        childParams["newChat"] = false
        childParams["conversationId"] = NSNull()
        childParams["chatUrl"] = NSNull()
        emitProgress([
          "event": "task_continuation",
          "status": "started",
          "errorCode": "task_continuation_started",
          "reason": workNaturalResultMissing ? "work_natural_result_missing" : (taskStatus ?? "missing_completion_certificate"),
          "iteration": continuationDepth + 1,
          "continuationPreparation": continuationPreparation,
          "taskReport": taskReport as Any,
          "backgroundOnly": pluginBackgroundRuntimeState(state) == .hidden,
          "runtimeState": pluginBackgroundRuntimeState(state).map(queueTargetRuntimeStateName) as Any,
          "workerUsed": false,
        ])
        relayFreshChatContinuation(childParams)
      }
      resultPayload["continuationPreparation"] = continuationPreparation
      resultPayload["errorCode"] = continuationPreparation["error"] ?? "continue_in_new_task_not_confirmed"
      resultPayload["message"] = "任务尚未完成，但没有确认新的插件 Chat 已创建；小程序已停止，避免把结果发送回旧 Chat。"
    }
  }
  // A failed public round must not leave a plugin-owned renderer behind for
  // the next invocation. Successful rounds remain visible/inspectable until
  // their caller explicitly stops them; retries and failures are disposable.
  if resultPayload["ok"] as? Bool != true {
    closeBackgroundTargets(&state)
    try? saveState(state)
  }
  output(resultPayload, exitCode: resultPayload["ok"] as? Bool == true ? 0 : 1)
default:
  output(["ok": false, "errorCode": "unknown_command", "message": "未知命令 \(command)"], exitCode: 2)
}
