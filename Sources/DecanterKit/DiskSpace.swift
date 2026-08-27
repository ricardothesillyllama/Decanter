import Foundation

/// Whether there is room to do something, asked before doing it.
///
/// Every operation here writes hundreds of megabytes: unpacking a Wine build,
/// copying one out of a disk image, staging a graphics layer. Running out
/// part-way leaves a half-written tree and an error from `tar` or `cp` that
/// says nothing about the actual cause, and the user is left with a broken
/// runtime they then have to work out how to remove.
public enum DiskSpace {

    /// Bytes this user can actually write to the volume holding `url`, which
    /// is not the same as bytes free: macOS counts purgeable space, and the
    /// "important usage" key is the one that accounts for what the system
    /// would evict to make room.
    ///
    /// The nearest existing ancestor is measured, because the destination
    /// usually does not exist yet — that is the point of asking.
    public static func available(at url: URL) -> Int64? {
        var probe = url
        let fm = FileManager.default
        while !fm.fileExists(atPath: probe.path) {
            let parent = probe.deletingLastPathComponent()
            // deletingLastPathComponent on "/" returns "/", so a path that
            // never resolves would spin here.
            guard parent.path != probe.path else { return nil }
            probe = parent
        }
        return (try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    public static func sizeOfFile(at url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
    }

    /// Refuses when the volume cannot hold `needed` bytes.
    ///
    /// An unreadable capacity is not treated as a failure: on a volume that
    /// does not report one, the old behaviour — try it and see — is still
    /// better than refusing to work at all.
    public static func require(_ needed: Int64, at url: URL, toDo what: String) throws {
        guard needed > 0, let free = available(at: url), free < needed else { return }
        throw DecanterError.outOfSpace(
            "\(what) needs about \(label(needed)) free and this disk has \(label(free)).")
    }

    /// Whole units, because a preflight figure is an estimate and "1.8 GB"
    /// reads as more precise than the number deserves.
    public static func label(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_000_000_000
        if gb >= 1 { return "\(Int(gb.rounded())) GB" }
        return "\(max(1, Int((Double(bytes) / 1_000_000).rounded()))) MB"
    }

    /// What unpacking an archive is expected to cost. Compressed Wine builds
    /// expand by roughly three times; the archive itself is already on disk
    /// and is not counted twice.
    public static func unpackEstimate(forArchiveOf bytes: Int64) -> Int64 { bytes * 3 }
}
