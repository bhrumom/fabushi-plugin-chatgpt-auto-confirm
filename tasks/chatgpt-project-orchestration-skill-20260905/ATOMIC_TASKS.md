# 架构组原子任务 DAG

这些是架构组为完整项目编排能力冻结的原子任务。当前 PR 的实现范围是 Skill 协议、
架构记录、任务记录和契约校验；未实现的 runtime/release 能力保持 `planned`，不得被
Skill 文档的存在掩盖。

| ID | 原子任务 | 依赖 | 主要输出 | 验收标准 | 状态/记录 |
|---|---|---|---|---|---|
| A00 | 冻结 orchestration contract | 无 | versioned protocol、schema ownership | 角色、状态和门禁各有唯一 owner | complete · [A00](atomic-tasks/A00-freeze-contract.md) |
| A01 | 项目/组/任务状态 schema | A00 | 可恢复状态 schema | 支持 revision、digest、lease、superseded | planned · [A01](atomic-tasks/A01-state-schema.md) |
| A02 | Evidence manifest schema | A00 | 证据 manifest | video/screenshot/trace/log/report 都有 digest、producer、source SHA | planned · [A02](atomic-tasks/A02-evidence-schema.md) |
| A03 | Role/tab registry | A01 | group-instance 与 tab lease | 一个活跃组只有一个 tab；不误关 RUNNING tab | planned · [A03](atomic-tasks/A03-role-tab-registry.md) |
| A04 | Chat Web mode/model guard | A00 | Chat/Work 与模型校验 | 条件不符时禁止 send | planned · [A04](atomic-tasks/A04-chat-guard.md) |
| A05 | Stop-button detector | A04 | RUNNING/IDLE detector | Stop 存在时禁止读结果、send、new Chat、关 tab | planned · [A05](atomic-tasks/A05-stop-button-detector.md) |
| A06 | Atomic DAG/conflict graph | A00/A01 | read/write set 与调度器 | 重叠 write-set 不并行，无依赖任务可并行 | planned · [A06](atomic-tasks/A06-atomic-dag.md) |
| A07 | Execution lease/idempotency | A01/A06 | claim、retry、dedupe | 同一 task+digest 不被重复执行 | planned · [A07](atomic-tasks/A07-execution-lease.md) |
| A08 | Same-tab context handoff | A01/A03/A05 | handoff packet | 仅回答结束后在同一组 tab 创建 fresh Chat | planned · [A08](atomic-tasks/A08-context-handoff.md) |
| A09 | Exact PR/head reviewer | A01 | review key、stale approval invalidator | PR/head/base/task/spec 任一变化立即取消旧批准 | planned · [A09](atomic-tasks/A09-exact-review.md) |
| A10 | Protected-main merge gate | A09 | merge receipt | 禁止 direct push，只接受 required checks 的精确 head | planned · [A10](atomic-tasks/A10-protected-main.md) |
| A11 | Packaged E2E harness | A02/A10 | clean-install E2E | 测试对象来自 exact main，不以 PR branch 冒充 | planned · [A11](atomic-tasks/A11-packaged-e2e.md) |
| A12 | Screenshot/video/trace evidence | A02/A11 | 完整 evidence bundle | 每个有意义步骤有截图，视频连续，trace/log/report 对应 | planned · [A12](atomic-tasks/A12-evidence-capture.md) |
| A13 | Video cross-review | A09/A12 | VIDEO-REVIEW-PASS record | REVIEW 逐项核对媒体、运行 ID、SHA 和报告 | planned · [A13](atomic-tasks/A13-video-review.md) |
| A14 | Tested-artifact promotion | A10/A11/A13 | release manifest | 正式构件 digest 等于 QA 构件，或有等价性证明 | planned · [A14](atomic-tasks/A14-artifact-promotion.md) |
| A15 | Security/redaction/recovery tests | A03-A14 | negative/recovery suite | 凭据、重复 tab、断线、stale review、上下文迁移全覆盖 | planned · [A15](atomic-tasks/A15-security-recovery.md) |

## 推荐波次

```text
Wave 0: A00
Wave 1: A01 A02 A04
Wave 2: A03 A05 A06
Wave 3: A07 A08 A09 A10
Wave 4: A11 → A12
Wave 5: A13
Wave 6: A14
Wave 7: A15
```

每个执行 Chat 只能认领一个 ID，并必须读取本文件、对应任务记录和 canonical source。
执行完成后写回执行记录、提交 SHA、PR/head、检查结果和下一步；审查、测试、视频和
正式发布分别由对应项目组完成，不能由执行 Chat 自行代办。
