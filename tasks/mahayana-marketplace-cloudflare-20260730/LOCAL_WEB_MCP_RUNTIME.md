# 可热安装的本地 Web MCP Runtime

## 文档地位

本文件是任务 `mahayana-marketplace-cloudflare-20260730` 的最高优先级移动端与 Web 运行约束。

`LOCAL_FIRST_MCP_APPS.md` 规定本地优先原则；本文件进一步明确：移动端和 Web 端应尽可能运行同一个可下载、签名、版本化的本地网页小程序包，而不是要求每个插件能力都预先编译进大乘主 App。

核心结论：

> 大乘移动端和 Web 端共用同一套本地 Web MCP Runtime。插件包安装后由本机 WebView/PWA 宿主从本地存储加载，MCP Host 通过标准 Tool 调用与网页包中的本地 Web Runtime 通信。Cloudflare 只负责市场、签名包、更新和可选网络服务，不承载必须在本地网页中执行的业务逻辑。

## 1. 一个可安装网页小程序包

```text
Mahayana Local Web MCP App package
├── .codex-plugin/plugin.json
├── mahayana.runtime.json
├── mahayana.permissions.json
├── tools.json
├── ui/
│   ├── index.html
│   ├── app.js
│   ├── styles.css
│   └── assets/
├── runtime/web/
│   ├── worker.js
│   ├── optional.wasm
│   └── workflows/
├── skills/
├── provenance.json
└── signatures/
```

包中的两部分必须隔离：

- `ui/`：MCP Apps View，只负责界面；
- `runtime/web/`：本地 Web MCP Runtime，负责 Tool 实现、业务流程、网络请求和本地网页状态。

不得把高权限业务逻辑仅隐藏在 UI 点击处理器中。UI 按钮和聊天输入都必须调用同一组 MCP Tool。

## 2. 本地安装和热更新

安装流程：

```text
市场签名元数据
→ 下载版本+SHA 不可变包
→ 校验签名、SHA、权限、CSP 和来源
→ 解压到插件版本目录
→ 注册 tools、ui:// resources 和 Web Runtime
→ 原子切换 current 版本
```

更新不要求发布新的大乘主 App，只要更新内容仍属于允许的 HTML/CSS/JavaScript/WASM 小程序范围，并且不新增主 App 尚未批准的原生平台能力。

版本目录：

```text
<plugin-store>/<plugin-id>/
├── versions/1.0.0/<sha>/
├── versions/1.1.0/<sha>/
└── current.json
```

要求：

- 下载和更新必须由用户明确发起或在用户启用自动更新后执行；
- 新版本先在 staging 沙箱加载并完成 smoke test；
- 切换失败立即回滚旧版本；
- 撤销版本不得重新安装；
- 更新记录插件 ID、版本、SHA、来源、权限变化和执行位置。

## 3. 本地资源地址

不要求真实启动对公网开放的 localhost 服务。

移动端优先使用宿主控制的本地 HTTPS-like Origin 或自定义安全 Scheme：

```text
https://local.mahayana.invalid/apps/<plugin-id>/<version>/ui/index.html
```

或平台等价的本地资源拦截器。Android 可用 WebViewAssetLoader/InternalStoragePathHandler；iOS 可用 WKURLSchemeHandler 或受控 loopback server。

必须：

- 每个插件和版本拥有独立 Origin/路径边界；
- 禁止 `file://` 的通配跨域访问；
- 禁止任意目录读取；
- CSP、Origin、插件 ID 和版本必须匹配；
- 网络访问只允许 manifest 声明的域名；
- 本地资源支持离线打开。

## 4. Local Web MCP Runtime

同一网页包在移动端和 Web 端运行相同的 JavaScript/TypeScript/WASM 业务代码。

推荐执行模型：

```text
MCP Host
  │ MCP JSON-RPC / in-process MessagePort
  ▼
Local Web MCP Runtime（Dedicated Worker）
  ├── tools/list
  ├── tools/call
  ├── resources/read
  ├── workflow state
  ├── allowed fetch
  └── local plugin storage

MCP Apps View
  │ AppBridge / postMessage
  ▼
MCP Host
```

这样 UI 与业务 Runtime 分离：

- UI 不能直接获得宿主 Secret；
- Runtime 不能直接操作宿主界面；
- Tool 调用经过 Host 权限、审计和取消控制；
- Runtime 崩溃不会破坏主 App；
- 同一 Runtime 可在移动 WebView、桌面 WebView 和浏览器 PWA 中复用。

允许在实现上使用 Dedicated Worker、Shared Worker、受控 iframe worker 或宿主内 JavaScript isolate，但 Tool 契约必须保持一致。

## 5. 聊天输入如何驱动小程序

用户在大乘输入框发送：

```text
把这篇内容全球法布施到已选择的平台
```

正确流程：

```text
对话 Host / Agent
→ 选择 global-dharma.send Tool
→ MCP Host 调用本地 Web MCP Runtime
→ Runtime 校验参数和权限
→ 执行网页端已有发送逻辑
→ 返回 structuredContent / progress / result
→ MCP Apps View 显示状态
```

不得使用：

