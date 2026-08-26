import Foundation

/// What Decanter has, what it is missing, and what the missing thing is for —
/// in the words someone uses before they have learned any of ours.
///
/// This exists because the honest answer to "why do I have to run six Terminal
/// commands" was that nothing in the app ever told you what it needed. The
/// commands were never the problem; the invisibility was.
public struct Readiness: Sendable {

    public struct Piece: Sendable, Identifiable, Equatable {
        public enum State: Sendable, Equatable {
            case present
            case missing
            /// On disk but not yet taken into Decanter's own store. One click.
            case foundNotPinned
        }
        public var id: String
        /// Plain language. The real name lives in `technical`, shown only
        /// under Advanced, so a forum thread still maps onto this screen.
        public var title: String
        public var technical: String?
        /// One line, present tense, no jargon: what you lose without it.
        public var why: String
        public var state: State
        /// Required pieces block playing anything. Optional ones cost you
        /// speed or compatibility, which is a choice, not a failure.
        public var required: Bool
        public var detail: String?
        /// Where a person gets this. Opened in their browser by them —
        /// Decanter never fetches it.
        public var source: URL?
        public var sourceLabel: String?
        /// What to hand back afterwards, phrased as an instruction.
        public var accepts: String?

        public init(id: String, title: String, technical: String? = nil, why: String,
                    state: State, required: Bool, detail: String? = nil,
                    source: URL? = nil, sourceLabel: String? = nil, accepts: String? = nil) {
            self.id = id; self.title = title; self.technical = technical; self.why = why
            self.state = state; self.required = required; self.detail = detail
            self.source = source; self.sourceLabel = sourceLabel; self.accepts = accepts
        }
    }

    public var pieces: [Piece] = []

    public var missingRequired: [Piece] { pieces.filter { $0.required && $0.state != .present } }
    public var missingOptional: [Piece] { pieces.filter { !$0.required && $0.state != .present } }
    public var ready: Bool { missingRequired.isEmpty }

    /// One sentence for the sidebar footer and the wizard's headline.
    public var headline: String {
        if !ready { return "Not ready yet" }
        if missingOptional.isEmpty { return "Ready" }
        return "Ready — some games will run better with more set up"
    }

    public static let gptkSource = URL(string: "https://developer.apple.com/download/all/?q=game%20porting%20toolkit")!
    public static let wineSource = URL(string: "https://github.com/Gcenx/homebrew-wine")!
    public static let dxvkSource = URL(string: "https://github.com/doitsujin/dxvk/releases/tag/v1.10.3")!
}

public extension Engine {
    /// Built from the same `doctor()` facts the CLI prints, so the two can
    /// never disagree about whether this Mac is set up.
    func readiness() -> Readiness {
        let h = doctor()
        let dxvk = DXVKInstaller(paths: paths)
        var r = Readiness()

        r.pieces.append(.init(
            id: "rosetta",
            title: "Rosetta 2",
            technical: "Apple's Intel translation",
            why: "Windows games are Intel programs, so nothing runs at all without it.",
            state: h.rosetta ? .present : .missing,
            required: true,
            detail: h.rosetta ? "Installed" : "macOS installs this the first time you open an Intel app, or you can install it now.",
            accepts: h.rosetta ? nil : "Install Rosetta"))

        let pinnedWine = h.pinnedRuntimes.filter { $0.kind == .wine }
        let pinnedGPTK = h.pinnedRuntimes.filter { $0.kind == .gptk }
        let foundWine = h.discovered.filter { $0.kind == .wine }
        let foundGPTK = h.discovered.filter { $0.kind == .gptk }

        r.pieces.append(.init(
            id: "wine",
            title: "Windows support",
            technical: pinnedWine.map(\.id).joined(separator: ", "),
            why: "The part that lets a Windows program run on your Mac at all.",
            state: !pinnedWine.isEmpty ? .present : (!foundWine.isEmpty ? .foundNotPinned : .missing),
            required: true,
            detail: pinnedWine.isEmpty
                ? (foundWine.isEmpty
                   ? "Not set up. Download a Wine build for Apple Silicon, then drop it here."
                   : "Found on this Mac — Decanter needs its own copy so an update can never break your games.")
                : pinnedWine.map(\.version).joined(separator: ", "),
            source: Readiness.wineSource, sourceLabel: "Wine builds for Apple Silicon",
            accepts: "Drop a Wine app or folder here"))

        r.pieces.append(.init(
            id: "gptk",
            title: "Apple graphics",
            technical: pinnedGPTK.map(\.id).joined(separator: ", "),
            why: "Apple's own graphics translation. Usually the fastest option for 3D games — without it those games still run, just slower.",
            state: !pinnedGPTK.isEmpty ? .present : (!foundGPTK.isEmpty ? .foundNotPinned : .missing),
            required: false,
            detail: pinnedGPTK.isEmpty
                ? "Apple gives this away; a free Apple ID is enough. It arrives as a disk image — drop the whole .dmg here and Decanter will take what it needs."
                : pinnedGPTK.map(\.version).joined(separator: ", "),
            source: Readiness.gptkSource, sourceLabel: "Apple Developer downloads",
            accepts: "Drop the disk image here"))

        let staged = dxvk.stagedVersions()
        r.pieces.append(.init(
            id: "dxvk",
            title: "Vulkan graphics",
            technical: staged.isEmpty ? nil : "DXVK " + staged.joined(separator: ", "),
            why: "A second way to draw a game's graphics. Games that will not start one way often start the other.",
            state: staged.isEmpty ? .missing : .present,
            required: false,
            detail: staged.isEmpty
                ? "Get version 1.10.3, not the newest — later versions need a Vulkan feature macOS does not have, and fail in ways that look like the game's fault."
                : staged.joined(separator: ", "),
            source: Readiness.dxvkSource, sourceLabel: "DXVK 1.10.3",
            accepts: "Drop the .tar.gz here"))

        r.pieces.append(.init(
            id: "template",
            title: "Clean Windows environment",
            technical: "golden prefix",
            why: "Built once, then copied instantly for every game you add. Decanter makes this itself.",
            state: h.templateBuilt ? .present : .missing,
            required: true,
            detail: h.templateBuilt
                ? (h.templateAge.map { "Built \(Self.ageLabel($0)) ago" } ?? "Built")
                : "Takes a minute or two, once.",
            accepts: h.templateBuilt ? nil : "Build it"))

        return r
    }

    static func ageLabel(_ t: TimeInterval) -> String {
        let days = Int(t / 86_400)
        if days >= 1 { return days == 1 ? "1 day" : "\(days) days" }
        let hours = Int(t / 3_600)
        if hours >= 1 { return hours == 1 ? "1 hour" : "\(hours) hours" }
        return "less than an hour"
    }
}
