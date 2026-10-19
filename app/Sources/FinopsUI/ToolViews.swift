import FinopsCore
import FinopsDash
import SwiftUI

// MARK: PORT

struct PortfolioView: View {
    let model: TerminalModel
    let run: (String) -> Void

    @State private var security = ""
    @State private var quantity = ""
    @State private var cost = ""

    var body: some View {
        let quotes = model.quotes.quotes
        let rows = model.positions.map { p -> (Position, Quote?, Double?) in
            let q = quotes[p.security]
            return (p, q, q.map { $0.last * p.quantity })
        }
        let total = rows.compactMap(\.2).reduce(0, +)
        let costBasis = model.positions.reduce(0) { $0 + $1.cost * $1.quantity }
        let dayPnL = rows.reduce(0.0) { acc, r in acc + ((r.1?.change ?? 0) * r.0.quantity) }

        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 24) {
                    stat("Market value", Format.price(total), Palette.text)
                    stat("Total P&L", Format.signed(total - costBasis), Palette.direction(total - costBasis))
                    stat("Return", Format.percent(costBasis > 0 ? (total / costBasis - 1) * 100 : nil),
                         Palette.direction(total - costBasis))
                    stat("Today", Format.signed(dayPnL), Palette.direction(dayPnL))
                }
                addForm
                if model.positions.isEmpty {
                    Text("No positions yet. Add one above, or type e.g. AAPL US EQ PORT ADD 10 180")
                        .foregroundStyle(Palette.muted)
                } else {
                    positionsGrid(rows, total: total)
                }
                Text("Prices: Yahoo Finance (may be delayed). Mixed currencies are summed as-is.")
                    .font(.terminalSmall).foregroundStyle(Palette.muted)
            }
            .padding(14)
        }
    }

    private func stat(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionLabel(title: label)
            Text(value).font(.title3.monospaced()).foregroundStyle(color).monospacedDigit()
        }
    }

    private var addForm: some View {
        HStack(spacing: 6) {
            field("Security (e.g. AAPL US EQ)", $security, width: 200)
            field("Quantity", $quantity, width: 80)
            field("Cost / share (blank = last)", $cost, width: 170)
            Button("Add position") {
                guard !security.isEmpty, Double(quantity) != nil else { return }
                let parts = ["PORT", "ADD", quantity] + (Double(cost) != nil ? [cost] : [])
                run("\(security) " + parts.joined(separator: " "))
                security = ""; quantity = ""; cost = ""
            }
            .buttonStyle(TerminalButtonStyle(selected: true))
            .disabled(security.isEmpty || Double(quantity) == nil)
        }
    }

    private func positionsGrid(_ rows: [(Position, Quote?, Double?)], total: Double) -> some View {
        Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: 5) {
            GridRow {
                Text("Security").gridColumnAlignment(.leading)
                Text("Qty"); Text("Cost"); Text("Last"); Text("Day %"); Text("Value"); Text("P&L"); Text("P&L %"); Text("Weight"); Text("")
            }
            .font(.terminalLabel).foregroundStyle(Palette.muted)
            ForEach(rows, id: \.0.id) { p, q, value in
                let pnl = value.map { $0 - p.cost * p.quantity }
                GridRow {
                    Button(p.security) { run("\(p.security) QUOTE") }
                        .buttonStyle(.plain).foregroundStyle(Palette.accent)
                    Text(Format.number(p.quantity))
                    Text(Format.price(p.cost))
                    Text(Format.price(q?.last))
                    Text(Format.percent(q?.changePct)).foregroundStyle(Palette.direction(q?.changePct))
                    Text(Format.price(value))
                    Text(Format.signed(pnl)).foregroundStyle(Palette.direction(pnl))
                    Text(Format.percent(pnl.flatMap { p.cost > 0 ? $0 / (p.cost * p.quantity) * 100 : nil }))
                        .foregroundStyle(Palette.direction(pnl))
                    Text(value.map { total > 0 ? Format.number($0 / total * 100, digits: 1) + "%" : "—" } ?? "—")
                    Button { model.removePosition(p) } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain).foregroundStyle(Palette.muted)
                        .help("Remove position").accessibilityLabel("Remove \(p.security)")
                }
                .monospacedDigit()
            }
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(10)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: ALERT

