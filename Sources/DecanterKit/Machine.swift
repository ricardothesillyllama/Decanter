import Foundation

/// The Mac a result was observed on, reduced to axes that group.
///
/// Deliberately coarse. "Apple M2" is a class thousands of people are in;
/// "Apple M2 Max, 96 GB, macOS 26.1 build 25B74" is very nearly a person. The
/// knowledge base only ever needs the class, so only the class is recorded.
public struct MachineClass: Codable, Hashable, Sendable {

    /// Closed vocabulary on purpose. A raw `machdep.cpu.brand_string` is a
    /// free-form string, and a free-form field is how identifying detail gets
    /// in without anyone deciding to let it in.
    public enum Chip: String, Codable, Sendable, CaseIterable {
        case m1, m2, m3, m4, m5, appleSilicon, intel, unknown

        public var label: String {
            switch self {
            case .m1: "M1"; case .m2: "M2"; case .m3: "M3"; case .m4: "M4"; case .m5: "M5"
            case .appleSilicon: "Apple silicon"; case .intel: "Intel"; case .unknown: "unknown"
            }
        }
    }

    public var chip: Chip
    public var macOSMajor: Int?

    public init(chip: Chip = .unknown, macOSMajor: Int? = nil) {
        self.chip = chip
        self.macOSMajor = macOSMajor
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chip = (try? c.decode(Chip.self, forKey: .chip)) ?? .unknown
        macOSMajor = try? c.decodeIfPresent(Int.self, forKey: .macOSMajor)
    }

    public var label: String {
        macOSMajor.map { "\(chip.label), macOS \($0)" } ?? chip.label
    }

    /// This Mac. Reads the brand string once and throws the detail away.
    public static func current() -> MachineClass {
        MachineClass(chip: Chip(brandString: brandString()),
                     macOSMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    }

    static func brandString() -> String {
        (try? Shell.run(URL(filePath: "/usr/sbin/sysctl"),
                        ["-n", "machdep.cpu.brand_string"], timeout: 15).out
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
    }
}

public extension MachineClass.Chip {
    /// Maps a brand string onto the closed vocabulary. Anything unrecognised
    /// that still says "Apple" lands on `appleSilicon` rather than leaking the
    /// original text — an unknown chip is a fact, its name is not needed.
    init(brandString s: String) {
        let l = s.lowercased()
        if l.contains("apple m1") { self = .m1 }
        else if l.contains("apple m2") { self = .m2 }
        else if l.contains("apple m3") { self = .m3 }
        else if l.contains("apple m4") { self = .m4 }
        else if l.contains("apple m5") { self = .m5 }
        else if l.contains("apple") { self = .appleSilicon }
        else if l.contains("intel") { self = .intel }
        else { self = .unknown }
    }
}
