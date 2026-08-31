import SwiftUI
import DecanterKit
import UniformTypeIdentifiers

/// The page that answers "what does this thing need, and have I got it?".
///
/// It exists because the honest reason setup took six Terminal commands was
/// that the app never said what it wanted. Decanter still downloads nothing —
/// that rule is what keeps an installed copy working after an upstream
/// repository is deleted — but "we don't fetch it for you" was never a reason
/// to make people type. Every piece here can be dropped on the window.
struct SetupView: View {
    /// Numbers the outstanding items in the order they appear on screen.
    ///
    /// An earlier version numbered required items first, which is defensible
    /// and completely unreadable: the rows ran 1, 3, 4, 2 down the page.
    /// Numbers next to a list are read as its order, so they have to be it.
    ///
    /// Only the required pieces are numbered, and the page puts them first so
    /// that still holds. Numbering the optional ones turned a first run into a
    /// six-item errand across four websites, when the honest instruction is
    /// press this, fetch one file, press that — the graphics layers are a
    /// choice a game asks for later, and a numbered step reads as neither.
    static func stepNumbers(_ r: Readiness) -> [String: Int] {
        var out: [String: Int] = [:]
        var n = 1
        for piece in r.pieces where piece.required && piece.state != .present {
            out[piece.id] = n; n += 1
        }
        return out
    }

