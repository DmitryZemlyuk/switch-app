import Foundation

/// Finds a Node.js runtime installed on this Mac. The Matter helper needs Node 22.13+ (or 20.19+ of the 20.x line).
enum NodeLocator {
    struct Found {
        let url: URL
        let version: [Int]
    }

    /// Looks through the usual install locations and the user's login shell. Slow-ish: call off the main thread.
    static func locate() -> Found? {
        var best: Found?
        var seen = Set<String>()
        for path in candidates() {
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            guard seen.insert(resolved).inserted,
                  FileManager.default.isExecutableFile(atPath: path),
                  let version = version(of: path), isSupported(version) else { continue }
            if best == nil || isNewer(version, than: best!.version) {
                best = Found(url: URL(fileURLWithPath: path), version: version)
            }
        }
        return best
    }

    static func isSupported(_ v: [Int]) -> Bool {
        guard v.count >= 2 else { return false }
        if v[0] == 20 { return v[1] >= 19 }
        if v[0] == 22 { return v[1] >= 13 }
        return v[0] > 22
    }

    static func parseVersion(_ text: String) -> [Int]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = trimmed.hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
        let parts = cleaned.split(separator: ".").prefix(3).map { Int($0) }
        guard parts.count >= 2, !parts.contains(where: { $0 == nil }) else { return nil }
        return parts.compactMap { $0 }
    }

    private static func isNewer(_ a: [Int], than b: [Int]) -> Bool {
        for (x, y) in zip(a, b) where x != y { return x > y }
        return a.count > b.count
    }

    private static func candidates() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var paths = [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/opt/local/bin/node",
            "\(home)/.volta/bin/node",
            "\(home)/.local/bin/node",
            "\(home)/.asdf/shims/node",
            "\(home)/.local/share/mise/shims/node"
        ]
        // Version managers keep one folder per installed version.
        for (root, suffix) in [
            ("\(home)/.nvm/versions/node", "bin/node"),
            ("\(home)/.local/share/fnm/node-versions", "installation/bin/node"),
            ("\(home)/Library/Application Support/fnm/node-versions", "installation/bin/node"),
            ("\(home)/.n/n/versions/node", "bin/node"),
            ("/usr/local/n/versions/node", "bin/node")
        ] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
            paths += names.map { "\(root)/\($0)/\(suffix)" }
        }
        // Whatever `node` means in the user's own terminal.
        if let fromShell = run("/bin/zsh", ["-lic", "command -v node"], timeout: 5)?
            .split(separator: "\n").last.map(String.init), fromShell.hasPrefix("/") {
            paths.append(fromShell)
        }
        return paths
    }

    private static func version(of path: String) -> [Int]? {
        guard let output = run(path, ["--version"], timeout: 5) else { return nil }
        return parseVersion(output)
    }

    private static func run(_ path: String, _ arguments: [String], timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return nil }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
