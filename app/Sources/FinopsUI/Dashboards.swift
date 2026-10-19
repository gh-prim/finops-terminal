import FinopsCore
import FinopsDash
import Foundation
import Observation

/// Dashboards built on the Mac for the Apple TV. Saved locally; every change is
/// pushed to connected TVs through the remote server (see `onChange`).
@MainActor
@Observable
public final class DashboardStore {
    public private(set) var dashboards: [Dashboard]
    public var currentID: UUID? {
        didSet { defaults.set(currentID?.uuidString, forKey: "dashboards.current") }
    }
    /// Names of the TVs currently connected (set by the app).
    public var displays: [String] = []

    /// Called (debounced) after any edit, so the app can push the new set to TVs.
    @ObservationIgnored public var onChange: (() -> Void)?
    /// Called when the user asks to show a dashboard on the TV now.
    @ObservationIgnored public var onDisplay: ((UUID) -> Void)?

    @ObservationIgnored private let store: Persisted<[Dashboard]>
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var pushTask: Task<Void, Never>?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        store = Persisted(key: "dashboards", defaults: defaults)
        let saved = store.load() ?? []
        dashboards = saved.isEmpty ? [.starter] : saved
        currentID = defaults.string(forKey: "dashboards.current").flatMap(UUID.init(uuidString:)) ?? dashboards.first?.id
        if !dashboards.contains(where: { $0.id == currentID }) { currentID = dashboards.first?.id }
    }

    public var current: Dashboard? { dashboards.first { $0.id == currentID } }

    public func update(_ id: UUID, _ change: (inout Dashboard) -> Void) {
        guard let index = dashboards.firstIndex(where: { $0.id == id }) else { return }
        change(&dashboards[index])
        changed()
    }

    public func updateWidget(_ widgetID: UUID, in id: UUID, _ change: (inout DashWidget) -> Void) {
        update(id) { dashboard in
            guard let index = dashboard.widgets.firstIndex(where: { $0.id == widgetID }) else { return }
            change(&dashboard.widgets[index])
            Self.clamp(&dashboard.widgets[index], in: dashboard)
        }
    }

    @discardableResult
    public func create(named name: String) -> Dashboard {
        let dashboard = Dashboard(name: uniqueName(name), widgets: [DashWidget(kind: .clock, x: 0, y: 0, w: 12, h: 1)])
        dashboards.append(dashboard)
        currentID = dashboard.id
        changed()
        return dashboard
    }

    /// Insert or replace a whole dashboard (e.g. one generated from a case).
    public func put(_ dashboard: Dashboard) {
        if let i = dashboards.firstIndex(where: { $0.id == dashboard.id }) { dashboards[i] = dashboard } else { dashboards.append(dashboard) }
        changed()
    }

    public func duplicate(_ id: UUID) {
        guard var copy = dashboards.first(where: { $0.id == id }) else { return }
        copy.id = UUID()
        copy.name = uniqueName(copy.name + " copy")
        copy.widgets = copy.widgets.map { var w = $0; w.id = UUID(); return w }
        dashboards.append(copy)
        currentID = copy.id
        changed()
    }

    public func delete(_ id: UUID) {
        dashboards.removeAll { $0.id == id }
        if dashboards.isEmpty { dashboards = [.starter] }
        if currentID == id { currentID = dashboards.first?.id }
        changed()
    }

    @discardableResult
    public func addWidget(_ kind: DashWidget.Kind, to id: UUID, securities: [String] = []) -> UUID? {
        var newID: UUID?
        update(id) { dashboard in
            var widget = DashWidget.starter(kind)
            if !securities.isEmpty { widget.securities = securities }
            // A full screen still takes a ticker tape: it claims the bottom row.
            if kind == .ticker, dashboard.findSlot(w: widget.w, h: widget.h) == nil { dashboard.makeRoomAtBottom() }
            let slot = dashboard.freeSlot(w: widget.w, h: widget.h)
            widget.x = slot.x
            widget.y = slot.y
            dashboard.widgets.append(widget)
            newID = widget.id
        }
        return newID
    }

    /// Turn the dashboard's ticker band on (adding `securities` to it), keeping any existing list.
    public func enableBand(on id: UUID, securities: [String] = []) {
        update(id) { dashboard in
            var band = dashboard.band ?? DashWidget(kind: .ticker, securities: DashWidget.tickerTape)
            for security in securities where !band.securities.contains(security) { band.securities.insert(security, at: 0) }
            dashboard.band = band
        }
    }

    public func updateBand(on id: UUID, _ change: (inout DashWidget) -> Void) {
        update(id) { dashboard in
            guard var band = dashboard.band else { return }
            change(&band)
            dashboard.band = band
        }
    }

    public func removeWidget(_ widgetID: UUID, from id: UUID) {
        update(id) { $0.widgets.removeAll { $0.id == widgetID } }
    }

    public func duplicateWidget(_ widgetID: UUID, in id: UUID) -> UUID? {
        var newID: UUID?
        update(id) { dashboard in
            guard var copy = dashboard.widgets.first(where: { $0.id == widgetID }) else { return }
            copy.id = UUID()
            let slot = dashboard.freeSlot(w: copy.w, h: copy.h)
            copy.x = slot.x
            copy.y = slot.y
            dashboard.widgets.append(copy)
            newID = copy.id
        }
        return newID
    }

    public func dashboard(named name: String) -> Dashboard? {
        dashboards.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    public func showOnTV(_ id: UUID) {
        onDisplay?(id)
    }

    // MARK: Private

    private static func clamp(_ widget: inout DashWidget, in dashboard: Dashboard) {
        widget.w = min(max(widget.w, 1), dashboard.columns)
        widget.h = min(max(widget.h, 1), dashboard.rows)
        widget.x = min(max(widget.x, 0), dashboard.columns - widget.w)
        widget.y = min(max(widget.y, 0), dashboard.rows - widget.h)
    }

    private func uniqueName(_ base: String) -> String {
        var name = base, n = 2
        while dashboards.contains(where: { $0.name == name }) {
            name = "\(base) \(n)"
            n += 1
        }
        return name
    }

    private func changed() {
        store.save(dashboards)
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.onChange?()
        }
    }
}
