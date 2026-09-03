# 迁移计划：全面切换到 MCP Apps

> v12.2 范围说明：本文件中的 Cloudflare Worker 步骤只适用于选择远程 Cloudflare runtime 的项目；local-only 和 GitHub Pages 静态项目不创建 Worker。新增本地 Workspace、双 GitHub 源码路径和部署路由按 `LOCAL_GENERATION_GITHUB_DEPLOYMENT.md` 与 `EXECUTION_TASKS_V12.md` 实施。

## 1. 原则

- 不运行期双栈；
- 不保留 legacy production lane；
- 先在隔离环境完成全部迁移，再一次性切换；
- 允许保留数据转换、静态扫描和升级提示工具；
- 不允许保留运行旧插件的代码；
- 切换失败时回滚整个新版本部署，而不是重新启用旧 MCP 通道。

## 2. 当前基线

需要移除的旧实现包括：

- `mcp-2025-06-18`；
- 服务 session 初始化与 `Mcp-Session-Id`；
- GET/SSE listener；
- DELETE session；
- SDK v1 server/WorkerTransport/McpAgent；
- 大乘自定义 iframe bridge；
- 旧插件 manifest 与 UI 入口；
- 允许 legacy 请求的 Cloudflare endpoint。

## 3. 阶段 0：冻结与审计

- 冻结新增旧格式插件；
- 搜索所有旧协议代码、依赖、测试和部署；
- 列出全部官方插件和已发布第三方插件；
- 建立迁移状态表；
- 固化现有市场、安装和插件行为证据，仅用于对比，不作为新运行时兼容要求；
- 建隔离 preview 环境和测试命名空间。

退出条件：旧实现和插件清单完整。

## 4. 阶段 1：共享 MCP Apps Host core

实现可被 Web、桌面、移动和 CLI 复用的 Host core：

- AppBridge；
- sandbox/CSP；
- `ui://` resource；
- host context；
- tool visibility；
- permission broker；
- display modes；
- teardown；
- structured/text result；
- 统一审计和错误码。

旧 Host 仍只存在于当前 production 分支；新代码分支不提供 runtime fallback。

退出条件：参考 MCP App 在所有新 Host 中运行。

## 5. 阶段 2：Cloudflare SDK v2 runtime

建立唯一插件 Worker 模板：

```text
createMcpHandler
+ @modelcontextprotocol/server v2
+ legacy: "reject"
+ allowed Host/Origin
+ OAuth/AuthInfo
+ explicit business state
```

退出条件：

- 正常 MCP Apps 调用成功；
- 旧请求被拒绝；
- 跨边缘实例连续调用成功；
- 无 session ID、sticky routing 或 transport store。

## 6. 阶段 3：迁移所有官方插件

对每个官方插件：

1. 转换 Tool schema；
2. 注册 `ui://` resources；
3. 使用 MCP Apps View SDK；
4. 删除自定义 bridge；
5. 配置 CSP；
6. 配置 model/app tool visibility；
7. 返回 text + structured result；
8. 部署 SDK v2 Worker；
9. 生成不可变包和 provenance；
10. 在所有大乘 Host 中验收。

退出条件：官方插件迁移率 100%。

## 7. 阶段 4：插件模板与市场准入

- `plugin init` 只生成 MCP Apps；
- `plugin test` 验证 Apps、SDK v2、CSP、visibility 和 legacy rejection；
- 市场 release schema 增加 runtime/ui 合规字段；
- 市场拒绝旧 manifest、旧 bridge、SDK v1 和 legacy endpoint；
- 未迁移插件标记 `migration_required`；
- 新版本不能绕过准入。

退出条件：无法通过任何正式入口发布旧格式插件。

## 8. 阶段 5：真实第三方示例插件

插件：

```text
io.mahayana.test.hello
```

版本：

- `1.0.0`：基础 MCP App、最小权限；
- `1.1.0`：增加一个受控权限和第二 display mode。

验证：

- 大乘托管发布；
- Cloudflare stateless Worker；
- MCP Apps UI；
- app/model visibility；
- CSP 拒绝；
- 权限 diff；
- 另一个合规 MCP Apps Host；
- 不可变安装和回滚。

## 9. 阶段 6：安装与本地状态迁移

新客户端升级时：

- 扫描已安装插件；
- MCP Apps 版本可继续；
- 旧版本标记 `migration_required`；
- 自动查找已批准的新版本；
- 用户可升级或卸载；
- 不允许以兼容模式启动；
- 保留旧数据备份和插件业务数据迁移工具，但不运行旧代码。

## 10. 阶段 7：删除旧代码

删除：

- SDK v1 生产依赖；
- legacy handler；
- session transport/storage；
- `Mcp-Session-Id`；
- GET/DELETE session endpoints；
- 长期 session SSE；
- 自定义 iframe bridge；
- 旧 manifest parser 的执行路径；
- 旧协议正向测试。

保留：

- 负向测试，证明旧请求被拒绝；
- 静态迁移检测；
- 升级错误文案；
- 历史数据备份读取工具。

## 11. 阶段 8：硬切换前置门槛

全部满足后才允许切换：

- 官方插件迁移 100%；
- Web/Desktop/Mobile/CLI Host 全通过；
- 市场只接受 MCP Apps；
- preview production 配置 `legacy:"reject"`；
- 真实第三方插件双版本 E2E 通过；
- 外部合规 Host 验证通过；
- 旧客户端升级错误通过；
- 数据迁移和回滚演练通过；
- GitHub Actions 与 Cloudflare 证据完整。

## 12. Production cutover

一次性发布：

1. 发布新 Host；
2. 发布全部官方 MCP Apps；
3. 启用 MCP Apps-only 市场准入；
4. 提升新 Cloudflare Worker versions；
5. 旧客户端返回升级错误；
6. 监控错误、CSP、权限和 edge traces。

不得同时重新启用旧 endpoint。

## 13. 回滚策略

出现严重故障时：

- 回滚整个大乘新版本和对应 MCP Apps Worker version；
- 回滚到同样是 MCP Apps-only 的上一候选版本；
- 不回滚到旧 MCP runtime；
- 已迁移业务数据必须有向前修复或备份恢复方案；
- 安全签名、撤销和不可变发布物保持有效。

## 14. 完成定义

- Production 只运行 MCP Apps + SDK v2；
- `legacy:"reject"` 已验证；
- 所有官方插件完成迁移；
- 旧插件不能启动；
- 旧客户端不能调用工具；
- 仓库无旧运行分支；
- 市场无旧发布入口；
- 全平台和真实 Cloudflare 验收完成。
