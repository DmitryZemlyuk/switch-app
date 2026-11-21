import Foundation

/// One JSON line from the Matter helper.
struct HelperEvent: Decodable {
    struct RawDevice: Decodable {
        let id: String
        let label: String?
        let on: Bool
        let reachable: Bool?
        let kind: String?
    }

    let ev: String
    let state: String?
    let devices: [RawDevice]?
    let id: String?
    let on: Bool?
    let code: String?
    let message: String?
}

/// Runs the matter.js helper with the Node.js installed on this Mac and exchanges JSON lines with it.
/// The helper is restarted with a growing delay if it exits unexpectedly.
@MainActor
final class HelperClient {
    var onEvent: ((HelperEvent) -> Void)?
    var onCrash: (() -> Void)?
    var onNodeMissing: (() -> Void)?

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var stopping = false
    private var restartDelay: TimeInterval = 1
    private var startedAt = Date()
    private var restartTask: Task<Void, Never>?
    private var locateTask: Task<Void, Never>?
    private var nodeURL: URL?

    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Switch", isDirectory: true)
    }

    static var logURL: URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Logs/Switch/helper.log")
    }

    /// Finds Node.js on this Mac (once) and starts the helper with it.
    func start() {
        stopping = false
        restartTask?.cancel()
        locateTask?.cancel()
        if let nodeURL, FileManager.default.isExecutableFile(atPath: nodeURL.path) {
            launch(node: nodeURL)
            return
        }
        nodeURL = nil
        locateTask = Task { @MainActor [weak self] in
            let found = await Task.detached(priority: .userInitiated) { NodeLocator.locate() }.value
            guard let self, !Task.isCancelled, !self.stopping else { return }
            if let found {
                self.appendLog("using node \(found.version.map(String.init).joined(separator: ".")) at \(found.url.path)")
                self.nodeURL = found.url
                self.launch(node: found.url)
            } else {
                self.appendLog("no suitable Node.js found (need 22.13+ or 20.19+)")
                self.onNodeMissing?()
                // Look again every 30 s so the app recovers by itself once Node is installed.
                self.startedAt = Date()
                self.restartDelay = 30
                self.scheduleRestart()
            }
        }
    }

    private func launch(node: URL) {
        guard let resources = Bundle.main.resourceURL else { return }
        let script = resources.appendingPathComponent("helper/matter-helper.mjs")
        let storage = Self.supportDirectory.appendingPathComponent("matter", isDirectory: true)
        try? FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)

        let proc = Process()
        proc.executableURL = node
        proc.arguments = [script.path]
        var env = ProcessInfo.processInfo.environment
        env["SWITCH_STORAGE_DIR"] = storage.path
        proc.environment = env

        let inPipe = Pipe()
        let outPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = openLog() ?? FileHandle.nullDevice

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            DispatchQueue.main.async { self?.consume(data) }
        }
        proc.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            DispatchQueue.main.async { self?.didTerminate(proc: finished, status: status) }
        }

        do {
            try proc.run()
            process = proc
            input = inPipe.fileHandleForWriting
            buffer.removeAll()
            startedAt = Date()
        } catch {
            appendLog("failed to launch helper: \(error)")
            nodeURL = nil // look for Node again next time
            onCrash?()
            scheduleRestart()
        }
    }

    func stop() {
        stopping = true
        restartTask?.cancel()
        locateTask?.cancel()
        // Closing stdin makes the helper shut matter.js down cleanly; terminate is the backstop.
        try? input?.close()
        input = nil
        if let proc = process, proc.isRunning {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if proc.isRunning { proc.terminate() }
            }
        }
        process = nil
    }

    func send(_ message: [String: Any]) {
        guard let input,
              var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(0x0A)
        do {
            try input.write(contentsOf: data)
        } catch {
            appendLog("write to helper failed: \(error)")
        }
    }

    // MARK: - Private

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !line.isEmpty else { continue }
            if let event = try? JSONDecoder().decode(HelperEvent.self, from: line) {
                onEvent?(event)
            }
        }
    }

    private func didTerminate(proc: Process, status: Int32) {
        // Ignore an old process that exits after a restart already happened.
        if let current = process, current !== proc { return }
        process = nil
        input = nil
        if stopping { return }
        appendLog("helper exited with status \(status)")
        if Date().timeIntervalSince(startedAt) < 5 { nodeURL = nil } // died at once: re-check Node next time
        onCrash?()
        scheduleRestart()
    }

    private func scheduleRestart() {
        if Date().timeIntervalSince(startedAt) > 60 { restartDelay = 1 }
        let delay = restartDelay
        restartDelay = min(restartDelay * 2, 30)
        restartTask?.cancel()
        restartTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled, !self.stopping else { return }
            self.start()
        }
    }

    private func openLog() -> FileHandle? {
        let url = Self.logURL
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Keep the log small: start over once it passes 2 MB.
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber, size.intValue > 2_000_000 {
            try? fm.removeItem(at: url)
        }
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        _ = try? handle.seekToEnd()
        return handle
    }

    private func appendLog(_ text: String) {
        guard let handle = openLog() else { return }
        let line = "\(ISO8601DateFormatter().string(from: Date())) [app] \(text)\n"
        try? handle.write(contentsOf: Data(line.utf8))
        try? handle.close()
    }
}
