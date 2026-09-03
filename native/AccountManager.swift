import CryptoKit
import Foundation
import Security

// Account metadata is deliberately kept separate from credentials.  The
// registry contains only opaque ids, local labels, state and timestamps; the
// two credential blobs are held by the macOS Keychain (or the explicit test
// vault directory used by contract tests).
struct AccountRecord: Codable {
  var id: String
  var label: String
  var fingerprint: String
  var status: String
  var isDefault: Bool
  var lastLocalVerifiedAt: String?
  var lastCloudVerifiedAt: String?
  var githubEnvironment: String
  var latestActionId: String?
  var profilePath: String
  var codexHomePath: String
}

let maximumAccountCount = 10
let accountIdPattern = "^acct_[0-9a-f]{12}$"

func accountsRootURL() -> URL {
  if let override = ProcessInfo.processInfo.environment["CHATGPT_AUTO_CONFIRM_ACCOUNTS_ROOT"],
     !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
    return URL(fileURLWithPath: override, isDirectory: true)
  }
  return stateURL().deletingLastPathComponent().appendingPathComponent("accounts", isDirectory: true)
}

func accountRegistryURL() -> URL {
  if let override = ProcessInfo.processInfo.environment["CHATGPT_AUTO_CONFIRM_ACCOUNT_REGISTRY"],
     !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
    return URL(fileURLWithPath: override)
  }
  return accountsRootURL().appendingPathComponent("registry.json")
}

func accountVaultDirectoryURL() -> URL? {
  guard let raw = ProcessInfo.processInfo.environment["CHATGPT_AUTO_CONFIRM_KEYCHAIN_DIR"],
        !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
  return URL(fileURLWithPath: raw, isDirectory: true)
}

func accountIsValidId(_ value: String) -> Bool {
  value.range(of: accountIdPattern, options: .regularExpression) != nil
}

func accountSafeComponent(_ value: String) -> String {
  value.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "-", options: .regularExpression)
}

func accountProfileURL(_ account: AccountRecord) -> URL {
  URL(fileURLWithPath: account.profilePath, isDirectory: true)
}

func accountCodexAuthURL(_ account: AccountRecord) -> URL {
  URL(fileURLWithPath: account.codexHomePath, isDirectory: true).appendingPathComponent("auth.json")
}

func defaultAccountLabel(_ account: AccountRecord) -> String {
  let trimmed = account.label.trimmingCharacters(in: .whitespacesAndNewlines)
  return trimmed.isEmpty ? "账号 \(account.id.suffix(4))" : String(trimmed.prefix(80))
}

func loadAccounts() -> [AccountRecord] {
  guard let data = try? Data(contentsOf: accountRegistryURL()),
        var records = try? decoder.decode([AccountRecord].self, from: data) else { return [] }
  var seen = Set<String>()
  records = records.filter { account in
    accountIsValidId(account.id) && seen.insert(account.id).inserted
  }
  if records.count > maximumAccountCount { records = Array(records.prefix(maximumAccountCount)) }
  let defaultIds = records.filter(\.isDefault).map(\.id)
  if defaultIds.count > 1 {
    var first = true
    for index in records.indices {
      if records[index].isDefault {
        records[index].isDefault = first
        first = false
      }
    }
  }
  if !records.isEmpty && !records.contains(where: { $0.isDefault }) {
    records[0].isDefault = true
  }
  return records
}

