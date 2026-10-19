import FinopsCore
import FinopsDash
import SwiftUI

/// One workspace panel: its own header (back, security, function tabs, link) and screen.
struct PanelView: View {
    let model: TerminalModel
    let panel: PanelModel

    private var isActive: Bool { model.activePanelID == panel.id }
    private var state: PanelState { panel.state }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Palette.border)
            screen
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Palette.background)
        .overlay(
            Rectangle().stroke(isActive && model.panels.count > 1 ? Palette.accent.opacity(0.7) : .clear, lineWidth: 1)
        )
        .simultaneousGesture(TapGesture().onEnded { model.activate(panel) })
    }

    private func run(_ command: String) {
        model.run(command, in: panel)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button { model.back(panel) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(TerminalButtonStyle())
                    .disabled(!panel.canGoBack)
                    .help("Back (⌘[)")
                    .accessibilityLabel("Back")
                Text(state.security ?? "—")
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(state.security == nil ? Palette.muted : Palette.accent)
                    .lineLimit(1)
                Text(state.function.title).foregroundStyle(Palette.muted).lineLimit(1)
                Spacer()
                Button {
                    let file = model.cases.pin(command: state.command,
                                               title: "\(state.security.map { "\($0) · " } ?? "")\(state.function.title)")
                    model.show(message: "Pinned to case \(file.name)")
                } label: { Image(systemName: "pin") }
                .buttonStyle(TerminalButtonStyle())
                .help("Pin this screen to the current case (CASE PIN)")
                .accessibilityLabel("Pin to case")
                Button { panel.linked.toggle() } label: {
                    Image(systemName: panel.linked ? "link" : "link.badge.plus")
                }
                .buttonStyle(TerminalButtonStyle(selected: panel.linked))
                .help(panel.linked ? "Linked: follows the security of other linked panels" : "Not linked")
                .accessibilityLabel(panel.linked ? "Unlink panel" : "Link panel")
                if model.panels.count > 1 {
                    Button { model.close(panel) } label: { Image(systemName: "xmark") }
                        .buttonStyle(TerminalButtonStyle())
                        .help("Close panel")
                        .accessibilityLabel("Close panel")
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(FunctionID.allCases.filter { $0.group == .security }, id: \.self) { function in
                        Button(function.rawValue) { model.open(function, in: panel) }
                            .buttonStyle(TerminalButtonStyle(selected: state.function == function))
                            .disabled(state.security == nil && function.needsSecurity)
                            .help("\(function.title) — \(function.summary)")
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Palette.surface)
    }

    // MARK: Screen routing

    @ViewBuilder
    private var screen: some View {
        if let client = model.client {
            routed(client)
                .id(stateKey)
        } else if case .failed(let reason) = model.connection {
            StatusMessage(title: "Data gateway failed to start", detail: reason, isError: true)
        } else {
            StatusMessage(title: "Starting data gateway…", detail: "The first launch installs Python dependencies and can take a minute.")
        }
    }

    /// The current watchlist, or securities given as args ("PERF AAPL,MSFT").
    private func watchlistParam(_ args: [String]) -> String {
        args.isEmpty ? model.watchlist.joined(separator: ";") : args.joined(separator: " ")
    }

    private var positionsParam: String {
        model.positions.map { "\($0.security)|\($0.quantity)" }.joined(separator: ";")
    }

    /// DCF args like W9 G10 T2.5 → service params (percent numbers).
    private func dcfParams(security: String, args: [String]) -> [String: String] {
        var params = ["security": security]
        for arg in args {
            guard let key = ["W": "wacc", "G": "growth", "T": "terminal"][String(arg.prefix(1))],
                  Double(arg.dropFirst()) != nil else { continue }
            params[key] = String(arg.dropFirst())
        }
        return params
    }

    private func portfolioTabs(risk: Bool) -> some View {
        HStack(spacing: 4) {
            Button("Positions") { run("PORT") }.buttonStyle(TerminalButtonStyle(selected: !risk))
            Button("Risk & analytics") { run("PORT RISK") }.buttonStyle(TerminalButtonStyle(selected: risk))
                .disabled(model.positions.isEmpty)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
    }

    private var stateKey: String {
        "\(model.clientGeneration)|\(state.security ?? "")|\(state.function.rawValue)|\(state.args.joined(separator: " "))"
    }

    @ViewBuilder
    private func routed(_ client: DataClient) -> some View {
        let security = state.security ?? ""
        let args = state.args
        switch state.function {
        case .quote:
            QuoteView(client: client, security: security, onError: model.report)
        case .chart:
            ChartView(client: client, security: security, config: state.chart, run: run,
                      onChange: { model.setArgs($0.args, in: panel) }, onError: model.report)
        case .desc:
            DocumentView(client: client, service: "profile", params: ["security": security], run: run)
        case .news:
            DocumentView(client: client, service: "news",
                         params: args.isEmpty && !security.isEmpty ? ["security": security] : ["query": args.joined(separator: " ")],
                         run: run)
        case .fin:
            DocumentView(client: client, service: "financials", params: [
                "security": security,
                "period": args.contains("Q") ? "Q" : "A",
                "statement": args.first { ["IS", "BS", "CF"].contains($0) } ?? "IS",
            ], run: run)
        case .est:
            DocumentView(client: client, service: "estimates", params: ["security": security], run: run)
        case .evt:
            DocumentView(client: client, service: "events", params: ["security": security], run: run)
        case .hold:
            DocumentView(client: client, service: "holders", params: ["security": security], run: run)
        case .file:
            DocumentView(client: client, service: "filings", params: ["security": security, "group": args.first ?? "ALL"], run: run)
        case .opt:
            DocumentView(client: client, service: "options", params: ["security": security, "expiry": args.first ?? ""], run: run)
        case .mkt:
            DocumentView(client: client, service: "market", params: [:], run: run)
        case .movers:
            DocumentView(client: client, service: "movers", params: ["kind": args.first ?? "GAINERS"], run: run)
        case .scrn:
            DocumentView(client: client, service: "screen", params: ["filters": args.joined(separator: " ")], run: run)
        case .econ:
            if args.first == "SEARCH" {
                DocumentView(client: client, service: "econ_search", params: ["query": args.dropFirst().joined(separator: " ")], run: run)
            } else if let id = args.first {
                EconSeriesView(client: client, id: id,
                               range: args.dropFirst().first { $0 != "YOY" } ?? "10Y",
                               yoy: args.contains("YOY"), run: run)
            } else {
                DocumentView(client: client, service: "econ", params: [:], run: run)
            }
        case .curve:
            CurveView(client: client)
        case .port where args.first == "RISK":
            VStack(spacing: 0) {
                portfolioTabs(risk: true)
                DocumentView(client: client, service: "portfolio", params: ["positions": positionsParam], run: run)
            }
        case .port:
            VStack(spacing: 0) {
                portfolioTabs(risk: false)
                if model.positions.isEmpty {
                    // No positions yet: the add form, then the watchlist's performance instead of a black page.
                    PortfolioView(model: model, run: run).frame(height: 150)
                    Divider().overlay(Palette.border)
                    DocumentView(client: client, service: "perf", params: ["securities": watchlistParam([])], run: run)
                } else {
                    PortfolioView(model: model, run: run)
                }
            }
        case .rv:
            DocumentView(client: client, service: "rv", params: ["security": security, "x": args.first ?? "FPE",
                                                                  "y": args.dropFirst().first ?? "GROWTH"], run: run)
        case .rels:
            DocumentView(client: client, service: "rels", params: ["security": security], run: run)
        case .dcf:
            DocumentView(client: client, service: "dcf", params: dcfParams(security: security, args: args), run: run)
        case .why:
            DocumentView(client: client, service: "why", params: ["security": security], run: run)
        case .sent:
            DocumentView(client: client, service: "sentiment", params: ["security": security], run: run)
        case .heat:
            DocumentView(client: client, service: "heatmap", params: [
                "period": args.first { ["1D", "1W", "1M", "3M", "YTD", "1Y"].contains($0) } ?? "1D",
                "sector": args.first { !["1D", "1W", "1M", "3M", "YTD", "1Y"].contains($0) } ?? "",
            ], run: run)
        case .fxm:
            DocumentView(client: client, service: "fxmatrix", params: [:], run: run)
        case .wbi:
            DocumentView(client: client, service: "worldbank", params: ["indicator": args.first ?? "GDP"], run: run)
        case .cbr:
            DocumentView(client: client, service: "centralbanks", params: [:], run: run)
        case .perf:
            DocumentView(client: client, service: "perf", params: ["securities": watchlistParam(args)], run: run)
        case .charts:
            DocumentView(client: client, service: "grid", params: ["securities": watchlistParam([]), "range": args.first ?? "3M"], run: run)
        case .corr:
            DocumentView(client: client, service: "corr", params: ["securities": watchlistParam([]), "range": args.first ?? "1Y"], run: run)
        case .quant:
            QuantView()
        case .tv:
            TVView(args: args, run: run)
        case .world:
            DocumentView(client: client, service: "world", params: ["kind": args.first ?? "ALL"], run: run)
        case .link where args.isEmpty && !security.isEmpty:
            DocumentView(client: client, service: "link", params: ["query": security], run: run)
        case .link:
            DocumentView(client: client, service: "link", params: ["query": args.isEmpty ? "HORMUZ" : args.joined(separator: " ")], run: run)
        case .study:
            DocumentView(client: client, service: "study", params: ["security": security.isEmpty ? "SPX IDX" : security,
                                                                     "args": args.joined(separator: " ")], run: run)
        case .rule:
            RulesView(book: model.rules, client: client, run: run)
        case .caseFile where state.args.first?.uppercased() == "FEED":
            DocumentView(client: client, service: "case_feed", params: ["terms": args.dropFirst().joined(separator: " ")], run: run)
        case .caseFile:
            CasesView(model: model, client: client, run: run)
        case .expo:
            DocumentView(client: client, service: "exposure", params: [
                "positions": model.positions.isEmpty || args.first == "WATCH" ? model.watchlist.joined(separator: ";") : positionsParam,
            ], run: run)
        case .dash:
            DashboardBuilderView(model: model, client: model.client)
        case .read:
            ReaderView(client: client, link: args.joined(separator: " "), run: run)
        case .etf where args.isEmpty && !security.isEmpty:
            DocumentView(client: client, service: "etf", params: ["security": security], run: run)
        case .etf:
            DocumentView(client: client, service: "etf", params: ["list": args.first ?? "TOP"], run: run)
        case .rwa:
            DocumentView(client: client, service: "rwa", params: ["kind": args.first ?? "OVERVIEW"], run: run)
        case .crypto where args.isEmpty && security.hasSuffix(" CRYPTO"):
            DocumentView(client: client, service: "crypto", params: ["security": security], run: run)
        case .crypto:
            DocumentView(client: client, service: "crypto", params: ["quote": args.first ?? "USDT"], run: run)
        case .ecal:
            DocumentView(client: client, service: "calendar", params: [
                "kind": args.contains("EARN") ? "EARN" : "ECO",
                "span": args.first { ["TODAY", "WEEK", "2WEEKS"].contains($0) } ?? "WEEK",
                "region": args.first { !["ECO", "EARN", "TODAY", "WEEK", "2WEEKS"].contains($0) } ?? "MAJOR",
            ], run: run)
        case .alert:
            AlertsView(model: model, defaultSecurity: state.security, client: client, run: run)
        case .help:
            HelpView(run: run)
        }
    }
}
