#if os(macOS)
import AppKit
#else
import UIKit
#endif
import FinopsCore
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

    var body: some View {
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
        }
        .task { await load() }
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
            case .block(let block):
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
                case .unknown: EmptyView()
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
    }

    // Consecutive key/value blocks render side by side as cards.
    private enum Group: Identifiable {
        case cards([GatewayDocument.KVBlock])
        case block(GatewayDocument.Block)

        var id: String {
            switch self {
            case .cards(let cards): "cards-" + cards.map { $0.title ?? "" }.joined(separator: "|")
            case .block(let block): block.id
            }
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
    @State private var hovered: Int?

    private static let charWidth: CGFloat = 7.4

    var body: some View {
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
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    Divider().overlay(Palette.border)
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(sortedRows.enumerated()), id: \.offset) { index, row in
                            rowView(row, index: index)
                        }
                    }
                }
            }
        }
    }

    private var widths: [CGFloat] {
        table.columns.enumerated().map { index, column in
            let longest = table.rows.prefix(200).reduce(column.label.count) { width, row in
                guard index < row.cells.count else { return width }
                return max(width, Format.value(row.cells[index], kind: kind(for: row, column: index)).count)
            }
            let cap = column.kind == .text ? 70 : 18
            return CGFloat(min(longest, cap)) * Self.charWidth + 18
        }
    }

    private var header: some View {
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
                    .foregroundStyle(Palette.muted)
                    .frame(width: widths[index], alignment: Format.isNumeric(column.kind) ? .trailing : .leading)
                    .padding(.horizontal, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Sort by \(column.label)")
            }
        }
        .padding(.vertical, 5)
    }

    private func kind(for row: GatewayDocument.Row, column index: Int) -> ValueKind {
        if index > 0, let override = row.kind { return override }
        return table.columns[index].kind
    }

    private func rowView(_ row: GatewayDocument.Row, index: Int) -> some View {
        let clickable = row.cmd != nil || row.url != nil
        return HStack(spacing: 0) {
            ForEach(Array(table.columns.enumerated()), id: \.offset) { col, column in
                let value = col < row.cells.count ? row.cells[col] : .null
                let k = kind(for: row, column: col)
                Text(Format.value(value, kind: k))
                    .foregroundStyle(col == 0 && clickable ? Palette.accent : Format.color(value, kind: k))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .monospacedDigit()
                    .frame(width: widths[col], alignment: Format.isNumeric(k) ? .trailing : .leading)
                    .padding(.horizontal, 4)
            }
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.vertical, 3)
        .background(hovered == index && clickable ? Palette.raised : (index.isMultiple(of: 2) ? .clear : Palette.surface.opacity(0.5)))
        .contentShape(Rectangle())
        .onHover { hovered = $0 ? index : (hovered == index ? nil : hovered) }
        .onTapGesture { activate(row) }
        .help(row.cmd ?? row.url ?? "")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(clickable ? .isButton : [])
        .accessibilityAction { activate(row) }
    }

    private func activate(_ row: GatewayDocument.Row) {
        if let cmd = row.cmd { run(cmd) }
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

/// CSV payload for the iPad share sheet.
struct CSVExport: Transferable {
    let name: String
    let csv: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .commaSeparatedText) { Data($0.csv.utf8) }
            .suggestedFileName { $0.name }
    }
}
