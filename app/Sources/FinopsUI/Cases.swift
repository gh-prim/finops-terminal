import FinopsCore
import FinopsDash
import Foundation
import Observation
import SwiftUI

public struct CaseItem: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var command: String
    public var title: String
    public var added = Date()
}

/// An investigation: what to follow (entities, keywords), notes, and pinned screens.
public struct CaseFile: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    public var terms: [String]
    public var notes = ""
    public var items: [CaseItem] = []
    public var created = Date()
}

@MainActor
@Observable
public final class CaseBook {
    public private(set) var cases: [CaseFile]
    public var currentID: UUID? {
        didSet { defaults.set(currentID?.uuidString, forKey: "cases.current") }
    }

    @ObservationIgnored private let store: Persisted<[CaseFile]>
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        store = Persisted(key: "cases.v1", defaults: defaults)
        cases = store.load() ?? []
        currentID = defaults.string(forKey: "cases.current").flatMap(UUID.init(uuidString:)) ?? cases.first?.id
    }

    public var current: CaseFile? { cases.first { $0.id == currentID } }

    @discardableResult
    public func create(_ name: String, terms: [String] = []) -> CaseFile {
        let file = CaseFile(name: name, terms: terms.isEmpty ? [name] : terms)
        cases.append(file)
        currentID = file.id
        save()
        return file
    }

    public func update(_ id: UUID, _ change: (inout CaseFile) -> Void) {
        guard let i = cases.firstIndex(where: { $0.id == id }) else { return }
        change(&cases[i])
        save()
    }

    public func delete(_ id: UUID) {
        cases.removeAll { $0.id == id }
        if currentID == id { currentID = cases.first?.id }
        save()
    }

    /// Pin a terminal screen (as its command) to the current case, creating one if needed.
    @discardableResult
    public func pin(command: String, title: String) -> CaseFile {
        let file = current ?? create("Investigation")
        update(file.id) { f in
            if !f.items.contains(where: { $0.command == command }) { f.items.append(CaseItem(command: command, title: title)) }
        }
        return current ?? file
    }

    private func save() { store.save(cases) }
}

extension PanelState {
    /// The command that reopens this screen.
    var command: String {
        ([security, function.rawValue].compactMap { $0 } + args).joined(separator: " ")
    }
}

/// CASE: investigations with a live feed of what is happening on their terms.
struct CasesView: View {
    let model: TerminalModel
    let client: DataClient
    let run: (String) -> Void
    @State private var termsText = ""

    private var book: CaseBook { model.cases }

    var body: some View {
        HStack(spacing: 0) {
            list.frame(width: 200)
            Divider().overlay(Palette.border)
            if let file = book.current {
                detail(file).id(file.id)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No case yet").font(.headline)
                    Text("Create one to follow a theme (e.g. “Taiwan, TSMC, chips”), keep notes, and pin screens with the 📌 button in any panel.")
                        .foregroundStyle(Palette.muted)
                    Button("New case") { book.create("Investigation") }
                }
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(title: "Cases")
            ForEach(book.cases) { file in
                Button { book.currentID = file.id } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(file.name).foregroundStyle(file.id == book.currentID ? Palette.accent : Palette.text)
                        Text("\(file.items.count) pinned · \(file.terms.joined(separator: ", "))")
                            .font(.terminalSmall).foregroundStyle(Palette.muted).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
            }
            Button { book.create("Investigation") } label: { Label("New case", systemImage: "plus") }
                .buttonStyle(.borderless).padding(.top, 6)
            Spacer()
        }
        .padding(10)
    }

