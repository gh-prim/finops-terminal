import FinopsCore
import FinopsRemote
import SwiftUI

enum Pad {
    static let background = Color(red: 0.035, green: 0.035, blue: 0.04)
    static let surface = Color(red: 0.08, green: 0.08, blue: 0.09)
    static let raised = Color(red: 0.15, green: 0.15, blue: 0.17)
    static let text = Color(red: 0.92, green: 0.92, blue: 0.90)
    static let muted = Color(red: 0.56, green: 0.56, blue: 0.58)
    static let amber = Color(red: 1.0, green: 0.66, blue: 0.10)
    static let yellow = Color(red: 0.98, green: 0.80, blue: 0.10)
    static let green = Color(red: 0.13, green: 0.62, blue: 0.30)
    static let red = Color(red: 0.84, green: 0.22, blue: 0.20)
}

/// A Bloomberg-style keyboard that drives the Mac's active panel: yellow
/// market-sector keys, amber function keys, red CANCEL, green GO, a numeric pad,
/// panel/layout keys and one-tap watchlist keys.
struct KeypadView: View {
    let link: RemoteLink

    @State private var buffer = ""
    @FocusState private var inputFocused: Bool

    private var state: RemoteState? { link.state }
    private var active: RemotePanel? {
        guard let state, state.panels.indices.contains(state.activePanel) else { return nil }
        return state.panels[state.activePanel]
    }