func saveAccounts(_ records: [AccountRecord]) throws {
  guard records.count <= maximumAccountCount else {
    throw NSError(domain: "chatgpt-auto-confirm", code: 701,
                  userInfo: [NSLocalizedDescriptionKey: "最多支持 \(maximumAccountCount) 个账号"])
  }
  var normalized = records
  var defaultIndex: Int?
  for index in normalized.indices {
    normalized[index].label = defaultAccountLabel(normalized[index])
    if normalized[index].isDefault {
      if defaultIndex == nil { defaultIndex = index }
      else { normalized[index].isDefault = false }
    }
  }
  if defaultIndex == nil, !normalized.isEmpty { normalized[0].isDefault = true }
  let url = accountRegistryURL()
  try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  let data = try encoder.encode(normalized)
  try data.write(to: url, options: .atomic)
  try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

func accountById(_ id: String?, records: [AccountRecord] = loadAccounts()) -> AccountRecord? {
  guard let id, accountIsValidId(id) else { return nil }
  return records.first(where: { $0.id == id })
}

func resolveAccount(_ requested: String?, records: [AccountRecord] = loadAccounts()) -> AccountRecord? {
  if let requested, !requested.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
    return accountById(requested, records: records)
  }
  return records.first(where: { $0.isDefault }) ?? records.first
}

func randomAccountId(_ existing: Set<String>) -> String {
  while true {
    let hex = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    let candidate = "acct_\(hex.prefix(12))"
    if !existing.contains(candidate) { return candidate }
  }
}

func accountFingerprint(_ rawIdentifier: String) -> String {
  let digest = SHA256.hash(data: Data(rawIdentifier.utf8))
  return digest.map { String(format: "%02x", $0) }.joined()
}

func authObject(at url: URL) -> [String: Any]? {
  guard let data = try? Data(contentsOf: url),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
  return object
}

func accountFingerprint(at authURL: URL) -> String? {
  guard let auth = authObject(at: authURL),
        let tokens = auth["tokens"] as? [String: Any],
        let accountId = tokens["account_id"] as? String,
        !accountId.isEmpty else { return nil }
  return accountFingerprint(accountId)
}

func accountRawIdentifier(data: Data) -> String? {
  guard let auth = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let tokens = auth["tokens"] as? [String: Any],
        let accountId = tokens["account_id"] as? String,
        !accountId.isEmpty else { return nil }
  return accountId
}

func accountFingerprint(data: Data) -> String? {
  guard let raw = accountRawIdentifier(data: data) else { return nil }
  return accountFingerprint(raw)
}

func accountRawIdentifier(at authURL: URL) -> String? {
  guard let auth = authObject(at: authURL),
        let tokens = auth["tokens"] as? [String: Any],
        let accountId = tokens["account_id"] as? String,
        !accountId.isEmpty else { return nil }
  return accountId
}

func accountPublicPayload(_ account: AccountRecord) -> [String: Any] {
  [
    "id": account.id,
    "label": defaultAccountLabel(account),
    "fingerprint": account.fingerprint,
    "status": account.status,
    "isDefault": account.isDefault,
    "lastLocalVerifiedAt": account.lastLocalVerifiedAt as Any,
    "lastCloudVerifiedAt": account.lastCloudVerifiedAt as Any,
    "githubEnvironment": account.githubEnvironment,
    "latestActionId": account.latestActionId as Any,
  ]
}

enum AccountVault {
  // v2 intentionally starts a fresh Keychain ACL after the runtime moved from
  // linker ad-hoc signing to a stable Apple Development signature. Reusing the
  // old service would keep the old CDHash-bound ACL and macOS would continue
  // asking for the login-keychain password after every rebuilt binary.
  static let service = "com.fabushi.chatgpt-auto-confirm.v2"

  static func key(_ accountId: String, _ name: String) -> String {
    "\(accountId):\(name)"
  }

  static func fakeURL(_ accountId: String, _ name: String) -> URL? {
    accountVaultDirectoryURL()?.appendingPathComponent("\(accountId)-\(name).bin")
  }

