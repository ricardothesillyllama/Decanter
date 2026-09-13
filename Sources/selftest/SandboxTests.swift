import Foundation
import DecanterKit

/// Wine links Windows user folders to the Mac user's real ones, and one of
/// them was four levels deeper than the check looked.
func runUserFolderSandboxTests(_ t: Harness) {
    t.suite("No Windows user folder reaches the Mac user's own, however deep")
    let fm = FileManager.default
    let root = Fixture.dir("user-folders")
    let paths = Paths(root: root); try? paths.ensure()
    let pb = PrefixBuilder(paths: paths)
    let prefix = paths.bottles.appending(path: UUID().uuidString)
    let user = prefix.appending(path: "drive_c/users/tester")
    let outside = Fixture.dir("user-folders-host")
    try? fm.createDirectory(at: outside.appending(path: "Documents"), withIntermediateDirectories: true)
    try? fm.createDirectory(at: outside.appending(path: "Templates"), withIntermediateDirectories: true)
    try? Data("private".utf8).write(to: outside.appending(path: "Documents/private.txt"))

    // As Wine lays them out.
    try? fm.createDirectory(at: user.appending(path: "AppData/Roaming/Microsoft/Windows"), withIntermediateDirectories: true)
    try? fm.createSymbolicLink(atPath: user.appending(path: "Documents").path,
                               withDestinationPath: outside.appending(path: "Documents").path)
    try? fm.createSymbolicLink(atPath: user.appending(path: "AppData/Roaming/Microsoft/Windows/Templates").path,
                               withDestinationPath: outside.appending(path: "Templates").path)
    // Decanter's own: a protected save folder pointing into the store.
    let store = paths.saves.appending(path: "a-game/live/drive_c/users/__user__/AppData/LocalLow/Vendor")
    try? fm.createDirectory(at: store, withIntermediateDirectories: true)
    try? fm.createDirectory(at: user.appending(path: "AppData/LocalLow"), withIntermediateDirectories: true)
    try? fm.createSymbolicLink(atPath: user.appending(path: "AppData/LocalLow/Vendor").path, withDestinationPath: store.path)
    // And a link that stays inside the environment.
    try? fm.createDirectory(at: prefix.appending(path: "drive_c/Shared"), withIntermediateDirectories: true)
    try? fm.createSymbolicLink(atPath: user.appending(path: "Shared").path, withDestinationPath: "../../Shared")

    let fixed = (try? pb.sandboxUserFolders(prefix: prefix)) ?? []
    let isLink = { (u: URL) in (try? fm.destinationOfSymbolicLink(atPath: u.path)) != nil }
    t.expect(!isLink(user.appending(path: "Documents")), "a user folder linked to the Mac's Documents is replaced")
    t.expect(!isLink(user.appending(path: "AppData/Roaming/Microsoft/Windows/Templates")),
             "and so is Templates, four levels down, which the one-level check never saw")
    t.expect(!fm.fileExists(atPath: user.appending(path: "Documents/private.txt").path),
             "so nothing of the Mac user's is reachable through them")
    t.expect(fm.fileExists(atPath: outside.appending(path: "Documents/private.txt").path),
             "and nothing of the Mac user's was deleted in the process")
    t.equal(fixed.count, 2, "exactly those two are reported")
    t.expect(isLink(user.appending(path: "AppData/LocalLow/Vendor")),
             "a protected save folder, which points into Decanter's store on purpose, is kept")
    t.expect(isLink(user.appending(path: "Shared")), "and a link that stays inside the environment is left alone")
}
