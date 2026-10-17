import Testing
@testable import FinopsCore

struct IndicatorTests {
    let values: [Double] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]

    @Test func sma() {
        let out = Indicators.sma(values, period: 3)
        #expect(out[0] == nil && out[1] == nil)
        #expect(out[2] == 2 && out[9] == 9)
    }

    @Test func emaSeedsWithSMA() {
        let out = Indicators.ema(values, period: 3)
        #expect(out[1] == nil)
        #expect(out[2] == 2)
        #expect(out[3] == 3)  // 4*0.5 + 2*0.5
    }

    @Test func rsiOfRisingSeriesIs100() {
        let out = Indicators.rsi(values, period: 3)
        #expect(out[2] == nil)
        #expect(out[3] == 100)
    }

    @Test func bollingerOfFlatSeriesCollapses() {
        let bands = Indicators.bollinger(Array(repeating: 5, count: 25), period: 20)
        #expect(bands.upper[19] == 5 && bands.lower[24] == 5)
    }

    @Test func macdAlignsWithInput() {
        let series = (0..<60).map { Double($0) }
        let m = Indicators.macd(series)
        #expect(m.macd.count == 60 && m.signal.count == 60)
        #expect(m.macd[24] == nil && m.macd[25] != nil)
        #expect(m.signal[32] == nil && m.signal[33] != nil)
    }
}

struct ChartConfigTests {
    @Test func roundTripsThroughArgs() {
        let config = ChartConfig(args: ["5Y", "CANDLE", "VOL", "SMA50", "RSI", "VS", "MSFT,NVDA"])
        #expect(config.range == .y5)
        #expect(config.style == .candle)
        #expect(config.volume)
        #expect(config.overlays == [.sma50])
        #expect(config.studies == [.rsi])
        #expect(config.compare == ["MSFT", "NVDA"])
        #expect(ChartConfig(args: config.args) == config)
    }

    @Test func defaultsAndUnknowns() {
        #expect(ChartConfig(args: []).args == ["1Y"])
        #expect(ChartConfig.unknownTokens(in: ["1Y", "FOO", "VS", "X"]) == ["FOO"])
    }
}