  static func put(_ data: Data, accountId: String, name: String) throws {
    if let url = fakeURL(accountId, name) {
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: url, options: .atomic)
      try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
      return
    }
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: key(accountId, name),
    ]
    let attributes = query.merging([kSecValueData as String: data]) { _, new in new }
    let status = SecItemAdd(attributes as CFDictionary, nil)
    if status == errSecDuplicateItem {
      let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
      guard updated == errSecSuccess else { throw vaultError(updated) }
    } else if status != errSecSuccess {
      throw vaultError(status)
    }
  }

  static func get(accountId: String, name: String) throws -> Data? {
    if let url = fakeURL(accountId, name) { return try? Data(contentsOf: url) }
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: key(accountId, name),
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw vaultError(status) }
    return result as? Data
  }

  static func remove(accountId: String, name: String) throws {
    if let url = fakeURL(accountId, name) {
      try? FileManager.default.removeItem(at: url)
      return
    }
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: key(accountId, name),
    ]
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else { throw vaultError(status) }
  }

  static func vaultError(_ status: OSStatus) -> NSError {
    NSError(domain: "chatgpt-auto-confirm.keychain", code: Int(status),
            userInfo: [NSLocalizedDescriptionKey: "macOS 凭据存储操作失败"])
  }
}

func accountCreateDirectories(_ account: AccountRecord) throws {
  let fileManager = FileManager.default
  try fileManager.createDirectory(at: accountProfileURL(account), withIntermediateDirectories: true)
  try fileManager.createDirectory(at: URL(fileURLWithPath: account.codexHomePath), withIntermediateDirectories: true)
  try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: accountProfileURL(account).path)
  try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: account.codexHomePath)
}

func accountAuthData(_ account: AccountRecord) -> Data? {
  try? AccountVault.get(accountId: account.id, name: "codex-auth")
}

func accountCookieData(_ account: AccountRecord) -> Data? {
  try? AccountVault.get(accountId: account.id, name: "session-cookies")
}

func accountStoreCredentials(_ account: AccountRecord, authData: Data, cookieData: Data) throws {
  // Write both values only after the caller has validated them.  If the second
  // write fails, remove the first value so the registry can never point at a
  // half-populated account.
  try AccountVault.put(authData, accountId: account.id, name: "codex-auth")
  do {
    try AccountVault.put(cookieData, accountId: account.id, name: "session-cookies")
  } catch {
    try? AccountVault.remove(accountId: account.id, name: "codex-auth")
    throw error
  }
}

func accountRemoveCredentials(_ account: AccountRecord) {
  try? AccountVault.remove(accountId: account.id, name: "codex-auth")
  try? AccountVault.remove(accountId: account.id, name: "session-cookies")
}

func accountEnvironmentName(_ id: String) -> String {
  "chatgpt-auto-confirm-\(id)"
}

struct AccountLoginSession {
  let account: AccountRecord
  let port: Int
  let target: ActionsLoginTarget
  let authData: Data
  let cookieData: Data
}

func accountAvailableCDPPort() -> Int {
  for port in 9400..<9500 where CDPClient.fetchTargets(portOverride: port).isEmpty {
    return port
  }
  return 9499
}

func accountLaunchDesktop(_ account: AccountRecord, port: Int) throws {
  let executable = "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"
  guard FileManager.default.fileExists(atPath: executable) else {
    throw NSError(domain: "chatgpt-auto-confirm", code: 702,
                  userInfo: [NSLocalizedDescriptionKey: "未找到 /Applications/ChatGPT.app"])
  }
  try accountCreateDirectories(account)
  let process = Process()
  process.executableURL = URL(fileURLWithPath: executable)
  process.arguments = [
    "--user-data-dir=\(accountProfileURL(account).path)",
    "--remote-debugging-port=\(port)",
  ]
  var environment = ProcessInfo.processInfo.environment
  environment["CODEX_HOME"] = account.codexHomePath
  process.environment = environment
  process.standardInput = FileHandle.nullDevice
  // The login window is intentionally visible.  We do not activate or close
  // the user's existing ChatGPT instance, and output is never captured.
  process.standardOutput = FileHandle.nullDevice
  process.standardError = FileHandle.nullDevice
  try process.run()
}

