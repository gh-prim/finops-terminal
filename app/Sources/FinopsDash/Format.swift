import FinopsCore
import Foundation
import SwiftUI

public enum Format {
    public static func number(_ value: Double?, digits: Int = 2) -> String {
        guard let value else { return "—" }
        if value != 0, abs(value) < 0.01 {
            // Small quantities (crypto sizes): keep four significant digits instead of "0.00".
            return value.formatted(.number.precision(.significantDigits(1...4)))
        }
        let fraction = value.rounded() == value && abs(value) >= 1 ? 0 : digits
        return value.formatted(.number.precision(.fractionLength(fraction)))
    }

    public static func date(_ t: Double?) -> String {
        guard let t else { return "—" }
        return Date(timeIntervalSince1970: t).formatted(.dateTime.year().month(.abbreviated).day())
    }

    public static func dateTime(_ t: Double?) -> String {
        guard let t else { return "—" }
        let date = Date(timeIntervalSince1970: t)
        return Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    /// Display a gateway value according to its kind.
    public static func value(_ value: JSONValue, kind: ValueKind) -> String {
        guard let n = value.number else { return value.string ?? "—" }
        switch kind {
        case .text: return value.string ?? "—"
        case .int: return n.formatted(.number.precision(.fractionLength(0)))
        case .number: return number(n)
        case .price: return price(n)
        case .compact: return compact(n)
        case .percent: return n.formatted(.number.precision(.fractionLength(2))) + "%"
        case .pctchange: return percent(n)
        case .change: return signed(n, digits: abs(n) < 10 ? 4 : 2)
        case .date: return date(n)
        case .datetime: return dateTime(n)
        }
    }

    public static func color(_ value: JSONValue, kind: ValueKind) -> Color {
        switch kind {
        case .pctchange, .change: Palette.direction(value.number)
        default: Palette.text
        }
    }

    public static func isNumeric(_ kind: ValueKind) -> Bool {
        ![.text, .date, .datetime].contains(kind)
    }

    public static func price(_ value: Double?) -> String {
        guard let value else { return "—" }
        if value != 0, abs(value) < 0.01 {
            // Sub-cent prices (PEPE, SHIB…): significant digits rather than 0.0000.
            return value.formatted(.number.precision(.significantDigits(4)))
        }
        let digits = abs(value) < 10 ? 4 : 2
        return value.formatted(.number.precision(.fractionLength(digits)).grouping(.automatic))
    }

    public static func signed(_ value: Double?, digits: Int = 2) -> String {
        guard let value else { return "—" }
        return value.formatted(.number.precision(.fractionLength(digits)).sign(strategy: .always()))
    }

    public static func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return signed(value) + "%"
    }

    public static func compact(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value.formatted(.number.notation(.compactName).precision(.fractionLength(0...2)))
    }

    public static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }
}

/// Dark, dense terminal palette. Color carries meaning only: amber = context and
/// interactive, green/red = direction, blue = selection.
public enum Palette {
    public static let background = Color(red: 0.035, green: 0.035, blue: 0.04)
    public static let surface = Color(red: 0.075, green: 0.075, blue: 0.085)
    public static let raised = Color(red: 0.12, green: 0.12, blue: 0.135)
    public static let border = Color.white.opacity(0.09)

    public static let text = Color(red: 0.90, green: 0.90, blue: 0.88)
    public static let muted = Color(red: 0.56, green: 0.56, blue: 0.58)
    public static let accent = Color(red: 1.0, green: 0.66, blue: 0.10)     // amber
    public static let onAccent = Color.black
    public static let selection = Color(red: 0.20, green: 0.45, blue: 0.95)
    public static let up = Color(red: 0.25, green: 0.80, blue: 0.40)
    public static let down = Color(red: 1.0, green: 0.36, blue: 0.33)

    public static func direction(_ value: Double?) -> Color {
        guard let value, value != 0 else { return text }
        return value > 0 ? up : down
    }
}

public extension Font {
    static let terminal = Font.system(size: 13, design: .monospaced)
    static let terminalSmall = Font.system(size: 11, design: .monospaced)
    static let terminalLabel = Font.system(size: 10, weight: .semibold, design: .monospaced)
}

/// Small rectangular button used for tabs, ranges and toolbar actions.
public struct TerminalButtonStyle: ButtonStyle {
    var selected = false

    public init(selected: Bool = false) {
        self.selected = selected
    }

    public func makeBody(configuration: Configuration) -> some View {
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
public struct SectionLabel: View {
    let title: String

    public init(title: String) {
        self.title = title
    }

    public var body: some View {
        Text(title.uppercased())
            .font(.terminalLabel)
            .foregroundStyle(Palette.muted)
            .tracking(1)
    }
}

/// Height of the screen area a view is shown in, so its main visual can fill it instead of
/// sitting at a fixed size above a black margin (0 = unknown, e.g. on the TV).
private struct ViewportHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

public extension EnvironmentValues {
    var viewportHeight: CGFloat {
        get { self[ViewportHeightKey.self] }
        set { self[ViewportHeightKey.self] = newValue }
    }
}
