# CLAUDE.md

AgentDeck — macOS 多 Agent 终端工作台。一个窗口同时运行多个 CLI Agent（Claude Code、Codex、OpenCode 等），支持广播、会话恢复、文件浏览、Git 集成。

## 技术栈

- Swift 6 / SwiftUI / AppKit（NSTextView 等），macOS 14+
- Swift Package Manager（无 .xcodeproj）
- 依赖：SwiftTerm（终端模拟）
- 测试：XCTest

## 常用命令

```bash
swift build                # 构建
swift test                 # 跑全部测试
swift test --filter XxxTests   # 跑单个测试类
swift run AgentDeck        # 直接运行
./Scripts/package_app.sh   # 打包为 dist/AgentDeck.app
swiftlint                  # 代码检查（配置在 .swiftlint.yml）
```

## 代码结构（Sources/AgentDeckApp/）

| 目录 | 职责 |
|------|------|
| `Agents/` | Agent 配置、检测、CLI 参数构建（`CLIInvocationBuilder`）、模型目录、OpenCode 流式客户端 |
| `AppShell/` | 主窗口（`ContentView`）、设置窗口、窗口配置 |
| `Sessions/` | 核心会话逻辑：`AgentSession`（单标签状态机）、`WorkspaceController`（多标签/广播/全局状态）、会话恢复、diff 构建 |
| `Parsing/` | Agent CLI 输出解析（`OutputParser`，stream-json 等） |
| `Processes/` | 进程启动（`ProcessRunner`）、PTY、shell 环境、OpenCode 本地 server |
| `Permissions/` | 文件修改权限确认（`PermissionBroker`） |
| `Storage/` | `SessionStore`/`ConversationStore` 持久化 |
| `MCP/` | 内置 MCP server（ask_user 交互式提问） |
| `PromptRefinement/` | 提示词优化（可配置 LLM 服务商） |
| `UI/` | 聊天面板（`ChatPaneView`）、Markdown 渲染（`MarkdownText`）、输入框（`ComposerView`）、右侧栏、diff 视图、主题等 |

关键数据流：用户输入 → `ComposerView` → `AgentSession.send` → `ProcessRunner` 启动 CLI 进程 → `OutputParser` 解析输出 → `SessionModels` 消息模型 → `ChatPaneView` 渲染。多标签与广播由 `WorkspaceController` 协调。

## 约定

- 行为改动先写失败测试（TDD），测试放在 `Tests/AgentDeckTests/`，与源文件一一对应命名（`Foo.swift` → `FooTests.swift`）。
- UI 字符串使用中文（产品面向中文用户）。
- 提交信息用 conventional commits（`feat:`/`fix:`/`chore:`/`docs:`），正文可中文。
- 不要提交 `.DS_Store`、`dist/`、`.build/`；`Package.resolved` 需要提交。
- 大文件（`ChatPaneView`、`AgentSession`、`ContentView`）正在等待拆分，新逻辑尽量放到独立类型/文件，不要继续往里堆。

## 已知欠账

未完成的 bug 修复与功能需求统一在 [GitHub Issues](https://github.com/B1ameD/AgentDeck/issues) 管理（`gh issue list` 查看），动手前先看那里，完成后关闭对应 issue 并在提交信息引用编号（如 `closes #24`）。`docs/BACKLOG.md` 仅保留迁移对照,不再更新。

## 注意事项

- 各 Agent 的会话恢复机制差异大（Claude Code 用 session id resume，OpenCode 走本地 server），改动 `Sessions/` 时注意区分。
- `MarkdownText` 基于 NSTextView 的可选中渲染有已知性能问题（见 issue #2），改渲染相关代码务必手动验证长输出场景。
- 广播模式绕过单会话权限弹窗，权限相关改动要同时验证单发和广播两条路径。