```text
把自然语言塞进 iframe
→ 模拟点击网页按钮
→ 猜测页面是否成功
```

页面按钮也调用同一个 Tool：

```text
用户点击“发送”
→ AppBridge tools/call
→ MCP Host
→ Local Web MCP Runtime
```

因此聊天模式和页面模式共享完全相同的发送逻辑。

## 6. 全球法布施

全球法布施如果当前网页已经能通过标准 Web API 完成全球发送，则移动端可以直接安装同一网页 Runtime：

```text
本地安装 global-dharma Web MCP App
→ 本地 WebView/PWA 打开 ui:// View
→ 本地 Worker 注册 send/status/cancel/logs Tools
→ 用户点击或聊天输入触发 send
→ Worker 使用允许的 HTTPS API 执行发送
→ 本地保存队列和结果
```

Cloudflare 不参与每次业务执行，除非网页本身调用获准的远程 API。

敏感凭证要求：

- 不把长期 Token 明文写入插件包；
- 每插件独立加密存储；
- Runtime 通过 Host 获取短期授权句柄或受控网络代理；
- 权限扩大重新确认；
- CSP 与网络 allowlist 同时生效。

## 7. 移动端和普通 Web 的统一与差异

### 统一部分

- 同一个安装包；
- 同一个 UI；
- 同一个 Web Runtime；
- 同一组 MCP Tools；
- 同一权限和版本模型；
- 同一热更新与回滚机制。

### 宿主差异

移动端：

- 包保存在 App 私有目录；
- WebView 从本地安全 Origin 加载；
- Host 能保证持久安装、签名校验和后台生命周期；
- 本地数据库由插件沙箱或 Host 存储适配器提供。

普通浏览器 Web：

- 包可保存到 Cache Storage、IndexedDB 或 OPFS；
- Service Worker/PWA 提供本地资源；
- 浏览器可能清理站点存储，因此需要持久化请求、重新下载和云端备份策略；
- 不能获得未声明的系统原生权限。

在大乘移动 App 内打开的 WebView 是最可靠的移动实现；公开浏览器 Web 可以复用同一代码，但其持久性和后台能力弱于 App 宿主。

## 8. 主 App 何时仍需更新

网页小程序可以独立热更新：

- UI；
- Tool 业务流程；
- 普通 HTTPS 网络调用；
- 表单、规则、模板、Skills；
- JavaScript/WASM 计算；
- 插件私有数据结构迁移。

以下情况仍可能要求更新大乘主 App或获得平台批准：

- 新增尚未存在的原生系统 API；
- 新增相机、蓝牙、通讯录、短信、辅助功能等受限能力；
- 新增长期后台任务；
- 新增越过 Web 沙箱的文件或进程访问；
- 新增平台政策要求单独审核的能力。

因此主 App 应提供少量稳定、通用、可审计的 Host 能力，而不是为每个插件写专属原生代码。

## 9. 应用商店合规边界

移动端热更新必须被定义为受管理的 HTML5/JavaScript MCP Apps 市场，而不是绕过应用商店审核的任意代码下载器。

必须：

- 市场拥有完整插件索引、元数据、年龄分级和 universal/deep link；
- 每个插件经过签名、权限、隐私、内容和恶意代码审核；
- 用户逐插件安装和授权；
- 主 App 商店说明明确披露小程序市场和动态内容；
- 审核人员可访问完整市场和测试账号；
- 不向下载的小程序任意暴露原生平台 API；
- 不通过远程代码隐藏或激活商店审核时不存在的违规功能。

## 10. Runtime Profile

新增统一 Profile：

```json
{
  "id": "local-web",
  "platforms": ["ios", "android", "web", "desktop"],
  "transport": "in-process-messageport",
  "ui": "ui://io.mahayana.publisher.plugin/main",
  "runtimeEntry": "runtime/web/worker.js",
  "offline": true,
  "hotUpdate": true,
  "priority": 300
}
```

可选：

- `desktop-stdio`：需要桌面本机进程、文件、浏览器自动化的插件；
- `remote-edge`：明确需要云端协作或后台服务的插件。

Runtime Resolver 优先级建议：

```text
local-web
→ desktop-stdio（插件需要桌面特权时）
→ approved remote-edge
```

ChatGPT 自动确认仍是 `desktop-stdio`，因为普通网页无法操作本机 ChatGPT renderer；全球法布施优先使用 `local-web`，前提是其发送逻辑确实已能在网页环境完成。

## 11. 强制验收

- 全球法布施同一签名包在 Android、iOS WebView 和桌面 Web/PWA 加载；
- 所有平台使用相同 `runtime/web` Tool 实现；
- 页面按钮与聊天指令调用同一 `tools/call`；
- 断网时本地 UI 和待发送队列可打开；
- 网络恢复后继续执行；
- 更新 Web Runtime 不更新主 App；
- 新版本原子切换并可回滚；
- 被撤销版本被阻止；
- CSP、Origin、域名和权限拒绝路径通过；
- Runtime 与 UI 隔离，UI 无法直接读取 Secret；
- Android/iOS 商店合规检查和审核说明完整；
- 不以模拟点击网页代替 MCP Tool 调用。
