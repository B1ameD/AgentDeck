import Foundation

/// 监听自定义 agent 配置目录（DispatchSource 文件系统事件），变更后防抖 300ms 回调——
/// 配置热加载（#30）：改/增/删 JSON 保存即生效，无需重启。
/// 已打开的会话各自持有 AgentConfig 快照，不受重载影响；新标签用新配置。
@MainActor
final class AgentConfigWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var debounce: Task<Void, Never>?
    private let onChange: @MainActor () -> Void

    /// 目录不存在则先创建（监听需要现存 fd）；打不开返回 nil（调用方降级为仅手动重载）。
    init?(directory: URL, onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            // queue: .main → 与 @MainActor 同隔离。
            MainActor.assumeIsolated { self?.scheduleReload() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    /// 防抖：编辑器保存往往触发多个事件（写临时文件+rename），合并为一次重载。
    private func scheduleReload() {
        debounce?.cancel()
        debounce = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.onChange()
        }
    }

    deinit {
        source?.cancel()
        debounce?.cancel()
    }
}
