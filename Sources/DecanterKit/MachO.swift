import Foundation

/// Just enough Mach-O to answer one question: what does this binary need
/// loaded alongside it, and where does it expect to find it?
///
/// Written because a runtime shipped that could not draw text. `wine-10.0-dxmt`
/// was assembled by hand from a build that keeps its libraries elsewhere, and
/// `libfreetype.6.dylib` was copied in without the four libraries FreeType
/// itself links against. Every font call failed, and nothing in Decanter could
/// say why: the file was present, so every check that asked "is it there?"
/// said yes. The question that would have caught it is "can it load?", and
/// that is a question about the dependency graph, not about one file.
///
/// `otool -L` answers it, but the developer tools are not installed on every
/// Mac, and a check that reports "sound" because a command is missing is worse
/// than no check. So the load commands are read directly.
public enum MachO {
    static let MH_MAGIC_64: UInt32 = 0xFEED_FACF
    static let MH_MAGIC_32: UInt32 = 0xFEED_FACE
    static let FAT_MAGIC:   UInt32 = 0xCAFE_BABE   // stored big-endian
    static let FAT_MAGIC_64: UInt32 = 0xCAFE_BABF

    static let LC_LOAD_DYLIB:      UInt32 = 0x0C
    static let LC_LOAD_WEAK_DYLIB: UInt32 = 0x8000_0018
    static let LC_REEXPORT_DYLIB:  UInt32 = 0x8000_001F
    static let LC_RPATH:           UInt32 = 0x8000_001C

    /// One `LC_LOAD_DYLIB` and friends, as written in the binary — still
    /// carrying `@rpath` / `@loader_path` rather than resolved, because where
    /// it resolves *to* depends on which file is asking.
    public struct Dependency: Sendable, Hashable {
        public var path: String
        /// A weak dependency that is missing is legal: dyld leaves the symbols
        /// null and the program is expected to cope. Reporting one as a fault
        /// would cry wolf on every optional codec.
        public var isWeak: Bool
    }

    /// What one binary asks for. `nil` when the file is not Mach-O at all —
    /// which is most of a Wine build, since the Windows side is PE.
    public struct Image: Sendable {
        public var dependencies: [Dependency] = []
        public var rpaths: [String] = []
    }

    static let CPU_TYPE_X86_64: UInt32 = 0x0100_0007
    static let CPU_TYPE_ARM64:  UInt32 = 0x0100_000C

    /// Which architectures a binary actually contains.
    ///
    /// Needed before one build's library can be given to another. Wine here is
    /// x86_64 running under Rosetta, and an arm64 library — which is what a
    /// package manager on this Mac hands you by default — will not load into it
    /// at all. The failure is silent in the usual way: `dlopen` returns null and
    /// the caller takes its fallback path. Checking is one field of the header.
    public static func architectures(at url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count >= 8 else { return [] }
        func name(_ cpu: UInt32) -> String {
            switch cpu {
            case CPU_TYPE_X86_64: "x86_64"
            case CPU_TYPE_ARM64:  "arm64"
            default: "cpu-\(cpu)"
            }
        }
        switch be32(data, 0) {
        case FAT_MAGIC, FAT_MAGIC_64:
            let wide = be32(data, 0) == FAT_MAGIC_64
            let n = Int(be32(data, 4))
            guard n > 0, n < 64 else { return [] }
            var out: [String] = []
            for i in 0..<n {
                let entry = 8 + i * (wide ? 32 : 20)
                guard data.count >= entry + 4 else { break }
                out.append(name(be32(data, entry)))
            }
            return out
        default:
            let magic = le32(data, 0)
            guard magic == MH_MAGIC_64 || magic == MH_MAGIC_32 else { return [] }
            return [name(le32(data, 4))]
        }
    }

    /// Reads the load commands of every architecture in the file and unions
    /// the results.
    ///
    /// Unioning is deliberate. Elsewhere in Decanter a fat file is refused
    /// outright, because *which slice runs* is not knowable from the file
    /// alone and picking one would be inventing an answer. Here the question is
    /// different — "is anything this build references absent?" — and a library
    /// missing for any slice is a real gap regardless of which slice runs.
    public static func read(at url: URL) -> Image? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count >= 8 else { return nil }

