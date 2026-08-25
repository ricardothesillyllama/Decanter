import Foundation

public struct Shell {
    @discardableResult
    public static func run(_ launchPath: URL, _ args: [String],
                           env: [String: String] = [:],
                           cwd: URL? = nil,
                           timeout: TimeInterval? = nil) throws -> (code: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = launchPath
        p.arguments = args
        var e = ProcessInfo.processInfo.environment
        for (k, v) in env { e[k] = v }
        p.environment = e
        if let cwd { p.currentDirectoryURL = cwd }
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe; p.standardError = errPipe
        try p.run()

        // Drain concurrently so a chatty child can't deadlock on a full pipe.
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var out = Data(), err = Data()
        }
        let box = Box()
        let q = DispatchQueue(label: "decanter.shell.drain", attributes: .concurrent)
        let g = DispatchGroup()
        q.async(group: g) {
            let d = outPipe.fileHandleForReading.readDataToEndOfFile()
            box.lock.lock(); box.out = d; box.lock.unlock()
        }
        q.async(group: g) {
            let d = errPipe.fileHandleForReading.readDataToEndOfFile()
            box.lock.lock(); box.err = d; box.lock.unlock()
        }

        if let timeout {
            let deadline = Date().addingTimeInterval(timeout)
            while p.isRunning && Date() < deadline { usleep(100_000) }
            if p.isRunning {
                // SIGTERM first, but do not trust it. A wine64 wrapper that is
                // stuck inside wineboot ignores it, and then waitUntilExit()
                // below blocks forever. Escalating is what stops a timed-out
                // wineboot from spinning at 100% CPU for days.
                p.terminate()
                let grace = Date().addingTimeInterval(5)
                while p.isRunning && Date() < grace { usleep(100_000) }
                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            }
        }
        p.waitUntilExit()
        g.wait()
        box.lock.lock(); defer { box.lock.unlock() }
        return (p.terminationStatus,
                String(decoding: box.out, as: UTF8.self),
                String(decoding: box.err, as: UTF8.self))
    }

    /// Launches without waiting. Used for the game itself.
    public static func spawn(_ launchPath: URL, _ args: [String],
                             env: [String: String] = [:],
                             cwd: URL? = nil,
                             logFile: URL? = nil) throws -> Process {
        let p = Process()
        p.executableURL = launchPath
        p.arguments = args
        var e = ProcessInfo.processInfo.environment
        for (k, v) in env { e[k] = v }
        p.environment = e
        if let cwd { p.currentDirectoryURL = cwd }
        if let logFile {
            FileManager.default.createFile(atPath: logFile.path, contents: nil)
            if let fh = try? FileHandle(forWritingTo: logFile) {
                p.standardOutput = fh; p.standardError = fh
            }
        }
        try p.run()
        return p
    }
}
