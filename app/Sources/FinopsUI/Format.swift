import Foundation
import SwiftUI

enum Format {
    static func price(_ value: Double?) -> String {
        guard let value else { return "—" }
        let digits = abs(value) < 10 ? 4 : 2
        return value.formatted(.number.precision(.fractionLength(digits)).grouping(.automatic))
    }

    static func signed(_ value: Double?, digits: Int = 2) -> String {
        guard let value else { return "—" }
        return value.formatted(.number.precision(.fractionLength(digits)).sign(strategy: .always()))
    }

    static func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return signed(value) + "%"
    }

    static func compact(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value.formatted(.number.notation(.compactName).precision(.fractionLength(0...2)))
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }
}

/// Dark, dense terminal palette. Color carries meaning only: amber = context and
/// interactive, green/red = direction, blue = selection.
enum Palette {
    static let background = Color(red: 0.035, green: 0.035, blue: 0.04)
    static let surface = Color(red: 0.075, green: 0.075, blue: 0.085)
    static let raised = Color(red: 0.12, green: 0.12, blue: 0.135)
    static let border = Color.white.opacity(0.09)

    static let text = Color(red: 0.90, green: 0.90, blue: 0.88)
    static let muted = Color(red: 0.56, green: 0.56, blue: 0.58)
    static let accent = Color(red: 1.0, green: 0.66, blue: 0.10)     // amber
    static let onAccent = Color.black
    static let selection = Color(red: 0.20, green: 0.45, blue: 0.95)
    static let up = Color(red: 0.25, green: 0.80, blue: 0.40)
    static let down = Color(red: 1.0, green: 0.36, blue: 0.33)

    static func direction(_ value: Double?) -> Color {
        guard let value, value != 0 else { return text }
        return value > 0 ? up : down
    }
}

extension Font {
    static let terminal = Font.system(size: 13, design: .monospaced)
    static let terminalSmall = Font.system(size: 11, design: .monospaced)
    static let terminalLabel = Font.system(size: 10, weight: .semibold, design: .monospaced)
}

/// Small rectangular button used for tabs, ranges and toolbar actions.
struct TerminalButtonStyle: ButtonStyle {
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.terminalSmall.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(selected ? Palette.onAccent : Palette.accent)
            .background(
                selected ? Palette.accent : (configuration.isPressed ? Palette.raised : Palette.surface),
                in: RoundedRectangle(cornerRadius: 3)
            )
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(selected ? .clear : Palette.border))
            .contentShape(Rectangle())
    }
}

/// Section caption, e.g. "WATCHLIST".
struct SectionLabel: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(.terminalLabel)
            .foregroundStyle(Palette.muted)
            .tracking(1)
    }
}
