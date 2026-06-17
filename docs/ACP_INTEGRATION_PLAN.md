# ACP 集成设计文档(设计先行)

> 状态:**设计稿,未动工**。仿 #36「设计先行」约定:落定接口/映射/分期,经评审再写代码。
> 日期:2026-06-17。调研依据:ACP v1 官方 JSON Schema(协议版本 `1`)+ `cola-io/codex-acp`、`openclaw/acpx`、`zed-industries/agent-client-protocol` 三仓 README。

## 1. 背景与目标

现状:每接一个 agent CLI,要在四处分别硬编码并逐一验证——

| 痛点 | 现状入口 |
|---|---|
| 参数翻译 | `CLIInvocationBuilder` 按 `kind` switch,把 model/effort/plan-build/resume 翻成各家真实 flag;自定义 agent 落 `.custom` 走 passthrough |
| 输出解析 | `OutputParser` 处理 3 种输出模式 + claude/opencode/codex 各自的 JSON 事件词汇 |
| 会话连续性 | `AgentSession` + `ClaudeSessionContinuity`:从流里捕获 `backendSessionID`,resume/continue 策略各家不同 |
| 发现+验证 | 装没装、版本、flag 是否被支持,要手动跑一遍才知道 |

**目标:用 ACP(Agent Client Protocol)统一传输/输出/连续性/权限,让"接一个 agent"从"改 Swift + 逐项验证"降为"声明它走 ACP 即可"。** 不支持 ACP 的 agent 保留现有 CLI 路径作回退。

## 2. 关键认知:ACP 不是新范式,是第三个传输层

OpenCode 那条路已经不是纯 CLI:`OpenCodeStreamingClient`(serve + SSE)把事件经 `OpenCodeEventTranslator` 翻成合成 JSON 行,再喂给现有 `OutputParser` → `OutputEvent`。**ACP 完全套用这个已验证的模式**,只是把"HTTP+SSE"换成"JSON-RPC over stdio":

```
ProcessRunner (CLI / stdout 字节流)        ─┐
OpenCodeStreamingClient (serve + SSE)      ─┼─► OutputEvent ─► AgentSession ─► UI
ACPClient (JSON-RPC / stdio)  【新增】      ─┘   (现有内部事件词汇)
```

AgentDeck 在 ACP 里扮演 **client**:把 `claude`(经适配器)、`codex-acp` 等当子进程拉起,走双向 JSON-RPC。

## 3. ACP v1 协议要点(已核实)

**传输:** JSON-RPC 2.0,换行分隔,跑在子进程 stdin/stdout。协议版本经 `initialize` 的 `protocolVersion` 协商;具体可选特性经 capabilities 协商(而非靠版本号推断)。

**方法(client→agent):**
`initialize` · `authenticate` · `session/new` · `session/load` · `session/resume` · `session/prompt` · `session/cancel`(通知) · `session/set_mode` · `session/set_config_option` · `session/list` · `session/close` · `session/delete`

**方法(agent→client):**
`session/request_permission` · `fs/read_text_file` · `fs/write_text_file` · `terminal/{create,output,wait_for_exit,kill,release}`

**通知(agent→client,`session/update`)的 `sessionUpdate` 变体:**
`agent_message_chunk` · `agent_thought_chunk` · `user_message_chunk` · `tool_call` · `tool_call_update` · `plan` · `usage_update` · `current_mode_update` · `config_option_update` · `available_commands_update` · `session_info_update`

**几个对我们最关键的 payload:**
- `session/prompt` 入参 `prompt: ContentBlock[]`(text/image/resource/resource_link,MCP 兼容),返回 `stopReason ∈ {end_turn, max_tokens, max_turn_requests, refusal, cancelled}`。
- `session/new` 入参 `cwd`(绝对路径)、`additionalDirectories`、`mcpServers`;返回 `sessionId` + `modes: SessionModeState{currentModeId, availableModes:[{id,name,description}]}` + `configOptions: SessionConfigOption[]{id,name,description,category}`。
- `session/request_permission` 入参 `{sessionId, toolCall, options: PermissionOption[]}`;`PermissionOption{optionId, name, kind}`,`kind ∈ {allow_once, allow_always, reject_once, reject_always}`;返回 `outcome`(选中的 optionId 或 cancelled)。
- `usage_update`:`{used, size}`(上下文 token)+ 可选 `cost: {amount, currency(ISO 4217)}`。
- `ClientCapabilities.fs: {readTextFile, writeTextFile}`、`terminal: bool`;`AgentCapabilities.loadSession`、`promptCapabilities{image,audio,embeddedContext}`、`SessionResumeCapabilities`。

