#if os(macOS)
import AppKit
#else
import UIKit
#endif
import FinopsCore
import FinopsDash
import SwiftUI
import UniformTypeIdentifiers

/// Loads a document-shaped service and renders its blocks. Choice buttons and
/// table rows carry commands, run through `run` exactly as if typed.
struct DocumentView: View {
    let client: DataClient
    let service: String
    let params: [String: String]
    let run: (String) -> Void

    @State private var document: GatewayDocument?
    @State private var failure: String?
    @State private var viewport: CGFloat = 0
    @State private var contentWidth: CGFloat = 0
    /// Measured heights: the whole page, and each block that stretches to fill it (by group id).
    @State private var contentHeight: CGFloat = 0
    @State private var flexHeights: [String: CGFloat] = [:]

    var body: some View {
        SwiftUI.Group {
            if let document, failure == nil, document.layout == "map" || document.layout == "split" {
                mapLayout(document)
            } else {
                scrolling
            }
        }
        .task { await load() }
    }

    /// Map screens (WORLD, case feeds): the whole world map on the left two thirds, full height;
    /// tabs, figures and tables in a scrolling column on the right third.
    private func mapLayout(_ document: GatewayDocument) -> some View {
        // The primary visual: the map, else the treemap (CRYPTO's split layout).
        let map = document.blocks.first { if case .map = $0 { true } else { false } }
            ?? document.blocks.first { if case .treemap = $0 { true } else { false } }
        let rest = document.blocks.filter { $0.id != map?.id }
        return GeometryReader { geo in
            HStack(alignment: .top, spacing: 0) {
                SwiftUI.Group {
                    switch map {
                    case .map(let m): MapBlockView(block: m, run: run, height: nil, wholeWorld: true)
                    case .treemap(let t): TreemapBlockView(block: t, run: run, minHeight: 0).frame(maxHeight: .infinity)
                    default: EmptyView()
                    }
                }
                .padding(10)
                .frame(width: geo.size.width * 2 / 3, height: geo.size.height)
                Divider().overlay(Palette.border)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(document.title).font(.system(size: 14, weight: .semibold, design: .monospaced))
                            Spacer()
                            Text("as of \(Format.time(Date(timeIntervalSince1970: document.asOf)))")
                                .font(.terminalSmall).foregroundStyle(Palette.muted)
                        }
                        ForEach(rest) { block in
                            if case .choices(let c) = block {
                                WrappingChoices(block: c, run: run)
                            } else if case .table = block {
                                // Tables share what the column has left, so it has no black margin.
                                blockView(block)
                                    .environment(\.tileHeight, columnTableHeight(rest, height: geo.size.height))
                                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { flexHeights[block.id] = $0 }
                            } else {
                                blockView(block)
                            }
                        }
                        ForEach(document.notes, id: \.self) { Text($0).font(.terminalSmall).foregroundStyle(Palette.muted) }
                        Text("Source: \(document.source)").font(.terminalSmall).foregroundStyle(Palette.muted)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                }
                .frame(width: geo.size.width / 3)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: GatewayDocument.Block) -> some View {
        switch block {
        case .table(let table): TableBlockView(table: table, run: run)
        case .text(let text): TextBlockView(block: text)
        case .choices(let choices): ChoicesBar(block: choices, run: run)
        case .kv(let kv): KVCard(block: kv)
        case .treemap(let b): TreemapBlockView(block: b, run: run)
        case .matrix(let b): MatrixBlockView(block: b, run: run)
        case .scatter(let b): ScatterBlockView(block: b, run: run)
        case .graph(let b): GraphBlockView(block: b, run: run)
        case .bars(let b): BarsBlockView(block: b, run: run)
        case .series(let b): SeriesBlockView(block: b)
        case .donut(let b): DonutBlockView(block: b)
        case .sparkgrid(let b): SparkGridBlockView(block: b, run: run)
        case .map(let b): MapBlockView(block: b, run: run)
        case .unknown: EmptyView()
        }
    }

    private var scrolling: some View {
        GeometryReader { geo in
            scrollingContent
                .environment(\.viewportHeight, geo.size.height)
                .onAppear { viewport = geo.size.height; contentWidth = geo.size.width - 28 }
                .onChange(of: geo.size) { _, size in viewport = size.height; contentWidth = size.width - 28 }
        }
    }

    private var scrollingContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let failure {
                    StatusMessage(title: "Couldn't load this screen", detail: failure, isError: true)
                } else if let document {
                    content(document)
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
    }