    private static let sectors = ["EQ", "ETF", "IDX", "FX", "CMD", "CRYPTO"]
    private static let venues = ["US", "LN", "FP", "GY", "NA", "SW", "JP", "HK"]

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width > geo.size.height
            ScrollView {
                VStack(spacing: 12) {
                    status
                    inputRow
                    if wide {
                        HStack(alignment: .top, spacing: 16) {
                            leftColumn
                            rightColumn.frame(width: 330)
                        }
                    } else {
                        leftColumn
                        rightColumn
                    }
                    watchlistStrip
                }
                .padding(16)
            }
        }
        .font(.system(size: 15, weight: .semibold, design: .monospaced))
        .background(Pad.background)
    }

    // MARK: Status and input

    private var status: some View {
        HStack(spacing: 10) {
            if let state, let active {
                Text("P\(state.activePanel + 1)").foregroundStyle(Pad.muted)
                Text(active.security ?? "—").foregroundStyle(Pad.amber)
                Text(([active.function] + active.args).joined(separator: " ")).foregroundStyle(Pad.text)
                if active.linked { Image(systemName: "link").foregroundStyle(Pad.muted) }
            } else {
                Text("Waiting for the Mac…").foregroundStyle(Pad.muted)
            }
            Spacer()
            if let message = state?.message {
                Text(message).foregroundStyle(message.hasPrefix("🔔") || message.hasPrefix("Added") ? Pad.amber : Pad.red)
                    .lineLimit(1)
            }
        }
        .font(.system(size: 16, weight: .semibold, design: .monospaced))
        .padding(12)
        .background(Pad.surface, in: RoundedRectangle(cornerRadius: 8))
    }

    private var inputRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right").foregroundStyle(Pad.amber)
            TextField("Ticker, then a yellow key and a function — e.g. AAPL  US  EQ  CHART", text: $buffer)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .focused($inputFocused)
                .onSubmit(go)
                .font(.system(size: 20, weight: .semibold, design: .monospaced))
            Key("⌫", style: .dark, width: 64) { if !buffer.isEmpty { buffer.removeLast() } }
                .accessibilityLabel("Delete")
        }
        .padding(.leading, 12)
        .padding(6)
        .background(Pad.surface, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Left: sectors, venues, functions, chart

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            group("Market sector") {
                keyRow(Self.sectors) { token in Key(token, style: .yellow) { append(token: token) } }
                keyRow(Self.venues) { token in Key(token, style: .yellowDim) { append(token: token) } }
            }
            group("Security") {
                functionGrid(FunctionID.allCases.filter { $0.group == .security }, columns: 5)
            }
            group("Markets & tools") {
                functionGrid(FunctionID.allCases.filter { $0.group != .security }, columns: 5)
            }
            group("Chart") {
                chartKeys
            }
        }
    }

    private func functionGrid(_ functions: [FunctionID], columns: Int) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: columns), spacing: 6) {
            ForEach(functions, id: \.self) { function in
                Key(function.rawValue, caption: function.title,
                    style: active?.function == function.rawValue ? .selected : .function) {
                    run(function)
                }
            }
        }
    }

    private var chartKeys: some View {
        let config = active?.function == FunctionID.chart.rawValue ? ChartConfig(args: active?.args ?? []) : ChartConfig()
        let ranges: [ChartRange] = [.d1, .d5, .m1, .m3, .m6, .ytd, .y1, .y5, .max]
        return VStack(spacing: 6) {
            keyRow(ranges.map(\.rawValue)) { label in
                Key(label, style: config.range.rawValue == label && active?.function == "CHART" ? .selected : .dark) {
                    var c = config
                    c.range = ChartRange(rawValue: label)!
                    sendChart(c)
                }
            }
            HStack(spacing: 6) {
                Key("CANDLE", style: config.style == .candle ? .selected : .dark) {
                    var c = config
                    c.style = c.style == .candle ? .line : .candle
                    sendChart(c)
                }
                Key("VOL", style: config.volume ? .selected : .dark) {
                    var c = config
                    c.volume.toggle()
                    sendChart(c)
                }
                ForEach([ChartConfig.Overlay.sma50, .sma200, .bollinger], id: \.self) { overlay in
                    Key(overlay.rawValue, style: config.overlays.contains(overlay) ? .selected : .dark) {
                        var c = config
                        if let i = c.overlays.firstIndex(of: overlay) { c.overlays.remove(at: i) } else { c.overlays.append(overlay) }
                        sendChart(c)
                    }
                }
                ForEach(ChartConfig.Study.allCases, id: \.self) { study in
                    Key(study.rawValue, style: config.studies.contains(study) ? .selected : .dark) {
                        var c = config
                        if let i = c.studies.firstIndex(of: study) { c.studies.remove(at: i) } else { c.studies.append(study) }
                        sendChart(c)
                    }
                }
            }
        }
    }

    // MARK: Right: numpad, CANCEL/BACK/GO, panels

    private var rightColumn: some View {
        VStack(spacing: 12) {
            group("Panels") {
                HStack(spacing: 6) {
                    ForEach(0..<4, id: \.self) { i in
                        Key("P\(i + 1)", style: state?.activePanel == i ? .selected : .dark) {
                            link.send([RemoteAction.panel1, .panel2, .panel3, .panel4][i])
                        }
                        .disabled(i >= (state?.panels.count ?? 0))
                        .opacity(i >= (state?.panels.count ?? 0) ? 0.35 : 1)
                    }
                }
                HStack(spacing: 6) {
                    Key("▭", caption: "1", style: state?.layout == 1 ? .selected : .dark) { link.send(.layout1) }
                    Key("▭▭", caption: "2", style: state?.layout == 2 ? .selected : .dark) { link.send(.layout2) }
                    Key("⊞", caption: "4", style: state?.layout == 4 ? .selected : .dark) { link.send(.layout4) }
                    Key("LINK", style: active?.linked == true ? .selected : .dark) { link.send(.toggleLink) }
                }
            }
            group("Keypad") {
                let rows = [["7", "8", "9", "<"], ["4", "5", "6", ">"], ["1", "2", "3", "."], ["0", "␣", "WATCH", "HELP"]]
                VStack(spacing: 6) {
                    ForEach(rows, id: \.self) { row in
                        HStack(spacing: 6) {
                            ForEach(row, id: \.self) { key in
                                switch key {
                                case "WATCH": Key("WATCH", style: .function) { send("\(trimmed) WATCH") }
                                case "HELP": Key("HELP", style: .green) { send("HELP") }
                                case "␣": Key("␣", style: .dark) { buffer += " " }.accessibilityLabel("Space")
                                default: Key(key, style: .number) { buffer += key }
                                }
                            }
                        }
                    }
                }
            }
            HStack(spacing: 6) {
                Key("CANCEL", style: .red, height: 64) {
                    buffer = ""
                    link.send(.cancel)
                }
                Key("BACK", style: .dark, height: 64) { link.send(.back) }
            }
            Key("GO", style: .green, height: 84, action: go)
                .accessibilityLabel("Go")
        }
    }

    // MARK: Watchlist

    private var watchlistStrip: some View {
        group(state.map { "Watchlist · \($0.watchlistName)" } ?? "Watchlist") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(state?.watchlist ?? [], id: \.self) { security in
                        Key(security, style: active?.security == security ? .selected : .dark, width: nil) {
                            send(security)
                        }
                    }
                }
            }
        }
    }

    // MARK: Behaviour

    private var trimmed: String { buffer.trimmingCharacters(in: .whitespaces) }

    private func append(token: String) {
        buffer = trimmed.isEmpty ? token : "\(trimmed) \(token)"
    }

    /// GO: send what's typed. A bare number runs the Mac's numbered action.
    private func go() {
        guard !trimmed.isEmpty else { return }
        send(trimmed)
    }

    /// Function keys act immediately. What's typed becomes the security, or the
    /// arguments when it looks like arguments (numbers, `>350`, screener filters…).
    private func run(_ function: FunctionID) {
        let typed = trimmed
        if typed.isEmpty {
            send(function.rawValue)
        } else if function.group != .security || looksLikeArgs(typed) || (function == .port && typed.hasPrefix("ADD")) {
            send("\(function.rawValue) \(typed)")
        } else {
            send("\(typed) \(function.rawValue)")
        }
    }

    private func looksLikeArgs(_ text: String) -> Bool {
        guard let first = text.first else { return false }
        return first.isNumber || "<>.".contains(first)
    }

    private func sendChart(_ config: ChartConfig) {
        let security = trimmed.isEmpty ? "" : "\(trimmed) "
        send(security + (["CHART"] + config.args).joined(separator: " "))
    }

    private func send(_ command: String) {
        let command = command.trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty else { return }
        link.send(command)
        buffer = ""
    }

    // MARK: Layout helpers

    private func group(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Pad.muted).tracking(1)
            content()
        }
    }

    private func keyRow(_ labels: [String], key: @escaping (String) -> Key) -> some View {
        HStack(spacing: 6) {
            ForEach(labels, id: \.self) { key($0) }
        }
    }
}

