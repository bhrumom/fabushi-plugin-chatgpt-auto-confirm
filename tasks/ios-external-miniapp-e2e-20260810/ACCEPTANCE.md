# 验收标准

全部项目必须有可复核代码、自动测试和日志/产物证据。

## A. 测试接口与安全

- [ ] CLI 提供版本化测试驱动协议与结构化事件流，具有 schema/contract 测试。
- [ ] iOS Debug/测试签名构建可通过本机安全通道连接；支持健康检查、状态等待、日志查询和诊断导出。
- [ ] Release/Store 构建无法启动测试接口、无法使用测试登录捷径、没有对外监听端口，并有自动负向测试。
- [ ] 所有日志脱敏，命令与事件用 correlation id 串联。

## B. CLI 为唯一核心

- [ ] 市场搜索、安装、更新、注册、会话和 action/tool 调用均由 CLI/核心库执行。
- [ ] Flutter/iOS 不维护重复业务状态机；UI 测试可以对照 CLI 状态快照。
- [ ] App 重启后安装状态由 CLI 安装收据恢复，UI 与 CLI 一致。

## C. 真实外部安装与热更新

- [ ] 新用户 profile 初始插件列表为空。
- [ ] 从真实线上官方市场搜索到“全球法布施”及其正式 plugin id、版本、平台和来源。
- [ ] 安装包中不存在该插件的预置可执行构件；安装发生前不能调用其 action。
- [ ] 下载线上构件并验证签名/digest/provenance/source commit/platform compatibility 后安装。
- [ ] 安装收据记录外部来源、精确版本和 digest；篡改包、错误平台和不可信来源会被拒绝。
- [ ] 发布一个可识别的新测试版本后，宿主无需重新构建即可检测、下载、原子切换并回滚失败更新。

## D. 对话与全部 action

- [ ] 自动进入已安装插件的机器人会话，发送确定性测试消息。
- [ ] 真实插件 runtime 收到请求并返回符合 Tool Contract 的正确响应。
- [ ] 测试以 CLI/runtime 的 request、tool call、result、conversation id、correlation id 和最终响应断言成功，不以 UI toast 作为依据。
- [ ] 从正式 manifest/Tool Contract 动态枚举全部可测试 action；每个 action 至少覆盖成功路径、参数校验、权限拒绝和可恢复错误。
- [ ] “全球法布施”关键 action 有真实线上 smoke 证据，不能用 mock response 替代。

## E. iOS 自动化与 CI

- [ ] 一条命令可构建测试 App、启动 iOS Simulator、安装、运行完整场景并导出诊断。
- [ ] 测试不依赖固定 sleep、屏幕坐标或中文文案；使用语义 key、状态条件和驱动协议。
- [ ] CI 在受支持的 iOS Simulator 上从干净状态执行，失败上传截图、视频（可用时）、Flutter 日志、CLI/runtime JSONL 和安装收据。
- [ ] 至少验证冷启动、进程重启、网络短暂失败、下载中断、安装失败回滚和重复运行幂等性。
- [ ] 真机 smoke 独立于核心 E2E，不阻塞普通代码验证，且不再是发现核心功能错误的唯一方式。

## F. 完成门禁

- [ ] 本地相关单元/契约/集成测试通过。
- [ ] GitHub Actions 的 iOS E2E 和 Release 安全负向检查通过。
- [ ] 证据指向真实线上插件版本、构件 digest、source commit、安装收据和一次成功对话 correlation id。
- [ ] 文档说明后续 Android、桌面和 Web 如何复用协议；不得声称这三个尚未实施的平台已经完成。
