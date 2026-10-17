import FinopsCore
import SwiftUI

/// Search box + live watchlist. Everything here is reachable by mouse.
struct SidebarView: View {
    let model: TerminalModel
    let client: DataClient?

    @State private var query = ""
    @State private var results: [LookupResult.Match] = []
    @State private var searching = false
    @State private var searchError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchField
                .padding(10)
            Divider().overlay(Palette.border)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if query.trimmingCharacters(in: .whitespaces).isEmpty {
                        watchlist
                    } else {
                        searchResults
                    }
                }
            }
        }
        .background(Palette.surface)
        .task(id: query) { await search() }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(Palette.muted)
            TextField("Search ticker or company", text: $query)
                .textFieldStyle(.plain)
                .foregroundStyle(Palette.text)
                .onSubmit { if let first = results.first { pick(first) } }
                .onExitCommand { query = "" }
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
            SectionLabel(title: "Watchlist")
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
