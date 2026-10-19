import Charts
import FinopsCore
import FinopsDash
import SwiftUI

/// QUANT: CFA-style calculators computed on the device (no data needed).
struct QuantView: View {
    enum Tab: String, CaseIterable { case tvm = "Time value", bond = "Bond", option = "Option" }
    @State private var tab: Tab = .tvm

    var body: some View {
        // No scroll: inputs on top, the calculator's chart takes the rest of the panel.
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 4) {
                ForEach(Tab.allCases, id: \.self) { t in
                    Button(t.rawValue) { tab = t }.buttonStyle(TerminalButtonStyle(selected: tab == t))
                }
            }
            switch tab {
            case .tvm: TVMCalculator()
            case .bond: BondCalculator()
            case .option: OptionCalculator()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// A labelled numeric input bound to a Double.
private struct NumberField: View {
    let label: String
    @Binding var value: Double
    var suffix: String = ""

    var body: some View {
        HStack {
            Text(label).foregroundStyle(Palette.muted).frame(width: 190, alignment: .leading)
            TextField(label, value: $value, format: .number.precision(.fractionLength(0...6)))
                .textFieldStyle(.plain)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .frame(width: 140)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Palette.background, in: RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Palette.border))
            Text(suffix).foregroundStyle(Palette.muted).frame(width: 40, alignment: .leading)
        }
        .font(.system(size: 12, design: .monospaced))
    }
}

private func output(_ label: String, _ value: String, highlight: Bool = false) -> some View {
    HStack {
        Text(label).foregroundStyle(Palette.muted).frame(width: 190, alignment: .leading)
        Text(value).monospacedDigit().foregroundStyle(highlight ? Palette.accent : Palette.text)
            .font(.system(size: highlight ? 15 : 12, weight: highlight ? .bold : .regular, design: .monospaced))
    }
    .font(.system(size: 12, design: .monospaced))
}

/// The full-height chart under a calculator.
@MainActor
private func chartCard(_ title: String, @ViewBuilder content: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: 6) {
        SectionLabel(title: title)
        content()
            .chartXAxis { AxisMarks { _ in AxisGridLine().foregroundStyle(Palette.border); AxisValueLabel().foregroundStyle(Palette.muted) } }
            .chartYAxis { AxisMarks(position: .trailing) { _ in AxisGridLine().foregroundStyle(Palette.border); AxisValueLabel().foregroundStyle(Palette.muted) } }
            .chartLegend(position: .top, alignment: .leading)
    }
    .padding(12)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 4))
    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Palette.border))
}

private func card(_ title: String, @ViewBuilder content: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: 6) {
        SectionLabel(title: title)
        content()
    }
    .padding(12)
    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 4))
    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Palette.border))
}

private struct TVMCalculator: View {
    @State private var pv = 10_000.0
    @State private var pmt = 0.0
    @State private var rate = 5.0
    @State private var years = 10.0
    @State private var perYear = 12.0
    @State private var flows = "-1000, 300, 400, 500"

    var body: some View {
        let r = rate / 100 / perYear, n = years * perYear
        let cfs = flows.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        let horizon = max(1, Int(years.rounded()))
        let growth = (0...horizon).map { y in (y, Quant.futureValue(pv: pv, pmt: pmt, rate: r, n: Double(y) * perYear)) }
        VStack(alignment: .leading, spacing: 14) {
        HStack(alignment: .top, spacing: 14) {
            card("Future value & payment") {
                NumberField(label: "Present value", value: $pv)
                NumberField(label: "Payment per period", value: $pmt)
                NumberField(label: "Annual rate", value: $rate, suffix: "%")
                NumberField(label: "Years", value: $years)
                NumberField(label: "Periods per year", value: $perYear)
                Divider().overlay(Palette.border)
                output("Future value", Format.price(Quant.futureValue(pv: pv, pmt: pmt, rate: r, n: n)), highlight: true)
                output("Payment to amortise PV", Format.price(Quant.payment(pv: pv, rate: r, n: n)))
                output("Effective annual rate", Format.number((pow(1 + r, perYear) - 1) * 100, digits: 4) + "%")
            }
            card("NPV & IRR") {
                HStack {
                    Text("Cash flows t=0,1,2…").foregroundStyle(Palette.muted).frame(width: 190, alignment: .leading)
                    TextField("e.g. -1000, 300, 400", text: $flows)
                        .textFieldStyle(.plain)
                        .frame(width: 220)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Palette.background, in: RoundedRectangle(cornerRadius: 3))
                }
                .font(.system(size: 12, design: .monospaced))
                NumberField(label: "Discount rate", value: $rate, suffix: "%")
                Divider().overlay(Palette.border)
                output("NPV", Format.price(Quant.npv(rate: rate / 100, cashFlows: cfs)), highlight: true)
                output("IRR", Quant.irr(cashFlows: cfs).map { Format.number($0 * 100, digits: 4) + "%" } ?? "—")
            }
        }
        chartCard("Value over time") {
            Chart(growth, id: \.0) { y, value in
                AreaMark(x: .value("Year", y), y: .value("Value", value))
                    .foregroundStyle(LinearGradient(colors: [Palette.accent.opacity(0.3), .clear], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Year", y), y: .value("Value", value)).foregroundStyle(Palette.accent)
            }
        }
        }
    }
}

private struct BondCalculator: View {
    @State private var face = 100.0
    @State private var coupon = 4.0
    @State private var ytm = 5.0
    @State private var years = 10.0
    @State private var frequency = 2.0
    @State private var price = 95.0

