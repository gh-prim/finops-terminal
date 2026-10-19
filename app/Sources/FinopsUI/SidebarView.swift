import FinopsCore
import FinopsDash
import SwiftUI

/// Search box + live watchlist. Everything here is reachable by mouse.
struct SidebarView: View {
    let model: TerminalModel
    let client: DataClient?

    @State private var query = ""
    @State private var results: [LookupResult.Match] = []
    @State private var searching = false
    @State private var searchError: String?
    @State private var naming: NamingMode?

    private enum NamingMode: Identifiable {
        case create, rename
        var id: Int { self == .create ? 0 : 1 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchField
                .padding(10)
            Divider().overlay(Palette.border)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if query.trimmingCharacters(in: .whitespaces).isEmpty {
                        functions
                        watchlist
                    } else {
                        searchResults
                    }
                }
            }
        }
        .background(Palette.surface)
        .task(id: query) { await search() }
        .sheet(item: $naming) { mode in
            NameSheet(title: mode == .create ? "New watchlist" : "Rename watchlist",
                      initial: mode == .create ? "" : model.currentWatchlist.name) { name in
                if mode == .create { model.createWatchlist(named: name) } else { model.renameCurrentWatchlist(to: name) }
            }
        }
    }

    private var functions: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(title: "Markets & tools")
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 4)
            ForEach(FunctionID.allCases.filter { $0.group != .security }, id: \.self) { function in
                Button { model.open(function) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: function.systemImage).frame(width: 16).foregroundStyle(Palette.muted)
                        Text(function.title)
                        Spacer()
                        Text(function.rawValue).font(.terminalLabel).foregroundStyle(Palette.muted)
                    }
                    .foregroundStyle(model.panel.function == function ? Palette.accent : Palette.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(function.summary)
            }
            Divider().overlay(Palette.border).padding(.top, 6)
        }
        .font(.terminal)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(Palette.muted)
            TextField("Search ticker or company", text: $query)
                .textFieldStyle(.plain)
                .foregroundStyle(Palette.text)
                .onSubmit { if let first = results.first { pick(first) } }
                .onKeyPress(.escape) { query = ""; return .handled }
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.muted)
                    .accessibilityLabel("Clear search")
            }
        }
        .font(.terminal)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Palette.background, in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Palette.border))
    }

    private var watchlist: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Menu {
                    ForEach(model.watchlists) { list in
                        Button(list.name) { model.currentWatchlistID = list.id }
                    }
                    Divider()
                    Button("New Watchlist…") { naming = .create }
                    Button("Rename…") { naming = .rename }
                    Button("Delete \(model.currentWatchlist.name)", role: .destructive) { model.deleteCurrentWatchlist() }
                        .disabled(model.watchlists.count < 2)
                } label: {
                    HStack(spacing: 4) {
                        Text(model.currentWatchlist.name.uppercased()).font(.terminalLabel).tracking(1)
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                    }
                    .foregroundStyle(Palette.muted)
                }
                #if os(macOS)
                .menuStyle(.borderlessButton)
                #endif
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Switch, create or rename watchlists")
                Spacer()
                if let security = model.panel.security, !model.isWatched(security) {
                    Button { model.addToWatchlist(security) } label: { Image(systemName: "plus") }
                        .buttonStyle(.plain).foregroundStyle(Palette.accent)
                        .help("Add \(security) to this watchlist")
                        .accessibilityLabel("Add \(security) to watchlist")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            if let client {
                ForEach(model.watchlist, id: \.self) { security in
                    WatchlistRow(
                        client: client,
                        security: security,
                        selected: model.panel.security == security,
                        onSelect: { model.load(security) },
                        onRemove: { model.removeFromWatchlist(security) }
                    )
                    .id("\(model.clientGeneration)|\(security)")
                }
            } else {
                ForEach(model.watchlist, id: \.self) { security in
                    Text(security).foregroundStyle(Palette.muted)
                        .padding(.horizontal, 12).padding(.vertical, 5)
                }
            }
            if model.watchlist.isEmpty {
                Text("Search for a security and press + to add it here.")
                    .font(.terminalSmall)
                    .foregroundStyle(Palette.muted)
                    .padding(12)
            }
        }
        .font(.terminal)
    }

    private var searchResults: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionLabel(title: "Results")
                if searching { ProgressView().controlSize(.mini) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if let searchError {
                Text(searchError).font(.terminalSmall).foregroundStyle(Palette.down).padding(.horizontal, 12)
            } else if results.isEmpty, !searching {
                Text("No matches").font(.terminalSmall).foregroundStyle(Palette.muted).padding(.horizontal, 12)
            }
            ForEach(results, id: \.symbol) { match in
                SearchResultRow(
                    match: match,
                    watched: model.isWatched(match.symbol),
                    onSelect: { pick(match) },
                    onAdd: { model.addToWatchlist(match.symbol) }
                )
            }
        }
    }

    private func pick(_ match: LookupResult.Match) {
        model.load(match.symbol.uppercased())
        query = ""
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let client else {
            results = []
            return
        }
        try? await Task.sleep(for: .milliseconds(250))  // debounce typing
        guard !Task.isCancelled else { return }
        searching = true
        defer { searching = false }
        do {
            let found = try await client.lookup(text)
            guard !Task.isCancelled else { return }
            results = found.results
            searchError = nil
        } catch {
            guard !Task.isCancelled else { return }
            searchError = error.localizedDescription
        }
    }
}

