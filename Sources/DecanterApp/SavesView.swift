import SwiftUI
import DecanterKit

/// One place for every game's saves, so nothing requires walking into a
/// bottle's UUID and guessing a vendor folder name.
struct SavesView: View {
    @EnvironmentObject var model: AppModel
    @State private var query = ""
    @State private var selected: UUID?
    @State private var confirmRestore: SaveStore.Snapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if query.isEmpty { browser } else { searchResults }
        }
        .navigationTitle("Saves")
        .onAppear { model.refreshSaves() }
        .confirmationDialog("Restore this snapshot?",
                            isPresented: Binding(get: { confirmRestore != nil },
                                                 set: { if !$0 { confirmRestore = nil } }),
                            titleVisibility: .visible) {
            Button("Restore", role: .destructive) {
                if let s = confirmRestore, let g = selectedGame { model.restoreSnapshot(g, s.name) }
                confirmRestore = nil
            }
            Button("Cancel", role: .cancel) { confirmRestore = nil }
        } message: {
            Text("Files in this snapshot will overwrite the current ones. Anything saved since will be lost — take a snapshot first if you are unsure.")
        }
    }

    private var selectedGame: Game? { model.games.first { $0.id == selected } }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Saves").font(.system(size: 26, weight: .semibold))
                    Text("Every game's save files in one place. Protect them so rebuilding a game cannot lose progress.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                InfoButton(text: Help.savesPane, title: "How saves are handled")
                Spacer()
                Button {
                    model.snapshotAll()
                } label: { Label("Snapshot All", systemImage: "camera.on.rectangle") }
                    .help(Help.snapshotAll)
                Button {
                    model.externaliseAll()
                } label: { Label("Protect All", systemImage: "lock.shield") }
                    .help(Help.externaliseAll)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([model.savesRoot])
                } label: { Image(systemName: "folder") }
                    .help("Open the saves store in Finder.")
            }
            .disabled(model.busy != nil)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search every game's saves", text: $query)
                    .textFieldStyle(.plain)
                    .onSubmit { model.searchSaves(query) }
                    .onChange(of: query) { _, v in model.searchSaves(v) }
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.tertiary)
                }
            }
            .padding(7)
            .background(RoundedRectangle(cornerRadius: 7).fill(.quaternary.opacity(0.5)))
            .help(Help.savesSearch)
        }
        .padding(20)
    }

    private var browser: some View {
        HSplitView {
            List(selection: $selected) {
                ForEach(model.games) { g in
                    let o = model.saveOverview[g.id]
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(g.name).lineLimit(1)
                            if model.externalised.contains(g.id) {
                                Image(systemName: "lock.shield.fill")
                                    .imageScale(.small).foregroundStyle(Palette.running)
                                    .help(Help.protectedBadge)
                            }
                        }
                        Text(o.map { "\($0.files) files · \(fmt($0.bytes)) · \($0.snapshots) snapshots" }
                             ?? "scanning…")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    .tag(g.id)
                }
            }
            .frame(minWidth: 230, idealWidth: 270)

            if let g = selectedGame { detail(for: g) }
            else {
                VStack(spacing: 8) {
                    Image(systemName: "externaldrive.badge.checkmark")
                        .font(.system(size: 34, weight: .light)).foregroundStyle(.tertiary)
                    VStack(spacing: 6) {
                        Text("Select a game to see its saves").foregroundStyle(.secondary)
                        Text("Saves are found by comparing the game's Windows environment against a clean one, so anything the game wrote shows up here.")
                            .font(.caption).foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center).frame(maxWidth: 380)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func detail(for g: Game) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(g.name).font(.title3).bold()
                    Spacer()
                    Button("Snapshot Now") { model.snapshotSaves(g) }
                        .help(Help.snapshotNow)
                    if !model.externalised.contains(g.id) {
                        Button("Protect") { model.externaliseSaves(g) }
                            .help(Help.externaliseOne)
                    }
                }
                .disabled(model.busy != nil)

                if model.externalised.contains(g.id) {
                    Label("Protected. These saves are stored outside the game's Windows environment, so rebuilding it cannot lose them.",
                          systemImage: "checkmark.shield")
                        .font(.caption).foregroundStyle(Palette.running)
                } else {
                    Label("Not protected yet. These saves sit inside the game's Windows environment — press Protect so rebuilding it cannot erase them.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(Palette.caution)
                }

                let files = model.saveFiles[g.id] ?? []
                GroupBox("Files (\(files.count))") {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(files.prefix(120).enumerated()), id: \.offset) { _, f in
                            HStack(spacing: 8) {
                                Text(fmt(f.bytes)).font(.evidence).foregroundStyle(.tertiary)
                                    .frame(width: 62, alignment: .trailing)
                                if let l = f.label { FactChip(text: l) }
                                Text(shorten(f.relPath)).font(.caption).lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        if files.count > 120 {
                            Text("… and \(files.count - 120) more").font(.caption).foregroundStyle(.tertiary)
                        }
                        if files.isEmpty {
                            Text("No saves yet. Play the game once, save inside it, and the files will appear here.")
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                let snaps = model.snapshots[g.id] ?? []
                GroupBox("Snapshots (\(snaps.count))") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(snaps) { s in
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(s.created.formatted(date: .abbreviated, time: .shortened))
                                        .font(.callout)
                                    Text("\(s.fileCount) files · \(fmt(s.bytes))\(s.hasRegistry ? " · registry" : "")\(s.note.map { " · \($0)" } ?? "")")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Restore") { confirmRestore = s }
                                    .controlSize(.small)
                                    .help(Help.restoreSnapshot)
                                Button { NSWorkspace.shared.activateFileViewerSelecting([s.url]) }
                                    label: { Image(systemName: "folder") }
                                    .controlSize(.small).buttonStyle(.borderless)
                                    .help("Reveal this snapshot in Finder.")
                            }
                            .disabled(model.busy != nil)
                            Divider()
                        }
                        if snaps.isEmpty {
                            Text("No snapshots yet. Decanter takes one automatically before anything that could lose saves, and you can take one yourself at any time.")
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(20)
        }
    }

    private var searchResults: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                if model.searchHits.isEmpty {
                    Text("No save files match “\(query)”.")
                        .foregroundStyle(.secondary).padding(20)
                }
                ForEach(Array(model.searchHits.enumerated()), id: \.offset) { _, h in
                    HStack(spacing: 8) {
                        FactChip(text: h.game)
                        Text(fmt(h.bytes)).font(.evidence).foregroundStyle(.tertiary)
                        Text(shorten(h.relPath)).font(.caption).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(h.modified.formatted(date: .numeric, time: .omitted))
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 20).padding(.vertical, 2)
                }
            }
            .padding(.vertical, 10)
        }
    }

    private func fmt(_ b: Int) -> String {
        if b >= 1_000_000 { return String(format: "%.1f MB", Double(b) / 1e6) }
        if b >= 1_000 { return "\(b / 1000) KB" }
        return "\(b) B"
    }

    /// Save paths are long and repetitive; show the meaningful tail.
    private func shorten(_ p: String) -> String {
        let parts = p.split(separator: "/").map(String.init)
        if let i = parts.firstIndex(where: { $0 == "LocalLow" || $0 == "Roaming" || $0 == "Local" || $0 == "ProgramData" }) {
            return parts[i...].joined(separator: "/")
        }
        return parts.suffix(4).joined(separator: "/")
    }
}