    var body: some View {
        let b = Quant.bond(face: face, couponRate: coupon / 100, ytm: ytm / 100, years: years, frequency: max(Int(frequency), 1))
        let curve = stride(from: max(0.1, ytm - 5), through: ytm + 5, by: 0.25).map { y in
            (y, Quant.bond(face: face, couponRate: coupon / 100, ytm: y / 100, years: years, frequency: max(Int(frequency), 1)).price)
        }
        VStack(alignment: .leading, spacing: 14) {
        HStack(alignment: .top, spacing: 14) {
            card("Price from yield") {
                NumberField(label: "Face value", value: $face)
                NumberField(label: "Coupon rate", value: $coupon, suffix: "%")
                NumberField(label: "Yield to maturity", value: $ytm, suffix: "%")
                NumberField(label: "Years to maturity", value: $years)
                NumberField(label: "Coupons per year", value: $frequency)
                Divider().overlay(Palette.border)
                output("Price", Format.number(b.price, digits: 4), highlight: true)
                output("Macaulay duration", Format.number(b.macaulayDuration, digits: 4) + " y")
                output("Modified duration", Format.number(b.modifiedDuration, digits: 4))
                output("Convexity", Format.number(b.convexity, digits: 4))
                output("Current yield", Format.number(b.currentYield * 100, digits: 4) + "%")
                output("Δ price for +100 bp", Format.signed((-b.modifiedDuration * 0.01 + 0.5 * b.convexity * 0.0001) * 100, digits: 3) + "%")
            }
            card("Yield from price") {
                NumberField(label: "Clean price", value: $price)
                Divider().overlay(Palette.border)
                output("Yield to maturity", Quant.yieldToMaturity(price: price, face: face, couponRate: coupon / 100, years: years,
                                                                  frequency: max(Int(frequency), 1))
                    .map { Format.number($0 * 100, digits: 4) + "%" } ?? "—", highlight: true)
            }
        }
        chartCard("Price vs yield (convexity)") {
            Chart {
                ForEach(curve, id: \.0) { y, p in
                    LineMark(x: .value("Yield %", y), y: .value("Price", p)).foregroundStyle(Palette.accent)
                }
                PointMark(x: .value("Yield %", ytm), y: .value("Price", b.price)).foregroundStyle(.white).symbolSize(60)
                RuleMark(x: .value("Yield %", ytm)).foregroundStyle(Palette.muted.opacity(0.5))
            }
        }
        }
    }
}

private struct OptionCalculator: View {
    @State private var spot = 100.0
    @State private var strike = 100.0
    @State private var days = 90.0
    @State private var rate = 4.0
    @State private var vol = 25.0
    @State private var dividend = 0.0

