# 技术设计

## 首个纵切面

先贯通 `test driver -> CLI command -> structured event -> Flutter adapter -> iOS harness -> scenario assertion`，再逐步补齐所有 action。每条命令生成 correlation id，安装、会话、tool call 与响应事件沿用同一标识。

## 驱动与状态

- 使用版本化 JSON-RPC/JSONL；命令和 schema 以契约测试固定。
- 用状态条件和事件订阅等待，不使用固定 sleep。
- 测试 profile 可重置且与真实用户数据隔离；进程重启后从 CLI 安装收据恢复。
- action 矩阵从已安装构件的 manifest/Tool Contract 动态生成。

## 外部构件

- 正式市场返回 plugin id、版本、下载位置、签名、digest、provenance 和平台兼容信息。
- 安装器下载到版本化临时目录，完整验证后原子激活；失败保留上一可用版本并产生结构化原因。
- 测试证明 App 包内没有“全球法布施”的预置可执行构件，并证明更新无需重打宿主。

## iOS 与 CI

- Debug/测试签名构建通过 loopback、Unix socket 或受控 VM service extension 暴露本机接口，并使用一次性 nonce。
- Release 构建不编译测试捷径或运行时拒绝启用；CI 同时检查符号、监听行为和测试登录入口。
- CI 从干净 Simulator 启动并保存截图、Flutter/CLI/runtime JSONL、安装收据与失败上下文。

详细分层与安全原则以 `ARCHITECTURE.md` 为准；逐项门禁以 `ACCEPTANCE.md` 为准。
