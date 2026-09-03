# PRD：可热安装的本地 Web MCP Apps 小程序市场

> v12.2 产品补充：AI 代码先进入本地 Workspace，只有用户明确上线才创建 GitHub source binding 或网页 deployment；源码目标与运行目标分开选择。完整产品和成本决策见 `LOCAL_GENERATION_GITHUB_DEPLOYMENT.md`。

## 1. 产品目标

大乘小程序统一为可签名下载、安装到本地、独立版本更新和回滚的 MCP Apps。

移动端、桌面 WebView 和普通 Web/PWA 尽可能运行同一套本地网页包：

```text
MCP Apps View
+ Local Web MCP Runtime
+ signed immutable package
+ local installation
+ hot update
```

MCP Apps 负责统一 UI、Tool、Resource 和 Host 通信；小程序业务逻辑可以运行在本地 JavaScript/TypeScript/WASM Runtime 中，不要求所有插件逻辑都预编译进大乘主 App，也不要求部署到 Cloudflare Runtime。

## 2. 产品原则

- 一个小程序一个稳定插件 ID；
- 一个版本一个签名、不可变的本地安装包；
- 移动端和 Web 共用同一网页 UI 与 Web Runtime；
- 页面按钮和聊天输入调用同一组 MCP Tool；
- 小程序网页包可以独立热更新，不要求每次更新主 App；
- 主 App 只提供通用 Host、安装器、沙箱、签名校验和政策允许的通用能力；
- 市场控制平面负责签名元数据、撤销和更新；不可变包可由受信任 provider 分发；Cloudflare 继续承载现有控制面和可选远程 API，但不是每个用户项目的必选资源；
- 不用远程网页替代已经安装的本地网页；
- 不通过模拟网页点击实现聊天调用；
- 不把热更新做成绕过应用商店审核的任意代码下载器。

## 3. 一个插件包

```text
plugin package
├── plugin.json
├── runtime.json
├── permissions.json
├── tools.json
├── ui/
├── runtime/web/
├── skills/
├── provenance.json
└── signatures/
```

### `ui/`

标准 MCP Apps View：

- `io.modelcontextprotocol/ui`；
- `ui://`；
- `text/html;profile=mcp-app`；
- `_meta.ui.resourceUri`；
- AppBridge；
- sandbox；
- CSP；
- model/app Tool visibility。

### `runtime/web/`

本地 Web MCP Runtime：

- JavaScript/TypeScript/WASM；
- 运行于 Dedicated Worker、MessagePort 或等价隔离执行环境；
- 实现 `tools/list`、`tools/call` 和本地 workflow；
- 只能访问声明并获批的网络和存储；
- 不直接读取 Host Secret；
- 不直接操作宿主界面。

## 4. 安装体验

```text
市场浏览
→ 用户点击安装
→ 下载版本+SHA 不可变包
→ 验证签名、来源、权限、CSP 和哈希
→ 安装到本地插件目录
→ 注册 UI、Tool 和 Runtime
→ 本地打开
```

用户应看到：

- 插件身份；
- 版本；
- 发布者；
- 执行位置：本地网页；
- 网络域名；
- 数据与隐私权限；
- 是否支持离线；
- 更新和回滚状态。

## 5. 移动端

移动端从 App 私有目录加载已安装网页包，通过安全本地 Origin 渲染 WebView。

```text
本地插件包
→ 本地 WebView
→ MCP Apps AppBridge
→ MCP Host
→ Local Web MCP Runtime Worker
```

移动端不需要为每个插件预编译专属业务逻辑。只要功能可以通过标准 Web API、JavaScript/WASM 和获准网络请求完成，就可以随插件包更新。

## 6. Web 端

普通 Web/PWA 使用同一网页包与 Runtime：

- Service Worker；
- Cache Storage；
- IndexedDB/OPFS；
- 本地版本清单；
- 重新下载与恢复策略。

浏览器存储可能被系统清理，因此 Web 端必须支持重新拉取签名版本和恢复插件状态。

## 7. 聊天驱动

用户在聊天框发送指令时：

```text
Host/Agent 解析意图
→ 调用插件公开的 MCP Tool
→ Local Web Runtime 执行
→ 返回 structuredContent
→ UI 展示进度和结果
```

页面按钮也调用相同 Tool。不得为聊天模式维护第二套业务逻辑。

## 8. 全球法布施

如果全球法布施现有网页已经可以完成发送，则它必须作为首个 `local-web` 官方插件迁移：

- iOS、Android、桌面和 Web 共用同一个包；
- `send/status/cancel/logs` 由本地 Web Runtime 实现；
- 发送队列和状态保存在插件本地存储；
- 页面点击与聊天指令调用同一 Tool；
- 无网络时能打开 UI、查看队列和编辑任务；
- 网络恢复后继续执行；
- 更新网页功能不发布新主 App。

## 9. 主 App 需要更新的情况

以下通常可以独立更新：

- UI；
- Web Tool 逻辑；
- 表单和规则；
- Skills；
- 普通 HTTPS 请求；
- JavaScript/WASM；
- 插件私有数据迁移。

以下可能要求更新主 App 或获得平台许可：

- 新原生平台 API；
- 相机、蓝牙、通讯录、短信等受限能力；
- 辅助功能或进程控制；
- 长期后台执行；
- 越过 Web 沙箱的文件和系统访问。

## 10. 桌面特殊插件

ChatGPT 自动确认无法仅靠普通网页 Runtime 操作本机 ChatGPT renderer，因此继续采用 `desktop-stdio`。

同一市场允许：

- `local-web`；
- `desktop-stdio`；
- `hybrid`；
- `remote-edge`。

但移动/Web 默认优先 `local-web`。

## 11. 商店合规

大乘必须把该能力公开描述为 HTML5/JavaScript 小程序市场，并提供：

- 完整软件索引；
- 插件元数据与深链；
- 发布审核；
- 隐私和权限逐插件同意；
- 内容分级；
- 举报和封禁；
- 审核账号；
- 签名、撤销和恶意代码处置。

不得允许插件下载后获得未经批准的任意原生平台 API，也不得通过远程更新隐藏商店审核时未披露的功能。

## 12. 成功标准

全球法布施必须证明：

```text
同一网页包
→ iOS 本地安装运行
→ Android 本地安装运行
→ 桌面 WebView 本地运行
→ 普通 Web/PWA 本地运行
→ 聊天 Tool 调用
→ 页面 Tool 调用
→ 热更新
→ 回滚
→ 撤销
```

并且更新小程序网页功能时不需要发布新的大乘主 App。
