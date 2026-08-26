import SwiftUI
import DecanterKit

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

    /// Surfaces for grouped rows. Kept semantic so the two list-shaped
    /// controls — graphics options and setup pieces — cannot drift apart.
    static let card     = Color(nsColor: .controlBackgroundColor)
    static let hairline = Color.secondary.opacity(0.18)
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


/// One graphics option: what it is, what Decanter thinks, and — for the ones
/// it did not pick — when you would reach for it.
///
/// A row rather than a segment because there are now three things to say per
/// option and a segmented control has room for one. The recommendation is a
/// badge, never part of the name: naming an option "Compatibility" told every
/// stuck user to pick the slowest one.
struct BackendRow: View {
    let backend: GraphicsBackend
    let selected: Bool
    let recommended: Bool
    let disabled: Bool
    let choose: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: choose) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Palette.accent(scheme) : Color.secondary)
                    .imageScale(.large)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: Help.symbol(backend)).imageScale(.small)
                            .foregroundStyle(.secondary)
                        Text(Help.plainName(backend)).font(.body)
                        if recommended {
                            Text("Recommended for this game")
                                .font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(Palette.running.opacity(0.16)))
                                .foregroundStyle(Palette.running)
                        }
                    }
                    Text(Help.rawTechnicalName(backend) + " — " + Help.oneLiner(backend))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !recommended && !selected {
                        Text(Help.whenToTry(backend))
                            .font(.caption).foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.55 : 1)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
