# 验收标准：单一身份、多构件 MCP Apps 架构

> v12.2 说明：本文件的原有多构件/MCP Apps 验收继续有效；新增本地生成、双 GitHub 源码路径与分级部署的 34 个强制门禁以 `EXECUTION_TASKS_V12.md` 为准。两者冲突时以后者为准。

任务只有在所有必须项满足并提供真实平台证据后才能报告 `complete`。

## 1. 单一插件身份

- [ ] 每个小程序只有一个稳定 plugin ID。
- [ ] 一个 Release 只有一个 semantic version。
- [ ] Tool 名称、input/output schema、错误码、权限和业务语义跨构件一致。
- [ ] MCP Apps `ui://` resource identity 跨平台一致。
- [ ] 父 Release Manifest 对完整构件图签名。

## 2. 多构件发布

- [ ] Release 支持 common、native 和 web-wasm 构件。
- [ ] common 包含 manifest、tools、permissions、UI、Skills 和 workflows。
- [ ] macOS、Windows、Linux 按实际 OS/CPU 提供 native CLI 构件。
- [ ] iOS、Android、桌面 WebView 和普通 Web/PWA 使用 web-wasm 构件。
- [ ] 每个构件有独立不可变 URL、SHA-256、大小、来源和 provenance。
- [ ] 构件声明 platform、OS、architecture、Host/MCP Apps version、WASM features 和 required capabilities。
- [ ] 构件选择条件不存在歧义或错误重叠。

## 3. 平台最小安装

- [ ] 桌面 App 只下载 common UI 与当前 OS/CPU native CLI。
- [ ] 纯 CLI 环境可跳过非必要 UI 大资源。
- [ ] iOS/Android 只下载 common UI 与 web-wasm，不下载桌面二进制。
- [ ] 普通 Web/PWA 只缓存 common UI 与 web-wasm。
- [ ] 不兼容构件在下载前即被拒绝。
- [ ] 安装前展示下载大小、执行位置、权限和选择的构件。

## 4. 全球法布施

- [ ] 同一 `global-dharma` Release 同时包含 native CLI 与 web-wasm。
- [ ] macOS native CLI 真实运行。
- [ ] Windows native CLI 真实运行。
- [ ] Linux native CLI 真实运行。
- [ ] iOS WebView + Worker/WASM 真实运行。
- [ ] Android WebView + Worker/WASM 真实运行。
- [ ] 桌面 WebView + Worker/WASM 真实运行。
- [ ] 普通 Web/PWA + Worker/WASM 真实运行。
- [ ] 所有环境实现相同 `send/status/cancel/logs` Tool Contract。
- [ ] 页面按钮和聊天输入调用同一个 Tool。
- [ ] 不通过向 iframe 注入自然语言或模拟点击实现发送。

## 5. MCP Apps

- [ ] 声明 `io.modelcontextprotocol/ui`。
- [ ] 使用 `ui://` resource。
- [ ] MIME 为 `text/html;profile=mcp-app`。
- [ ] Tool 通过 `_meta.ui.resourceUri` 关联 UI。
- [ ] View 使用 AppBridge 或规范一致实现。
- [ ] iframe/WebView 使用 sandbox、CSP、Origin 和网络 allowlist。
- [ ] app/model Tool visibility 正确。
- [ ] host context、display modes 和 teardown 正常。

## 6. 本地 Web/WASM Runtime

- [ ] UI 与 Runtime 分离。
- [ ] Web Runtime 在 Worker、MessagePort 或等价隔离环境中执行。
- [ ] 移动端从 App 私有目录和安全本地 Origin 加载。
- [ ] 普通 Web/PWA 使用 Service Worker、Cache Storage、IndexedDB 或 OPFS。
- [ ] 无网络时可打开 UI、读取本地状态和管理队列。
- [ ] 网络恢复后可继续允许的任务。
- [ ] 长期 Secret 不进入安装包或 WASM。
- [ ] Host 提供短期授权句柄或受控网络代理。

## 7. Native 与 WASM 契约一致

- [ ] native CLI 与 web-wasm 运行同一 Tool Contract Test 套件。
- [ ] 成功结果 `content` 与 `structuredContent` 语义一致。
- [ ] 参数校验一致。
- [ ] 错误码和可重试语义一致。
- [ ] 权限请求一致。
- [ ] 队列状态机和取消语义一致。
- [ ] 数据模型版本和迁移规则一致。

