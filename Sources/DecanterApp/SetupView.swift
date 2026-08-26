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
    @EnvironmentObject var model: AppModel
    @State private var dropTargeted = false
    @State private var showAdvanced = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let r = model.readiness {
                    piecesCard(r)
                    if !r.ready { nextStep(r) }
                    advanced(r)
                }
                ActivityList()
            }
            .padding(22)
            .frame(maxWidth: 760, alignment: .leading)
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Setup").font(.largeTitle).bold()
            Text(model.readiness?.headline ?? "Checking…")
                .font(.title3).foregroundStyle(model.readiness?.ready == true ? Palette.running : .secondary)
            Text("Decanter never downloads any of this. You fetch it once, hand it over, and Decanter keeps its own copy — so nothing disappearing from the internet can break a game you have already set up.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func piecesCard(_ r: Readiness) -> some View {
        VStack(spacing: 0) {
            ForEach(r.pieces) { piece in
                PieceRow(piece: piece)
                if piece.id != r.pieces.last?.id { Divider().padding(.leading, 40) }
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.hairline))
    }

    /// One instruction at a time. A list of five missing things is a wall; the
    /// next single thing to do is an instruction.
    @ViewBuilder private func nextStep(_ r: Readiness) -> some View {
        if let next = r.missingRequired.first {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "arrow.right.circle.fill")
                    .foregroundStyle(Palette.accent(scheme)).imageScale(.large)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Next: \(next.title)").font(.callout).bold()
                    Text(next.detail ?? next.why).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 9).fill(Palette.accent(scheme).opacity(0.10)))
        }
    }

    @ViewBuilder private func advanced(_ r: Readiness) -> some View {
        DisclosureGroup(isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 10) {
                if let h = model.health {
                    ForEach(h.pinnedRuntimes) { rt in
                        LabeledContent(rt.id) {
                            Text("\(rt.version) · \(rt.supports32Bit ? "32-bit capable" : "64-bit only") · \(rt.backends.map(Help.rawTechnicalName).joined(separator: ", "))")
                        }
                    }
                    if h.pinnedRuntimes.isEmpty { Text("No Wine builds copied yet.") }
                    Divider()
                    LabeledContent("macOS", value: "\(h.macOSMajor)")
                    if !h.discovered.isEmpty {
                        LabeledContent("Found on this Mac",
                                       value: h.discovered.map { "\($0.kind.rawValue) \($0.version)" }
                                        .joined(separator: ", "))
                    }
                }
                Button("Re-check This Mac") { model.pinDiscovered() }
                    .controlSize(.small).disabled(model.busy != nil)
            }
            .font(.evidence).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
        } label: {
            Text("Advanced").font(.callout).foregroundStyle(.secondary)
        }
    }
}

/// One thing Decanter needs: whether it is there, what it is for, and the one
/// action that would get it. Shared by the Setup page and the wizard so the
/// two can never describe the same piece differently.
struct PieceRow: View {
    @EnvironmentObject var model: AppModel
    let piece: Readiness.Piece
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint).imageScale(.large)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(piece.title).font(.body)
                    if !piece.required && piece.state != .present {
                        Text("Optional").font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.secondary.opacity(0.14)))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(piece.why).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let d = piece.detail {
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
                Button("Build It") { model.buildTemplate() }
                    .buttonStyle(.borderedProminent).disabled(model.busy != nil)
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
                    Button("Choose File…") { model.chooseSetupFile() }
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

/// First run only. Same rows as the Setup page, one screen, with the sentence
/// that explains why any of this is being asked of you — which is the part a
/// list of missing pieces cannot carry on its own.
struct SetupWizard: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var dropTargeted = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to Decanter").font(.title2).bold()
                Text("Windows games need a few pieces of software that Decanter is not allowed to give you. Get them once — they are free — and drop them on this window. Decanter keeps its own copy of each, so nothing can take them away again later.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let r = model.readiness {
                VStack(spacing: 0) {
                    ForEach(r.pieces) { piece in
                        PieceRow(piece: piece)
                        if piece.id != r.pieces.last?.id { Divider().padding(.leading, 40) }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10).fill(Palette.card))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(dropTargeted ? Palette.accent(scheme) : Palette.hairline,
                                  lineWidth: dropTargeted ? 2 : 1))

                Text(r.ready
                     ? "You are ready. Add a game whenever you like."
                     : "Drop a file anywhere on this window.")
                    .font(.callout)
                    .foregroundStyle(r.ready ? Palette.running : .secondary)
            }

            if let e = model.lastError {
                Label(e, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if let busy = model.busy {
                    ProgressView().controlSize(.small)
                    Text(busy).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                // Always dismissable. Someone who wants to look around before
                // installing anything should be able to, and a modal you cannot
                // leave is how an app gets deleted instead of set up.
                Button(model.readiness?.ready == true ? "Done" : "Later") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in model.accept(path: url) } }
                }
            }
            return true
        }
    }
}
