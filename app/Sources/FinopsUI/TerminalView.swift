import FinopsCore
import SwiftUI

public struct TerminalView: View {
    @Bindable var model: TerminalModel
    let accessory: AnyView
    @FocusState private var commandFocused: Bool

    /// `accessory` is shown at the right of the toolbar (Settings/pairing on Mac, connection on iPad).
    public init(model: TerminalModel, accessory: AnyView = AnyView(EmptyView())) {
        self.model = model
        self.accessory = accessory
    }

    public var body: some View {
        HStack(spacing: 0) {
            SidebarView(model: model, client: model.client)
                .frame(width: 270)
            Divider().overlay(Palette.border)
            VStack(spacing: 0) {
                toolbar
                Divider().overlay(Palette.border)
                panelGrid
                Divider().overlay(Palette.border)
                commandLine
            }
            .background(Palette.background)
        }
        .font(.terminal)
        .foregroundStyle(Palette.text)
        .tint(Palette.accent)
        .preferredColorScheme(.dark)
        .focusedSceneValue(\.terminalModel, model)
        .focusedSceneValue(\.focusCommandLine) { commandFocused = true }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            SectionLabel(title: "Layout")
            ForEach(Layout.allCases, id: \.self) { layout in
                Button { model.setLayout(layout) } label: { Image(systemName: layout.systemImage) }
                    .buttonStyle(TerminalButtonStyle(selected: model.layout == layout))
                    .help("\(layout.rawValue) panel\(layout == .single ? "" : "s") (⌥⌘\(layout.rawValue))")
                    .accessibilityLabel("\(layout.rawValue) panels")
            }
            Spacer()
            if let message = model.message {
                Text(message)
                    .font(.terminalSmall)
                    .foregroundStyle(message.hasPrefix("🔔") || message.hasPrefix("Added") || message.hasPrefix("Alert set")
                                     ? Palette.accent : Palette.down)
                    .lineLimit(1)
                Button { model.clearMessage() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(Palette.muted).accessibilityLabel("Dismiss message")
            }
            accessory
            ConnectionBadge(state: model.connection, source: model.dataSource)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Palette.surface)
    }

    @ViewBuilder
    private var panelGrid: some View {
        let panels = model.panels
        switch panels.count {
        case 1:
            PanelView(model: model, panel: panels[0])
        case 2:
            HStack(spacing: 1) {
                PanelView(model: model, panel: panels[0])
                PanelView(model: model, panel: panels[1])
            }
            .background(Palette.border)
        default:
            VStack(spacing: 1) {
                HStack(spacing: 1) {
                    PanelView(model: model, panel: panels[0])
                    PanelView(model: model, panel: panels[1])
                }
                HStack(spacing: 1) {
                    PanelView(model: model, panel: panels[2])
                    if panels.count > 3 {
                        PanelView(model: model, panel: panels[3])
                    } else {
                        Palette.background
                    }
                }
            }
            .background(Palette.border)
        }
    }

    private var commandLine: some View {
        HStack(spacing: 8) {
            Text(model.panels.count > 1 ? "P\((model.panels.firstIndex { $0.id == model.activePanelID } ?? 0) + 1)" : "")
                .font(.terminalLabel)
                .foregroundStyle(Palette.muted)
            Image(systemName: "chevron.right")
                .font(.terminalSmall)
                .foregroundStyle(commandFocused ? Palette.accent : Palette.muted)
            TextField("Command (optional) — e.g. AAPL US EQ CHART 5Y CANDLE SMA50 · FIN Q · SCRN PE<15 · ECON UNRATE   ⌘L",
                      text: $model.commandText)
                .textFieldStyle(.plain)
                .focused($commandFocused)
                .onSubmit { model.submit() }
                .onKeyPress(.escape) { model.cancel(); commandFocused = false; return .handled }
                .autocorrectionDisabled()
        }
        .font(.terminalSmall)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Palette.surface)
    }
}

struct ConnectionBadge: View {
    let state: ConnectionState
    var source: String? = nil

    var body: some View {
        let (label, color): (String, Color) = switch state {
        case .starting: ("starting", Palette.muted)
        case .ready: (source.map { "live · \($0)" } ?? "live", Palette.up)
        case .failed: ("offline", Palette.down)
        }
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.terminalSmall).foregroundStyle(Palette.muted)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Data gateway \(label)")
    }
}

struct StatusMessage: View {
    let title: String
    let detail: String
    var isError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).foregroundStyle(isError ? Palette.down : Palette.text)
            Text(detail).foregroundStyle(Palette.muted).textSelection(.enabled)
        }
        .padding(16)
    }
}

// MARK: Menu commands

public struct TerminalModelKey: FocusedValueKey {
    public typealias Value = TerminalModel
}

public struct FocusCommandLineKey: FocusedValueKey {
    public typealias Value = () -> Void
}

public extension FocusedValues {
    var terminalModel: TerminalModel? {
        get { self[TerminalModelKey.self] }
        set { self[TerminalModelKey.self] = newValue }
    }

    var focusCommandLine: (() -> Void)? {
        get { self[FocusCommandLineKey.self] }
        set { self[FocusCommandLineKey.self] = newValue }
    }
}

public struct TerminalCommands: Commands {
    @FocusedValue(\.terminalModel) private var model
    @FocusedValue(\.focusCommandLine) private var focusCommandLine

    public init() {}

    private static let keys: [Character] = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]

    public var body: some Commands {
        CommandMenu("Navigate") {
            Button("Back") { model?.back() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!(model?.activePanel.canGoBack ?? false))
            Button("Command Line") { focusCommandLine?() }
                .keyboardShortcut("l", modifiers: .command)
            Divider()
            ForEach(Layout.allCases, id: \.self) { layout in
                Button("\(layout.rawValue) Panel\(layout == .single ? "" : "s")") { model?.setLayout(layout) }
                    .keyboardShortcut(KeyEquivalent(Character(String(layout.rawValue))), modifiers: [.command, .option])
            }
        }
        CommandMenu("Function") {
            let security = FunctionID.allCases.filter { $0.group == .security }
            ForEach(Array(security.enumerated()), id: \.element) { index, function in
                Button(function.title) { model?.open(function) }
                    .keyboardShortcut(KeyEquivalent(Self.keys[index]), modifiers: .command)
            }
            Divider()
            ForEach(FunctionID.allCases.filter { $0.group != .security }, id: \.self) { function in
                Button(function.title) { model?.open(function) }
            }
        }
    }
}
