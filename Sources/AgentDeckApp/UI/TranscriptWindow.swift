import Foundation

/// 聊天转录的「尾部窗口」：长会话只渲染最近 limit 条，更早的折叠在「显示更早消息」按钮后。
/// 动机(#2)：恢复 389 条的会话时,bottom 锚定的 LazyVStack 需要测量全部气泡高度
/// (每条都是一次完整 TextKit 布局)——窗口化让首帧成本与历史长度解耦。
enum TranscriptWindow {
    /// 默认初始渲染条数;上滑接近窗口顶部时按 scrollReleaseBatch 渐进放出。
    /// 40→100：用户实测 100 条与 40 条流畅度相当，而「全部展开」明显卡顿——取更大的可视窗口。
    static let defaultLimit = 100
    /// 设置项「历史会话默认全部展开」：打开后不做尾部窗口截断，打开会话即全量渲染。
    /// 代价＝首帧成本随历史长度线性增长（#2 的根因）；跨实例高度缓存会软化重复打开。
    static let expandAllStorageKey = "chat.transcript.expandAll"
    static let expandAllDefault = false
    /// 每次自动释放的条数:小批量+冷却,渐进展开避免一次性大重排(操作体感,用户反馈)。
    static let scrollReleaseBatch = 10
    /// 触发自动释放的距离:哨兵距视口上沿 80px 内(几乎滚到顶)才放下一批。
    /// 距离放宽到 600 时曾连锁触发直至全量展开——翻历史时 SwiftUI 保持「距顶偏移」,
    /// 释放后视口会压进新内容再次命中哨兵;配合释放后的锚定补偿,小距离+小批量才稳。
    static let releaseDistance: CGFloat = 80

    /// 给定总条数与当前窗口上限,返回(隐藏条数, 可见后缀起始下标)。
    static func slice(totalCount: Int, limit: Int) -> (hiddenCount: Int, visibleStart: Int) {
        let clampedLimit = max(1, limit)
        let hidden = max(0, totalCount - clampedLimit)
        return (hidden, hidden)
    }

    /// 自动释放后的新窗口上限(逐批放出,封顶全量)。
    static func scrollExpandedLimit(current: Int, totalCount: Int) -> Int {
        min(totalCount, max(1, current) + scrollReleaseBatch)
    }
}
