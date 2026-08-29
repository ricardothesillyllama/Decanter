import Foundation

/// The question Decanter asks after a launch it could not judge for itself.
///
/// A launch already produces evidence: whether a window appeared, whether the
/// process survived, whether the engine log complained. When that evidence is
/// clean, Decanter records the setup as working and asks nothing — being asked
/// to confirm what is plainly visible is how a prompt becomes something people
/// dismiss without reading.
///
/// The gap is the ambiguous outcome. A game that drew a window and then exited,
/// or ran with no window, or ran while its log filled with errors, is a case
/// Decanter deliberately refuses to record. Until now that refusal was the end
/// of it: the knowledge base learned nothing from the launches most worth
/// learning from. This is where the person who watched it happen gets to say.
///
/// It also carries the answer to a separate question. Someone running a setup
/// they chose by hand is not testing Decanter's suggestion, so a failure there
/// says nothing about the suggestion — the suggestion is *unjudged*, not
/// disproven, and the distinction has to survive into what gets recorded.
public struct Verdict: Sendable {
    let paths: Paths
    public init(paths: Paths) { self.paths = paths }

    /// Why someone moved off the recommended setup.
    ///
    /// A closed list, like every other reason in Decanter. Free text is the one
    /// place a game title could leak into knowledge that travels, so there is
    /// no free text — and "other" is a real answer rather than a prompt to
    /// write one.
    public enum SwitchReason: String, Codable, Sendable, CaseIterable {
        case suggestionFailed
        case suggestionSlow
        case advisedElsewhere
        case experimenting
        case unstated

        public var label: String {
            switch self {
            case .suggestionFailed:  "the suggested setup did not work"
            case .suggestionSlow:    "the suggested setup worked but ran badly"
            case .advisedElsewhere:  "a guide or someone else advised this one"
            case .experimenting:     "just trying things"
            case .unstated:          "no reason given"
            }
        }
    }

    /// A launch waiting to be judged.
    public struct Pending: Codable, Sendable {
        public var gameID: UUID
        /// Held so the question can name the game. Local only — this file is
        /// never exported, and nothing derived from it reaches the knowledge
        /// base, which keys on situations and never on titles.
        public var gameName: String
        public var runtimeID: String
        public var backend: GraphicsBackend
        public var launchedAt: Date
        /// What Decanter saw for itself, in its own words.
        public var observed: String
        /// Whether this launch was on the setup Decanter suggested. A failure
        /// on a setup someone chose themselves is not evidence against the
        /// suggestion, and recording it as though it were would teach the
        /// knowledge base something untrue.
        public var onRecommendation: Bool
        /// The setup that was suggested instead, when this was not it.
        public var suggested: String?

        public init(gameID: UUID, gameName: String, runtimeID: String, backend: GraphicsBackend,
                    launchedAt: Date = Date(), observed: String,
                    onRecommendation: Bool, suggested: String? = nil) {
            self.gameID = gameID; self.gameName = gameName
            self.runtimeID = runtimeID; self.backend = backend
            self.launchedAt = launchedAt; self.observed = observed
            self.onRecommendation = onRecommendation; self.suggested = suggested
        }

        /// The question, in the form somebody can answer without thinking about
        /// what Decanter needs from them.
        public var question: String {
            "Decanter watched \(gameName) start and could not tell whether it worked — \(observed). Did it play?"
        }

        /// The second question, when there is one.
        public var switchQuestion: String? {
            guard !onRecommendation, let suggested else { return nil }
            return "This is not the setup Decanter suggested (\(suggested)). Why did you move off it?"
        }
    }

    public var path: URL { paths.root.appending(path: "pending-verdict.json") }

    /// Only the most recent unjudged launch is kept.
    ///
    /// A queue of them would be a queue of questions about launches nobody
    /// remembers, and a stale answer is worse than no answer: it records a
    /// guess as an observation.
    public func park(_ p: Pending) throws {
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(p).write(to: path, options: .atomic)
    }

    /// The launch waiting to be judged, if it is still worth asking about.
    ///
    /// Expires. Being asked on Friday how Tuesday's launch went produces an
    /// answer nobody should record, so an old question is dropped rather than
    /// asked.
    public func pending(within: TimeInterval = 60 * 60 * 24 * 2) -> Pending? {
        guard let d = try? Data(contentsOf: path),
              let p = try? JSONDecoder().decode(Pending.self, from: d) else { return nil }
        guard Date().timeIntervalSince(p.launchedAt) < within else { clear(); return nil }
        return p
    }

    public func clear() { try? FileManager.default.removeItem(at: path) }
}