    /// Window height left for the stretching blocks: measured, not guessed (everything on the
    /// page that isn't a stretching block keeps its natural height).
    private var flexBudget: CGFloat? {
        guard viewport > 0, contentHeight > 0, !flexHeights.isEmpty else { return nil }
        return viewport - (contentHeight - flexHeights.values.reduce(0, +))
    }

    @ViewBuilder
    private func content(_ document: GatewayDocument) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(document.title).font(.system(size: 14, weight: .semibold, design: .monospaced))
            if let subtitle = document.subtitle {
                Text(subtitle).foregroundStyle(Palette.muted)
            }
            Spacer()
            Text("as of \(Format.time(Date(timeIntervalSince1970: document.asOf)))")
                .font(.terminalSmall).foregroundStyle(Palette.muted)
        }

        ForEach(groupedBlocks(document.blocks)) { group in
            switch group {
            case .cards(let cards):
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), alignment: .top)], alignment: .leading, spacing: 12) {
                    ForEach(cards, id: \.title) { KVCard(block: $0) }
                }
            case .flow(let blocks):
                // Small blocks side by side: as many columns as the width allows, and the tiles share
                // the window height so the page is filled without scrolling or black margins.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 430), spacing: 18, alignment: .top)],
                          alignment: .leading, spacing: 18) {
                    ForEach(blocks) { blockView($0) }
                }
                .environment(\.tileHeight, tileHeight(document))
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { flexHeights[group.id] = $0 }
            case .block(let block):
                if case .table = block, loneTableHeight(document) > 0 {
                    blockView(block).environment(\.tileHeight, loneTableHeight(document))
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { flexHeights[group.id] = $0 }
                } else {
                    blockView(block)
                }
            }
        }

        if document.blocks.isEmpty {
            Text("No data available.").foregroundStyle(Palette.muted)
        }
        ForEach(document.notes, id: \.self) { note in
            Text(note).font(.terminalSmall).foregroundStyle(Palette.muted)
        }
        Text("Source: \(document.source)").font(.terminalSmall).foregroundStyle(Palette.muted)
    }

    private func load() async {
        do {
            document = try await client.document(service, params)
        } catch {
            failure = error.localizedDescription
        }
        // Live screens reload in place; a failed refresh keeps the last good data on screen.
        while let seconds = document?.refresh, seconds > 0, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            if let next = try? await client.document(service, params) { document = next }
        }
    }

    // Consecutive key/value blocks render side by side as cards; consecutive small blocks
    // (short tables, bars, donuts, series) flow into columns.
    private enum Group: Identifiable {
        case cards([GatewayDocument.KVBlock])
        case flow([GatewayDocument.Block])
        case block(GatewayDocument.Block)

        var id: String {
            switch self {
            case .cards(let cards): "cards-" + cards.map { $0.title ?? "" }.joined(separator: "|")
            case .flow(let blocks): "flow-" + blocks.map(\.id).joined(separator: "|")
            case .block(let block): block.id
            }
        }
    }

    /// Height budget of one grid tile: the window height left after the other groups, split over
    /// the grid rows of every flow group. 0 (no stretching) when a full-width block also needs room.
    private func tileHeight(_ document: GatewayDocument) -> CGFloat {
        guard viewport > 0, contentWidth > 0 else { return 0 }
        let groups = groupedBlocks(document.blocks)
        let columns = max(1, Int((contentWidth + 18) / (430 + 18)))
        var gridRows = 0
        var overhead: CGFloat = 70 + CGFloat(document.notes.count) * 18
        for group in groups {
            switch group {
            case .flow(let blocks): gridRows += (blocks.count + columns - 1) / columns
            case .cards(let cards): overhead += 40 + CGFloat(cards.map(\.items.count).max() ?? 0) * 19
            case .block(let block):
                switch block {
                case .choices: overhead += 40
                case .text: overhead += 90
                default: return 0
                }
            }
        }
        guard gridRows > 0 else { return 0 }
        let flows = groups.filter { if case .flow = $0 { true } else { false } }.count
        if let budget = flexBudget {
            return max(0, (budget - CGFloat(gridRows - flows) * 18) / CGFloat(gridRows))
        }
        return max(0, (viewport - 28 - overhead) / CGFloat(gridRows) - 18)
    }

    /// A page whose only big block is one table (calendars, lists): the table gets the window
    /// height left after the header, choices and cards, so its rows fill the page.
    private func loneTableHeight(_ document: GatewayDocument) -> CGFloat {
        guard viewport > 0 else { return 0 }
        var overhead: CGFloat = 70 + CGFloat(document.notes.count) * 18
        var tables = 0
        for group in groupedBlocks(document.blocks) {
            switch group {
            case .flow: return 0
            case .cards(let cards): overhead += 40 + CGFloat(cards.map(\.items.count).max() ?? 0) * 19
            case .block(let block):
                switch block {
                case .choices: overhead += 40
                case .text: overhead += 90
                case .table: tables += 1
                default: return 0
                }
            }
        }
        guard tables == 1 else { return 0 }
        return max(0, flexBudget ?? (viewport - 28 - overhead - 18))
    }

    /// Split layouts: the right column's height left after its fixed blocks, shared by its tables.
    private func columnTableHeight(_ blocks: [GatewayDocument.Block], height: CGFloat) -> CGFloat {
        let tables = blocks.filter { if case .table = $0 { true } else { false } }
        guard !tables.isEmpty, contentHeight > 0 else { return 0 }
        let flex = tables.reduce(0) { $0 + (flexHeights[$1.id] ?? 0) }
        let budget = height - (contentHeight - flex) - CGFloat(tables.count - 1) * 14
        return max(0, budget / CGFloat(tables.count))
    }

    /// Fits in a column next to others: short, narrow tables and small charts.
    private static func isCompact(_ block: GatewayDocument.Block) -> Bool {
        switch block {
        case .table(let t): t.rows.count <= 60 && t.columns.count <= 9
        case .bars, .donut, .series: true
        case .matrix(let m): m.cols.count <= 10
        default: false
        }
    }

    private func groupedBlocks(_ blocks: [GatewayDocument.Block]) -> [Group] {
        var out: [Group] = []
        for block in blocks {
            if case .kv(let kv) = block {
                if case .cards(let existing) = out.last {
                    out[out.count - 1] = .cards(existing + [kv])
                } else {
                    out.append(.cards([kv]))
                }
            } else if Self.isCompact(block) {
                switch out.last {
                case .flow(let existing): out[out.count - 1] = .flow(existing + [block])
                case .block(let previous) where Self.isCompact(previous): out[out.count - 1] = .flow([previous, block])
                default: out.append(.block(block))
                }
            } else {
                out.append(.block(block))
            }
        }
        return out
    }
}

