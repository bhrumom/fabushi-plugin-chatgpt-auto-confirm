# iOS 外部小程序全链路自动化任务

## 目标

这是全平台自动化计划的第 1 项。先完成 iOS，后续平台复用同一个 CLI 测试协议和验收语义，不在各 UI 重写业务逻辑。

为 Fabushi 建立可在构建前和安装包构建后快速驱动的自动化测试能力，完成真实路径：

1. 启动一个没有安装任何小程序的新用户环境。
2. 通过应用搜索框对应的 CLI 能力搜索线上官方市场。
3. 搜索到已发布的“全球法布施”小程序。
4. 下载、校验并安装外部构件；该插件不得编译进 App 或以测试 fixture 伪装安装。
5. 验证线上新版本能够热更新，无需重新打包或重新安装宿主 App。
6. 打开该插件对应的机器人会话并发送确定性测试消息。
7. 根据 CLI/runtime 结构化事件和插件真实返回验证成功，不根据按钮、toast 或本地伪造文案判断。

## 核心约束

- Mahayana CLI 是认证、市场搜索、下载验证、安装、更新、插件注册、会话、action/tool 调用、日志与结果判定的唯一业务事实源。
- Flutter/iOS 只负责展示 CLI 状态、转发用户意图和暴露受控测试驱动入口，不复制市场或插件业务逻辑。
- 优先使用 iOS Simulator 运行可重复的核心 E2E；真机只承担签名、Keychain、系统权限和平台差异的少量烟雾检查。
- 必须使用真实线上市场和真实发布构件。允许使用专用测试账号和确定性测试 action，但不能用 mock server 替代最终验收。
- 从 CLI 到 UI、安装器、插件 host 和日志必须共享 correlation id；每个断言可追溯到真实命令、构件、版本、进程与结果。
- 测试驱动接口只能在 Debug 或专用测试签名构建中编译启用，使用 loopback/Unix socket/Dart VM service extension 等本机通道和单次随机凭证；Release 必须默认不包含或不可启用该接口。

## 实施范围

- `third_party/mahayana/mahayana-rs`: CLI、产品核心、市场、安装、runtime、conversation、结构化事件与测试驱动协议。
- `fabushi/lib`: 薄 UI 适配和稳定语义标识，不新增第二套业务状态机。
- `fabushi/ios`: iOS 测试构建开关、Runner 适配和 Release 安全关闭证明。
- `fabushi/integration_test`、`fabushi/patrol_test`: Flutter/Patrol 场景驱动。
- `.github/workflows`: iOS Simulator 构建与 E2E、产物日志和失败诊断。

## 工作方式

先审计现有 CLI 和 UI 路径，直接实现首个缺失的可执行纵切面。每轮必须提交可验证代码和对应测试，不得只写设计、只截图、只读取结果或只增加 mock。外部部署/发布需要等待时，先完成仍可本地推进的工作，再按统一任务报告给出等待时间。
