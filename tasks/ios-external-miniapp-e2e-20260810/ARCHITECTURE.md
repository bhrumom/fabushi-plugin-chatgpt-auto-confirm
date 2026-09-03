# 自动化架构约束

## 分层

1. `Mahayana Core/CLI`：持有全部业务状态机和命令语义。
2. `Test Driver Protocol`：对 CLI 命令、状态快照、事件流和日志提供版本化 JSON-RPC/JSONL 协议。
3. `Flutter Adapter`：把 UI intent 映射到 CLI 命令，为元素提供稳定语义 key，并把 CLI 状态渲染到界面。
4. `iOS Harness`：启动/重置测试环境、注入一次性测试凭证、连接本机测试通道、采集系统与 runtime 证据。
5. `Scenario Runner`：使用 Flutter `integration_test`/Patrol 驱动用户路径，同时直接读取 Test Driver 事件做真实断言。

## Test Driver Protocol

- 版本化 schema，至少支持 `health`、`resetProfile`、`loginTestAccount`、`marketplace.search`、`plugin.install`、`plugin.update`、`plugin.list`、`miniapp.open`、`miniapp.chat`、`actions.describe`、`actions.invoke`、`events.subscribe`、`logs.query` 和 `shutdown`。
- 命令返回 request/correlation id；事件包含时间、账号、插件 ID、版本、source commit、package digest、阶段、结果和可脱敏错误。
- 支持等待确定状态而不是固定 sleep；超时必须输出最近事件、CLI stderr、安装收据和 Flutter/iOS 日志。
- action 测试矩阵从已安装插件的 Tool Contract/manifest 动态发现，不在测试代码硬编码一份容易漂移的 action 列表。
- 日志不得包含令牌、密码、邮件内容或原始敏感 header；测试凭证通过 stdin、Keychain 或 CI secret 注入。

## 安全

- Release/Store 构建中测试 server、测试登录捷径和重置命令不可达；CI 要对二进制符号、端口监听和运行行为做负向验证。
- 测试通道只绑定本机，要求随机 nonce/短期会话，不接受远程网络连接。
- 外部插件必须通过正式签名、digest、provenance、platform compatibility 和 capability policy 校验后才可运行。
- 热更新使用版本化安装目录、原子切换与可回滚收据；不得覆盖正在运行的构件或绕过签名。

## 可移植性

协议和场景定义不得依赖 XCTest 私有 API。iOS Harness 是第一适配器；Android、macOS/Windows、Web 后续只实现各自启动和 UI 驱动层，复用相同 CLI 命令、事件 schema、场景和证据格式。