    @EnvironmentObject var model: AppModel
    @State private var dropTargeted = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        // Width is measured rather than inferred. ViewThatFits kept choosing the
        // stacked layout in a window with room to spare, because the wide
        // branch's ideal width is larger than what it would actually settle for.
        GeometryReader { geo in
            let wide = geo.size.width >= 880
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    // Two columns when there is room. This page has no
                    // inspector, so the width was going to waste — and the
                    // aside answers what someone asks next: "why do I have to
                    // fetch these?" and "what does it already have?".
                    if wide {
                        HStack(alignment: .top, spacing: 18) {
                            VStack(alignment: .leading, spacing: 18) {
                                mainColumn
                                ActivityList(entries: model.globalActivity)
                            }
                            aside.frame(width: 268)
                        }
                    } else {
                        mainColumn
                        aside
                        ActivityList(entries: model.globalActivity)
                    }
                }
                .padding(22)
                .frame(maxWidth: 1100, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(dropTargeted ? Palette.accent(scheme).opacity(0.08) : Color.clear)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in model.accept(path: url) } }
                }
            }
            return true
        }
    }

    /// What the page leads with, and it changes completely once this Mac can
    /// run something.
    ///
    /// Before: one instruction. The checklist is six rows, five of which were
    /// downloads from five places, and the *shape* of that page taught somebody
    /// "this is complicated" before they had read a word of it. It is a
    /// procurement list, and procurement is not the job — it is the toll the
    /// no-download rule was charging the user.
    ///
    /// After: the checklist, because "what am I missing?" is a real question
    /// that gets asked again every time a game misbehaves, and it is the right
    /// answer to it. The same rows, demoted from an instruction to a status.
    @ViewBuilder private var mainColumn: some View {
        if let r = model.readiness {
            if r.ready {
                piecesCard(r)
            } else {
                packCard
                DisclosureGroup("Set these up individually") {
                    piecesCard(r)
                        .padding(.top, 10)
                }
                .font(.callout)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Palette.card))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.hairline))
            }
        }
    }

    /// The one-file path, and the whole of what a first run should ask of
    /// anybody.
    ///
    /// Getting it and taking it in are one card because they are one action
    /// separated by a download. They were two — a checklist that sent people to
    /// three releases pages, and a separate "already downloaded it?" card — and
    /// two cards about how to set up is the duplication the rest of this app
    /// spent a release removing.
    ///
    /// The link is to the file, not to a releases page. A page listing
    /// seventeen assets is not an instruction, and being sent to three of them
    /// is what made "Decanter downloads nothing" something the user paid for
    /// rather than a guarantee they were given.
    private var packCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Get everything in one file", systemImage: "shippingbox")
                    .font(.title3).bold()
                Text("One download, about 200 MB, holding the three pieces Decanter needs. Your browser fetches it; Decanter reads it off your disk. Nothing here reaches the internet on its own.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button {
                    NSWorkspace.shared.open(Readiness.packSource)
                } label: {
                    Label("Get the Pack", systemImage: "arrow.down.circle.fill")
                        .frame(minWidth: 130)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Button("What is in it?") { NSWorkspace.shared.open(Readiness.packNotes) }
                    .controlSize(.large)
            }

            Text("When it has downloaded, drag it onto this window. Or let Decanter look for it:")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)

            if !model.downloadFindings.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.downloadFindings) { f in
                        Toggle(isOn: Binding(
                            get: { model.chosenDownloads.contains(f.id) },
                            set: { on in
                                if on { model.chosenDownloads.insert(f.id) }
                                else { model.chosenDownloads.remove(f.id) }
                            })) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(f.summary).font(.callout)
                                Text(f.url.lastPathComponent)
                                    .font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            } else if model.lookedInDownloads {
                Text("Nothing in Downloads is something Decanter can use yet.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                ActionButton(title: model.lookedInDownloads ? "Look Again" : "Look in Downloads",
                             systemImage: "magnifyingglass", key: "look",
                             blurb: "Reads the file names in your Downloads folder. Installs nothing.") {
                    model.lookInDownloads()
                }
                if !model.downloadFindings.isEmpty {
                    ActionButton(title: "Use \(model.chosenDownloads.count) Selected",
                                 systemImage: "square.and.arrow.down",
                                 key: "acceptChosen",
                                 blurb: "Takes Decanter's own copy of each one, so nothing later can move it.") {
                        model.acceptChosenDownloads()
                    }
                    .disabled(model.chosenDownloads.isEmpty)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.hairline))
    }

    /// One header, two moods. On a Mac that cannot run anything yet this is the
    /// first thing a new user sees, so it opens by saying what to do. Once
    /// everything is present it becomes a status page and gets out of the way.
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(firstRun ? "Welcome to Decanter" : "Setup")
                .font(.largeTitle).bold()
            if firstRun {
                Text("Decanter needs one free download before it can run a game. Get the pack below, then **drag it onto this window** — Decanter takes it from there, and the whole thing takes about a minute.")
                    .font(.title3).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(model.readiness?.headline ?? "Checking…")
                    .font(.title3)
                    .foregroundStyle(model.readiness?.ready == true ? Palette.running : .secondary)
            }
            Text("Decanter never downloads anything by itself. That way nothing can vanish from the internet later and leave your games broken.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var firstRun: Bool { model.readiness?.ready == false && model.games.isEmpty }

    private func piecesCard(_ r: Readiness) -> some View {
        let steps = Self.stepNumbers(r)
        let needed = r.pieces.filter(\.required)
        let extras = r.pieces.filter { !$0.required }
        return VStack(spacing: 0) {
            rows(needed, steps: steps)
            if !extras.isEmpty {
                extrasHeader
                rows(extras, steps: [:])
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.hairline))
    }

    @ViewBuilder private func rows(_ pieces: [Readiness.Piece], steps: [String: Int]) -> some View {
        ForEach(pieces) { piece in
            PieceRow(piece: piece, step: steps[piece.id])
            if piece.id != pieces.last?.id { Divider().padding(.leading, 40) }
        }
    }

    /// The line that turns the rest of the card from "four more things to do"
    /// into "things you can add when something wants one".
    private var extrasHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Graphics — optional")
                .font(.callout).bold()
            Text("A game runs without these. Decanter says which one to add when a game actually needs it.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 8)
        .background(Palette.hairline.opacity(0.35))
        .overlay(alignment: .top) { Divider() }
    }

    /// The column beside the steps: the question people ask next, then the
    /// facts about this specific Mac.
    private var aside: some View {
        VStack(alignment: .leading, spacing: 14) {
            asideCard("Why do I fetch these myself?", icon: "questionmark.circle") {
                Text("Decanter's predecessor, Whisky, downloaded them for you. When the place it downloaded from was deleted, every copy already installed stopped being able to finish setting itself up.")
                Text("Fetching them once is more work. It also means nothing on the internet can reach into your Mac and break a game that already works.")
            }
            asideCard("On this Mac", icon: "desktopcomputer") {
                if let h = model.health {
                    if h.pinnedRuntimes.isEmpty {
                        Text("Nothing copied in yet.")
                    } else {
                        ForEach(h.pinnedRuntimes) { rt in
                            Markdown(text: "**\(rt.id)** — \(rt.supports32Bit ? "32-bit capable" : "64-bit only")\n\(rt.backends.map(Help.rawTechnicalName).joined(separator: ", "))")
                        }
                    }
                    if !h.discovered.isEmpty {
                        Divider()
                        Text("Also installed elsewhere: " + h.discovered.map { "\($0.kind.rawValue) \($0.version)" }.joined(separator: ", "))
                    }
                    Divider()
                    Text("macOS \(h.macOSMajor)")
                    Button("Re-check This Mac") { model.pinDiscovered() }
                        .controlSize(.small).disabled(model.busy != nil)
                        .padding(.top, 2)
                }
            }
            asideCard("Shared knowledge", icon: "arrow.left.arrow.right") {
                Text("Decanter learns from the games on this Mac. Someone else's Decanter can hand you what theirs learned — a file, by whatever means you like.")
                // Said here because the alternative people expect is an
                // automatic update, and the reason there is none is the same
                // reason Whisky's users lost their runtimes: something that
                // fetches is something that can reach in.
                Text("Decanter never fetches this, and nothing leaves this Mac unless you export it.")
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button("Import a File…") { model.importKnowledge() }
                        .controlSize(.small).disabled(model.busy != nil)
                    Button("Export…") { model.exportKnowledge() }
                        .controlSize(.small).disabled(model.busy != nil)
                }
                ReactionNote(key: "kbImport")
                ReactionNote(key: "kbExport")
                Text("An export carries situations and outcomes: no game names, no paths, no machine identifiers. There is no setting for that — a name is never recorded.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private func asideCard<C: View>(_ title: String, icon: String,
                                    @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: icon)
                .font(.callout).bold()
            content()
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.hairline))
    }

}

