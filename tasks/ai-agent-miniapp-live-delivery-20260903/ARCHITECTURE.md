# 系统架构与技术设计 (ARCHITECTURE)

## 1. 总体设计

```text
[用户输入: 创建打地鼠小程序]
        │
        ▼
[Mahayana Agent Runtime / 后端编排]
        │
        ├─► 发送 Step 1: 规划打地鼠游戏规则 (agent.step)
        ├─► 发送 Step 2: 绘制九宫格与地鼠造型 (agent.step)
        ├─► 发送 Step 3: 编写点击与计分引擎 (agent.step)
        └─► 发送 Step 4: 打包自包含 MiniApp 并交付 (artifact.delivered)
        │
        ▼
[客户端通信与状态层 (Host Coordinator / Transport)]
        │
        ▼
[全平台 UI 会话层 (desktop/src/messaging-shell-v2.tsx & web)]
        ├─► 渲染实时步骤折叠卡片 (StepTrackerCard)
        ├─► 渲染小程序交互式交付卡片 (MiniAppDeliverableCard)
        │        │
        │        └─► 用户点击【立即试玩 / 运行】
        │                 │
        ▼                 ▼
[安全隔离沙箱容器 (MiniAppSandboxRunner)]
        ├─ 基于 HTML5 iframe (sandbox="allow-scripts allow-forms")
        ├─ 加载自包含 entryHtml (零外部网络请求)
        └─ 用户交互试玩 (打地鼠、实时计分、倒计时、结束结算)
```

## 2. 关键数据结构与契约定义

### 2.1 MiniApp 交付产物结构
```typescript
export interface MiniAppDeliverable {
  id: string;              // 唯一 ID，如 "miniapp-whacamole-v1"
  title: string;           // "打地鼠小游戏"
  version: string;         // "1.0.0"
  description: string;     // 玩法描述
  icon?: string;           // 图标或 emoji
  entryHtml: string;       // 完整的可运行网页代码 (含 HTML/CSS/JS)
  createdAtMs: number;
}
```

### 2.2 消息模型扩展
在 `DisplayMessage` 中新增支持：
```typescript
type DisplayMessage = {
  // 现有字段...
  deliverable?: MiniAppDeliverable;
  steps?: Array<{
    id: string;
    title: string;
    detail?: string;
    status: 'running' | 'completed' | 'failed';
  }>;
};
```

### 2.3 容错与向后兼容设计
- **自动检测与代码转交付物**：如果大模型在过渡阶段仍输出了完整的 HTML 代码块（如 ````html <!DOCTYPE html>... ````），客户端具有智能检测机制，自动提取并将其包装为可运行的 `MiniAppDeliverable`，用户无需手动复制代码，即可直接点击运行！
