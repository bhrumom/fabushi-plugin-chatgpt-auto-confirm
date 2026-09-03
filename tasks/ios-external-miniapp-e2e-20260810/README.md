# iOS 外部小程序自动化任务文档

本目录是 `ios-external-miniapp-e2e-20260810` 的唯一任务规范入口。执行 Chat 每轮开始时必须读取本目录全部文件，并以 `ACCEPTANCE.md` 的逐项验收为完成门禁。

- `PRD.md`：用户目标、范围和完成结果。
- `TASK.md`：实施范围、核心约束和工作方式。
- `ARCHITECTURE.md`：分层、协议、安全和跨平台复用原则。
- `TECHNICAL_DESIGN.md`：首个可执行纵切面与证据链设计。
- `UI_UX.md`：iOS/Flutter 薄 UI 与自动化语义要求。
- `ACCEPTANCE.md`：唯一完整验收清单。

本任务只实现全平台计划的第一项 iOS。Android、桌面与 Web 只能复用这里建立的 CLI 协议和场景，不得在本任务中声称已完成。