private struct WatchlistRow: View {
    let client: DataClient
    let security: String
    let selected: Bool
    let onSelect: () -> Void
    let onRemove: () -> Void

    @State private var quote: Quote?
    @State private var hovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Text(security)
                    .foregroundStyle(selected ? Palette.accent : Palette.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if hovering {
                    Button(action: onRemove) { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain)
                        .foregroundStyle(Palette.muted)
                        .help("Remove from watchlist")
                        .accessibilityLabel("Remove \(security) from watchlist")
                }
                VStack(alignment: .trailing, spacing: 1) {
                    Text(Format.price(quote?.last)).foregroundStyle(Palette.text)
                    Text(Format.percent(quote?.changePct))
                        .font(.terminalSmall)
                        .foregroundStyle(Palette.direction(quote?.changePct))
                }
                .monospacedDigit()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(selected ? Palette.raised : (hovering ? Palette.raised.opacity(0.5) : .clear))
            .overlay(alignment: .leading) {
                if selected { Rectangle().fill(Palette.accent).frame(width: 2) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu { Button("Remove from Watchlist", action: onRemove) }
        .accessibilityLabel("\(security), \(Format.price(quote?.last)), \(Format.percent(quote?.changePct))")
        .task {
            for await event in await client.subscribe(security) {
                if case .tick(let tick) = event { quote = tick }
            }
        }
    }
}

private struct SearchResultRow: View {
    let match: LookupResult.Match
    let watched: Bool
    let onSelect: () -> Void
    let onAdd: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onSelect) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(match.symbol).foregroundStyle(Palette.accent)
                        if let type = match.type {
                            Text(type).font(.terminalLabel).foregroundStyle(Palette.muted)
                        }
                    }
                    Text([match.name, match.exchange].compactMap(\.self).joined(separator: " · "))
                        .font(.terminalSmall)
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(match.symbol), \(match.name ?? "")")

            Button(action: onAdd) {
                Image(systemName: watched ? "checkmark" : "plus")
            }
            .buttonStyle(TerminalButtonStyle(selected: watched))
            .disabled(watched)
            .help(watched ? "In watchlist" : "Add to watchlist")
            .accessibilityLabel(watched ? "\(match.symbol) is in watchlist" : "Add \(match.symbol) to watchlist")
        }
        .font(.terminal)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(hovering ? Palette.raised.opacity(0.5) : .clear)
        .onHover { hovering = $0 }
    }
}

private struct NameSheet: View {
    let title: String
    let initial: String
    let onSave: (String) -> Void

    @State private var name = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TextField("Name", text: $name).onSubmit(save)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: save).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 300)
        .onAppear { name = initial }
    }

    private func save() {
        onSave(name)
        dismiss()
    }
}

/// The collapsed sidebar: one icon per function (tooltip = name and command), the current
/// one highlighted; the top button (or ⌘\\) brings the full sidebar back.
struct SidebarRail: View {
    let model: TerminalModel

    var body: some View {
        VStack(spacing: 0) {
            Button { withAnimation(.easeInOut(duration: 0.2)) { model.sidebarCollapsed = false } } label: {
                Image(systemName: "magnifyingglass").frame(width: 48, height: 40)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.muted)
            .help("Search and watchlist (⌘\\)")
            Divider().overlay(Palette.border)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(FunctionID.Group.allCases.filter { $0 != .security }, id: \.self) { group in
                        ForEach(FunctionID.allCases.filter { $0.group == group }, id: \.self) { function in
                            let selected = model.panel.function == function
                            Button { model.open(function) } label: {
                                Image(systemName: function.systemImage)
                                    .font(.system(size: 14))
                                    .frame(width: 34, height: 30)
                                    .foregroundStyle(selected ? Palette.onAccent : Palette.muted)
                                    .background(selected ? Palette.accent : .clear, in: RoundedRectangle(cornerRadius: 5))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("\(function.title) — \(function.rawValue)")
                            .accessibilityLabel(function.title)
                        }
                        Divider().overlay(Palette.border).padding(.vertical, 4).padding(.horizontal, 8)
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .background(Palette.surface)
    }
}
