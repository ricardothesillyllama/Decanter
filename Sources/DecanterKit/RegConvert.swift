import Foundation

/// Converts Wine's internal `user.reg`/`system.reg` syntax into the Windows
/// .reg format that `regedit` can actually import.
///
/// These are NOT the same format, which is a genuinely easy trap: a fragment
/// sliced out of a user.reg looks like a .reg file, and regedit exits 0 while
/// importing nothing at all.
public struct WineRegConverter {
    public init() {}

    public struct Result: Sendable {
        public var text: String
        public var keyCount: Int
    }

    public static func isWineInternal(_ text: String) -> Bool {
        text.hasPrefix("WINE REGISTRY Version")
    }

    /// - Parameter hive: which root the fragment came from. `user.reg` is
    ///   HKEY_CURRENT_USER; `system.reg` is HKEY_LOCAL_MACHINE.
    public func convert(_ text: String, hive: String = "HKEY_CURRENT_USER") -> Result {
        var out = ["Windows Registry Editor Version 5.00", ""]
        var keys = 0
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("WINE REGISTRY") { continue }
            if line.hasPrefix("#") { continue }          // #time=, #class= metadata
            if line.hasPrefix("[") {
                // [Software\\Foo\\Bar] 1771908086  ->  [HKEY_CURRENT_USER\Software\Foo\Bar]
                guard let close = line.lastIndex(of: "]") else { continue }
                var key = String(line[line.index(after: line.startIndex)..<close])
                key = key.replacingOccurrences(of: #"\\"#, with: #"\"#)
                key = Self.decodeHexEscapes(key)
                let full = key.uppercased().hasPrefix("HKEY_") ? key : "\(hive)\\\(key)"
                out.append("[\(full)]")
                keys += 1
                continue
            }
            if line.trimmingCharacters(in: .whitespaces).isEmpty { out.append(""); continue }
            out.append(convertValue(line))
        }
        return Result(text: out.joined(separator: "\n") + "\n", keyCount: keys)
    }

    private func convertValue(_ line: String) -> String {
        // Wine writes REG_EXPAND_SZ / REG_MULTI_SZ as str(2):"..." / str(7):"..."
        // Windows .reg expects hex(2): / hex(7): with UTF-16LE bytes.
        guard let eq = line.firstIndex(of: "="), line.hasPrefix("\"") else { return line }
        let name = String(line[line.startIndex...eq])
        let value = String(line[line.index(after: eq)...])
        for (prefix, type) in [("str(2):", 2), ("str(7):", 7)] {
            if value.hasPrefix(prefix) {
                var inner = String(value.dropFirst(prefix.count))
                if inner.hasPrefix("\"") { inner = String(inner.dropFirst()) }
                if inner.hasSuffix("\"") { inner = String(inner.dropLast()) }
                inner = Self.decodeHexEscapes(inner.replacingOccurrences(of: #"\\"#, with: #"\"#))
                var bytes: [String] = []
                for u in Array(inner.utf16) + [0] {
                    bytes.append(String(format: "%02x", u & 0xff))
                    bytes.append(String(format: "%02x", (u >> 8) & 0xff))
                }
                return "\(name)hex(\(type)):\(bytes.joined(separator: ","))"
            }
        }
        return line
    }

    /// Wine escapes non-ASCII in key names as \x65b0 (UTF-16 code units).
    public static func decodeHexEscapes(_ s: String) -> String {
        guard s.contains(#"\x"#) else { return s }
        var units: [UInt16] = []
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "\\", s.index(after: i) < s.endIndex, s[s.index(after: i)] == "x" {
                let start = s.index(i, offsetBy: 2)
                var j = start, hex = ""
                while j < s.endIndex, hex.count < 4, s[j].isHexDigit { hex.append(s[j]); j = s.index(after: j) }
                if let v = UInt16(hex, radix: 16) { units.append(v); i = j; continue }
            }
            for u in String(s[i]).utf16 { units.append(u) }
            i = s.index(after: i)
        }
        return String(decoding: units, as: UTF16.self)
    }
}
