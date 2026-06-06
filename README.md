# AgentDeck

<p align="center">
  <img src="icons/icon_256.png" width="128" alt="AgentDeck Icon">
</p>

<p align="center">
  <strong>多 Agent 终端工作台 — 一个窗口，多个 AI Agent，统一管理</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2014+-blue" alt="Platform">
  <img src="https://img.shields.io/badge/Swift-6.0-orange" alt="Swift">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="License">
</p>

---

## 功能特性

| 功能 | 描述 |
|------|------|
| **多标签工作台** | 同时运行多个 CLI Agent（Claude Code、Codex、OpenCode 等），每个 Agent 一个标签页 |
| **广播模式** | 一条 Prompt 同时发送给所有 Agent，批量执行任务 |
| **会话恢复** | 退出后重新打开，自动恢复所有标签页和聊天记录 |
| **文件浏览器** | 内置文件树 + 文本编辑器，支持查看和编辑项目文件 |
| **内置浏览器** | WebKit 浏览器，无需离开应用即可预览网页 |
| **交互终端** | 基于 SwiftTerm 的完整终端，支持 vim、REPL 等交互程序 |
| **Git 集成** | 分支切换、文件暂存、提交，一站式 Git 操作 |
| **权限管理** | 文件修改操作需确认，支持"允许一次"或"记住" |
| **主题系统** | 支持浅色/深色模式，自定义界面字体和大小 |

## 快速开始

### 前置要求

- macOS 14.0+
- Swift 6.0+
- Xcode 16+（用于构建）

### 安装

```bash
git clone https://github.com/B1ameD/AgentDeck.git
cd AgentDeck
swift run AgentDeck
```

### 打包为 App

```bash
./Scripts/package_app.sh
```

生成的 App 位于 `dist/AgentDeck.app`，双击运行或拷贝到 `/Applications/` 目录。

### 运行测试

```bash
swift test
```

## 支持的 Agent

| Agent | 命令 | 模型选择 | 推理强度 | 会话恢复 | 状态 |
|-------|------|---------|---------|---------|------|
| **Claude Code** | `claude` | 支持 | 支持（5 档） | 支持 | 已完成 |
| **Codex** | `codex` | 支持 | 支持 | 支持 | 开发中 |
| **OpenCode** | `opencode` | 支持（动态获取） | 支持 | 支持 | 已完成 |
| **Pi** | `pi` | 不支持 | 不支持 | 不支持 | 实验性 / 开发中 |
| **自定义** | JSON 配置 | 可选 | 可选 | 可选 | 开发中 |

> **备注**：Pi 目前仅保留基础进程检测与标准输入输出透传框架，CLI 参数、输出协议、停止行为及兼容性尚未完整开发和验证。Codex 集成与自定义 Agent 功能也仍在开发中，具体支持范围可能发生变化。

### 自定义 Agent

在 `~/Library/Application Support/AgentDeck/Agents/` 创建 JSON 文件：

```json
{
  "id": "my-agent",
  "name": "My Agent",
  "command": "/usr/local/bin/my-agent",
  "args": ["chat", "--stdio"],
  "env": { "API_KEY": "xxx" },
  "workingDirectoryPolicy": "workspace",
  "inputMode": "stdin",
  "outputMode": "stream",
  "supportsStop": true,
  "stopSignal": "interrupt"
}
```

> 自定义 Agent 功能目前为基础框架，后续将完善配置校验与热加载机制。

## 快捷键与命令

| 命令 | 功能 |
|------|------|
| `/` | 打开命令菜单 |
| `/model` | 切换模型 |
| `/new` | 新建会话 |
| `/resume` | 恢复历史会话 |
| `/continue` | 继续上次会话 |
| `Tab` | 切换 Agent 模式 |
| `⌃T` | 切换推理强度 |

## 项目结构

```
AgentDeck/
├── Sources/AgentDeckApp/
│   ├── Agents/           # Agent 配置与检测
│   ├── AppShell/         # 主窗口、设置窗口
│   ├── Git/              # Git 服务封装
│   ├── Parsing/          # 输出解析器
│   ├── Permissions/      # 权限管理
│   ├── Processes/        # 进程运行器
│   ├── PromptRefinement/ # 提示词优化器
│   ├── Sessions/         # 会话管理
│   ├── Storage/          # 数据持久化
│   └── UI/               # 25+ UI 组件
├── Tests/                # 单元测试
├── Scripts/              # 构建脚本
└── Package.swift
```

## 贡献

欢迎提交 Issue 和 Pull Request！

```bash
# Fork & Clone
git clone https://github.com/your-username/AgentDeck.git

# 创建分支
git checkout -b feature/your-feature

# 提交
git commit -m "feat: add your feature"

# 推送
git push origin feature/your-feature
```

## License

MIT License