private struct KVCard: View {
    let block: GatewayDocument.KVBlock

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let title = block.title { SectionLabel(title: title) }
            ForEach(block.items, id: \.self) { item in
                HStack(alignment: .firstTextBaseline) {
                    Text(item.label).foregroundStyle(Palette.muted)
                    Spacer(minLength: 12)
                    if let url = item.url.flatMap(URL.init(string:)) {
                        Link(Format.value(item.value, kind: item.kind), destination: url)
                            .foregroundStyle(Palette.accent)
                    } else {
                        Text(Format.value(item.value, kind: item.kind))
                            .foregroundStyle(Format.color(item.value, kind: item.kind))
                            .monospacedDigit()
                            .textSelection(.enabled)
                    }
                }
                .lineLimit(1)
            }
        }
        .padding(10)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Palette.border))
    }
}

private struct TextBlockView: View {
    let block: GatewayDocument.TextBlock
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let title = block.title { SectionLabel(title: title) }
            Text(block.text)
                .foregroundStyle(Palette.text.opacity(0.85))
                .lineLimit(expanded ? nil : 4)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if block.text.count > 320 {
                Button(expanded ? "Show less" : "Show more") { expanded.toggle() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.accent)
                    .font(.terminalSmall)
            }
        }
    }
}

struct ChoicesBar: View {
    let block: GatewayDocument.ChoicesBlock
    let run: (String) -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let title = block.title { SectionLabel(title: title) }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(block.items, id: \.self) { item in
                        Button(item.label) { run(item.cmd) }
                            .buttonStyle(TerminalButtonStyle(selected: item.label == block.selected))
                            .help(item.cmd)
                    }
                }
            }
        }
    }
}

// MARK: Table

struct TableBlockView: View {
    let table: GatewayDocument.TableBlock
    let run: (String) -> Void

    @Environment(\.openURL) private var openURL
    @State private var sortColumn: Int?
    @State private var ascending = false
    @State private var available: CGFloat = 0
    @Environment(\.viewportHeight) private var viewport
    @Environment(\.tileHeight) private var tile

    /// In a sized grid tile, rows spread over the tile (22–64 pt); else the standard 22 pt.
    private var rowHeight: CGFloat {
        guard tile > 0, !table.rows.isEmpty else { return Self.rowHeight }
        return min(max(Self.rowHeight, (tile - 56) / CGFloat(table.rows.count)), 64).rounded(.down)
    }

    private var bodyHeight: CGFloat {
        let natural = CGFloat(table.rows.count) * rowHeight
        if tile > 0 { return min(natural, max(tile - 56, 3 * Self.rowHeight)) }
        return min(natural, viewport > 0 ? max(Self.maxBodyHeight, viewport - 170) : Self.maxBodyHeight)
    }

