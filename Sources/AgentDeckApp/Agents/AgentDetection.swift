import Foundation

public enum AgentDetection {
    /// Fallback paths for executable lookup, ordered by priority.
    /// Includes common Homebrew paths, user-local bin, and system defaults.
    public static let defaultFallbackPaths = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        FileManager.default.homeDirectoryForCurrentUser.path + "/.local/bin"
    ]

    public static func resolveExecutable(named name: String) -> String? {
        resolveExecutable(
            named: name,
            pathEnvironment: ProcessInfo.processInfo.environment["PATH"],
            fallbackPaths: defaultFallbackPaths
        )
    }

    public static func resolveExecutable(
        named name: String,
        pathEnvironment: String?,
        fallbackPaths: [String] = defaultFallbackPaths
    ) -> String? {
        let pathEntries = pathEnvironment?
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init) ?? []

        for path in orderedUnique(pathEntries + fallbackPaths) {
            let candidate = URL(fileURLWithPath: path).appendingPathComponent(name)
            if isTrulyExecutable(at: candidate) {
                return candidate.path
            }
        }
        return nil
    }

    /// Checks whether a file is truly executable and resolves symbolic links.
    /// `FileManager.isExecutableFile` alone returns `true` for broken symlinks
    /// because the symlink itself may have execute permissions. This helper
    /// resolves the symlink and verifies the target exists.
    private static func isTrulyExecutable(at url: URL) -> Bool {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: url.path) else { return false }

        // Resolve symbolic links: if the link is broken, the destination won't exist.
        do {
            let resolved = try fm.destinationOfSymbolicLink(atPath: url.path)
            // destination may be relative; resolve against the symlink's directory.
            let base = url.deletingLastPathComponent()
            let resolvedURL = URL(fileURLWithPath: resolved, relativeTo: base).standardizedFileURL
            return fm.fileExists(atPath: resolvedURL.path)
        } catch {
            // Not a symlink (or unreadable); fall back to plain existence check.
            return fm.fileExists(atPath: url.path)
        }
    }

    private static func orderedUnique(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for path in paths where seen.insert(path).inserted {
            result.append(path)
        }
        return result
    }
}