    var body: some View {
        let t = max(days, 1) / 365
        let args = (spot: spot, strike: strike, years: t, rate: rate / 100, vol: max(vol, 0.01) / 100, q: dividend / 100)
        let call = Quant.blackScholes(call: true, spot: args.spot, strike: args.strike, years: args.years, rate: args.rate,
                                      volatility: args.vol, dividendYield: args.q)
        let put = Quant.blackScholes(call: false, spot: args.spot, strike: args.strike, years: args.years, rate: args.rate,
                                     volatility: args.vol, dividendYield: args.q)
        let spots = stride(from: strike * 0.5, through: strike * 1.5, by: strike / 50).map { $0 }
        let lines: [(String, Double, Double)] = spots.flatMap { x -> [(String, Double, Double)] in
            let c = Quant.blackScholes(call: true, spot: x, strike: strike, years: t, rate: args.rate, volatility: args.vol, dividendYield: args.q)
            let p = Quant.blackScholes(call: false, spot: x, strike: strike, years: t, rate: args.rate, volatility: args.vol, dividendYield: args.q)
            return [("Call today", x, c.price), ("Put today", x, p.price),
                    ("Call at expiry", x, max(x - strike, 0)), ("Put at expiry", x, max(strike - x, 0))]
        }
        VStack(alignment: .leading, spacing: 14) {
        HStack(alignment: .top, spacing: 14) {
            card("Black–Scholes–Merton inputs") {
                NumberField(label: "Spot", value: $spot)
                NumberField(label: "Strike", value: $strike)
                NumberField(label: "Days to expiry", value: $days)
                NumberField(label: "Risk-free rate", value: $rate, suffix: "%")
                NumberField(label: "Volatility", value: $vol, suffix: "%")
                NumberField(label: "Dividend yield", value: $dividend, suffix: "%")
            }
            card("Price & Greeks") {
                Grid(alignment: .trailing, horizontalSpacing: 24, verticalSpacing: 5) {
                    GridRow {
                        Text("").gridColumnAlignment(.leading)
                        Text("Call").foregroundStyle(Heat.up)
                        Text("Put").foregroundStyle(Heat.down)
                    }
                    greek("Price", call.price, put.price, digits: 4)
                    greek("Delta", call.delta, put.delta, digits: 4)
                    greek("Gamma", call.gamma, put.gamma, digits: 5)
                    greek("Vega (per 1 vol pt)", call.vega / 100, put.vega / 100, digits: 4)
                    greek("Theta (per day)", call.theta / 365, put.theta / 365, digits: 4)
                    greek("Rho (per 1% rate)", call.rho / 100, put.rho / 100, digits: 4)
                }
                .font(.system(size: 12, design: .monospaced))
                .monospacedDigit()
            }
        }
        chartCard("Value vs spot · today and at expiry") {
            Chart {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                    LineMark(x: .value("Spot", l.1), y: .value("Value", l.2), series: .value("Line", l.0))
                        .foregroundStyle(by: .value("Line", l.0))
                        .lineStyle(StrokeStyle(lineWidth: l.0.contains("expiry") ? 1 : 2, dash: l.0.contains("expiry") ? [4, 3] : []))
                }
                RuleMark(x: .value("Spot", spot)).foregroundStyle(.white.opacity(0.5))
            }
            .chartForegroundStyleScale(["Call today": Heat.up, "Put today": Heat.down,
                                        "Call at expiry": Heat.up.opacity(0.5), "Put at expiry": Heat.down.opacity(0.5)])
        }
        }
    }

    private func greek(_ name: String, _ c: Double, _ p: Double, digits: Int) -> some View {
        GridRow {
            Text(name).foregroundStyle(Palette.muted)
            Text(Format.number(c, digits: digits))
            Text(Format.number(p, digits: digits))
        }
    }
}

/// World market clocks (TradingView/Bloomberg-style strip), with a dot when the exchange is open.
struct MarketClocks: View {
    private static let markets: [(String, String, (Int, Int), (Int, Int))] = [
        ("NY", "America/New_York", (9, 30), (16, 0)),
        ("LON", "Europe/London", (8, 0), (16, 30)),
        ("PAR", "Europe/Paris", (9, 0), (17, 30)),
        ("TKY", "Asia/Tokyo", (9, 0), (15, 30)),
        ("HK", "Asia/Hong_Kong", (9, 30), (16, 0)),
        ("SYD", "Australia/Sydney", (10, 0), (16, 0)),
    ]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 10) {
                ForEach(Self.markets, id: \.0) { name, zone, open, close in
                    let tz = TimeZone(identifier: zone)!
                    var cal = Calendar(identifier: .gregorian)
                    let _ = cal.timeZone = tz
                    let comps = cal.dateComponents([.hour, .minute, .weekday], from: context.date)
                    let minutes = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
                    let isOpen = (2...6).contains(comps.weekday ?? 1)
                        && minutes >= open.0 * 60 + open.1 && minutes < close.0 * 60 + close.1
                    HStack(spacing: 3) {
                        Circle().fill(isOpen ? Heat.up : Palette.muted.opacity(0.4)).frame(width: 5, height: 5)
                        Text(name).foregroundStyle(Palette.muted)
                        Text(String(format: "%02d:%02d", comps.hour ?? 0, comps.minute ?? 0))
                            .foregroundStyle(isOpen ? Palette.text : Palette.muted)
                    }
                    .font(.system(size: 10, design: .monospaced))
                    .help("\(zone) · \(isOpen ? "open" : "closed")")
                }
            }
        }
    }
}
