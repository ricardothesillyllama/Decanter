import SwiftUI

@main
struct DecanterApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                // The first-run wizard is a tall sheet. A window shorter than
                // this clips it, which is a bad first thing to see.
                .frame(minWidth: 820, idealWidth: 1080,
                       minHeight: 640, idealHeight: 760)
                // Coming back to the window is the moment the app is most
                // likely to be out of date: the usual way to change something
                // behind its back is to switch to a terminal and do it there.
                // Cheaper and more predictable than watching the files — a
                // watcher fires mid-write, and this cannot.
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { model.reload() }
                }
                .onAppear { model.startWatchingForReplacement() }
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1080, height: 760)
        .commands {
            // A Mac app with one keyboard shortcut is a Mac app somebody has
            // to reach for the mouse to use. Every verb here already existed
            // as a button somewhere; none of them had a key, and Add Game —
            // the app's primary action — could only be reached by clicking a
            // toolbar icon.
            CommandGroup(replacing: .newItem) {
                Button("Add Game…") { model.presentAddGamePanel() }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(model.busy != nil)
            }
            CommandGroup(after: .newItem) {
                Divider()
                Button("Refresh") { model.reload() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            CommandGroup(after: .toolbar) {
                Button(model.showInspector ? "Hide Details" : "Show Details") {
                    model.showInspector.toggle()
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(model.selectedGame == nil)
                Divider()
            }
            // Its own menu, because these are the four places the app has and
            // three of them were reachable only by aiming at a sidebar row.
            CommandMenu("Game") {
                Button("Play") { if let g = model.selectedGame { model.play(g) } }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.selectedGame == nil || model.busy != nil
                              || model.running.contains(model.selectedGame?.id ?? UUID()))
                Button("Stop") { if let g = model.selectedGame { model.stop(g) } }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!(model.selectedGame.map { model.running.contains($0.id) } ?? false))
                Divider()
                Button("Troubleshoot Launch") {
                    if let g = model.selectedGame { model.troubleshoot(g) }
                }
                .disabled(model.selectedGame == nil || model.busy != nil)
                Button("Diagnose Last Failure") {
                    if let g = model.selectedGame { model.diagnose(g) }
                }
                .disabled(model.selectedGame == nil || model.busy != nil)
                Button("Copy Problem Report") {
                    if let g = model.selectedGame { model.makeReport(g) }
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(model.selectedGame == nil || model.busy != nil)
                Divider()
                Button("Show Windows Files in Finder") {
                    if let g = model.selectedGame { model.revealPrefix(g) }
                }
                .disabled(model.selectedGame == nil)
            }
            CommandMenu("Go") {
                Button("Library") { model.selection = model.games.first.map { .game($0.id) } }
                    .keyboardShortcut("1", modifiers: .command)
                    .disabled(model.games.isEmpty)
                Button("All Saves") { model.selection = .saves }
                    .keyboardShortcut("2", modifiers: .command)
                Button("Windows Environments") { model.selection = .storage }
                    .keyboardShortcut("3", modifiers: .command)
                Button("Setup") { model.selection = .setup }
                    .keyboardShortcut("4", modifiers: .command)
            }
        }
    }
}
