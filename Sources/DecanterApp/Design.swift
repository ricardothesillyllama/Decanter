import SwiftUI

/// Aesthetic: "inspection desk". Facts are set in monospace because they are
/// evidence, not decoration; chrome is SF Pro. One accent colour only — an
/// amber that belongs to the name — used exclusively for the primary action
/// and the running state, so it always means "this is the live thing".
enum Palette {
    static let amber      = Color(red: 0.80, green: 0.53, blue: 0.18)
    static let amberDeep  = Color(red: 0.62, green: 0.38, blue: 0.09)
    static let running    = Color(red: 0.30, green: 0.68, blue: 0.44)
    static let caution    = Color(red: 0.85, green: 0.60, blue: 0.20)
    static let danger     = Color(red: 0.79, green: 0.31, blue: 0.27)

    static func accent(_ scheme: ColorScheme) -> Color { scheme == .dark ? amber : amberDeep }
}

extension Font {
    /// Evidence, paths, hashes — anything the user should read as literal.
    static let evidence = Font.system(.caption, design: .monospaced)
    static let factLabel = Font.system(.caption2, design: .monospaced).weight(.medium)
}

/// A small capsule used for engine / bitness / backend facts.
struct FactChip: View {
    let text: String
    var tint: Color? = nil
    var icon: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).imageScale(.small) }
            Text(text).font(.factLabel)
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(
            Capsule().fill((tint ?? Color.secondary).opacity(0.13))
        )
        .overlay(
            Capsule().strokeBorder((tint ?? Color.secondary).opacity(0.25), lineWidth: 0.5)
        )
        .foregroundStyle(tint ?? Color.secondary)
    }
}

/// Status dot + label. Shape and text carry the meaning; colour only reinforces.
struct StatusDot: View {
    let color: Color
    var pulsing: Bool = false
    @State private var on = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .opacity(pulsing ? (on ? 1.0 : 0.35) : 1.0)
            .animation(pulsing ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true) : .default,
                       value: on)
            .onAppear { if pulsing { on = true } }
    }
}
