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
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1080, height: 760)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Refresh") { model.reload() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
    }
}
