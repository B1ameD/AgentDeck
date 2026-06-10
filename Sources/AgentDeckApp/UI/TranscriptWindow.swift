import Foundation

/// 聊天转录的「尾部窗口」：长会话只渲染最近 limit 条，更早的折叠在「显示更早消息」按钮后。
/// 动机(#2)：恢复 389 条的会话时,bottom 锚定的 LazyVStack 需要测量全部气泡高度
/// (每条都是一次完整 TextKit 布局)——窗口化让首帧成本与历史长度解耦。
enum TranscriptWindow {
    /// 默认初始渲染条数;上滑接近窗口顶部时按 scrollReleaseBatch 渐进放出。
    static let defaultLimit = 40
    /// 每次自动释放的条数:小批量+冷却,渐进展开避免一次性大重排(操作体感,用户反馈)。
    static let scrollReleaseBatch = 10
    /// 触发自动释放的距离:窗口顶部哨兵进入视口上沿之上这个像素范围内即放出下一批。
    static let releaseDistance: CGFloat = 600

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
