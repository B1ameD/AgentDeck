import SwiftUI

// 主界面空态与背景。从 ContentView.swift 拆出(#24)。

struct EmptyRegistryView: View {
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "terminal")
                .appFont(relative: 14, weight: .semibold)
                .foregroundStyle(Theme.accent)
            Text(message)
                .appFont(relative: -1)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .stroke(Theme.hairline, lineWidth: 1)
        }
    }
}

struct GlassBackground: View {
    var body: some View {
        Theme.backgroundGradient
            .ignoresSafeArea()
    }
}
