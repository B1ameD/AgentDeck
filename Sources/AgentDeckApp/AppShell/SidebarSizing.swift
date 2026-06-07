import Foundation

/// 右侧栏宽度算法（对齐 Codex 右栏机制）。
/// Flex 模型：中间栏 `flex-1 min-w-0` 可压缩，右栏固定宽由状态控制；右栏最小 320，
/// 正常至少给中间栏保留 352，默认宽 600。宽度以**归一化比例**持久化，窗口变化按比例还原。
public enum SidebarSizing {
    public static let minWidth: CGFloat = 320
    /// 正常情况下至少给中间（聊天）栏保留的宽度。
    public static let minChatWidth: CGFloat = 352
    public static let defaultWidth: CGFloat = 600

    /// 右栏最大宽度：给中间栏留够 `minChatWidth`，且右栏不小于 `minWidth`（窗口很窄时以 minWidth 兜底）。
    public static func maxSidebarWidth(for containerWidth: CGFloat) -> CGFloat {
        max(minWidth, containerWidth - minChatWidth)
    }

    /// 把目标宽度夹到 [minWidth, maxSidebarWidth(container)]。
    public static func clampWidth(_ width: CGFloat, container: CGFloat) -> CGFloat {
        min(max(width, minWidth), maxSidebarWidth(for: container))
    }

    /// 按容器宽度把保存的归一化比例还原成像素宽度（夹紧）；ratio ≤ 0 视为未保存 → 用默认宽度。
    public static func width(forRatio ratio: CGFloat, container: CGFloat) -> CGFloat {
        let base = ratio > 0 ? ratio * container : defaultWidth
        return clampWidth(base, container: container)
    }

    /// 像素宽度 → 归一化比例（持久化用，窗口尺寸变化后仍能保持相近比例）。容器未知（≤0）返回 0。
    public static func ratio(forWidth width: CGFloat, container: CGFloat) -> CGFloat {
        guard container > 0 else { return 0 }
        return width / container
    }

    /// 拖拽中：原始建议宽度是否已小到应当“直接关闭右栏”（< minWidth）。
    public static func shouldCloseWhileDragging(rawWidth: CGFloat) -> Bool {
        rawWidth < minWidth
    }
}