        switch be32(data, 0) {
        case FAT_MAGIC, FAT_MAGIC_64:
            let wide = be32(data, 0) == FAT_MAGIC_64
            let n = Int(be32(data, 4))
            // A corrupt or hostile header must not send this into a huge loop.
            guard n > 0, n < 64 else { return nil }
            var out = Image()
            var seen = false
            for i in 0..<n {
                let entry = 8 + i * (wide ? 32 : 20)
                guard data.count >= entry + (wide ? 32 : 20) else { break }
                let off = wide ? Int(be64(data, entry + 8)) : Int(be32(data, entry + 8))
                guard let slice = thin(data, at: off) else { continue }
                seen = true
                out.dependencies.append(contentsOf: slice.dependencies)
                out.rpaths.append(contentsOf: slice.rpaths)
            }
            guard seen else { return nil }
            out.dependencies = Array(Set(out.dependencies))
            out.rpaths = Array(Set(out.rpaths))
            return out
        default:
            return thin(data, at: 0)
        }
    }

    /// One architecture's load commands, starting at `base`.
    ///
    /// Little-endian only, and that is not laziness: every Mac Decanter runs on
    /// is little-endian, and a byte-swapping path with nothing to test it
    /// against is a path that is wrong the first time it matters.
    static func thin(_ data: Data, at base: Int) -> Image? {
        guard data.count >= base + 32 else { return nil }
        let magic = le32(data, base)
        guard magic == MH_MAGIC_64 || magic == MH_MAGIC_32 else { return nil }
        let headerSize = magic == MH_MAGIC_64 ? 32 : 28
        let ncmds = Int(le32(data, base + 16))
        let sizeofcmds = Int(le32(data, base + 20))
        guard ncmds > 0, ncmds < 10_000,
              data.count >= base + headerSize + sizeofcmds else { return nil }

        var out = Image()
        var off = base + headerSize
        let end = base + headerSize + sizeofcmds
        for _ in 0..<ncmds {
            guard off + 8 <= end else { break }
            let cmd = le32(data, off)
            let size = Int(le32(data, off + 4))
            // A zero or unaligned command size would loop forever or walk off
            // the end; both are how a malformed file turns a scan into a hang.
            guard size >= 8, off + size <= end else { break }

            switch cmd {
            case LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB:
                // dylib_command: cmd, cmdsize, name.offset, timestamp,
                // current_version, compatibility_version — the name follows.
                if size >= 24, let s = cString(data, at: off + Int(le32(data, off + 8)), limit: off + size) {
                    out.dependencies.append(.init(path: s, isWeak: cmd == LC_LOAD_WEAK_DYLIB))
                }
            case LC_RPATH:
                if size >= 12, let s = cString(data, at: off + Int(le32(data, off + 8)), limit: off + size) {
                    out.rpaths.append(s)
                }
            default: break
            }
            off += size
        }
        return out
    }

    static func cString(_ data: Data, at start: Int, limit: Int) -> String? {
        guard start >= 0, start < limit, limit <= data.count else { return nil }
        var bytes: [UInt8] = []
        var i = start
        while i < limit, data[data.startIndex + i] != 0 {
            bytes.append(data[data.startIndex + i]); i += 1
        }
        guard !bytes.isEmpty else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func le32(_ d: Data, _ o: Int) -> UInt32 { u32(d, o, bigEndian: false) }
    static func be32(_ d: Data, _ o: Int) -> UInt32 { u32(d, o, bigEndian: true) }

    static func u32(_ d: Data, _ o: Int, bigEndian: Bool) -> UInt32 {
        guard o >= 0, d.count >= o + 4 else { return 0 }
        let b = d.startIndex + o
        let x = (UInt32(d[b]) << 24) | (UInt32(d[b+1]) << 16) | (UInt32(d[b+2]) << 8) | UInt32(d[b+3])
        return bigEndian ? x : x.byteSwapped
    }

    static func be64(_ d: Data, _ o: Int) -> UInt64 {
        guard o >= 0, d.count >= o + 8 else { return 0 }
        return (UInt64(be32(d, o)) << 32) | UInt64(be32(d, o + 4))
    }
}
