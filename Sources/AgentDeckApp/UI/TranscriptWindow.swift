import Foundation
import CoreGraphics

/// 聊天转录的「占位虚拟化」：列表始终包含**全部**消息——滚动条对应完整历史，自由滚动、
/// 无折叠、无分批加载——但只有视口上下 renderMargin 内的消息真正渲染气泡，
/// 其余用等高占位帧顶替（已测量＝精确高度，未访问过＝按文本量估算）。
///
/// 迭代史(#2/#3)：全量渲染→长会话卡顿；尾部窗口→翻到顶等于全量；浮动窗口→
/// 滑动锚定补偿与滚动手势打架（跳动）+批量冷却限速（卡墙）。占位虚拟化把
/// 「渲染量有界」与「滚动自由」解耦：滚动期间零 scrollTo、零冷却。
/// 已测量消息的占位⇄真身切换高度无损（同宽精确）；仅首次滚入从未渲染过的
/// 消息时有轻微高度修正。
enum TranscriptWindow {
    /// 行间距（VStack spacing），总高与占位计算都按它积分。
    static let rowSpacing: CGFloat = 10
    /// 视口上下各预渲染的余量(px)：提前物化，减少快滚时的占位闪现。
    static let renderMargin: CGFloat = 900
    /// 首帧 offset 尚未上报时的兜底渲染条数（取尾部，约一屏多）。
    static let initialRowCount = 30

    /// 设置项「历史会话全部展开」：打开后不做虚拟化，所有消息真实渲染（长会话明显卡顿）。
    static let expandAllStorageKey = "chat.transcript.expandAll"
    static let expandAllDefault = false

    /// 一次虚拟化结果：真实渲染的行区间 + 上下占位高度。
    struct VirtualLayout: Equatable {
        var range: Range<Int>
        var topInset: CGFloat
        var bottomInset: CGFloat
    }

    /// 未渲染过的消息按文本量估算高度：气泡铅垂方向 padding ≈24 + 行数×行高 ≈21。
    /// 换行符与 ~80 字/行的折行取大者；封顶 60 行（超长消息真身有折叠/截断机制）。
    static func estimatedRowHeight(characterCount: Int, newlineCount: Int) -> CGFloat {
        let wrappedLines = Int((Double(characterCount) / 80.0).rounded(.up))
        let lines = max(1, max(newlineCount + 1, wrappedLines))
        return CGFloat(min(lines, 60)) * 21 + 24
    }

    /// 打开/切换/转录回填时的**确定性尾部布局**：从末行向上累计直到盖满「视口+预渲染余量」。
    /// 同时返回贴底滚动偏移（内容总高−视口）——调用方把它预置为「最近偏移」，
    /// 使首帧渲染与随后的偏移上报处于同一坐标系：布局不再经历多帧收敛，
    /// defaultScrollAnchor(.bottom) 的锚定不会被坐标系切换掀翻（首发 bug 根因）。
    static func tailLayout(
        rowHeights: [CGFloat],
        viewportHeight: CGFloat
    ) -> (layout: VirtualLayout, bottomOffset: CGFloat) {
        let count = rowHeights.count
        guard count > 0 else {
            return (VirtualLayout(range: 0..<0, topInset: 0, bottomInset: 0), 0)
        }
        let needed = viewportHeight + renderMargin
        var covered: CGFloat = 0
        var lo = count
        while lo > 0, covered < needed {
            lo -= 1
            covered += rowHeights[lo] + rowSpacing
        }
        var topInset: CGFloat = 0
        if lo > 0 {
            var sum: CGFloat = 0
            for j in 0..<lo { sum += rowHeights[j] }
            topInset = sum + rowSpacing * CGFloat(lo - 1)
        }
        var total: CGFloat = -rowSpacing
        for height in rowHeights { total += height + rowSpacing }
        return (VirtualLayout(range: lo..<count, topInset: topInset, bottomInset: 0), max(0, total - viewportHeight))
    }

    /// 由各行高度、滚动偏移（内容顶到视口顶的距离）与视口高计算虚拟化布局。
    /// VStack(spacing) 模型：行 i 起点 y_i=Σ_{j<i}(h_j+spacing)；
    /// topInset 替代 rows[0..<lo] 含其内部 spacing（=Σh+spacing×(lo-1)），
    /// 与首个真身行之间的 spacing 由 VStack 自然提供；bottomInset 对称。
    static func virtualLayout(rowHeights: [CGFloat], offset: CGFloat, viewportHeight: CGFloat) -> VirtualLayout {
        let count = rowHeights.count
        guard count > 0 else { return VirtualLayout(range: 0..<0, topInset: 0, bottomInset: 0) }
        let lowY = offset - renderMargin
        let highY = offset + viewportHeight + renderMargin

        var rowStart: CGFloat = 0
        var lo = count - 1 // 全部行都在窗口上方时（瞬态过滚）兜底渲染末行
        var hi = count
        var loFound = false
        for index in 0..<count {
            let rowEnd = rowStart + rowHeights[index]
            if !loFound, rowEnd > lowY {
                lo = index
                loFound = true
            }
            if rowStart < highY { hi = index + 1 }
            rowStart = rowEnd + rowSpacing
        }
        if hi <= lo { hi = lo + 1 }

        var topInset: CGFloat = 0
        if lo > 0 {
            var sum: CGFloat = 0
            for j in 0..<lo { sum += rowHeights[j] }
            topInset = sum + rowSpacing * CGFloat(lo - 1)
        }
        var bottomInset: CGFloat = 0
        if hi < count {
            var sum: CGFloat = 0
            for j in hi..<count { sum += rowHeights[j] }
            bottomInset = sum + rowSpacing * CGFloat(count - hi - 1)
        }
        return VirtualLayout(range: lo..<hi, topInset: topInset, bottomInset: bottomInset)
    }
}
