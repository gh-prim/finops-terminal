import FinopsCore
import FinopsDash
import Foundation
import Observation
import SwiftUI

/// Cross-source rules: saved on the Mac, evaluated by the gateway every 5 minutes;
/// a notification when one starts holding (at most once per 6 hours per rule).
@MainActor
@Observable
public final class RuleBook {
    public private(set) var rules: [WatchRule]
    public private(set) var status: [String: RuleStatus] = [:]
    public private(set) var checked: Date?
    public private(set) var unavailable: [String] = []
    public private(set) var presets: RulePresets?

    @ObservationIgnored private let store: Persisted<[WatchRule]>
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var client: DataClient?
    @ObservationIgnored var notify: ((String, String) -> Void)?

    static let interval: Duration = .seconds(300)
    static let cooldown: TimeInterval = 6 * 3600

    init(defaults: UserDefaults = .standard) {
        store = Persisted(key: "rules.v1", defaults: defaults)
        rules = store.load() ?? []
    }

    func start(_ client: DataClient) {
        self.client = client
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check()
                try? await Task.sleep(for: Self.interval)
            }
        }
        Task { presets = try? await client.rulePresets() }
    }

    public func check() async {
        guard let client else { return }
        let enabled = rules.filter(\.enabled)
        guard !enabled.isEmpty, let result = try? await client.evaluate(enabled) else { return }
        checked = Date(timeIntervalSince1970: result.checked)
        unavailable = result.unavailable
        for s in result.rules {
            let wasMet = status[s.id]?.met ?? false
            status[s.id] = s
            guard s.met, !wasMet, let i = rules.firstIndex(where: { $0.id == s.id }) else { continue }
            if let last = rules[i].lastFired, Date.now.timeIntervalSince(last) < Self.cooldown { continue }
            rules[i].lastFired = .now
            notify?("Rule triggered: \(rules[i].name)", s.conditions.map { "\($0.text): \($0.observed)" }.joined(separator: " · "))
        }
        save()
    }

    public func add(_ rule: WatchRule) {
        var rule = rule
        if rules.contains(where: { $0.id == rule.id }) { rule.id = UUID().uuidString }
        rules.append(rule)
        save()
        Task { await check() }
    }

    public func update(_ id: String, _ change: (inout WatchRule) -> Void) {
        guard let i = rules.firstIndex(where: { $0.id == id }) else { return }
        change(&rules[i])
        status[id] = nil
        save()
    }

    public func remove(_ id: String) {
        rules.removeAll { $0.id == id }
        status[id] = nil
        save()
    }

    private func save() { store.save(rules) }
}

/// RULE: cross-source alerts — presets, live status per condition, and an editor.
struct RulesView: View {
    let book: RuleBook
    let client: DataClient
    let run: (String) -> Void
    @State private var editing: String?

    var body: some View {
        HStack(spacing: 0) {
            if book.rules.isEmpty && editing == nil {
                // No rules yet: show live what the presets watch, instead of an empty page.
                VStack(alignment: .leading, spacing: 0) {
                    Text("No rules yet: add one from the presets on the right. What they watch, live:")
                        .font(.terminalSmall).foregroundStyle(Palette.muted).padding(.horizontal, 14).padding(.top, 10)
                    DocumentView(client: client, service: "world", params: ["kind": "ALL"], run: run)
                }
            } else {
                rulesList
            }
            Divider().overlay(Palette.border)
            side.frame(width: 320)
        }
    }