struct AlertsView: View {
    let model: TerminalModel
    let defaultSecurity: String?
    let client: DataClient
    let run: (String) -> Void

    @State private var security = ""
    @State private var above = true
    @State private var price = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Price alerts").font(.system(size: 14, weight: .semibold, design: .monospaced))
                HStack(spacing: 6) {
                    field("Security", $security, width: 200)
                    Button("≥ above") { above = true }.buttonStyle(TerminalButtonStyle(selected: above))
                    Button("≤ below") { above = false }.buttonStyle(TerminalButtonStyle(selected: !above))
                    field("Price", $price, width: 100)
                    Button("Add alert") {
                        guard let p = Double(price), !security.isEmpty else { return }
                        model.addAlert(security: security, above: above, price: p)
                        price = ""
                    }
                    .buttonStyle(TerminalButtonStyle(selected: true))
                    .disabled(security.isEmpty || Double(price) == nil)
                }
                Text("Or type: AAPL US EQ ALERT > 350. Alerts are checked while the app is open.")
                    .font(.terminalSmall).foregroundStyle(Palette.muted)

                if model.alerts.isEmpty {
                    Text("No alerts.").foregroundStyle(Palette.muted)
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                        GridRow {
                            Text("Security"); Text("Condition"); Text("Last"); Text("Distance"); Text("Status"); Text("")
                        }
                        .font(.terminalLabel).foregroundStyle(Palette.muted)
                        ForEach(model.alerts) { alert in
                            let last = model.quotes.quotes[alert.security]?.last
                            GridRow {
                                Text(alert.security).foregroundStyle(Palette.accent)
                                Text(alert.condition)
                                Text(Format.price(last)).monospacedDigit()
                                Text(last.map { Format.percent((alert.price / $0 - 1) * 100) } ?? "—").monospacedDigit()
                                if let at = alert.triggeredAt {
                                    Text("triggered \(at.formatted(date: .abbreviated, time: .shortened))").foregroundStyle(Palette.down)
                                } else {
                                    Text("active").foregroundStyle(Palette.up)
                                }
                                HStack(spacing: 8) {
                                    if alert.triggeredAt != nil {
                                        Button("Re-arm") { model.rearm(alert) }.buttonStyle(TerminalButtonStyle())
                                    }
                                    Button { model.removeAlert(alert) } label: { Image(systemName: "trash") }
                                        .buttonStyle(.plain).foregroundStyle(Palette.muted)
                                        .accessibilityLabel("Delete alert")
                                }
                            }
                        }
                    }
                    .font(.system(size: 12, design: .monospaced))
                    .padding(10)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 4))
                }
                quickAlerts
            }
            .padding(14)
            Divider().overlay(Palette.border)
            // The watchlist's last month under the alerts, so the page is useful all the way down.
            DocumentView(client: client, service: "grid",
                         params: ["securities": model.watchlist.joined(separator: ";"), "range": "1M"], run: run)
        }
        .onAppear {
            if security.isEmpty { security = defaultSecurity ?? "" }
            model.quotes.track(Set(model.watchlist), for: "alerts-watchlist")
        }
    }

    /// The watchlist with one-click alerts a few percent away from the last price.
    private var quickAlerts: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("QUICK ALERTS · WATCHLIST").font(.terminalLabel).tracking(1).foregroundStyle(Palette.accent)
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow {
                    Text("Security"); Text("Last"); Text("Change"); Text("Alert at")
                }
                .font(.terminalLabel).foregroundStyle(Palette.muted)
                ForEach(model.watchlist, id: \.self) { typed in
                    let quote = model.quotes.quotes[typed]
                    GridRow {
                        Button(typed) { security = typed }.buttonStyle(.plain).foregroundStyle(Palette.accent)
                        Text(Format.price(quote?.last)).monospacedDigit()
                        Text(Format.percent(quote?.changePct)).foregroundStyle(Palette.direction(quote?.changePct)).monospacedDigit()
                        HStack(spacing: 6) {
                            ForEach([-5.0, -2.0, 2.0, 5.0], id: \.self) { pct in
                                Button(pct > 0 ? "+\(Int(pct))%" : "\(Int(pct))%") {
                                    guard let last = quote?.last else { return }
                                    model.addAlert(security: typed, above: pct > 0, price: last * (1 + pct / 100))
                                }
                                .buttonStyle(TerminalButtonStyle())
                                .disabled(quote?.last == nil)
                            }
                        }
                    }
                }
            }
            .font(.system(size: 12, design: .monospaced))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 4))
    }
}