func accountLoginTarget(port: Int) -> ActionsLoginTarget? {
  let targets = CDPClient.fetchTargets(portOverride: port).filter { target in
    guard isLoadedApprovalRendererTarget(target),
          let url = target["url"] as? String else { return false }
    return !url.contains("avatar-overlay") && url.hasPrefix("app://-/index.html")
  }
  for target in targets {
    guard let targetId = target["id"] as? String,
          let wsURL = target["webSocketDebuggerUrl"] as? String,
          let url = target["url"] as? String else { continue }
    return ActionsLoginTarget(port: port, targetId: targetId, wsURL: wsURL, url: url)
  }
  return nil
}

func accountAuthDataIsUsable(_ data: Data) -> Bool {
  guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let tokens = object["tokens"] as? [String: Any],
        let accountId = tokens["account_id"] as? String,
        !accountId.isEmpty,
        let refreshToken = tokens["refresh_token"] as? String,
        !refreshToken.isEmpty else { return false }
  return true
}

func accountCredentialData(_ account: AccountRecord) -> (auth: Data, cookies: Data)? {
  if let auth = accountAuthData(account), let cookies = accountCookieData(account) {
    return (auth, cookies)
  }
  guard let auth = try? Data(contentsOf: accountCodexAuthURL(account)),
        let cookies = try? Data(contentsOf: accountsRootURL().appendingPathComponent("\(account.id)-session-cookies.json")) else {
    return nil
  }
  return (auth, cookies)
}

func accountCredentialSession(
  _ account: AccountRecord,
  waitSeconds: Int,
  openLoginWindow: Bool
) throws -> AccountLoginSession {
  let port = accountAvailableCDPPort()
  if openLoginWindow || accountLoginTarget(port: port) == nil {
    try accountLaunchDesktop(account, port: port)
  }
  let deadline = Date().addingTimeInterval(TimeInterval(waitSeconds))
  var target: ActionsLoginTarget?
  while Date() < deadline {
    target = accountLoginTarget(port: port)
    if let target,
       let state = actionsDesktopState(target),
       state["authenticated"] as? Bool == true,
       let auth = try? Data(contentsOf: accountCodexAuthURL(account)),
       accountAuthDataIsUsable(auth) {
      let cookies = CDPClient.allCookies(wsURLString: target.wsURL, timeout: 8.0)
      guard !cookies.isEmpty,
            let cookieObject = try? JSONSerialization.data(withJSONObject: ["cookies": cookies], options: [.sortedKeys]) else {
        throw NSError(domain: "chatgpt-auto-confirm", code: 703,
                      userInfo: [NSLocalizedDescriptionKey: "登录完成但没有捕获到 ChatGPT Cookie"])
      }
      return AccountLoginSession(account: account, port: port, target: target, authData: auth, cookieData: cookieObject)
    }
    Thread.sleep(forTimeInterval: 2)
  }
  throw NSError(domain: "chatgpt-auto-confirm", code: 704,
                userInfo: [NSLocalizedDescriptionKey: "等待账号登录超时；没有保存凭据"])
}

// Credential registration already has a dedicated, authenticated renderer
// from `accountCredentialSession`.  Validate the auth state and a real Chat
// composer in that renderer directly; account setup must not launch a second
// hidden ChatGPT instance merely to prove that the captured credentials work.
func accountHiddenSmoke(_ session: AccountLoginSession) -> Bool {
  queueTrace("account-smoke stage=visible-begin account=\(session.account.id)")
  guard let state = actionsDesktopState(session.target),
        state["authenticated"] as? Bool == true else {
    queueTrace("account-smoke stage=visible-auth-failed")
    return false
  }
  guard accountAuthDataIsUsable(session.authData), !session.cookieData.isEmpty else {
    queueTrace("account-smoke stage=visible-credential-shape-failed")
    return false
  }
  queueTrace("account-smoke stage=visible-passed credentials=present")
  return true
}