    private func detail(_ file: CaseFile) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        TextField("Name", text: Binding(get: { file.name }, set: { v in book.update(file.id) { $0.name = v } }))
                            .font(.system(size: 15, weight: .semibold)).textFieldStyle(.plain)
                        Button(role: .destructive) { book.delete(file.id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                    SectionLabel(title: "Follow (countries, chokepoints, commodities, companies, keywords)")
                    TextField("Taiwan, TSMC, chips", text: $termsText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { commitTerms(file) }
                    Button("Update feed") { commitTerms(file) }.controlSize(.small)
                    SectionLabel(title: "Pinned")
                    if file.items.isEmpty {
                        Text("Pin any screen with the 📌 button in its panel header, or type CASE PIN.")
                            .font(.terminalSmall).foregroundStyle(Palette.muted)
                    }
                    ForEach(file.items) { item in
                        HStack {
                            Button { run(item.command) } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.title).foregroundStyle(Palette.text)
                                    Text(item.command).font(.terminalSmall).foregroundStyle(Palette.accent)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.borderless)
                            Button { book.update(file.id) { $0.items.removeAll { $0.id == item.id } } } label: { Image(systemName: "pin.slash") }
                                .buttonStyle(.borderless).help("Unpin")
                        }
                        .padding(6)
                        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 3))
                    }
                    SectionLabel(title: "Notes")
                    TextEditor(text: Binding(get: { file.notes }, set: { v in book.update(file.id) { $0.notes = v } }))
                        .font(.system(size: 12))
                        .frame(minHeight: 160)
                        .scrollContentBackground(.hidden)
                        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 3))
                    Button { showOnTV(file) } label: { Label("Show on TV as a dashboard", systemImage: "appletv") }
                        .buttonStyle(TerminalButtonStyle(selected: false))
                        .disabled(model.dashboards.displays.isEmpty)
                }
                .padding(12)
            }
            .frame(width: 320)
            Divider().overlay(Palette.border)
            DocumentView(client: client, service: "case_feed", params: ["terms": file.terms.joined(separator: ",")], run: run)
                .id(file.terms)
        }
        .onAppear { termsText = file.terms.joined(separator: ", ") }
    }

    private func commitTerms(_ file: CaseFile) {
        let terms = termsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        book.update(file.id) { $0.terms = terms }
    }

    /// The case as a TV dashboard: its feed (map + events) and up to four pinned screens.
    private func showOnTV(_ file: CaseFile) {
        let feed = "CASE FEED " + file.terms.joined(separator: ",")
        var widgets: [DashWidget] = [
            DashWidget(kind: .text, title: "Case", x: 0, y: 0, w: 6, h: 1, text: file.name),
            DashWidget(kind: .screen, title: "Events", x: 0, y: 1, w: 6, h: 4, command: feed, part: "map-map"),
            DashWidget(kind: .screen, title: "World events", x: 0, y: 5, w: 6, h: 3, command: feed, part: "World events"),
        ]
        for (i, item) in file.items.prefix(4).enumerated() {
            let frame = (x: 6 + (i % 2) * 3, y: (i / 2) * 4, w: 3, h: 4)
            if case .run(let security, .chart?, let args) = CommandParser.parse(item.command), let security {
                let config = ChartConfig(args: args)
                widgets.append(DashWidget(kind: .chart, title: item.title, x: frame.x, y: frame.y, w: frame.w, h: frame.h,
                                          securities: [security], range: config.range.rawValue, interval: config.interval?.rawValue,
                                          style: config.style == .candle ? .candle : .area))
            } else {
                widgets.append(DashWidget(kind: .screen, title: item.title, x: frame.x, y: frame.y, w: frame.w, h: frame.h,
                                          command: item.command))
            }
        }
        if file.items.isEmpty {
            widgets.append(DashWidget(kind: .screen, title: "Headlines", x: 6, y: 0, w: 6, h: 8, command: feed, part: "Headlines"))
        }
        let name = "Case · \(file.name)"
        let existing = model.dashboards.dashboard(named: name)
        let dashboard = Dashboard(id: existing?.id ?? UUID(), name: name, widgets: widgets)
        model.dashboards.put(dashboard)
        model.dashboards.showOnTV(dashboard.id)
    }
}