## 8. 安装、更新与回滚

- [ ] common 与 selected artifact 在 staging 中完整验证。
- [ ] 激活是完整构件集合的原子切换。
- [ ] 不存在 UI 新版本、Runtime 旧版本的意外混合状态。
- [ ] 更新失败不会破坏当前版本。
- [ ] 回滚恢复同一旧 Release 的完整构件集合。
- [ ] 撤销强制构件会阻止该平台继续运行整个 Release。
- [ ] 运行时不得临时下载 Release 未声明代码。

## 9. 非全平台插件

- [ ] 插件可以只提供部分平台构件。
- [ ] ChatGPT 自动确认可以只提供 desktop native artifact。
- [ ] 缺少 web-wasm 时移动/Web 明确显示不支持。
- [ ] 不会伪造移动或云端执行。

## 10. 市场与发布安全

- [ ] 一个发布者可以拥有多个插件。
- [ ] plugin ID 和版本不可覆盖。
- [ ] GitHub Actions OIDC、provenance 和市场签名完整。
- [ ] CLI/Host 验证父 manifest 与每个构件哈希。
- [ ] 权限扩大必须重新确认。
- [ ] 支持审核、撤销、封禁、升级和回滚。
- [ ] 禁止 R2。
- [ ] 市场不永久代理安装包字节。

## 11. 旧路径删除

- [ ] 不存在生产 `Mcp-Session-Id`。
- [ ] 不存在旧 GET/SSE/DELETE Session。
- [ ] 不存在 SDK v1 Server。
- [ ] 不存在 `createLegacyMcpHandler`、`McpAgent` 或 `WorkerTransport` 生产路径。
- [ ] 不存在 `mcp-2025-06-18` fallback。
- [ ] 不存在大乘自定义 iframe bridge。
- [ ] 新 Host 不运行未迁移旧插件。

## 12. GitHub Actions 与真实证据

- [ ] Actions 构建所有 declared native 和 web-wasm artifacts。
- [ ] Actions 生成并签署构件图。
- [ ] 每个平台安装测试证明只下载匹配构件。
- [ ] Tool Contract Test 在 native 与 WASM 全部通过。
- [ ] 真实移动端、桌面端和 Web 端 E2E 通过。
- [ ] 构件篡改、架构错误、平台不兼容和撤销均被拒绝。
- [ ] 日志记录 plugin ID、version、artifact ID、SHA、platform 和执行位置。

## 13. 完成报告

最终报告必须列出：

- PR、合并提交和 Actions runs；
- plugin ID/version 与父 Release Manifest；
- 全部构件 ID、平台、URL、SHA 和 provenance；
- 各平台实际下载的最小构件集合；
- 全球法布施 native CLI 与 web-wasm 运行证据；
- 跨构件 Tool Contract Test；
- MCP Apps UI、CSP、权限与执行位置；
- 安装、更新、原子切换、回滚和撤销；
- 旧 Runtime 删除证据。

缺少任一强制项时状态必须为 `incomplete`。

## 14. 本地生成、源码托管与网页部署

- [ ] AI 生成的首份代码在平台管理的本地 Workspace 落盘，断网可重开、修改和运行。
- [ ] 未经用户明确执行上线，不创建 GitHub repo、Pages site、Cloudflare project 或其他远程资源。
- [ ] 官方托管使用与 `bhrumom` 隔离的 managed user apps 组织，用户不需要 GitHub 账号。
- [ ] “我的 GitHub”只使用官方 GitHub MCP/连接器，法布施 API、日志和数据库不接收用户 GitHub 凭证。
- [ ] source provider/actor/transport 与 hosting provider 分字段保存，上传源码不被显示成网页已上线。
- [ ] GitHub Pages 只接收用户明确同意公开、符合其用途政策的纯静态项目；不宣传无限容量。
- [ ] 动态、鉴权、API、实时或私有场景保留 Cloudflare/外部托管路径。
- [ ] managed org 容量、Actions、存储、滥用、归档、迁移和退出均有自动护栏。
- [ ] 用户可以把官方托管项目无损迁移到自己的 GitHub，并保留 lineage。
- [ ] 所有 34 个 `v12 / Txx.n` required checks 在 GitHub Actions 中真实通过。
