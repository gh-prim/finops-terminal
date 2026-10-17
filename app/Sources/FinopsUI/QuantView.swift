import FinopsCore
import SwiftUI

/// QUANT: CFA-style calculators computed on the device (no data needed).
struct QuantView: View {
    enum Tab: String, CaseIterable { case tvm = "Time value", bond = "Bond", option = "Option" }
    @State private var tab: Tab = .tvm

    var body: some View {
        ScrollView {
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
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
