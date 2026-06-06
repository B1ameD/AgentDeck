import SwiftUI

/// 渲染单个文件的 diff：绿增 / 红删 + 双行号槽（旧 | 新），等宽。仿 codex / GitHub。
struct DiffView: View {
    let diff: FileDiff

    @AppStorage(BundledCodeFont.storageKey) private var selectedCodeFontID = BundledCodeFont.defaultID
    @AppStorage(AppFontSize.storageKey) private var appFontSize = AppFontSize.defaultValue

    private var codeFont: Font {
        BundledCodeFont.resolve(selectedCodeFontID).swiftUIFont(size: max(9, AppFontSize.points(appFontSize) - 1))
    }

    var body: some View {
        if diff.isBinary {
            stateLabel("二进制文件，无法显示逐行 diff")
        } else if diff.isEmpty {
            stateLabel("无文本改动")
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(diff.hunks.enumerated()), id: \.offset) { _, hunk in
                    hunkHeader(hunk.header)
                    ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                        lineRow(line)
                    }
                }
            }
            .font(codeFont)
            .background(Theme.canvas)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                    .stroke(Theme.hairline, lineWidth: 1)
            }
        }
    }

    private func stateLabel(_ text: String) -> some View {
        Text(text)
            .appFont(relative: -2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
    }

    private func hunkHeader(_ header: String) -> some View {
        Text(header)
            .font(codeFont)
            .foregroundStyle(Theme.accentStrong)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Theme.accentSoft)
    }

    private func lineRow(_ line: DiffLine) -> some View {
        HStack(alignment: .top, spacing: 0) {
            gutter(line.oldNumber)
            gutter(line.newNumber)
            Text(sign(line.kind))
                .foregroundStyle(signColor(line.kind))
                .frame(width: 12, alignment: .center)
            Text(line.text.isEmpty ? " " : line.text)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.trailing, 8)
        .padding(.vertical, 1)
        .background(background(line.kind))
    }

    private func gutter(_ number: Int?) -> some View {
        Text(number.map(String.init) ?? "")
            .foregroundStyle(.tertiary)
            .frame(width: 34, alignment: .trailing)
            .padding(.horizontal, 4)
    }

    private func sign(_ kind: DiffLine.Kind) -> String {
        switch kind {
        case .addition: "+"
        case .deletion: "−"
        case .context: " "
        }
    }

    private func signColor(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .addition: Color.green
        case .deletion: Color.red
        case .context: Color.secondary
        }
    }

    private func background(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .addition: Color.green.opacity(0.14)
        case .deletion: Color.red.opacity(0.12)
        case .context: Color.clear
        }
    }
}
