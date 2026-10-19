import FinopsCore
import FinopsDash
import SwiftUI

struct QuoteView: View {
    let client: DataClient
    let security: String
    let onError: (Error) -> Void

    @State private var info: SecurityInfo?
    @State private var quote: Quote?
    @State private var streamStatus: String?
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let failure, quote == nil {
                StatusMessage(title: "Couldn't load \(security)", detail: failure, isError: true)
            } else if let quote {
                header(quote)
                stats(quote)
                Text(statusLine(quote))
                    .font(.terminalSmall)
                    .foregroundStyle(Palette.muted)
            } else {
                ProgressView().controlSize(.small).padding(16)
            }
        }
        .padding(16)
        .task { await load() }
    }

    private func header(_ quote: Quote) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(info?.typed ?? security).foregroundStyle(Palette.accent)
                Text(info?.name ?? quote.symbol).foregroundStyle(Palette.muted)
            }
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(Format.price(quote.last))
                    .font(.system(size: 34, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(Format.signed(quote.change, digits: abs(quote.last) < 10 ? 4 : 2))
                    .foregroundStyle(Palette.direction(quote.change))
                Text(Format.percent(quote.changePct))
                    .foregroundStyle(Palette.direction(quote.changePct))
                if let currency = quote.currency {
                    Text(currency).foregroundStyle(Palette.muted)
                }
            }
            .monospacedDigit()
        }
    }

    private func stats(_ quote: Quote) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 6) {
            GridRow {
                stat("Open", Format.price(quote.open))
                stat("Prev close", Format.price(quote.previousClose))
            }
            GridRow {
                stat("Day high", Format.price(quote.dayHigh))
                stat("Day low", Format.price(quote.dayLow))
            }
            GridRow {
                stat("Volume", Format.compact(quote.volume))
                stat("Mkt cap", Format.compact(quote.marketCap))
            }
            GridRow {
                stat("Exchange", quote.exchange ?? "—")
                stat("Symbol", quote.symbol)
            }
        }
        .monospacedDigit()
    }

    private func stat(_ label: String, _ value: String) -> some View {
        HStack(spacing: 12) {
            Text(label).foregroundStyle(Palette.muted).frame(width: 90, alignment: .leading)
            Text(value).frame(minWidth: 110, alignment: .trailing)
        }
    }

    private func statusLine(_ quote: Quote) -> String {
        var parts = ["as of \(Format.time(quote.asOfDate))", "source Yahoo Finance (may be delayed)"]
        if let streamStatus { parts.append(streamStatus) }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        do {
            let ref = try await client.refData(security)
            info = ref.security
            quote = ref.quote
        } catch {
            failure = error.localizedDescription
            onError(error)
            return
        }

        for await event in await client.subscribe(security) {
            switch event {
            case .tick(let tick):
                withAnimation { quote = tick }
                streamStatus = nil
            case .status(let status, let reason):
                streamStatus = status == "stale" ? "stale: \(reason ?? "provider not responding")" : nil
            case .error(let message):
                streamStatus = message
            }
        }
    }
}