    private static let charWidth: CGFloat = 7.4
    static let rowHeight: CGFloat = 22
    private static let maxBodyHeight: CGFloat = 560

    /// Everything a row needs, computed once per sort (not per cell, not per hover).
    struct PreparedRow: Identifiable {
        let id: Int
        let texts: [String]
        let colors: [Color]
        let trailing: [Bool]
        let row: GatewayDocument.Row
        var clickable: Bool { row.cmd != nil || row.url != nil }
    }

    var body: some View {
        let rows = prepared(sortedRows)
        let widths = stretched(columnWidths(rows))
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let title = table.title { SectionLabel(title: title) }
                Text("\(table.rows.count) rows").font(.terminalLabel).foregroundStyle(Palette.muted)
                Spacer()
                Button { copyTSV() } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(TerminalButtonStyle())
                    .help("Copy table")
                    .accessibilityLabel("Copy table")
                #if os(macOS)
                Button { exportCSV() } label: { Image(systemName: "square.and.arrow.down") }
                    .buttonStyle(TerminalButtonStyle())
                    .help("Export CSV")
                    .accessibilityLabel("Export CSV")
                #else
                ShareLink(item: CSVExport(name: exportName, csv: delimited(",")), preview: SharePreview(exportName)) {
                    Image(systemName: "square.and.arrow.up")
                }
                .buttonStyle(TerminalButtonStyle())
                .accessibilityLabel("Export CSV")
                #endif
            }
            // Horizontal scroll moves header and rows together; rows scroll vertically under a frozen header.
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    header(widths)
                    Divider().overlay(Palette.border)
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(rows) { row in
                                TableRowView(row: row, widths: widths, height: rowHeight, striped: row.id.isMultiple(of: 2)) { activate(row.row) }
                            }
                        }
                    }
                    .frame(height: bodyHeight)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { available = $0 }
    }

    /// Spread spare width over the text columns (the longest gets most), so a table fills its
    /// panel or grid cell instead of leaving a black margin. Never shrinks below the content.
    private func stretched(_ widths: [CGFloat]) -> [CGFloat] {
        let used = widths.reduce(0, +) + CGFloat(widths.count) * 8   // cells have 4 pt padding each side
        let spare = available - used - 4
        guard spare > 1 else { return widths }
        let text = table.columns.indices.filter { table.columns[$0].kind == .text }
        let targets = text.isEmpty ? Array(widths.indices) : text
        let weight = targets.reduce(0) { $0 + widths[$1] }
        var out = widths
        for i in targets { out[i] += spare * (weight > 0 ? widths[i] / weight : 1 / CGFloat(targets.count)) }
        return out
    }

    private func prepared(_ rows: [GatewayDocument.Row]) -> [PreparedRow] {
        rows.enumerated().map { index, row in
            let clickable = row.cmd != nil || row.url != nil
            var texts: [String] = [], colors: [Color] = [], trailing: [Bool] = []
            for col in table.columns.indices {
                let value = col < row.cells.count ? row.cells[col] : .null
                let k = kind(for: row, column: col)
                texts.append(Format.value(value, kind: k))
                colors.append(col == 0 && clickable ? Palette.accent : Format.color(value, kind: k))
                trailing.append(Format.isNumeric(k))
            }
            return PreparedRow(id: index, texts: texts, colors: colors, trailing: trailing, row: row)
        }
    }

    private func columnWidths(_ rows: [PreparedRow]) -> [CGFloat] {
        table.columns.enumerated().map { index, column in
            let longest = rows.prefix(300).reduce(column.label.count) { max($0, $1.texts[index].count) }
            let cap = column.kind == .text ? 70 : 18
            return CGFloat(min(longest, cap)) * Self.charWidth + 18
        }
    }

    private func header(_ widths: [CGFloat]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(table.columns.enumerated()), id: \.offset) { index, column in
                Button {
                    if sortColumn == index { ascending.toggle() } else { sortColumn = index; ascending = column.kind == .text }
                } label: {
                    HStack(spacing: 3) {
                        Text(column.label)
                        if sortColumn == index { Image(systemName: ascending ? "chevron.up" : "chevron.down") }
                    }
                    .font(.terminalLabel)
                    .foregroundStyle(sortColumn == index ? Palette.accent : Palette.muted)
                    .frame(width: widths[index], alignment: Format.isNumeric(column.kind) ? .trailing : .leading)
                    .padding(.horizontal, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Sort by \(column.label)")
            }
        }
        .padding(.vertical, 5)
        .background(Palette.surface)
    }

    private func kind(for row: GatewayDocument.Row, column index: Int) -> ValueKind {
        if index > 0, let override = row.kind { return override }
        return table.columns[index].kind
    }

    private func activate(_ row: GatewayDocument.Row) {
        if let cmd = row.cmd { run(cmd) }
        else if let url = row.url, url.hasPrefix("http") { run("READ \(url)") }  // headlines open in the terminal
        else if let url = row.url.flatMap(URL.init(string:)) { openURL(url) }
    }

    private var sortedRows: [GatewayDocument.Row] {
        guard let column = sortColumn else { return table.rows }
        return table.rows.sorted { a, b in
            let x = column < a.cells.count ? a.cells[column] : .null
            let y = column < b.cells.count ? b.cells[column] : .null
            let ordered: Bool
            switch (x.number, y.number) {
            case let (l?, r?): ordered = l < r
            case (nil, _?): return false
            case (_?, nil): return true
            default: ordered = (x.string ?? "").localizedStandardCompare(y.string ?? "") == .orderedAscending
            }
            return ascending ? ordered : !ordered
        }
    }

    private func delimited(_ separator: String) -> String {
        func escape(_ s: String) -> String {
            separator == "," && (s.contains(",") || s.contains("\"")) ? "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\"" : s
        }
        var lines = [table.columns.map { escape($0.label) }.joined(separator: separator)]
        for row in sortedRows {
            lines.append(table.columns.indices.map { i in
                let value = i < row.cells.count ? row.cells[i] : .null
                let k = kind(for: row, column: i)
                // Raw numbers for spreadsheets; formatted dates.
                if [.date, .datetime].contains(k) { return escape(Format.value(value, kind: k)) }
                return escape(value.number.map { String($0) } ?? value.string ?? "")
            }.joined(separator: separator))
        }
        return lines.joined(separator: "\n")
    }

    private var exportName: String {
        "\(table.title ?? table.id).csv".replacingOccurrences(of: "/", with: "-")
    }

    private func copyTSV() {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(delimited("\t"), forType: .string)
        #else
        UIPasteboard.general.string = delimited("\t")
        #endif
    }

    #if os(macOS)
    private func exportCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = exportName
        panel.allowedContentTypes = [.commaSeparatedText]
        let csv = delimited(",")
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? csv.write(to: url, atomically: true, encoding: .utf8)
        }
    }
    #endif
}