    private var rulesList: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Rules").font(.system(size: 14, weight: .semibold, design: .monospaced))
                        Text("fire when all their conditions hold · checked every 5 min").foregroundStyle(Palette.muted)
                        Spacer()
                        if let checked = book.checked { Text("checked \(Format.time(checked))").foregroundStyle(Palette.muted) }
                        Button("Check now") { Task { await book.check() } }.buttonStyle(TerminalButtonStyle(selected: false))
                    }
                    .font(.terminalSmall)
                    if book.rules.isEmpty {
                        Text("No rules yet. Add one from the presets on the right, or build your own.").foregroundStyle(Palette.muted)
                    }
                    ForEach(book.rules) { rule in card(rule) }
                    if !book.unavailable.isEmpty {
                        Text("Sources unavailable right now: \(book.unavailable.joined(separator: ", "))")
                            .font(.terminalSmall).foregroundStyle(Palette.down)
                    }
                }
                .padding(14)
            }
    }

    private func card(_ rule: WatchRule) -> some View {
        let s = book.status[rule.id]
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle().fill(s?.met == true ? Palette.down : (s == nil ? Palette.muted : Palette.up)).frame(width: 9, height: 9)
                Text(rule.name).font(.system(size: 13, weight: .semibold))
                if s?.met == true { Text("TRIGGERED").font(.terminalLabel).foregroundStyle(Palette.down) }
                Spacer()
                if let fired = rule.lastFired {
                    Text("last fired \(fired.formatted(date: .abbreviated, time: .shortened))").font(.terminalSmall).foregroundStyle(Palette.muted)
                }
                Toggle("", isOn: Binding(get: { rule.enabled }, set: { on in book.update(rule.id) { $0.enabled = on } }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                Button { editing = rule.id } label: { Image(systemName: "pencil") }.buttonStyle(.borderless)
                Button(role: .destructive) { book.remove(rule.id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
            }
            ForEach(Array(rule.conditions.enumerated()), id: \.offset) { i, condition in
                let check = s?.conditions[safe: i]
                HStack(spacing: 6) {
                    Image(systemName: check == nil ? "circle.dashed" : check!.met ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(check?.met == true ? Palette.down : Palette.muted)
                    Text(check?.text ?? RuleText.describe(condition)).foregroundStyle(Palette.text)
                    Spacer()
                    Text(check?.observed ?? "").foregroundStyle(Palette.muted).lineLimit(1)
                }
                .font(.terminalSmall)
            }
        }
        .padding(10)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(s?.met == true ? Palette.down.opacity(0.6) : Palette.border))
    }

    @ViewBuilder
    private var side: some View {
        if let id = editing, let rule = book.rules.first(where: { $0.id == id }) {
            RuleEditor(rule: rule, entities: book.presets?.entities ?? [], book: book, done: { editing = nil })
                .id(id)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(title: "Presets")
                    ForEach(book.presets?.presets ?? []) { preset in
                        Button { book.add(preset) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.name).foregroundStyle(Palette.text)
                                Text(preset.conditions.map(RuleText.describe).joined(separator: " AND "))
                                    .font(.terminalSmall).foregroundStyle(Palette.muted).multilineTextAlignment(.leading)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.borderless)
                        .disabled(book.rules.contains { $0.id == preset.id })
                    }
                    Divider()
                    Button {
                        let rule = WatchRule(name: "New rule", conditions: [RuleCondition(kind: "price", security: "SPX IDX", op: "<", value: -2)])
                        book.add(rule)
                        editing = rule.id
                    } label: { Label("Build a rule", systemImage: "plus") }
                    Text("Commands: RULE ADD <preset id>, RULE CHECK").font(.terminalSmall).foregroundStyle(Palette.muted)
                }
                .padding(12)
            }
        }
    }
}

enum RuleText {
    static func describe(_ c: RuleCondition) -> String {
        switch c.kind {
        case "price": "\(c.security ?? "?") \(c.op ?? ">") \(Format.number(c.value ?? 0))% today"
        case "chokepoint": "\(c.entity ?? "?") transits \(c.op ?? "<") \(Format.number(c.value ?? 0))% vs last month"
        case "quake": "Earthquake M\(Format.number(c.value ?? 6))+ near \(c.entity ?? "?")"
        case "outage": "Internet disruption in \(c.entity ?? "?")"
        case "keyword": "“\(c.text ?? "")” in the news"
        default: "\(c.kind.capitalized) linked to \(c.entity ?? "?"), severity ≥ \(c.severity ?? 1)"
        }
    }

    static let kinds: [(id: String, label: String)] = [
        ("price", "Price move"), ("chokepoint", "Chokepoint traffic"), ("conflict", "Conflict / sanctions"),
        ("unrest", "Unrest"), ("disaster", "Disaster"), ("quake", "Earthquake"), ("outage", "Internet outage"),
        ("keyword", "Keyword in the news"),
    ]
}

