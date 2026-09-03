# 安全模型：MCP Apps-only 大乘小程序市场

## 1. 安全目标

系统必须保证：

- 只运行已批准的 MCP Apps 版本；
- 生产 endpoint 不接受旧 MCP 协议；
- View 只能在 Host sandbox 和 CSP 内运行；
- Tool visibility、权限和插件身份不能被绕过；
- 发布物不可变、可签名验证、可撤销、可回滚；
- 单插件泄露不扩散到其他插件；
- OIDC、provenance 和审计可复核。

## 2. 主要威胁

- 恶意或被接管的发布者；
- 被修改的 Actions workflow；
- 伪造 provenance；
- 被攻破的插件 Worker；
- 旧客户端尝试走 legacy lane；
- View 绕过 Host 直接调用外部网络或 Tool；
- CSP 过宽、iframe sandbox 逃逸、顶层导航；
- app-only Tool 被模型调用；
- model-only Tool 被 View 调用；
- 跨插件 resource/Tool 调用；
- MCP session fixation、sticky routing 或 session store 复活；
- 包篡改、回退、冻结、路径穿越和压缩炸弹。

## 3. MCP Apps Host 安全

Host 必须：

- 使用 sandboxed iframe；
- 按 resource 声明构造 CSP；
- CSP 缺失时使用限制性默认策略；
- 不允许未声明域名；
- 验证 resource URI、plugin ID、version 和 content hash；
- View 只能通过 AppBridge 与 Host 通信；
- Tool 调用经过 visibility、权限和风险确认；
- `ui/open-link` 经过 URL 和用户策略；
- teardown 后关闭 bridge、事件和授权上下文；
- 记录 CSP、Tool、权限和链接操作审计。

禁止注入 access token、Secret、原生对象或无限制网络能力到 View。

## 4. Tool visibility

- `visibility: ["model"]`：仅模型可见；
- `visibility: ["app"]`：仅同一插件 View 可调用；
- `visibility: ["model", "app"]`：两者可调用；
- Host 必须拒绝越权调用；
- app-only Tool 不得进入模型 tool list；
- 跨服务器 app-only Tool 永远禁止。

## 5. 无状态 runtime

Production 必须使用 SDK v2 `createMcpHandler` 与 `legacy:"reject"`。

禁止：

- `Mcp-Session-Id`；
- `WorkerTransport`；
- SDK v1 server；
- sticky session；
- transport session store；
- GET/DELETE session；
- legacy route。

业务状态必须使用认证后的显式句柄。Durable Object 只能表示业务对象，不能表示 MCP transport session。

## 6. Host、Origin 与 OAuth

当 `hostingProvider` 为 Cloudflare 且存在远程 MCP endpoint 时必须：

- 校验 Host allowlist；
- 校验浏览器 Origin；
- 拒绝 opaque/malformed Origin；
- CORS 不作为认证；
- 校验 OAuth access token、issuer、audience、scope 和 resource；
- AuthInfo 绑定插件、用户和 Tool 权限；
- 不记录 token 或敏感 claims。

## 7. OIDC 可信发布

GitHub Actions OIDC 验证：

- issuer/audience；
- repository/workflow/commit；
- environment/ref；
- plugin owner；
- intent expiry；
- nonce 防重放；
- stage/release scope。

短期发布 token 只允许一个插件、版本和阶段，且不得写日志。

## 8. Provenance 与不可变发布

provenance 绑定：repository ID、commit/tree、snapshot、workflow、run、builder、artifact SHA、hosting provider/version/deployment（若存在）。

正式 URL 包含 version 和 SHA；同一版本不可覆盖；`latest` 只作为指针；回滚只切 deployment，不改旧字节。

## 9. 市场签名和更新安全

签名覆盖：

- plugin ID/version；
- MCP Apps runtime contract；
- UI resources/MIME/CSP/visibility；
- package URL/SHA/size；
- permissions/source/provenance；
- review/revocation/expiry/metadata version。

客户端实施根信任、过期、防回退、防冻结、密钥轮换和撤销。

## 10. 包和安装安全

- 只接受发布清单和 provider policy 批准的 HTTPS/artifact 来源；GitHub Pages、Cloudflare 和 external 分别执行 allowlist/所有权校验；
- 限制重定向、大小和时间；
- 校验内容类型、大小和 SHA；
- 拒绝绝对路径、`..`、链接逃逸、设备文件、压缩炸弹、重复路径；
- staging 验证后原子切换；
- 包内 MCP Apps manifest 必须与签名元数据一致。

## 11. 旧客户端和旧插件

旧客户端：

- 返回 `MCP_APPS_HOST_UPGRADE_REQUIRED`；
- 不创建 session；
- 不执行 Tool；
- 不返回旧 UI。

旧插件：

- 标记 `migration_required`；
- 不可安装、不可运行、不可成为 production；
- 只能由迁移工具读取静态信息。

## 12. 强制攻击测试

必须证明拒绝：

- legacy 请求；
- SDK v1/legacy handler；
- 缺失或伪造 MCP Apps extension；
- 非 `ui://` resource；
- 错误 MIME；
- CSP 未声明域名；
- sandbox 逃逸和顶层导航；
- Tool visibility 越权；
- 跨插件调用；
- OIDC claims 不匹配和 nonce 重放；
- 包/签名/provenance/权限篡改；
- 回退、冻结、撤销版本；
- 路径穿越和压缩炸弹；
- 插件访问其他插件 Secret 或数据。

## 13. 审计

记录：插件、版本、Host、resource URI、Tool、visibility、CSP、permission decision、OIDC 摘要、provenance、source binding、hosting provider/deployment、legacy rejection（若适用）、升级要求、安装/撤销/回滚。

禁止记录 token、Secret、敏感输入和包正文。
