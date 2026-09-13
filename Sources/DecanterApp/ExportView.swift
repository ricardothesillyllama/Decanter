import SwiftUI
import DecanterKit

/// Taking a game somewhere else: how it is set up, or all of it.
///
/// Two very different things behind one door, because somebody reaching for
/// either is asking the same question — can I have this elsewhere? — and the
/// difference between them, a few hundred bytes that name nothing or the whole
/// game, is the first thing they need to see rather than something to find in
/// a second menu.
struct ExportSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let game: Game

    enum Kind: Hashable { case setupFile, app }
    /// Neither answer is preselected. Both cost something, and a default would
    /// be Decanter deciding which.
    enum Answer: Hashable { case undecided, no, yes }

    @State private var kind: Kind = .setupFile
    @State private var plan: BundlePlan?
    @State private var planError: String?
    @State private var includeSaves = false
    @State private var gptk: Answer = .undecided
    @State private var borrowed: Answer = .undecided

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Export \(game.name)").font(.title2.weight(.semibold)).lineLimit(2)
                Picker("", selection: $kind) {
                    Text("Setup File").tag(Kind.setupFile)
                    Text("Mac App").tag(Kind.app)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 260)
            }
            ScrollView {
                Group {
                    switch kind {
                    case .setupFile: setupPane
                    case .app: appPane
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 6)
            }
            .frame(minHeight: 260, maxHeight: 470)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                primary
            }
        }
        .padding(22)
        .frame(width: 560)
        .task(id: kind) { await measureIfNeeded() }
    }

    // MARK: Setup file

    private var setupPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How this game is set up — its Wine build, graphics, launch switches and settings — in a file of a few hundred bytes. Someone with the same game applies it in Decanter and gets the same setup. The file names the setup, never the game, and holds no paths.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let file = model.setupFile(for: game) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(file.title).font(.callout.weight(.medium))
                        Text(file.fileName).font(.evidence).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }
                if !file.launchArguments.isEmpty || !file.environment.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("It carries launch switches and settings. Read them before sharing it, in case one names the game.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(Palette.caution)
                            .fixedSize(horizontal: false, vertical: true)
                        if !file.launchArguments.isEmpty {
                            Text(file.launchArguments.joined(separator: " ")).font(.evidence)
                        }
                        ForEach(file.environment.sorted(by: { $0.key < $1.key }), id: \.key) { pair in
                            Text("\(pair.key)=\(pair.value)").font(.evidence)
                        }
                    }
                    .textSelection(.enabled)
                }
            }
            Divider().padding(.vertical, 2)
            HStack(spacing: 8) {
                Text("Somebody gave you one?").font(.callout).foregroundStyle(.secondary)
                Button("Apply a Setup File…") {
                    dismiss()
                    Task { @MainActor in model.chooseSetupFileToApply(game) }
                }
                .controlSize(.small)
                .disabled(model.busy != nil)
            }
        }
    }

    // MARK: Mac app

    private var appPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(plan?.needsGPTK == true
                 ? "One Mac app holding the game and how it is set up. The Game Porting Toolkit cannot go in it, so whoever opens it points it at their own copy the first time."
                 : "One Mac app holding the game, the Wine it runs on and its Windows environment. Open it and the game starts; the Mac it is opened on does not need Decanter.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.bundleLauncher == nil {
                Label(Help.noLauncher, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(Palette.caution)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let planError {
                Label(planError, systemImage: "xmark.octagon")
                    .font(.callout).foregroundStyle(Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let plan {
                sizes(plan)
                saves(plan)
                if plan.needsGPTK {
                    choice(title: "The Game Porting Toolkit cannot go in an app",
                           detail: "Apple's licence does not allow passing it on, and a Windows environment it built carries parts of it."
                               + (plan.wineAlternative.map {
                                   " \($0.label) has worked for games like this one. To bundle Wine instead, switch to it under How this game is set up, check the game still runs, and export again."
                               } ?? "")
                               + " Built anyway, the app asks for a copy on the Mac that opens it — its disk image or the app. Nothing is downloaded.",
                           selection: $gptk,
                           no: "Don't build it",
                           yes: "Build it; whoever opens it brings their own")
                }
                if !plan.borrowedLibraries.isEmpty {
                    choice(title: "\(plan.runtime.id) holds \(plural(plan.borrowedLibraries.count, "library", "libraries")) from the Game Porting Toolkit",
                           detail: "They cannot be passed on: \(plan.borrowedLibraries.joined(separator: ", ")). Without them the game may lose video or audio.",
                           selection: $borrowed,
                           no: "Leave this game unbundled",
                           yes: "Build it without them")
                }
                GroupBox {
                    Label {
                        Text(Export.disclaimer).font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "hand.raised")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }
                Text("Signed on this Mac only, not notarised. Another Mac refuses to open it until it is let through once, with xattr -dr com.apple.quarantine followed by the app.")
                    .font(.caption).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Measuring the game, its Wine and its Windows environment…")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func sizes(_ plan: BundlePlan) -> some View {
        let total = plan.sizes.total - (includeSaves ? 0 : plan.sizes.saves)
        return GroupBox {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 5) {
                sizeRow("Game", plan.sizes.game)
                if !plan.needsGPTK {
                    sizeRow("Wine", plan.sizes.runtime)
                    sizeRow("Windows environment", plan.sizes.prefix)
                }
                if plan.sizes.components > 0 { sizeRow("Graphics layer", plan.sizes.components) }
                if includeSaves { sizeRow("Saves", plan.sizes.saves) }
                Divider().gridCellUnsizedAxes(.horizontal)
                GridRow {
                    Text("About").fontWeight(.medium)
                    Text(size(total)).fontWeight(.medium).monospacedDigit()
                        .gridColumnAlignment(.trailing)
                }
            }
            .font(.callout)
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sizeRow(_ label: String, _ bytes: Int) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(size(bytes)).monospacedDigit()
        }
    }

    private func saves(_ plan: BundlePlan) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: $includeSaves) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Include saves").font(.callout)
                    Text(plan.sizes.saves == 0
                         ? "Decanter found no saves for this game."
                         : "Leave off to give it to someone. Turn on to keep a copy for yourself — \(size(plan.sizes.saves)) of saves go in as a snapshot.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(plan.sizes.saves == 0)
            if plan.registryKeysInEnvironment > 0 {
                Text("\(plural(plan.registryKeysInEnvironment, "registry setting")) the game wrote stay in its Windows environment either way.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.leading, 20)
            }
        }
    }

    private func choice(title: String, detail: String, selection: Binding<Answer>,
                        no: String, yes: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(Palette.caution)
            Text(detail).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("", selection: selection) {
                Text(no).tag(Answer.no)
                Text(yes).tag(Answer.yes)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.caution.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.caution.opacity(0.30), lineWidth: 0.5))
    }

    // MARK: Actions

    @ViewBuilder private var primary: some View {
        switch kind {
        case .setupFile:
            Button("Export Setup File…") {
                dismiss()
                Task { @MainActor in model.exportSetupFile(game) }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(model.busy != nil || model.setupFile(for: game) == nil)
        case .app:
            Button("Build App…") {
                guard let plan else { return }
                let options = BundleOptions(includeSaves: includeSaves,
                                            bringYourOwnGPTK: gptk == .yes,
                                            shipWithoutBorrowedLibraries: borrowed == .yes)
                dismiss()
                Task { @MainActor in model.buildBundle(plan, options: options) }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canBuild)
            .help(canBuild ? "Choose a folder, then the app is built there. Nothing is launched."
                           : "Answer the questions above first.")
        }
    }

    private var canBuild: Bool {
        guard let plan, model.bundleLauncher != nil, model.busy == nil else { return false }
        if plan.needsGPTK && gptk != .yes { return false }
        if !plan.borrowedLibraries.isEmpty && borrowed != .yes { return false }
        return true
    }

    private func measureIfNeeded() async {
        guard kind == .app, plan == nil, planError == nil else { return }
        switch await model.planBundle(game) {
        case .success(let p): plan = p
        case .failure(let e): planError = e.localizedDescription
        }
    }
}
