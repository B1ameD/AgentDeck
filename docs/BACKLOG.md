# AgentDeck Backlog

> 由 2026-06 多份 handoff 文档（KNOWN_BUGS、DIFF_REVIEW_FIX_PLAN、OPENCODE_SUBAGENT_DETAIL、fix_plan）合并而来。
> 原始文档存档于 `docs/archive/`（不入库）。动手前先核对状态，完成后更新本文件。

## 状态说明

- ⬜ 待办 — 未实现
- 🔶 待验证 — 代码已存在/疑似已修，需在 macOS 上手动验证后销账
- ✅ 已完成

---

## P0

| # | 状态 | 项目 | 入口 |
|---|------|------|------|
| 1 | ⬜ | Markdown/右侧栏渲染性能：长输出高 CPU、拖动分隔条与窗口缩放卡顿 | `UI/MarkdownText.swift`（NSTextView 渲染链路） |
| 2 | ⬜ | 长上下文输入导致聊天视口过滚、消息消失（滚动锚定问题） | `UI/ChatPaneView.swift` |
| 3 | ⬜ | Claude Code 同一 AgentDeck 会话内丢失上下文（session id / resume 行为） | `Sessions/AgentSession.swift`、`Agents/CLIInvocationBuilder.swift` |

## P1

| # | 状态 | 项目 | 入口 |
|---|------|------|------|
| 4 | 🔶 | Claude Code 工具/文件输出刷屏 → 折叠展示（CollapsedBlock 已实现，待验证长会话表现） | `UI/MessagePresentation.swift` |
| 5 | ⬜ | 跨行/跨段复制与文件链接不稳定（左键打开右侧栏、右键菜单） | `UI/MarkdownText.swift`、`UI/LinkifiedText.swift` |
| 6 | 🔶 | 审核 tab 显示真实的逐轮 diff（TurnDiffBuilder/TurnDiffModels 已存在，按 DIFF_REVIEW_FIX_PLAN 验收：before→after 基线而非整文件绿色） | `Sessions/TurnDiffBuilder.swift`、`UI/ChangeReviewView.swift` |
| 7 | ⬜ | OpenCode 委派任务行不可点击、无法在右侧栏看子代理详情（根因：`OpenCodeEventTranslator.translateUpdatedPart` 丢失结构化 task 信息；Claude Code 路径可作参照） | `Agents/OpenCodeStreamingClient.swift` |

## P2

| # | 状态 | 项目 | 入口 |
|---|------|------|------|
| 8 | ⬜ | OpenCode thinking 内容不显示（需先确认原始输出格式） | `Parsing/OutputParser.swift` |
| 9 | ⬜ | 窗口缺最小尺寸约束 | `AppShell/AppWindowConfigurator.swift` |

## 功能需求（来自 handoff「Planned / Requested Features」）

| # | 状态 | 项目 |
|---|------|------|
| F1 | 🔶 | 附件 chips：文件名/缩略图/大小/单个删除/图片预览（AttachmentChipsView 已存在，对照需求验收） |
| F2 | ⬜ | 附件按钮拆分动作：附加照片/文件、屏幕截图 |
| F3 | ⬜ | 广播输入框移到底部输入区附近 |
| F4 | ⬜ | 历史搜索默认显示全部会话 + 工作区过滤 |
| F5 | ⬜ | 最近项可单独删除（不删历史） |
| F6 | ⬜ | 工作区级 Agent 窗口/标签分组 |
| F7 | ⬜ | 标签重命名、删除、固定（pin） |
| F8 | ⬜ | 统一的会话右键菜单 |
| F9 | ⬜ | 自动生成会话标题 |

## 已完成（留档）

| 项目 | 出处 |
|------|------|
| ✅ 广播默认放行（删除聚合权限弹窗，单会话仍弹窗） | fix_plan.md，2026-06-04 批次 |
| ✅ 代码块 SwiftUI 卡片：0.8 宽、语言头条、复制按钮、语法高亮 | fix_plan.md，同上 |
| ✅ App 图标（squircle iconset + Info.plist CFBundleIconFile） | CHANGELOG-SESSION 第五批 |

## 验收清单（P0/P1 修完后逐项手测）

- 长 Claude 输出不冻结应用；右侧栏开启时拖分隔条、缩放窗口保持流畅
- 长历史下输入不会让会话滚出视野
- 文件名渲染为蓝色可点链接：左键在右侧栏打开，右键有菜单
- 助手消息内跨行/跨段选择复制正常；表格、代码块、本地链接可读
- Claude Code 在同一会话记得之前轮次
- 审核 tab 显示真实增删行（非整文件绿色）
- OpenCode 委派任务行可点开子代理详情
