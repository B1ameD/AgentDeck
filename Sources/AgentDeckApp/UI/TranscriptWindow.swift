import Foundation

/// 聊天转录的「浮动窗口」：任意时刻只渲染视口附近 ~windowSize 条，滚动时窗口跟随滑动。
/// 动机(#2)：全量渲染的首帧 TextKit 测量成本随历史长度线性增长；早期的「尾部窗口」
/// 解决了打开慢，但上滑翻历史只放不收——翻到顶等于全量渲染。浮动窗口让渲染量全程有界：
/// 上滑→窗口上移（顶部放出、底部回收），下滑→窗口下移（底部放出、顶部回收），
/// 贴尾时跟随新消息；自己发消息则跳回尾部。
enum TranscriptWindow {
    /// 窗口大小：用户实测 80~100 条流畅度与 40 条相当，「全部展开」明显卡顿。
    static let windowSize = 80
    /// 每次滑动的条数：小批量+冷却，渐进推进避免一次性大重排。
    static let slideBatch = 10
    /// 触发滑动的距离：哨兵距视口边缘 80px 内才推进下一批。
    /// 距离放宽到 600 时曾连锁触发（SwiftUI 翻历史时保持「距顶/距底偏移」，滑动后视口
    /// 会压进新内容再次命中哨兵）；配合滑动后的锚定补偿，小距离+小批量才稳。
    static let releaseDistance: CGFloat = 80

    /// 设置项「历史会话全部展开」：打开后不做窗口截断，打开会话即全量渲染。
    /// 用户实测明显卡顿，保留供短历史/特殊场景使用，默认关闭。
    static let expandAllStorageKey = "chat.transcript.expandAll"
    static let expandAllDefault = false

    /// 可见窗口 [start, end)，为消息数组下标。
    struct Window: Equatable {
        var start: Int
        var end: Int

        var hiddenAbove: Int { start }
        func hiddenBelow(totalCount: Int) -> Int { max(0, totalCount - end) }
    }

    /// 尾部窗口：打开/重置会话时显示最新 windowSize 条。
    static func tail(totalCount: Int) -> Window {
        Window(start: max(0, totalCount - windowSize), end: totalCount)
    }

    /// 全量窗口（「全部展开」设置）。
    static func full(totalCount: Int) -> Window {
        Window(start: 0, end: totalCount)
    }

    /// 把 @State 里的窗口落到当前消息数组上：未初始化或已越界（切会话/清空残留）回落尾部。
    static func resolved(_ window: Window, totalCount: Int) -> Window {
        guard window.end > window.start, window.end <= totalCount else {
            return tail(totalCount: totalCount)
        }
        return window
    }

    /// 上滑翻历史：窗口上移一批（顶部放出、底部回收），保持大小、夹紧边界。
    static func slidUp(_ window: Window, totalCount: Int) -> Window {
        let start = max(0, window.start - slideBatch)
        return Window(start: start, end: min(totalCount, start + windowSize))
    }

    /// 下滑回看新消息：窗口下移一批（底部放出、顶部回收）。
    static func slidDown(_ window: Window, totalCount: Int) -> Window {
        let end = min(totalCount, window.end + slideBatch)
        return Window(start: max(0, end - windowSize), end: end)
    }

    /// 消息总数变化后的窗口：贴尾（或未初始化）则跟随新尾部；翻历史中则原地不动
    /// （新消息落在窗口外，渲染量不变）；清空/收缩一律重置为尾部。
    static func afterCountChange(_ window: Window, oldCount: Int, newCount: Int) -> Window {
        if newCount < oldCount { return tail(totalCount: newCount) }
        if window.end >= oldCount { return tail(totalCount: newCount) }
        return window
    }
}
