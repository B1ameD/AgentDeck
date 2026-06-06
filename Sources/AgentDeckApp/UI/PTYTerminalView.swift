import SwiftUI
import SwiftTerm

/// 真·PTY 终端：用 SwiftTerm 的 LocalProcessTerminalView 在工作目录里起一个登录 shell。
/// 与命令终端不同，这是带伪终端的交互式 shell——cd / 环境跨命令保留，可跑 vim、REPL 等。
struct PTYTerminalView: NSViewRepresentable {
    let workingDirectory: URL

    func makeNSView(context: Context) -> NSView {
        let terminal = LocalProcessTerminalView(frame: .zero)
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"

        // 透传当前环境并确保 TERM 合理，让 PATH（含 claude/codex 等）可用。
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        let envArray = environment.map { "\($0.key)=\($0.value)" }

        terminal.startProcess(
            executable: shell,
            args: ["-l"], // 登录 shell：加载用户 PATH 等配置
            environment: envArray,
            currentDirectory: workingDirectory.path
        )

        // 用容器包一层并把终端内缩，制造文字与边线之间的留白（参考常见终端模拟器的内边距）；
        // 间隙用终端自身背景色填充，视觉上无缝、就像终端自带内边距。整体布局不变。
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = terminal.nativeBackgroundColor.cgColor

        terminal.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            terminal.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            terminal.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            terminal.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8)
        ])
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// 内嵌终端面板：标题栏 + 填满的 PTY 终端。放在聊天框下方。
/// 终端视图会抢走键盘（Esc/⌘W 都被送进 shell），所以给一个可点击的关闭按钮。
struct TerminalPanel: View {
    let workingDirectory: URL
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label("终端", systemImage: "terminal").appFont(relative: -1, weight: .semibold)
                Text(workingDirectory.lastPathComponent).appFont(relative: -2).foregroundStyle(.secondary)
                Spacer()
                Button { onClose() } label: { Image(systemName: "xmark").font(.caption) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("关闭终端")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Divider().opacity(0.4)
            PTYTerminalView(workingDirectory: workingDirectory)
                .id(workingDirectory) // 切到不同工作目录时重建终端（新 shell 在新目录）
        }
        .background(.thinMaterial)
    }
}