/// One table row; it owns its hover state so hovering doesn't redraw the whole table.
private struct TableRowView: View {
    let row: TableBlockView.PreparedRow
    let widths: [CGFloat]
    let height: CGFloat
    let striped: Bool
    let activate: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            ForEach(row.texts.indices, id: \.self) { col in
                Text(row.texts[col])
                    .foregroundStyle(row.colors[col])
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .monospacedDigit()
                    .frame(width: widths[col], alignment: row.trailing[col] ? .trailing : .leading)
                    .padding(.horizontal, 4)
            }
        }
        .font(.system(size: 12, design: .monospaced))
        .frame(height: height)
        .background(hovering && row.clickable ? Palette.raised : (striped ? .clear : Palette.surface.opacity(0.5)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: activate)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(row.clickable ? .isButton : [])
        .accessibilityAction { activate() }
    }
}

/// CSV payload for the iPad share sheet.
struct CSVExport: Transferable {
    let name: String
    let csv: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .commaSeparatedText) { Data($0.csv.utf8) }
            .suggestedFileName { $0.name }
    }
}

/// Choice buttons that wrap onto several lines (narrow side column).
private struct WrappingChoices: View {
    let block: GatewayDocument.ChoicesBlock
    let run: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title = block.title { SectionLabel(title: title) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 4)], alignment: .leading, spacing: 4) {
                ForEach(block.items, id: \.self) { item in
                    Button(item.label) { run(item.cmd) }
                        .buttonStyle(TerminalButtonStyle(selected: item.label == block.selected))
                }
            }
        }
    }
}

/// A key/value block as one line of figures (map screens keep their height for the map).
private struct InlineFigures: View {
    let block: GatewayDocument.KVBlock

    var body: some View {
        HStack(spacing: 16) {
            if let title = block.title { SectionLabel(title: title) }
            ForEach(block.items, id: \.self) { item in
                HStack(spacing: 5) {
                    Text(item.label).foregroundStyle(Palette.muted)
                    Text(Format.value(item.value, kind: item.kind)).foregroundStyle(Format.color(item.value, kind: item.kind))
                }
            }
            Spacer(minLength: 0)
        }
        .font(.terminalSmall)
        .lineLimit(1)
    }
}