**模型/推理强度怎么处理(重要):** v1 **没有** `session/set_model`。模型与 effort 一律作为**会话配置项**:agent 在 `session/new` 自报 `configOptions`(带人类可读 name/description),client 用 `session/set_config_option` 修改。**→ 我们不再硬编码任何 flag,agent 自己告诉我们有哪些选项。** plan/build 走**会话模式**:agent 自报 `availableModes`,`session/set_mode` 切换。

## 4. ACP ↔ 现有类型映射

| ACP | 映射到现有 | 备注 |
|---|---|---|
| `session/update` 各变体 | `OutputEvent.Kind`(message/status/tool/error/question/subagent)| 新增 `ACPEventTranslator`,与 `OpenCodeEventTranslator` 同构 |
| `agent_message_chunk` / `agent_thought_chunk` | `.message`(思考块用现有 `<think>` 包裹)| |
| `tool_call` / `tool_call_update` | `.tool`(紧凑摘要);Task/子代理类 → `.subagent` | |
| `session/request_permission` + `options[]` | `pendingPermission` / `PermissionBroker` / 授权卡片 | **几乎 1:1**;现在靠 flag 假 bypass,ACP 变成真请求。`allow_always`/`reject_always` ↔ "允许并记住" |
| `usage_update`(used/size/cost)| `SessionUsage`(#28)| 全 agent 统一真实计量,替代 `ContextEstimate` 估算与 claude-only 的 `UsageCapture` |
| `availableModes` + `set_mode` | plan/build 模式芯片(`InteractionMode`、`supportsPlanMode`)| read-only≈plan,full-access/auto≈build;不再 per-kind 硬编码 |
| `configOptions` + `set_config_option` | 模型/effort 芯片 | agent 自报选项 → UI 动态渲染,**消除 `CLIInvocationBuilder` 的 flag 翻译** |
| `session/new`→`sessionId`、`session/load`/`resume`| `backendSessionID` + 续接策略 | 替代从流里"猜" id 的 hack 与 `ClaudeSessionContinuity` |
| `session/{list,close,delete}` | Recents / 关闭 / 删除(#23)| 可逐步收敛到协议方法 |
| `fs/{read,write}_text_file`(client 实现)| 编辑流经本 client | **#7 逐轮 diff** 的协议级挂载点;run/build 只读由 read-only 模式 + 不实现 write 双重保证 |
| `ContentBlock`(image/resource)| 附件 chips(#11/#12)| 按 `promptCapabilities` 决定降级为文本 @路径 还是结构化块 |
| `stopReason: refusal/cancelled` | 状态机 idle/failed/停止 | |

## 5. 架构设计

### 5.1 传输抽象
新增 `ACPClient`(actor 或 `@unchecked Sendable` final class),不复用面向字节流的 `AgentRunning`(它是 stdout/stderr/exit 模型,与 JSON-RPC 双向请求不匹配)。参照 `OpenCodeStreaming` 另立协议:

```swift
public protocol ACPTransport: Sendable {
    func start(command: String, args: [String], env: [String:String]) async throws
    func initialize(clientCapabilities: ACPClientCapabilities) async throws -> ACPAgentCapabilities
    func newSession(cwd: URL, mcpServers: [ACPMcpServer]) async throws -> ACPSession      // sessionId+modes+configOptions
    func loadSession(id: String, cwd: URL) async throws -> ACPSession                      // 若 agent 支持 loadSession
    func prompt(sessionId: String, content: [ACPContentBlock]) -> AsyncThrowingStream<ACPSessionUpdate, Error>  // 流式;终值 stopReason
    func setMode(sessionId: String, modeId: String) async throws
    func setConfigOption(sessionId: String, id: String, value: ...) async throws
    func cancel(sessionId: String) async
    // client 侧回调(agent→client):权限、fs;由 AgentSession 注入决策闭包
}
```

`session/update` 通知 → `ACPEventTranslator` → `OutputEvent`,接进 `AgentSession` 现有消费链。`session/request_permission` → 复用 `AgentSession.pendingPermission` 等待用户在卡片作答 → 回 `outcome`。

### 5.2 AgentConfig 标记走 ACP
给 `AgentConfig` 加传输种类(声明式,落 JSON,复用现成热加载):

```swift
public enum Transport: String, Codable { case cli, acp }   // 缺省 .cli,旧配置零改动
public var transport: Transport = .cli
// acp 时:command/args 指向适配器可执行(如 codex-acp,或 `npx acpx ...` 兜底)
```

`AgentSession` 按 `transport` 选 `ProcessRunner`/`OpenCodeStreamingClient`/`ACPClient`。**内置 agent 默认仍 `.cli`,行为完全不变**;ACP 先以可选开关灰度。

### 5.3 能力协商取代 kind-switch
`initialize` 拿到 `AgentCapabilities` 后:`loadSession` 决定能否续接;`availableModes` 决定模式芯片;`configOptions` 决定模型/effort 芯片;`promptCapabilities` 决定附件降级。**UI 由协商结果驱动,而非 `kind` 硬编码**——这正是"接新 agent 不改 Swift"的机制。

## 6. 集成方式取舍:原生 Swift client vs 经 acpx 桥接

| | 原生 Swift `ACPClient`(推荐)| 经 `acpx`(Node)桥接 |
|---|---|---|
| 依赖 | 无;手搓 JSON-RPC over stdio(协议简单)| 需 Node + npx 拉适配器;acpx 处 alpha |
| 控制力 | 完整(权限/fs/取消/流式都在掌心)| 受 acpx CLI 接口约束,且其接口"likely to change" |
| 工作量 | 中(一次性,可据官方 schema 生成类型)| 低(快出原型)|
| 风险 | 自己维护协议跟进 | 多一层进程 + alpha 依赖 + 接口漂移 |

**推荐原生**:无 Swift SDK 但协议够简单,且权限/fs 回调必须由 client 实现才能接住 #7/授权卡片——经 acpx 会被它的 CLI 表达力卡住。acpx 留作**调研参照**与**临时验证**(`acpx compare` 还能跑多 agent 对比,正好印证 #27)。

## 7. 分期落地

- **阶段 0(spike) ✅ 完成:** 手搓 `ACPClient`,跑通 `initialize → session/new → session/prompt`。对 `npx -y @agentclientprotocol/claude-agent-acp` 实测打通(protocolVersion=1、authMethods=[]、plan/bypassPermissions 模式自报、usage_update 带 token+USD)。
- **阶段 1 ✅ 完成:** `AgentConfig.transport`(cli|acp,可选缺省回落 cli);`AgentSession.performSendACP/consumeACP` 独立路径——经 `ACPEventTranslator` 把 `session/update` 翻成 `OutputEvent`,复用现有 `apply`/气泡装配/计时;`ACPTransporting` 协议便于注入测试;跨轮复用同一适配器进程与 sessionId(多轮上下文);`stop()` 发 `session/cancel` 干净收尾;plan/build→`set_mode`(仅当 agent 自报该模式);PATH 经 `ShellEnvironment` 增强避免 GUI launchd 最小 PATH 找不到 npx。验证:`ACPSessionTests`(假传输 4 例:流式累加/跨轮复用/plan 映射/错误冒泡)+ `testLiveACPThroughAgentSession`(真适配器端到端,ACPDECK_LIVE=1,回 ACP_OK)。提供 `~/Library/Application Support/AgentDeck/Agents/claude-acp.json` 即开即用。**未做(留后续阶段):权限卡片、模型/effort 配置项 UI、附件结构化块、UI 上的模式芯片联动。**
- **阶段 2 ✅ 完成（协议/数据层）:**
  - **权限卡片**:`session/request_permission` → `ACPClient` onPermission 回调 → `AgentSession.requestACPPermission`(挂起 + `pendingACPPermission` 状态)→ ChatPaneView confirmationDialog 按 agent 自报选项逐个出按钮(allow→普通、reject→destructive)→ `resolveACPPermission(optionId:)` 回传;停止/超时/取消放掉挂起避免 agent 永久等待。build 模式映射改 `acceptEdits`(编辑放行、危险操作经卡片征询),契合 AgentDeck 权限把关定位。
  - **配置项 + 模式**:`session/new` 捕获 `configOptions`(暴露 `acpConfigOptions`)与 `currentModeId`(`acpCurrentModeID`);`current_mode_update` 实时刷新 `acpCurrentModeID`;`setACPConfigOption(configId:value:)` → `session/set_config_option`(参数对齐 schema)。
  - 验证:`ACPSessionTests` 共 11 例(权限往返/取消/build→acceptEdits/捕获 configOptions+mode/current_mode_update 刷新/set_config_option 转发 等)。
  - **实测结论 → 故意不做的部分**:Claude 适配器**不自报 configOptions**(模型走 `ANTHROPIC_MODEL` 环境变量)、modes 也基本用户驱动 → 「模型/effort 配置项 picker UI」「模式芯片可视联动」对捆绑的 claude agent **零 payoff**,仅 codex-acp（自定义 provider）受益。数据/协议层已就绪（codex-acp 即插即用），UI picker 留到接 codex-acp 时再做。
- **阶段 3 ✅ 完成:**
  - **续接（resume）**:`ACPClient.resumeSession(sessionId:cwd:)` + 能力位 `ACPAgentCapabilities.supportsResume`(读 `agentCapabilities.sessionCapabilities.resume`)。`AgentSession.backendSessionID` 对 ACP 返回当前/恢复的 sessionId（复用现有持久化通道落盘）；恢复时若 agent 支持 resume 则 `ensureACPSession` 走 `session/resume` 续接（不重放历史，本地转录已存），否则新建。用 resume 而非 load 正是为避免历史重复。
  - **fs 回调（修隐患 + #7 hook）**:`makeACPHandlers` 的 `onReadTextFile`/`onWriteTextFile` 由 stub 改真实磁盘读写（相对路径按 cwd 解析）——我们 initialize 时 advertise 了 fs 能力，agent 会把文件操作回调过来，之前返回空/失败是隐患。#7 逐轮 diff 本就经 `appendChangedFileLinks`（文件系统快照）对 ACP 生效，与写入机制无关。
  - **附件 → ContentBlock**:`acpContentBlocks` 把附件转 `resource_link`（ACP baseline，所有 agent 必支持），替代 @路径文本；图片内联 base64 块留作增强。
  - 验证:`ACPSessionTests` +6（resume 续接 / 不支持时回退新建 / backendSessionID 持久化 / 附件 3 块 / fs 读写磁盘 / 两会话独立）。
- **阶段 4 ✅ 完成:**
  - **多 agent 独立**:每个 AgentSession 持有自己的 ACPClient（独立适配器进程 + sessionId），天然隔离；测试 `testTwoACPSessionsAreIndependent` 证两会话各自流式互不干扰。
  - **失败回退**:transport 由 `AgentConfig.transport` **显式声明**（不做隐式 ACP↔CLI 自动回退——同一 agent 同时配两套传输属过度设计）；ACP 适配器 start/initialize/resume 失败经 consumeACP 的 catch 冒泡为红色错误消息 + failed 状态（不静默吞）。
  - **文档**:见下「§11 如何声明一个 ACP agent」。

每阶段:行为改动先写失败测试(沿用仓库约定)。`ACPEventTranslator` 与 JSON-RPC 编解码是纯逻辑,易测。

## 8. 风险与开放问题

1. **适配器破坏性变更**:codex-acp 明示"breaking changes likely"。对策:钉版本 + 能力协商容错(`x-deserialize-default-on-error` 思路,未知字段忽略)。
2. **Claude 是否原生说 ACP**:待核实是官方原生还是经适配器(acpx 列了 `acpx claude` 会自动拉适配器)。影响"拉起什么可执行"。
3. **无 Swift SDK**:需自维护 JSON-RPC 层;可由 schema.json 生成 Codable 类型降低手写量。
4. **认证**:`claude login`/OpenAI key 如何经 `authenticate` 协商,需各适配器实测。
5. **模型/effort 取值发现**:虽机制标准,但具体 model id 仍 agent 自报;UI 需能渲染任意自报选项(已在设计内)。

## 9. 验收标准

- 一个标记 `transport: acp` 的 agent,无需改 Swift/无需在 `CLIInvocationBuilder` 加分支,即可:聊天、流式思考/工具、plan/build 切换、模型/effort 切换、权限弹卡片、token/费用统计、关闭后续接。
- 内置 CLI agent 行为零回归;ACP 路径可整体开关。
- 协议层有单测覆盖(编解码 + 事件翻译 + 权限往返)。

## 10. 参考

- ACP 官方:https://agentclientprotocol.com · schema v1:`zed-industries/agent-client-protocol` `schema/v1/schema.json`
- codex-acp(Codex 适配器,Rust):https://github.com/cola-io/codex-acp
- acpx(headless ACP 客户端/多路复用,Node):https://github.com/openclaw/acpx

## 10.5 ACP-first 内置预设（2026-06-17，ACP 替代默认接入）

`AgentRegistry.builtInPresets` 已从「逐家 CLI」改为「ACP-first」：检测到基础 agent 安装即生成其 ACP 预设，
全部 `transport: acp`：
- `codex` → `npx -y @agentclientprotocol/codex-acp`（沿用 id `codex`，kind/品牌图标延续）
- `opencode` → `npx -y opencode-ai acp`（沿用 id `opencode`）
- `gemini` → `gemini --acp`（id `gemini-acp`）
- `cursor-agent` → `cursor-agent acp`（id `cursor-acp`）

codex/opencode/gemini/cursor 的 ACP 适配器用各自**原生登录**，开箱即用。**claude 不做内置**——claude-agent-acp
借不到宿主 OAuth、需显式 base_url/token，由用户 `claude-acp.json` 提供（见 §11）。`runtimeEnvironment` 对
`transport==.acp` 一律只返回 `env`、不注入 CLI 专属环境（claude settings / OPENCODE_CONFIG_CONTENT），
避免与 ACP 协议冲突。CLI 引擎代码（CLIInvocationBuilder / OutputParser / OpenCodeStreamingClient）保留，
作为 `transport: cli` 自定义 agent 的支撑与回退，不再是默认接入。

## 11. 如何声明一个 ACP agent

在自定义 agent 目录 `~/Library/Application Support/AgentDeck/Agents/` 放一个 JSON，把 `transport` 设为 `"acp"`，`command`/`args` 指向 ACP 适配器可执行。重载（设置页「重新加载」或重启）后即出现在「+」菜单。

**Claude（已随仓库提供 `claude-acp.json`）:**
```json
{
  "id": "claude-acp", "name": "Claude (ACP)",
  "command": "npx", "args": ["-y", "@agentclientprotocol/claude-agent-acp"],
  "env": {}, "workingDirectoryPolicy": "workspace",
  "inputMode": "oneShotArgument", "outputMode": "stream",
  "supportsStop": true, "stopSignal": "interrupt",
  "transport": "acp"
}
```

**Codex（Rust 适配器，需自行装 `codex-acp` 或用 npx 包）:**
```json
{
  "id": "codex-acp", "name": "Codex (ACP)",
  "command": "npx", "args": ["-y", "@agentclientprotocol/codex-acp"],
  "env": {}, "workingDirectoryPolicy": "workspace",
  "inputMode": "oneShotArgument", "outputMode": "stream",
  "supportsStop": true, "stopSignal": "interrupt",
  "transport": "acp"
}
```

要点：
- ACP 路径不使用 `inputMode`/`outputMode`（它们只对 CLI 传输有意义），但 schema 必填，填占位即可。
- `env` 为空时适配器子进程继承 App 进程环境；需要覆盖模型/密钥/base_url 时在此填。
- PATH 已自动按登录 shell 增强（`ShellEnvironment`），GUI 启动也能找到 `npx`/`node`。

### 鉴权坑（claude-agent-acp，实测踩过）

1. **借不到 Claude Code 宿主 OAuth**：claude-agent-acp 在 Claude Code 宿主里跑能直接用宿主的 OAuth（initialize 的 `authMethods: []`）；但 AgentDeck 经 `open` 从 launchd 启动，拿不到那套 OAuth 环境变量 → 运行时 **403 Request not allowed**。所以**必须给适配器自己的凭证**（API key 或中转 token），不能指望它白嫖宿主登录。
2. **第三方中转**：填中转的 `ANTHROPIC_BASE_URL` + `ANTHROPIC_AUTH_TOKEN`（如小米 mimo：`https://token-plan-cn.xiaomimimo.com/anthropic`）。base_url 与 token 必须配对——base_url 设成官方而 token 是中转的会 403。
3. **模型来源 = `~/.claude/settings.json` 的 `model`，不是 `ANTHROPIC_MODEL`**：claude-agent-acp 读全局 settings.json 的 `model` 字段且**优先于 `ANTHROPIC_MODEL` 环境变量**。若该字段是给宿主用的官方模型（如 `claude-opus-4-8`），发到中转会 **400 Param Incorrect**（中转没这模型）。解法：给 ACP agent 设独立 **`CLAUDE_CONFIG_DIR`**，里面放一份只含中转模型的 `settings.json`（如 `{"model":"mimo-v2.5-pro"}`），与宿主配置隔离。
4. **自检脚本**：`python3 Scripts/acp_check.py` 读 `claude-acp.json` 的 env，在极简环境（模拟 GUI launchd）里实测 initialize→prompt，输出 `✓ 打通` / `✗ 失败`（不打印 token），改完配置先跑它再重启 app。

完整可用配置示例（中转）：
```json
"env": {
  "ANTHROPIC_BASE_URL": "https://token-plan-cn.xiaomimimo.com/anthropic",
  "ANTHROPIC_AUTH_TOKEN": "<你的 tp- token>",
  "ANTHROPIC_MODEL": "mimo-v2.5-pro",
  "CLAUDE_CONFIG_DIR": "/Users/<你>/Library/Application Support/AgentDeck/acp-claude-config"
}
```
（`acp-claude-config/settings.json` 内容：`{"model": "mimo-v2.5-pro"}`）
