# Tool Activity Command And Error Order Design

## Goal

Improve inline tool activity readability in two related areas:

- Running a concrete program or script should show a compact command without turning path fragments into links.
- Tool execution errors should appear at their actual point in the assistant timeline instead of being appended after the final answer.

## Scope

This change affects tool activity presentation and tool-result error placement only. It does not change command execution, permissions, process exit handling, file-link behavior in normal prose, or the visual treatment of whole-agent failures.

## Run Command Presentation

Tool activity rows beginning with `运行` never create clickable file links.

When the command directly executes a concrete program or script located inside the current workspace, compact only that executable argument to its basename:

- `运行 python3 /workspace/test.py` becomes `运行 python3 test.py`.
- `运行 zsh /workspace/Scripts/package_app.sh` becomes `运行 zsh package_app.sh`.
- `运行 /workspace/bin/tool --flag` becomes `运行 tool --flag`.

The rest of the command stays unchanged. Arguments after the executable or script are not scanned and rewritten.

Commands used to inspect, locate, search, or list content retain their original complete text:

- `运行 ls -la /workspace/dist`
- `运行 find /workspace -name '*.swift'`
- `运行 grep -n TODO /workspace/Sources`
- `运行 pwd`

File-oriented activities such as `读取`, `编辑`, `创建`, and `编辑笔记本` keep their existing compact clickable file links.

## Classification

Run-command compaction is based on command structure, not a growing list of inspection command names:

1. Parse the shell command sufficiently to identify the command executable and its immediate script/program operand.
2. Compact an in-workspace absolute path only when that path is the directly executed program, or the script operand of a known interpreter/shell invocation.
3. Otherwise return the original summary unchanged.

The implementation should support common interpreter and shell forms already produced by agents, including `python`, `python3`, `ruby`, `node`, `bash`, `sh`, and `zsh`. It should not attempt to fully implement shell parsing or rewrite paths embedded in pipes, redirections, command substitutions, or later arguments.

If the command is ambiguous, preserve the original text.

## Tool Error Ordering

Tool-result failures are tool activity events and belong in the same ordered assistant text stream as normal tool calls.

For example:

```text
运行 bash package_app.sh
工具出错：Exit code 1 ...
后续分析
运行 zsh package_app.sh
最终回答
```

Claude `tool_result` events marked `is_error` should produce an inline tool event rather than a standalone system message. OpenCode tool-state errors already use inline tool events and should keep that behavior.

The ordering fix belongs in parsing/session event handling. The view should render the ordered timeline it receives and must not infer or reorder events after the fact.

## Errors That Remain Separate

These remain standalone error or system messages:

- API/authentication failures.
- Agent process launch failures.
- Nonzero exit of the overall agent process.
- Timeouts and user-requested termination.
- Stream or transport failures unrelated to an individual tool call.

Only errors tied to an individual tool result move into the assistant timeline.

## Testing

Add focused tests covering:

- Script execution compacts the workspace path and returns only text display parts.
- Direct executable paths compact to the basename.
- Inspection/search commands preserve their complete original paths.
- File activities continue to produce clickable file targets.
- Claude `tool_result is_error` parses as an inline tool event.
- A session receiving text, a tool error, and later text preserves that exact assistant block order.
- Existing OpenCode tool errors remain inline.
- Standalone API and overall process errors remain separate messages.

Run the focused tests first, then the full `swift test` suite.

## Non-Goals

- No general-purpose shell parser.
- No links inside `运行` rows.
- No changes to Markdown body linkification.
- No visual redesign of tool activity rows.
- No changes to the command actually executed.