private struct RuleEditor: View {
    let rule: WatchRule
    let entities: [RulePresets.EntityRef]
    let book: RuleBook
    let done: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Button(action: done) { Label("Rules", systemImage: "chevron.left") }.buttonStyle(.borderless)
                SectionLabel(title: "Name")
                TextField("Name", text: Binding(get: { rule.name }, set: { v in book.update(rule.id) { $0.name = v } }))
                    .textFieldStyle(.roundedBorder)
                SectionLabel(title: "All of these at once")
                ForEach(Array(rule.conditions.enumerated()), id: \.element.id) { i, c in
                    conditionEditor(i, c)
                }
                Menu {
                    ForEach(RuleText.kinds, id: \.id) { kind in
                        Button(kind.label) {
                            book.update(rule.id) { $0.conditions.append(Self.template(kind.id)) }
                        }
                    }
                } label: { Label("Add condition", systemImage: "plus") }
                .menuStyle(.borderlessButton).fixedSize()
            }
            .padding(12)
        }
    }

    static func template(_ kind: String) -> RuleCondition {
        switch kind {
        case "price": RuleCondition(kind: kind, security: "CL1 CMD", op: ">", value: 2)
        case "chokepoint": RuleCondition(kind: kind, entity: "HORMUZ", op: "<", value: -15)
        case "quake": RuleCondition(kind: kind, entity: "JP", value: 7)
        case "outage": RuleCondition(kind: kind, entity: "RU")
        case "keyword": RuleCondition(kind: kind, text: "sanctions")
        default: RuleCondition(kind: kind, entity: "IR", severity: 2)
        }
    }

    private func conditionEditor(_ i: Int, _ c: RuleCondition) -> some View {
        func set(_ change: @escaping (inout RuleCondition) -> Void) {
            book.update(rule.id) { if $0.conditions.indices.contains(i) { change(&$0.conditions[i]) } }
        }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(RuleText.kinds.first { $0.id == c.kind }?.label ?? c.kind).font(.system(size: 12, weight: .semibold))
                Spacer()
                Button(role: .destructive) { book.update(rule.id) { $0.conditions.remove(at: i) } } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
            }
            if c.kind == "price" {
                TextField("Security", text: Binding(get: { c.security ?? "" }, set: { v in set { $0.security = v.uppercased() } }))
                    .textFieldStyle(.roundedBorder)
            }
            if ["chokepoint", "conflict", "unrest", "disaster", "quake", "outage"].contains(c.kind) {
                Picker("Entity", selection: Binding(get: { c.entity ?? "" }, set: { v in set { $0.entity = v } })) {
                    ForEach(entities.filter { c.kind != "chokepoint" || $0.kind == "chokepoint" }) { Text($0.name).tag($0.id) }
                }
            }
            if ["price", "chokepoint"].contains(c.kind) {
                HStack {
                    Picker("", selection: Binding(get: { c.op ?? ">" }, set: { v in set { $0.op = v } })) {
                        Text("above").tag(">"); Text("below").tag("<")
                    }
                    .labelsHidden().frame(width: 90)
                    TextField("%", value: Binding(get: { c.value ?? 0 }, set: { v in set { $0.value = v } }), format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 70)
                    Text("%").foregroundStyle(Palette.muted)
                }
            }
            if c.kind == "quake" {
                Stepper("Magnitude \(Format.number(c.value ?? 6))+", value: Binding(get: { c.value ?? 6 }, set: { v in set { $0.value = v } }),
                        in: 5...9, step: 0.5)
            }
            if ["conflict", "unrest", "disaster"].contains(c.kind) {
                Picker("Severity", selection: Binding(get: { c.severity ?? 1 }, set: { v in set { $0.severity = v } })) {
                    Text("any ●").tag(1); Text("notable ●●").tag(2); Text("major ●●●").tag(3)
                }
                .pickerStyle(.segmented)
            }
            if c.kind == "keyword" {
                TextField("word", text: Binding(get: { c.text ?? "" }, set: { v in set { $0.text = v } })).textFieldStyle(.roundedBorder)
            }
        }
        .padding(8)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 4))
    }
}
