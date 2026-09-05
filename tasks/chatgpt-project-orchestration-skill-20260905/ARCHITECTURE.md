# 架构组输出：ChatGPT 项目组编排 Skill

- **Task ID:** `chatgpt-project-orchestration-skill-20260905`
- **输出来源:** 2026-09-05，网页版 ChatGPT，聊天模式，GPT-5.6 Sol，推理强度“极高”
- **权威实现仓库:** `bhrumom/fabushi-plugin-chatgpt-auto-confirm`
- **明确排除:** `bhrumom/fabushi` Fabushi 主仓库不承载本 Skill 的实现代码
- **状态:** 架构已冻结；Skill 实现待插件仓库 PR 合并和远程发布验证

## 1. 目标边界

本 Skill 是项目级控制平面协议：它规定如何让 ChatGPT 规划、拆分、执行、审查、
测试、复核视频并发布。它不把浏览器驱动、标签页注册表、录屏、trace、证据摘要、
精确 PR/head 自动审查或发布流水线假装成已经存在的能力；缺失能力进入
`ATOMIC_TASKS.md` 的原子任务 DAG。

## 2. 五个项目组

| 组 | 责任 | 禁止事项 | 固定标签页 |
|---|---|---|---|
| 架构组（ARCH） | 读取事实、开源调查、冻结架构和原子任务 | 写业务代码、合并、发布 | 1 个 |
| 执行组（EXEC） | 每个 Chat 只认领一个原子任务，修改代码、测试、提交 PR | 扩大范围、自审、自发布 | 1 个组标签页；任务 Chat 在其中隔离 |
| 代码审查组（REVIEW） | 按精确 PR/head 审查实现和记录，并复核 E2E 视频 | 修改被审代码、合并 | 1 个 |
| 测试/候选发布组（QA） | 受保护 main 构建可安装包、模拟真实用户、收集全量证据 | 直接修代码、用旧 SHA 冒充 | 1 个 |
| 正式发布组（RELEASE） | 只发布已通过所有门禁的同一构件 | 发布未经视频复核的构件 | 1 个 |

“一项目组一标签页”是硬性传输边界；同一组内可以创建 fresh Chat 作为会话隔离，
但不得为每个会话开新标签页。运行时不支持这种约束时必须阻塞，而不是静默增加标签页。

## 3. 状态与证据流

```text
PROJECT_CONTRACT
  → ARCHITECTURE_PACKET + ATOMIC_TASK_PACKET[]
  → EXECUTION_RECORD + PR/head
  → CODE_REVIEW_RECORD
  → MERGE_RECEIPT + protected-main SHA
  → PACKAGE_MANIFEST
  → E2E_REPORT + screenshots + complete video + trace + logs
  → VIDEO_REVIEW_RECORD
  → RELEASE_MANIFEST + POST_RELEASE_REPORT
```

项目级状态为：

```text
NEW → ARCHITECTING → ARCH_FROZEN → ATOMS_READY → EXECUTING → CODE_REVIEWING
→ ALL_ATOMS_APPROVED → MERGING_TO_PROTECTED_MAIN → MAIN_CANDIDATE_FROZEN
→ PACKAGED_E2E → VIDEO_REVIEW → RELEASE_READY → FORMAL_RELEASE
→ POST_RELEASE_VERIFY → COMPLETE
```

Chat 状态的不变量是：`停止回答` 存在即 `RUNNING`；只有它消失且没有授权/错误卡片，
才允许读取结果、写 handoff 或在同一标签页创建新 Chat。

## 4. 复用和集成

- `actions-first-task-queue`：复用稳定 task ID、revision、spec digest、可恢复状态和
  GitHub 事实源；不创建第二套任务修订协议。
- `in-app-browser-task-queue`：复用 Chat surface、GPT-5.6 Sol/Extra High、授权卡和
  恢复思想；扩展为 role-aware group/tab registry。
- `drive-chatgpt-devspace`：只借鉴发送验证、恢复和授权卡协议，不作为网页版 Chat 的
  transport fallback。
- `recover-actions-chatgpt-renderer`：复用空白 renderer、漂移和诊断证据的恢复思路。
- `sync-action-credentials`：只作为凭据供应边界；状态里可以写 secret reference，
  不得写 cookie、密码、API key、OTP 或 token 值。

`.codex-plugin/plugin.json` 已声明 `skills: "./skills"`，所以 Skill 的发现入口在
独立插件仓库本身，不需要把实现复制到 Fabushi 主仓库。

## 5. 关键门禁

1. `main` 保护规则必须可验证，不能用需求文字假设保护已启用。
2. Review key 绑定 repository、PR、head SHA、base SHA、task ID 和 spec digest；head
   变化立即使旧批准失效。
3. QA 必须从精确 protected-main SHA 打包，在干净环境运行真实用户 E2E。
4. 每条旅程保留步骤截图、连续完整视频、trace、报告和平台日志；成功/失败都上传，
   可行时保留 90 天。
5. 视频审查必须确认版本、main SHA、运行 ID 和所有证据相互对应。
6. 正式发布提升 QA 已验证的同一 artifact digest，或提供可复核的等价性证明；版本
   单一事实源/映射、回滚点和 Release 资产必须入库。
7. 所有 prompt、handoff、提交、日志、trace、截图和视频都不能包含凭据值。

## 6. 开源调查结论

架构组审查了以下固定版本，借鉴协议和边界，不复制源代码：

- `xai-org/grok-build` `main` @ `72a61251fcffb464bcc687aeb5a998e5a98ec0c9`，Apache-2.0；
  借鉴 session/任务计划持久化、工具更新和隔离工作区的思路。
- `openai/codex` `main` @ `459a79eb85400af759e9220c7bafb4429ae07516`，Apache-2.0；
  借鉴边界明确的多 agent 分工、执行与审查隔离。
- `bhrum/grok-bot-0.18-reconstructed` `main` @ `107877b4e2134fd167d239411386f09e42eadd6d`；
  仅作为非官方、低活跃重构项目的行为参考，不作为依赖。

## 7. 当前交付范围

本轮交付的是可发现、可校验的 Skill 协议与任务记录。标签页注册表、录屏/trace、
证据上传、精确 head 自动化和完整 packaged E2E 若尚未由插件 runtime 提供，保持为
计划中的原子任务，不把文档交付报告为这些运行时能力已经完成。
