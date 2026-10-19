import FinopsCore
import FinopsDash
import SwiftUI

/// DASH: build Apple TV dashboards. The canvas is the live dashboard, scaled down;
/// drag a widget to move it, drag its corner to resize, and edit it in the inspector.
struct DashboardBuilderView: View {
    let model: TerminalModel
    let client: DataClient?

    @State private var selection: UUID?
    @State private var drag: (id: UUID, offset: CGSize, resize: Bool)?
    @State private var renaming = ""

    private var store: DashboardStore { model.dashboards }

    var body: some View {
        if let dashboard = store.current {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    toolbar(dashboard)
                    canvas(dashboard)
                    Text("Click a widget to edit it · drag to move · drag its corner to resize. Commands: DASH NEW <name>, DASH <name>, DASH TV, <security> DASH ADD CHART")
                        .font(.terminalSmall).foregroundStyle(Palette.muted)
                }
                .padding(12)
                Divider().overlay(Palette.border)
                inspector(dashboard)
                    .frame(width: 300)
            }
            .onChange(of: store.currentID) { selection = nil }
        } else {
            StatusMessage(title: "No dashboard", detail: "Type DASH NEW <name> to create one.", isError: false)
        }
    }

    // MARK: Toolbar

    private func toolbar(_ dashboard: Dashboard) -> some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(store.dashboards) { d in
                    Button(d.name) { store.currentID = d.id }
                }
                Divider()
                Button("New dashboard") { store.create(named: "Dashboard") }
                Button("Duplicate \(dashboard.name)") { store.duplicate(dashboard.id) }
                Button("Delete \(dashboard.name)", role: .destructive) { store.delete(dashboard.id) }
            } label: {
                Label(dashboard.name, systemImage: "rectangle.3.group")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            TextField("Name", text: Binding(
                get: { dashboard.name },
                set: { name in store.update(dashboard.id) { $0.name = name } }))
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)

            Menu {
                Button { store.enableBand(on: dashboard.id) } label: {
                    Label("Ticker band (thin, along an edge)", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
                .disabled(dashboard.band != nil)
                Divider()
                ForEach(DashWidget.Kind.allCases) { kind in
                    Button { selection = store.addWidget(kind, to: dashboard.id) } label: {
                        Label(kind == .ticker ? "Ticker tape (as a tile)" : kind.title, systemImage: kind.systemImage)
                    }
                }
            } label: {
                Label("Add widget", systemImage: "plus.rectangle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()
            Text(store.displays.isEmpty ? "No TV connected" : "On: " + store.displays.joined(separator: ", "))
                .font(.terminalSmall).foregroundStyle(Palette.muted)
            Button { store.showOnTV(dashboard.id) } label: { Label("Show on TV", systemImage: "appletv") }
                .buttonStyle(TerminalButtonStyle(selected: false))
                .disabled(store.displays.isEmpty)
        }
    }

    // MARK: Canvas

    private func canvas(_ dashboard: Dashboard) -> some View {
        GeometryReader { geo in
            let scale = min(geo.size.width / DashboardView.canvas.width, geo.size.height / DashboardView.canvas.height)
            ZStack(alignment: .topLeading) {
                DashboardView(dashboard: dashboard, client: client, selection: nil)
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(width: DashboardView.canvas.width * scale, height: DashboardView.canvas.height * scale,
                           alignment: .topLeading)
                    .allowsHitTesting(false)
                grid(dashboard, scale: scale)
                ForEach(dashboard.widgets) { widget in
                    handle(widget, in: dashboard, scale: scale)
                }
            }
            .frame(width: DashboardView.canvas.width * scale, height: DashboardView.canvas.height * scale)
            .contentShape(Rectangle())
            .onTapGesture { selection = nil }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
    }

    /// Faint cell grid while editing, so placement is predictable.
    private func grid(_ dashboard: Dashboard, scale: CGFloat) -> some View {
        Canvas { context, _ in
            let cols = CGFloat(dashboard.columns), rows = CGFloat(dashboard.rows)
            let area = DashboardView.gridArea(dashboard)
            let r = CGRect(x: area.minX * scale, y: area.minY * scale, width: area.width * scale, height: area.height * scale)
            var path = Path()
            for i in 1..<dashboard.columns {
                let x = r.minX + r.width * CGFloat(i) / cols
                path.move(to: CGPoint(x: x, y: r.minY)); path.addLine(to: CGPoint(x: x, y: r.maxY))
            }
            for j in 1..<dashboard.rows {
                let y = r.minY + r.height * CGFloat(j) / rows
                path.move(to: CGPoint(x: r.minX, y: y)); path.addLine(to: CGPoint(x: r.maxX, y: y))
            }
            context.stroke(path, with: .color(.white.opacity(drag == nil ? 0.03 : 0.08)), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }

    private func handle(_ widget: DashWidget, in dashboard: Dashboard, scale: CGFloat) -> some View {
        let frame = DashboardView.frame(of: widget, in: dashboard)
        let rect = CGRect(x: frame.minX * scale, y: frame.minY * scale, width: frame.width * scale, height: frame.height * scale)
        let active = drag?.id == widget.id ? drag : nil
        let area = DashboardView.gridArea(dashboard)
        let cell = CGSize(width: area.width * scale / CGFloat(dashboard.columns),
                          height: area.height * scale / CGFloat(dashboard.rows))
        let selected = selection == widget.id

        return ZStack(alignment: .bottomTrailing) {
            Rectangle()
                .fill(Color.white.opacity(0.001))
                .overlay(Rectangle().stroke(selected ? Palette.selection : .clear, lineWidth: 2))
                .gesture(DragGesture(minimumDistance: 3)
                    .onChanged { value in
                        selection = widget.id
                        drag = (widget.id, value.translation, false)
                    }
                    .onEnded { value in
                        let dx = Int((value.translation.width / cell.width).rounded())
                        let dy = Int((value.translation.height / cell.height).rounded())
                        store.updateWidget(widget.id, in: dashboard.id) { $0.x += dx; $0.y += dy }
                        drag = nil
                    })
                .onTapGesture { selection = widget.id }
            if selected {
                RoundedRectangle(cornerRadius: 2).fill(Palette.selection)
                    .frame(width: 12, height: 12)
                    .gesture(DragGesture(minimumDistance: 1)
                        .onChanged { value in drag = (widget.id, value.translation, true) }
                        .onEnded { value in
                            let dw = Int((value.translation.width / cell.width).rounded())
                            let dh = Int((value.translation.height / cell.height).rounded())
                            store.updateWidget(widget.id, in: dashboard.id) { $0.w += dw; $0.h += dh }
                            drag = nil
                        })
            }
        }
        .frame(width: max(rect.width + (active?.resize == true ? active!.offset.width : 0), 12),
               height: max(rect.height + (active?.resize == true ? active!.offset.height : 0), 12))
        .overlay {
            if active != nil { Rectangle().stroke(Palette.accent, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])) }
        }
        .offset(x: rect.minX + (active?.resize == false ? active!.offset.width : 0),
                y: rect.minY + (active?.resize == false ? active!.offset.height : 0))
    }

    // MARK: Inspector

    @ViewBuilder
    private func inspector(_ dashboard: Dashboard) -> some View {
        if let id = selection, let widget = dashboard.widgets.first(where: { $0.id == id }) {
            WidgetInspector(widget: widget, client: client, watchlist: model.watchlist,
                            update: { change in store.updateWidget(id, in: dashboard.id, change) },
                            duplicate: { selection = store.duplicateWidget(id, in: dashboard.id) },
                            remove: { store.removeWidget(id, from: dashboard.id); selection = nil })
                .id(id)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(title: "Dashboard")
                    Text("\(dashboard.widgets.count) widgets on a \(dashboard.columns) × \(dashboard.rows) grid.")
                        .font(.terminalSmall).foregroundStyle(Palette.muted)
                    Text("Select a widget to edit it, or add one with Add widget.")
                        .font(.terminalSmall).foregroundStyle(Palette.muted)
                    Divider()
                    BandInspector(dashboard: dashboard, store: store, watchlist: model.watchlist)
                        .id(dashboard.id)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Settings for one widget; every field writes straight to the store.
private struct WidgetInspector: View {
    let widget: DashWidget
    let client: DataClient?
    let watchlist: [String]
    let update: ((inout DashWidget) -> Void) -> Void
    let duplicate: () -> Void
    let remove: () -> Void
    /// Editing one slide of a slideshow: no position, and slides can't nest slideshows.
    var isSlide = false

    @State private var securitiesText = ""
    @State private var blockTitles: [String] = []
    @State private var editingSlide: UUID?

    var body: some View {
        if let slideID = editingSlide, let slide = widget.slides.first(where: { $0.id == slideID }) {
            VStack(alignment: .leading, spacing: 0) {
                Button { editingSlide = nil } label: { Label("Slideshow", systemImage: "chevron.left") }
                    .buttonStyle(.borderless).padding([.horizontal, .top], 12)
                WidgetInspector(
                    widget: slide, client: client, watchlist: watchlist,
                    update: { change in update { show in
                        if let i = show.slides.firstIndex(where: { $0.id == slideID }) { change(&show.slides[i]) }
                    } },
                    duplicate: { update { show in
                        if let i = show.slides.firstIndex(where: { $0.id == slideID }) {
                            var copy = show.slides[i]
                            copy.id = UUID()
                            show.slides.insert(copy, at: i + 1)
                        }
                    } },
                    remove: { update { $0.slides.removeAll { $0.id == slideID } }; editingSlide = nil },
                    isSlide: true)
                .id(slideID)
            }
        } else {
            form
        }
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(widget.kind.title, systemImage: widget.kind.systemImage).font(.headline)
                    Spacer()
                    Button(action: duplicate) { Image(systemName: "plus.square.on.square") }.help("Duplicate")
                    Button(role: .destructive, action: remove) { Image(systemName: "trash") }.help("Delete widget")
                }
                .buttonStyle(.borderless)

                field("Type") {
                    Picker("", selection: binding(\.kind)) {
                        ForEach(DashWidget.Kind.allCases.filter { !isSlide || $0 != .carousel }) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                }
                field("Title (optional)") {
                    TextField("Automatic", text: Binding(get: { widget.title ?? "" },
                                                        set: { v in update { $0.title = v.isEmpty ? nil : v } }))
                }
                if !isSlide {
                    field("Position and size (cells)") {
                        Grid(horizontalSpacing: 8, verticalSpacing: 4) {
                            GridRow { stepper("X", \.x); stepper("Y", \.y) }
                            GridRow { stepper("W", \.w); stepper("H", \.h) }
                        }
                    }
                }
                kindFields
            }
            .textFieldStyle(.roundedBorder)
            .padding(12)
        }
        .onAppear { securitiesText = widget.securities.joined(separator: ", ") }
    }

    @ViewBuilder
    private var kindFields: some View {
        switch widget.kind {
        case .quotes:
            securitiesField
        case .ticker:
            securitiesField
            field("Speed") {
                Picker("", selection: binding(\.speed)) {
                    Text("Slow").tag(1); Text("Normal").tag(2); Text("Fast").tag(3)
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            Text("Wide tile: scrolls sideways (top or bottom band). Tall tile: scrolls up (side column).")
                .font(.terminalSmall).foregroundStyle(Palette.muted)
        case .carousel:
            field("Seconds per slide") {
                Stepper("\(widget.seconds) s", value: binding(\.seconds), in: 3...600, step: 5)
            }
            field("Slides") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(widget.slides.enumerated()), id: \.element.id) { i, slide in
                        HStack(spacing: 6) {
                            Image(systemName: slide.kind.systemImage).frame(width: 18)
                            VStack(alignment: .leading, spacing: 0) {
                                Text("\(i + 1). \(slide.title ?? slide.kind.title)").lineLimit(1)
                                Text(slideSummary(slide)).font(.terminalSmall).foregroundStyle(Palette.muted).lineLimit(1)
                            }
                            Spacer()
                            Button { editingSlide = slide.id } label: { Image(systemName: "pencil") }.help("Edit slide")
                            Button { moveSlide(i, by: -1) } label: { Image(systemName: "arrow.up") }.disabled(i == 0)
                            Button { moveSlide(i, by: 1) } label: { Image(systemName: "arrow.down") }
                                .disabled(i == widget.slides.count - 1)
                            Button(role: .destructive) { update { $0.slides.remove(at: i) } } label: { Image(systemName: "minus.circle") }
                        }
                        .buttonStyle(.borderless)
                    }
                    Menu {
                        ForEach(DashWidget.Kind.allCases.filter { $0 != .carousel }) { kind in
                            Button { update { $0.slides.append(.starter(kind)) } } label: {
                                Label(kind.title, systemImage: kind.systemImage)
                            }
                        }
                    } label: { Label("Add slide", systemImage: "plus") }
                    .menuStyle(.borderlessButton).fixedSize()
                }
            }
        case .chart:
            securitiesField
            rangeField
            field("Bars") {
                Picker("", selection: Binding(get: { widget.interval ?? "" }, set: { v in update { $0.interval = v.isEmpty ? nil : v } })) {
                    Text("Auto").tag("")
                    ForEach(ChartConfig.Interval.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) }
                }
                .labelsHidden()
            }
            field("Style") {
                Picker("", selection: binding(\.style)) {
                    ForEach(DashWidget.Style.chartStyles) { Text($0.rawValue.capitalized).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            field("Overlays") {
                HStack {
                    ForEach(["SMA20", "SMA50", "SMA200", "EMA20"], id: \.self) { name in
                        Toggle(name, isOn: Binding(
                            get: { widget.overlays.contains(name) },
                            set: { on in update { w in
                                if on { w.overlays.append(name) } else { w.overlays.removeAll { $0 == name } }
                            } }))
                        .toggleStyle(.button).controlSize(.small)
                    }
                }
            }
        case .compare:
            securitiesField
            rangeField
        case .diagram:
            securitiesField
            field("Diagram") {
                Picker("", selection: binding(\.style)) {
                    ForEach(DashWidget.Style.diagramStyles) { Text($0.rawValue.capitalized).tag($0) }
                }
                .labelsHidden()
            }
            field("Value") {
                Picker("", selection: binding(\.metric)) {
                    ForEach(DashWidget.Metric.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
            }
            if widget.metric == .change { rangeField }
        case .screen:
            commandField(presets: DashSource.presets, placeholder: "e.g. CRYPTO, HEAT 1D, ECAL ECO TODAY")
            field("Show") {
                Picker("", selection: Binding(get: { widget.part ?? "" }, set: { v in update { $0.part = v.isEmpty ? nil : v } })) {
                    Text("Main block").tag("")
                    ForEach(blockTitles, id: \.self) { Text($0).tag($0) }
                    Text("Whole screen (stacked)").tag(DashBlocks.all)
                }
                .labelsHidden()
            }
            .task(id: widget.command) { await loadBlockTitles() }
            if ["PERF", "CORR", "CHARTS"].contains(widget.command?.split(separator: " ").first.map(String.init) ?? "") {
                securitiesField
            }
        case .news:
            commandField(presets: DashSource.newsPresets, placeholder: "NEWS CRYPTO, AAPL US EQ NEWS, NEWS <words>")
        case .video:
            field("Channel") {
                Picker("", selection: Binding(get: { widget.channel ?? "us" }, set: { v in update { $0.channel = v } })) {
                    ForEach(LiveChannel.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .labelsHidden()
            }
            Toggle("Muted", isOn: binding(\.muted))
        case .text:
            field("Text") {
                TextField("Markets", text: Binding(get: { widget.text ?? "" }, set: { v in update { $0.text = v } }))
            }
        case .clock:
            Text("New York, London, Paris, Tokyo, Hong Kong and Sydney, with market open/closed status.")
                .font(.terminalSmall).foregroundStyle(Palette.muted)
        }
    }

    private var securitiesField: some View {
        field("Securities") {
            VStack(alignment: .leading, spacing: 4) {
                TextField("AAPL US EQ, BTC CRYPTO, SPX IDX", text: $securitiesText, axis: .vertical)
                    .lineLimit(2...5)
                    .onSubmit(commitSecurities)
                    .onChange(of: securitiesText) { commitSecurities() }
                HStack {
                    Button("Use watchlist") {
                        securitiesText = watchlist.joined(separator: ", ")
                        commitSecurities()
                    }
                    .controlSize(.small)
                    Text("Separate with commas").font(.terminalSmall).foregroundStyle(Palette.muted)
                }
            }
        }
    }

    private var rangeField: some View {
        field("Range") {
            Picker("", selection: binding(\.range)) {
                ForEach(ChartRange.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) }
            }
            .labelsHidden()
        }
    }

    private func commandField(presets: [(label: String, command: String)], placeholder: String) -> some View {
        field("Command") {
            HStack {
                TextField(placeholder, text: Binding(get: { widget.command ?? "" },
                                                     set: { v in update { $0.command = v.uppercased(); $0.part = nil } }))
                Menu {
                    ForEach(presets, id: \.command) { preset in
                        Button(preset.label) { update { $0.command = preset.command; $0.part = nil } }
                    }
                } label: { Image(systemName: "list.bullet") }
                .menuStyle(.borderlessButton).fixedSize()
            }
        }
    }

    private func slideSummary(_ slide: DashWidget) -> String {
        switch slide.kind {
        case .screen, .news: slide.command ?? ""
        case .video: LiveChannel(rawValue: slide.channel ?? "us")?.title ?? ""
        case .text: slide.text ?? ""
        default: slide.securities.prefix(3).joined(separator: ", ")
        }
    }

    private func moveSlide(_ index: Int, by delta: Int) {
        update { show in
            let target = index + delta
            guard show.slides.indices.contains(target) else { return }
            show.slides.swapAt(index, target)
        }
    }

    private func commitSecurities() {
        let list = securitiesText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
            .filter { !$0.isEmpty }
        if list != widget.securities { update { $0.securities = list } }
    }

    private func loadBlockTitles() async {
        guard let client, let request = DashSource.request(for: widget.command ?? "", securities: widget.securities),
              let document = try? await client.document(request.service, request.params) else {
            blockTitles = []
            return
        }
        blockTitles = DashBlocks.displayable(document.blocks).map(DashBlocks.title)
    }

    private func binding<T>(_ path: WritableKeyPath<DashWidget, T>) -> Binding<T> {
        Binding(get: { widget[keyPath: path] }, set: { v in update { $0[keyPath: path] = v } })
    }

    private func stepper(_ label: String, _ path: WritableKeyPath<DashWidget, Int>) -> some View {
        Stepper("\(label) \(widget[keyPath: path])", value: binding(path), in: 0...12)
            .font(.terminalSmall)
    }

    private func field<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(title: title)
            content()
        }
    }
}

/// The dashboard's ticker band: on/off, edge, speed, tickers.
private struct BandInspector: View {
    let dashboard: Dashboard
    let store: DashboardStore
    let watchlist: [String]

    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(get: { dashboard.band != nil }, set: { on in
                if on { store.enableBand(on: dashboard.id) } else { store.update(dashboard.id) { $0.band = nil } }
            })) {
                SectionLabel(title: "Ticker band")
            }
            if let band = dashboard.band {
                Picker("Edge", selection: Binding(get: { dashboard.edge }, set: { edge in store.update(dashboard.id) { $0.bandEdge = edge } })) {
                    ForEach(Dashboard.BandEdge.allCases) { Text($0.rawValue.capitalized).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Speed", selection: Binding(get: { band.speed }, set: { v in store.updateBand(on: dashboard.id) { $0.speed = v } })) {
                    Text("Slow").tag(1); Text("Normal").tag(2); Text("Fast").tag(3)
                }
                .pickerStyle(.segmented)
                SectionLabel(title: "Tickers")
                TextField("SPX IDX, AAPL US EQ, BTC CRYPTO", text: $text, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(3...8)
                    .onChange(of: text) { commit() }
                Button("Use watchlist") { text = watchlist.joined(separator: ", ") }.controlSize(.small)
            }
        }
        .onAppear { text = dashboard.band?.securities.joined(separator: ", ") ?? "" }
        .onChange(of: dashboard.band != nil) { text = dashboard.band?.securities.joined(separator: ", ") ?? "" }
    }

    private func commit() {
        let list = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }.filter { !$0.isEmpty }
        if list != dashboard.band?.securities { store.updateBand(on: dashboard.id) { $0.securities = list } }
    }
}
