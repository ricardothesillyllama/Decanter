import Foundation
import DecanterKit

/// Builds throwaway game folders that look structurally like the real thing.
enum Fixture {
    static let root = FileManager.default.temporaryDirectory.appending(path: "decanter-selftest")

    static func dir(_ tag: String) -> URL {
        let u = root.appending(path: "\(tag)-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// Structurally valid PE: MZ, e_lfanew, "PE\0\0", machine field.
    static func pe(machine: UInt16, strings: [String] = [], padTo: Int = 4096) -> Data {
        var d = Data(count: 0x80)
        d[0] = 0x4D; d[1] = 0x5A
        withUnsafeBytes(of: UInt32(0x40).littleEndian) { for (i, b) in $0.enumerated() { d[0x3c + i] = b } }
        d[0x40] = 0x50; d[0x41] = 0x45
        withUnsafeBytes(of: machine.littleEndian) { for (i, b) in $0.enumerated() { d[0x44 + i] = b } }
        for s in strings { d.append(contentsOf: Array(s.utf8)); d.append(0) }
        if d.count < padTo { d.append(Data(count: padTo - d.count)) }
        return d
    }

    @discardableResult
    static func write(_ dir: URL, _ name: String, _ data: Data = Data([0])) -> URL {
        let u = dir.appending(path: name)
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: u)
        return u
    }

    static func unity(name: String = "TestGame", machine: UInt16 = 0x8664,
                      modded: Bool = false, warmCache: Bool = false, d3d12: Bool = true,
                      unityVersion: String? = nil) -> URL {
        let d = dir("unity")
        write(d, "\(name).exe", pe(machine: machine))

        var apis = ["d3d11.dll", "dxgi.dll", "d3d9.dll"]
        if d3d12 { apis.append("d3d12.dll") }
        // The version is read out of UnityPlayer.dll, so that is where the
        // fixture has to put it. Unity also leaves 2018.3.0a1 in every build,
        // which is why the scan takes the most frequent match, not the first —
        // include the decoy so the fixture exercises that.
        if let v = unityVersion { apis += ["2018.3.0a1", v, v, v] }
        write(d, "UnityPlayer.dll", pe(machine: machine, strings: apis))
        write(d, "GameAssembly.dll", pe(machine: machine))
        write(d, "\(name)_Data/app.info")
        if modded { write(d, "doorstop_config.ini", Data("[General]\nenabled=true".utf8)) }
        if warmCache { write(d, "\(name).dxvk-cache", Data("DXVK".utf8)) }
        return d
    }

    static func renpy() -> URL {
        let d = dir("renpy")
        write(d, "VN.exe", pe(machine: 0x014c))
        write(d, "renpy/main.rpy"); write(d, "archive.rpa")
        return d
    }

    static func rpgMaker() -> URL {
        let d = dir("rpgm")
        write(d, "Game.exe", pe(machine: 0x014c))
        write(d, "nw.dll", pe(machine: 0x014c)); write(d, "package.nw")
        return d
    }

    static func godot() -> URL {
        let d = dir("godot")
        write(d, "Game.exe", pe(machine: 0x8664)); write(d, "Game.pck")
        return d
    }

    static func unreal(machine: UInt16 = 0x8664) -> URL {
        let d = dir("ue")
        write(d, "Shipping.exe", pe(machine: machine, strings: ["d3d12.dll", "dxgi.dll"]))
        write(d, "Engine/Binaries/marker.txt")
        return d
    }

    /// A packaged Unreal build: launcher at the root next to Engine/, with the
    /// real binary buried in <Game>/Binaries/Win64. Launching the inner one
    /// fails with "Failed to open descriptor file '../../X.uproject'".
    static func unrealPackaged(game: String = "SampleGame", launcher: String = "Start Sample Game.exe") -> URL {
        let d = dir("ue-packaged")
        write(d, launcher, pe(machine: 0x8664, padTo: 200_000))
        write(d, "Engine/Binaries/ThirdParty/marker.txt")
        write(d, "\(game)/Binaries/Win64/\(game)-Win64-Shipping.exe",
              pe(machine: 0x8664, strings: ["d3d11.dll", "d3d12.dll", "dxgi.dll"], padTo: 8_000_000))
        write(d, "\(game)/Content/Paks/pak.pak")
        return d
    }

    /// Decoys the executable picker must ignore, all larger than the real game.
    static func noisy() -> URL {
        let d = dir("noisy")
        write(d, "UnityCrashHandler64.exe", pe(machine: 0x8664, padTo: 3_000_000))
        write(d, "unins000.exe", pe(machine: 0x8664, padTo: 2_000_000))
        write(d, "vcredist_x64.exe", pe(machine: 0x8664, padTo: 5_000_000))
        write(d, "RealGame.exe", pe(machine: 0x8664, padTo: 700_000))
        write(d, "UnityPlayer.dll", pe(machine: 0x8664, strings: ["d3d11.dll"]))
        write(d, "RealGame_Data/app.info")
        return d
    }
}
