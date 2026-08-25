import Foundation

/// Edits a prefix's user.reg directly.
///
/// Setting a DLL override used to shell out to `wine reg add`, which starts a
/// wineserver and briefly puts Wine's desktop windows on screen — so merely
/// *looking* at a different configuration launched something. Wine reads
/// user.reg when the server starts, so writing the file while nothing is
/// running is both quieter and faster.
public struct PrefixRegistry {
    let fm = FileManager.default
    public init() {}

    /// Wine stores times as 100ns ticks since 1601 in the section header.
    static func wineTimestamp() -> String {
        let unix = Date().timeIntervalSince1970
        let ticks = UInt64((unix + 11_644_473_600) * 10_000_000)
        return String(ticks)
    }

    public func setDllOverrides(_ overrides: [String: String], in prefix: URL) throws {
        try setValues(overrides.mapValues { .string($0) },
                      section: #"Software\\Wine\\DllOverrides"#, in: prefix)
    }

    public enum Value { case string(String), dword(UInt32) }

    /// Creates or updates a section, leaving everything else alone.
    ///
    /// `file` selects the hive: HKCU lives in user.reg, HKLM in system.reg.
    /// Both are UTF-8 with non-ASCII escaped as `\xNNNN`, so plain text
    /// round-trips safely.
    public func setValues(_ values: [String: Value], section: String,
                          in prefix: URL, file: String = "user.reg") throws {
        let reg = prefix.appending(path: file)
        var text = (try? String(contentsOf: reg, encoding: .utf8))
            ?? "WINE REGISTRY Version 2\n\n"
        guard !values.isEmpty else { return }
        let header = "[\(section)]"

        func render(_ k: String, _ v: Value) -> String {
            switch v {
            case .string(let s): return "\"\(k)\"=\"\(s)\""
            case .dword(let d):  return "\"\(k)\"=dword:\(String(format: "%08x", d))"
            }
        }

        var lines = text.components(separatedBy: "\n")
        if let start = lines.firstIndex(where: { $0.hasPrefix(header) }) {
            // Replace matching keys in place; append the rest before the next section.
            var end = start + 1
            while end < lines.count, !lines[end].hasPrefix("[") { end += 1 }
            var body = Array(lines[(start + 1)..<end])
            for (k, v) in values.sorted(by: { $0.key < $1.key }) {
                let needle = "\"\(k)\"="
                if let i = body.firstIndex(where: { $0.hasPrefix(needle) }) {
                    body[i] = render(k, v)
                } else {
                    // Keep it tidy: insert before the trailing blank lines.
                    var at = body.count
                    while at > 0, body[at - 1].trimmingCharacters(in: .whitespaces).isEmpty { at -= 1 }
                    body.insert(render(k, v), at: at)
                }
            }
            lines.replaceSubrange((start + 1)..<end, with: body)
            text = lines.joined(separator: "\n")
        } else {
            var block = "\n\(header) \(Self.wineTimestamp())\n#time=\(Self.wineTimestamp())\n"
            for (k, v) in values.sorted(by: { $0.key < $1.key }) { block += render(k, v) + "\n" }
            text += block
        }
        try text.write(to: reg, atomically: true, encoding: .utf8)
    }

    public func dllOverrides(in prefix: URL) -> [String: String] {
        values(section: #"[Software\\Wine\\DllOverrides]"#, in: prefix)
    }

    /// Reads back one section's string values. `section` is the full bracketed
    /// header, since that is how it appears in the file.
    public func values(section: String, in prefix: URL, file: String = "user.reg") -> [String: String] {
        guard let text = try? String(contentsOf: prefix.appending(path: file), encoding: .utf8)
        else { return [:] }
        var out: [String: String] = [:]
        var inSection = false
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("[") { inSection = line.hasPrefix(section); continue }
            guard inSection, line.hasPrefix("\"") else { continue }
            let parts = line.dropFirst().components(separatedBy: "\"=\"")
            if parts.count == 2 { out[parts[0]] = String(parts[1].dropLast()) }
        }
        return out
    }
}
