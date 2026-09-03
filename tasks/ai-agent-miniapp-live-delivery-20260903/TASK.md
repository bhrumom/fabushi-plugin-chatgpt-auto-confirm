# 工作任务与执行约束 (TASK)

## 1. 目标与执行范围

1. **协议层扩展**：
   - 在 `frontend/apps/web/src/lib/mahayana-host/contracts.ts` 中明确 `MiniAppDeliverable` 和交付事件契约；
2. **桌面端与前端界面改造**：
   - 改造 `desktop/src/messaging-shell-v2.tsx`：
     - 在消息流中拦截并识别带有交付物的小程序或代码块，转换为 `MiniAppDeliverable` 结构；
     - 渲染 `MiniAppDeliverableCard` 交付物卡片，替换单纯的 `<p>{message.text}</p>` 纯代码渲染；
     - 实现 `MiniAppSandboxRunner` 弹窗/面板，支持在安全 `iframe` 沙箱中即时运行小程序并试玩；
     - 渲染逐步执行步骤卡片（`StepTracker`），支持动态 `running`/`completed` 状态；
3. **Web 端及跨平台一致性**：
   - 在 Web 端会话视图和公共组件库中同步支持该卡片与沙箱运行逻辑；
4. **验证与 E2E 证据**：
   - 编写包含打地鼠小程序生成、卡片展示、沙箱交互（模拟点击打地鼠与得分递增）的自动化测试或 E2E 脚本；
   - 通过 GitHub Actions CI 进行验证。

## 2. 严禁与强制约束 (Critical Constraints)

- **绝对禁止本地构建与测试**：
  - 本地开发机存储极度受限（无可用磁盘空间），**严禁运行 `npm run build`、`cargo build`、`cargo test`、`gradlew`、`xcodebuild`** 或下载大型依赖包。
  - 只能在本地进行文件阅读、精确编辑和轻量语法静态检查。
- **所有重型验证必须提交到 GitHub Actions**：
  - 利用 GitHub Actions Runner 进行全套代码编译、包构建和 E2E 验证。
- **每轮产出要求**：
  - 每轮必须产生可验证的代码增量与测试；
  - 任务负责人（Antigravity）将逐轮对代码与效果进行审核验收。
