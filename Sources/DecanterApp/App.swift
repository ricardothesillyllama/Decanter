import SwiftUI

@main
struct DecanterApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                // The first-run wizard is a tall sheet. A window shorter than
                // this clips it, which is a bad first thing to see.
                .frame(minWidth: 820, idealWidth: 1080,
                       minHeight: 640, idealHeight: 760)
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