private func field(_ placeholder: String, _ text: Binding<String>, width: CGFloat) -> some View {
    TextField(placeholder, text: text)
        .textFieldStyle(.plain)
        .font(.terminalSmall)
        .frame(width: width)
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(Palette.background, in: RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Palette.border))
}

// MARK: HELP

struct HelpView: View {
    let run: (String) -> Void

    private let examples: [(String, String)] = [
        ("AAPL US EQ", "Load Apple (keeps the current screen)"),
        ("CHART 5Y CANDLE VOL SMA50 RSI", "Candles, volume, 50-day average and RSI over 5 years"),
        ("CHART 1Y VS MSFT,^GSPC", "Compare with Microsoft and the S&P 500 in %"),
        ("FIN Q CF", "Quarterly cash-flow statement"),
        ("SCRN MCAP>10B PE<15 SECTOR=TECHNOLOGY", "Cheap large-cap tech stocks"),
        ("ECON UNRATE 20Y", "Unemployment rate over 20 years"),
        ("ECON CPIAUCSL 10Y YOY", "CPI inflation, % change from a year ago"),
        ("AAPL US EQ ALERT > 350", "Alert when Apple crosses 350"),
        ("NVDA US EQ PORT ADD 10 120", "Add 10 NVDA at 120 to the portfolio"),
        ("TSLA US EQ WATCH", "Add Tesla to the current watchlist"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section("Two ways to drive it") {
                    Text("Click: search on the left, the function tabs on each panel, buttons inside screens, and table rows. Type: the command line at the bottom (⌘L) takes [security] [function] [options]. Both always do the same thing — hover a button to see its command.")
                        .foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(FunctionID.Group.allCases, id: \.self) { group in
                    section(group.rawValue) {
                        ForEach(FunctionID.allCases.filter { $0.group == group }, id: \.self) { function in
                            HStack(alignment: .firstTextBaseline, spacing: 16) {
                                Button(function.aliases.joined(separator: " / ")) { run(function.rawValue) }
                                    .buttonStyle(.plain).foregroundStyle(Palette.accent)
                                    .frame(width: 170, alignment: .leading)
                                Text(function.summary).foregroundStyle(Palette.muted)
                            }
                        }
                    }
                }
                section("Examples (click to run)") {
                    ForEach(examples, id: \.0) { cmd, text in
                        HStack(alignment: .firstTextBaseline, spacing: 16) {
                            Button(cmd) { run(cmd) }.buttonStyle(.plain).foregroundStyle(Palette.accent)
                                .frame(width: 330, alignment: .leading)
                            Text(text).foregroundStyle(Palette.muted)
                        }
                    }
                }
                section("Securities") {
                    Text("<symbol> [venue] <class>. Classes: EQ ETF FX IDX CMD CRYPTO. Venues: US LN FP GY NA IM SM SW JP HK CN AU. Bare Yahoo symbols (MSFT, ^GSPC, EURUSD=X) also work.")
                        .foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                }
                section("Keys") {
                    ForEach([("⌘1…⌘9, ⌘0", "Security functions in the active panel"), ("⌥⌘1 / ⌥⌘2 / ⌥⌘4", "1, 2 or 4 panels"),
                             ("⌘[", "Back"), ("⌘L", "Command line"), ("⌘,", "Settings (FRED key, EDGAR contact)"),
                             ("number ⏎", "Numbered action, e.g. chart ranges 1–11")], id: \.0) { key, text in
                        HStack(spacing: 16) {
                            Text(key).foregroundStyle(Palette.accent).frame(width: 170, alignment: .leading)
                            Text(text).foregroundStyle(Palette.muted)
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(title: title)
            content()
        }
    }
}
