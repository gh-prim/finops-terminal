import FinopsCore
import SwiftUI

public struct TerminalView: View {
    @Bindable var model: TerminalModel
    @FocusState private var commandFocused: Bool

    public init(model: TerminalModel) {
        self.model = model
    }

    public var body: some View {
        HStack(spacing: 0) {
            SidebarView(model: model, client: model.client)
                .frame(width: 270)
            Divider().overlay(Palette.border)
            VStack(spacing: 0) {
                topBar
                Divider().overlay(Palette.border)
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                if model.panel.function == .chart, model.panel.security != nil {
                    rangeBar
                }
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

    // MARK: Top bar: back · security · function tabs · status

    private var topBar: some View {
        HStack(spacing: 10) {
            Button { model.back() } label: { Image(systemName: "chevron.left") }
                .buttonStyle(TerminalButtonStyle())
                .disabled(!model.canGoBack)
                .help("Back (⌘[)")
                .accessibilityLabel("Back")

            Text(model.panel.security ?? "No security loaded")
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .foregroundStyle(model.panel.security == nil ? Palette.muted : Palette.accent)
                .lineLimit(1)

            Spacer()

            tab(.quote, number: 1)
            tab(.chart, number: 2)
            Button { model.open(.help) } label: { Image(systemName: "questionmark") }
                .buttonStyle(TerminalButtonStyle(selected: model.panel.function == .help))
                .help("Help")
                .accessibilityLabel("Help")

            ConnectionBadge(state: model.connection)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Palette.surface)
    }

    private func tab(_ function: FunctionID, number: Int) -> some View {
        Button { model.open(function) } label: {
            Text("\(number) \(function.rawValue)")
        }
        .buttonStyle(TerminalButtonStyle(selected: model.panel.function == function))
        .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
        .disabled(model.panel.security == nil)
        .help("\(function.title) (⌘\(number))")
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch (model.connection, model.client) {
        case (.failed(let reason), _):
            StatusMessage(title: "Data gateway failed to start", detail: reason, isError: true)
        case (_, nil):
            StatusMessage(title: "Starting data gateway…", detail: "The first launch installs Python dependencies and can take a minute.")
        case (.ready, let client?):
            panelView(client: client)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func panelView(client: DataClient) -> some View {
        let panel = model.panel
        switch (panel.function, panel.security) {
        case (.quote, let security?):
            QuoteView(client: client, security: security, onError: model.report)
                .id(security)
        case (.chart, let security?):
            ChartView(client: client, security: security, range: panel.chartRange, onError: model.report)
                .id("\(security)|\(panel.chartRange.rawValue)")
        default:
            HelpView()
        }
    }

    private var rangeBar: some View {
        HStack(spacing: 4) {
            ForEach(ChartRange.allCases, id: \.self) { range in
                Button(range.rawValue) { model.setRange(range) }
                    .buttonStyle(TerminalButtonStyle(selected: model.panel.chartRange == range))
                    .accessibilityLabel("Chart range \(range.rawValue)")
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: Optional command line

    private var commandLine: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.terminalSmall)
                .foregroundStyle(commandFocused ? Palette.accent : Palette.muted)
            TextField("Command (optional) — e.g. AAPL US EQ CHART 5Y   ⌘L", text: $model.commandText)
                .textFieldStyle(.plain)
                .focused($commandFocused)
                .onSubmit { model.submit() }
                .onExitCommand { model.cancel(); commandFocused = false }
                .autocorrectionDisabled()
            if let message = model.message {
                Text(message)
                    .font(.terminalSmall)
                    .foregroundStyle(Palette.down)
                    .lineLimit(1)
            }
        }
        .font(.terminalSmall)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Palette.surface)
    }
}

private struct ConnectionBadge: View {
    let state: ConnectionState

    var body: some View {
        let (label, color): (String, Color) = switch state {
        case .starting: ("starting", Palette.muted)
        case .ready: ("live", Palette.up)
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

    public var body: some Commands {
        CommandMenu("Navigate") {
            Button("Back") { model?.back() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!(model?.canGoBack ?? false))
            Button("Command Line") { focusCommandLine?() }
                .keyboardShortcut("l", modifiers: .command)
        }
    }
}
