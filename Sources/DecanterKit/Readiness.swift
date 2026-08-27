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
        /// Plain language. The real name lives in `technical`.
        public var title: String
        /// What is actually installed, once something is. Real names, because
        /// this is the line a forum thread has to map onto.
        public var technical: String?
        /// What to get, in the terms someone who already knows would use —
        /// exact project, exact version, and the constraint that matters.
        /// Always shown: a beginner can skip a greyed monospace line, and
        /// someone who knows what Wine is should not have to guess which build
        /// or which version this expects.
        public var spec: String?
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

        public init(id: String, title: String, technical: String? = nil,
                    spec: String? = nil, why: String,
                    state: State, required: Bool, detail: String? = nil,
                    source: URL? = nil, sourceLabel: String? = nil, accepts: String? = nil) {
            self.id = id; self.title = title; self.technical = technical
            self.spec = spec; self.why = why
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
    /// The releases page, not the Homebrew tap. The tap's front page is a
    /// README whose instructions are Terminal commands — which is the thing
    /// this app exists to remove, and it left a new user hunting for a file
    /// that was never on the page they landed on.
    public static let wineSource = URL(string: "https://github.com/Gcenx/macOS_Wine_builds/releases/latest")!
    public static let dxvkSource = URL(string: "https://github.com/doitsujin/dxvk/releases/tag/v1.10.3")!
    public static let dxmtSource = URL(string: "https://github.com/3Shain/dxmt/releases")!
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
            spec: "x86_64 translation · every Wine build here is an Intel binary",
            why: "Lets your Mac run software built for older Intel chips. Every Windows game is.",
            state: h.rosetta ? .present : .missing,
            required: true,
            detail: h.rosetta ? "Already on this Mac" : "One click, and macOS handles the rest.",
            accepts: h.rosetta ? nil : "Install Rosetta"))

        let pinnedWine = h.pinnedRuntimes.filter { $0.kind == .wine }
        let pinnedGPTK = h.pinnedRuntimes.filter { $0.kind == .gptk }
        let foundWine = h.discovered.filter { $0.kind == .wine }
        let foundGPTK = h.discovered.filter { $0.kind == .gptk }

        r.pieces.append(.init(
            id: "wine",
            title: "Windows support",
            technical: pinnedWine.map(\.id).joined(separator: ", "),
            spec: pinnedWine.isEmpty
                ? "Wine 10 or 11, macOS build · wine-devel-<version>-osx64.tar.xz from Gcenx"
                : "Wine " + pinnedWine.map(\.version).joined(separator: ", ")
                  + " · " + (pinnedWine.contains(where: \.supports32Bit) ? "32-bit capable" : "64-bit only"),
            why: "Without this, a Windows game is just a file your Mac cannot open.",
            state: !pinnedWine.isEmpty ? .present : (!foundWine.isEmpty ? .foundNotPinned : .missing),
            required: true,
            detail: pinnedWine.isEmpty
                ? (foundWine.isEmpty
                   ? "Free. On that page, click the file ending in -osx64.tar.xz, then drag it onto this window."
                   : "Already on this Mac. Decanter wants its own copy, so an update to it can never break your games.")
                : pinnedWine.map(\.version).joined(separator: ", "),
            source: Readiness.wineSource, sourceLabel: "Download",
            accepts: "Drag the downloaded file onto this window"))

        r.pieces.append(.init(
            id: "gptk",
            title: "Apple graphics",
            technical: pinnedGPTK.map(\.id).joined(separator: ", "),
            spec: pinnedGPTK.isEmpty
                ? "Game Porting Toolkit 2.1+ · provides D3DMetal, on a Wine 7.7 base"
                : "Game Porting Toolkit on Wine "
                  + pinnedGPTK.map(\.version).joined(separator: ", ")
                  + " · D3DMetal available",
            why: "Makes 3D games run much faster, using Apple's own graphics software. Games still work without it — just slower.",
            state: !pinnedGPTK.isEmpty ? .present : (!foundGPTK.isEmpty ? .foundNotPinned : .missing),
            required: false,
            detail: pinnedGPTK.isEmpty
                ? "Free from Apple — an ordinary Apple ID is enough. It downloads as one big file ending in .dmg. Drag that whole file here; Decanter takes only the part it needs."
                : pinnedGPTK.map(\.version).joined(separator: ", "),
            source: Readiness.gptkSource, sourceLabel: "Download from Apple",
            accepts: "Drag the .dmg onto this window"))

        let staged = dxvk.stagedVersions()
        r.pieces.append(.init(
            id: "dxvk",
            title: "Alternative graphics",
            technical: staged.isEmpty ? nil : "DXVK " + staged.joined(separator: ", "),
            spec: staged.isEmpty
                ? "DXVK 1.10.3 · targets Vulkan 1.1. 2.x/3.x need Vulkan 1.3, which MoltenVK does not fully implement"
                : "DXVK " + staged.joined(separator: ", ")
                  + (staged.contains("1.10.3") ? "" : " · 1.10.3 is the one that works here"),
            why: "A different way of drawing a game. Some games only run with this one, so it is worth having both.",
            state: staged.isEmpty ? .missing : .present,
            required: false,
            detail: staged.isEmpty
                ? "Take version 1.10.3, even though newer ones exist — the newer ones do not work on any Mac. The link goes straight to the right one."
                : staged.joined(separator: ", "),
            source: Readiness.dxvkSource, sourceLabel: "Download 1.10.3",
            accepts: "Drop the .tar.gz here"))

        // Only surfaced once a runtime that can host it is pinned. Listing a
        // piece nobody here can use is the same mistake as offering a button
        // whose only outcome is an error.
        let dxmt = DXMTInstaller(paths: paths)
        let dxmtStaged = dxmt.stagedVersions()
        let dxmtHosts = h.pinnedRuntimes.filter { RuntimeManager.metalHosting(root: $0.root).looksCapable }
        if !dxmtHosts.isEmpty || !dxmtStaged.isEmpty {
            r.pieces.append(.init(
                id: "dxmt",
                title: "Unity 6 graphics",
                technical: dxmtStaged.isEmpty ? nil : "DXMT " + dxmtStaged.joined(separator: ", "),
                spec: dxmtStaged.isEmpty
                    ? "DXMT · Direct3D 11 to Metal · needs a Wine whose Mac driver exposes a Cocoa view"
                    : "DXMT " + dxmtStaged.joined(separator: ", ")
                      + " · hosted by " + dxmtHosts.map(\.id).joined(separator: ", "),
                why: "The only one here that can start a Unity 6 game. Skip it unless you have one.",
                state: dxmtStaged.isEmpty ? .missing : .present,
                required: false,
                detail: dxmtStaged.isEmpty
                    ? "Decanter has not confirmed a Unity 6 game running on this yet — it is the only option that can, not one that is known to."
                    : (dxmtHosts.isEmpty
                        ? "Staged, but no pinned runtime can host it yet."
                        : dxmtStaged.joined(separator: ", ")),
                source: Readiness.dxmtSource, sourceLabel: "Download from DXMT",
                accepts: dxmtHosts.isEmpty ? nil : "Drop the archive here"))
        }

        // Decanter makes this one itself — but only once it has something to
        // make it *with*. Offering the button before a runtime exists is an
        // action whose only possible outcome is an error message.
        let canBuild = !h.pinnedRuntimes.isEmpty
        r.pieces.append(.init(
            id: "template",
            title: "Clean Windows environment",
            technical: "golden prefix",
            spec: "golden WoW64 prefix per runtime · APFS-cloned per game, with wine-mono and DXVK baked in",
            why: "A blank Windows setup that each game gets its own private copy of. Nothing to download — Decanter builds this one.",
            state: h.templateBuilt ? .present : .missing,
            required: true,
            detail: h.templateBuilt
                ? (h.templateAge.map { "Built \(Self.ageLabel($0)) ago" } ?? "Built")
                : (canBuild ? "Takes a minute or two, and only happens once."
                            : "Waiting for the step above. Decanter can build this as soon as it has something to build it from."),
            accepts: h.templateBuilt ? nil : (canBuild ? "Build it" : nil)))

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