/// One key of the keypad.
struct Key: View {
    enum Style { case yellow, yellowDim, function, selected, dark, number, green, red }

    let label: String
    var caption: String?
    var style: Style
    var width: CGFloat? = .infinity
    var height: CGFloat = 52
    let action: () -> Void

    init(_ label: String, caption: String? = nil, style: Style, width: CGFloat? = .infinity, height: CGFloat = 52,
         action: @escaping () -> Void) {
        self.label = label
        self.caption = caption
        self.style = style
        self.width = width
        self.height = height
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(label)
                    .font(.system(size: label.count > 6 ? 13 : 16, weight: .bold, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let caption {
                    Text(caption).font(.system(size: 9, design: .monospaced)).opacity(0.7).lineLimit(1)
                }
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, width == nil ? 14 : 4)
            .frame(maxWidth: width, minHeight: height, maxHeight: height)
            .background(background, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(.white.opacity(0.06)))
            .shadow(color: .black.opacity(0.4), radius: 0, x: 0, y: 2)
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(KeyPressStyle())
        .accessibilityLabel(caption.map { "\(label), \($0)" } ?? label)
    }

    private var background: Color {
        switch style {
        case .yellow: Pad.yellow
        case .yellowDim: Pad.yellow.opacity(0.55)
        case .function: Pad.raised
        case .selected: Pad.amber
        case .dark: Pad.surface
        case .number: Color(red: 0.2, green: 0.2, blue: 0.22)
        case .green: Pad.green
        case .red: Pad.red
        }
    }

    private var foreground: Color {
        switch style {
        case .yellow, .yellowDim, .selected: .black
        case .function: Pad.amber
        case .green, .red: .white
        case .dark, .number: Pad.text
        }
    }
}

private struct KeyPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .brightness(configuration.isPressed ? 0.15 : 0)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}
