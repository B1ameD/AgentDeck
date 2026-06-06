import Foundation

public enum SidebarSizing {
    public static let minWidth: CGFloat = 280
    public static let maxWidth: CGFloat = 880
    public static let minChatWidth: CGFloat = 420

    public static func maxSidebarWidth(for containerWidth: CGFloat) -> CGFloat {
        max(minWidth, min(maxWidth, containerWidth - minChatWidth))
    }

    public static func widthAfterWindowResize(
        currentWidth: CGFloat,
        oldContainerWidth: CGFloat,
        newContainerWidth: CGFloat
    ) -> CGFloat {
        let delta = newContainerWidth - oldContainerWidth
        let proposed = delta > 0 ? currentWidth + delta : currentWidth
        return min(max(proposed, minWidth), maxSidebarWidth(for: newContainerWidth))
    }
}