/// One thing Decanter needs: whether it is there, what it is for, and the one
/// action that would get it. Shared by the Setup page and the wizard so the
/// two can never describe the same piece differently.
struct PieceRow: View {
    @EnvironmentObject var model: AppModel
    let piece: Readiness.Piece
    /// Position among the things still to do, if this is one of them. A list of
    /// five items reads as a list; the outstanding ones numbered read as
    /// instructions, which is what someone opening this actually wants.
    var step: Int? = nil
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if let step, piece.state != .present {
                    Text("\(step)")
                        .font(.callout.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(tint))
                } else {
                    Image(systemName: symbol)
                        .foregroundStyle(tint).imageScale(.large)
                }
            }
            .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(piece.title).font(.body)
                    // Name, one reason, one button. Four stacked lines per row
                    // — reason, instruction, exact versions — was a wall for
                    // someone who only wants to know what to click, and the
                    // rest is reference material you consult once.
                    PieceInfoButton(piece: piece)
                    if !piece.required && piece.state != .present {
                        Text("Optional").font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.secondary.opacity(0.14)))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(piece.why).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // Once a piece is present its detail reports the installed
                // version rather than telling you what to do, which is worth a
                // line. While it is missing, that line is an instruction the
                // buttons beneath already give.
                if let d = piece.detail, piece.state == .present {
                    Text(d).font(.caption).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if piece.state != .present { actions }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 8) {
            switch piece.id {
            case "rosetta":
                Button("Install Rosetta 2") { model.installRosetta() }
                    .disabled(model.busy != nil)
            case "template":
                // `accepts` is nil while there is nothing to build from, so the
                // row explains itself rather than offering a button that fails.
                if piece.accepts != nil {
                    Button("Build It") { model.buildTemplate() }
                        .buttonStyle(.borderedProminent).disabled(model.busy != nil)
                }
            default:
                if piece.state == .foundNotPinned {
                    Button("Use It") { model.pinDiscovered() }
                        .buttonStyle(.borderedProminent).disabled(model.busy != nil)
                } else {
                    if let src = piece.source, let label = piece.sourceLabel {
                        // Opens in the user's browser. Decanter itself makes no
                        // network request — that is the guarantee the whole
                        // project rests on — but pointing at the page costs
                        // nothing and saves a search.
                        Button {
                            model.openSource(src)
                        } label: {
                            Label(label, systemImage: "arrow.up.forward.square")
                        }
                    }
                    // "Choose File…" describes the dialog. This describes the
                    // moment the person is in: they have just downloaded
                    // something and want to give it to Decanter.
                    Button("Add Downloaded File…") { model.chooseSetupFile() }
                        .disabled(model.busy != nil)
                }
            }
        }
        .controlSize(.small)
        .padding(.top, 3)
    }

    private var symbol: String {
        switch piece.state {
        case .present: "checkmark.circle.fill"
        case .foundNotPinned: "arrow.down.circle.fill"
        case .missing: piece.required ? "exclamationmark.circle.fill" : "circle.dashed"
        }
    }

    private var tint: Color {
        switch piece.state {
        case .present: Palette.running
        case .foundNotPinned: Palette.accent(scheme)
        case .missing: piece.required ? Palette.danger : Color.secondary
        }
    }
}


/// What this piece is, in full: the longer instruction, then the exact project
/// and version for someone who already knows the words.
///
/// A popover rather than a hover tooltip, because a version string is the kind
/// of thing people select and copy — and because this is how every other
/// explanation in the app already works.
struct PieceInfoButton: View {
    let piece: Readiness.Piece
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "questionmark.circle")
                .imageScale(.small).foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .help(piece.spec ?? piece.why)
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 9) {
                Text(piece.title).font(.headline)
                Markdown(text: piece.why).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if let d = piece.detail {
                    Markdown(text: d).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let spec = piece.spec {
                    Divider()
                    Text(spec).font(.evidence).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(15).frame(width: 330)
        }
    }
}
