import FinopsCore
import SwiftUI

struct HelpView: View {
    private let examples: [(String, String)] = [
        ("AAPL US EQ", "Load Apple and show its quote"),
        ("CHART 5Y", "Chart the loaded security over 5 years"),
        ("VOD LN EQ CHART 1M", "Load Vodafone (London) and chart 1 month"),
        ("EURUSD FX", "Euro / US dollar"),
        ("SPX IDX CH YTD", "S&P 500 year to date"),
        ("CL1 CMD", "Front-month crude oil future"),
        ("BTC CRYPTO", "Bitcoin in USD"),
        ("3", "Numbered action: on a chart, 1–11 pick the range"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section("Getting around") {
                    Text("Search a ticker or company on the left, click a result to open it, and press + to add it to your watchlist. Use the QUOTE and CHART tabs at the top and the range buttons under the chart.")
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                section("Command line (optional)") {
                    Text("[security] [function] [args…]  ⏎").foregroundStyle(Palette.accent)
                    Text("Security: <symbol> [venue] <class>. Classes: EQ ETF FX IDX CMD CRYPTO. Venues: US LN FP GY NA IM SM SW JP HK CN AU.")
                        .foregroundStyle(Palette.muted)
                    Text("A bare symbol (e.g. MSFT, ^GSPC) is passed to Yahoo as-is.")
                        .foregroundStyle(Palette.muted)
                }
                section("Functions") {
                    ForEach(FunctionID.allCases, id: \.self) { function in
                        row(function.aliases.joined(separator: " / "), function.summary)
                    }
                }
                section("Examples") {
                    ForEach(examples, id: \.0) { row($0.0, $0.1) }
                }
                section("Keys") {
                    row("⌘1 / ⌘2", "Quote / Chart tabs")
                    row("⌘[", "Back")
                    row("⌘L", "Focus the command line")
                    row("esc", "Clear the command line")
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.terminalSmall).foregroundStyle(Palette.muted)
            content()
        }
    }

    private func row(_ key: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(key).foregroundStyle(Palette.accent).frame(width: 200, alignment: .leading)
            Text(text).foregroundStyle(Palette.muted)
        }
    }
}
