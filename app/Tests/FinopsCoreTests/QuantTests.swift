import Foundation
import Testing
@testable import FinopsCore

struct QuantTests {
    @Test func timeValueRoundTrips() {
        let fv = Quant.futureValue(pv: 1000, pmt: 0, rate: 0.05, n: 10)
        #expect(abs(fv - 1628.894627) < 1e-5)
        #expect(abs(Quant.presentValue(fv: fv, pmt: 0, rate: 0.05, n: 10) - 1000) < 1e-9)
        // 30-year mortgage of 300k at 6%/12: textbook payment 1798.65
        #expect(abs(Quant.payment(pv: 300_000, rate: 0.06 / 12, n: 360) - 1798.65) < 0.01)
    }

    @Test func npvAndIrr() {
        let flows: [Double] = [-1000, 300, 400, 500]
        let irr = Quant.irr(cashFlows: flows)!
        #expect(abs(Quant.npv(rate: irr, cashFlows: flows)) < 1e-6)
        #expect(abs(irr - 0.0889633947) < 1e-6)
        #expect(Quant.irr(cashFlows: [100, 200]) == nil)
    }

    @Test func bondAtParAndYieldInverse() {
        let par = Quant.bond(couponRate: 0.05, ytm: 0.05, years: 10)
        #expect(abs(par.price - 100) < 1e-9)
        #expect(par.modifiedDuration < par.macaulayDuration)
        let discount = Quant.bond(couponRate: 0.04, ytm: 0.06, years: 5)
        #expect(discount.price < 100)
        #expect(abs(Quant.yieldToMaturity(price: discount.price, couponRate: 0.04, years: 5)! - 0.06) < 1e-9)
        // Zero-coupon: Macaulay duration equals maturity.
        #expect(abs(Quant.bond(couponRate: 0, ytm: 0.05, years: 7).macaulayDuration - 7) < 1e-9)
    }

    @Test func blackScholesTextbookAndParity() {
        // Hull: S=42, K=40, r=10%, σ=20%, T=0.5 → call 4.76, put 0.81
        let call = Quant.blackScholes(call: true, spot: 42, strike: 40, years: 0.5, rate: 0.10, volatility: 0.20)
        let put = Quant.blackScholes(call: false, spot: 42, strike: 40, years: 0.5, rate: 0.10, volatility: 0.20)
        #expect(abs(call.price - 4.7594) < 1e-3)
        #expect(abs(put.price - 0.8086) < 1e-3)
        #expect(abs((call.price - put.price) - (42 - 40 * exp(-0.05))) < 1e-9)
        #expect(abs(call.delta - put.delta - 1) < 1e-12)
    }
}

struct MoreIndicatorTests {
    let high: [Double] = (0..<60).map { 10 + Double($0) * 0.5 + 1 }
    let low: [Double] = (0..<60).map { 10 + Double($0) * 0.5 - 1 }
    var close: [Double] { (0..<60).map { 10 + Double($0) * 0.5 } }

    @Test func stochasticInRange() {
        let s = Indicators.stochastic(high: high, low: low, close: close)
        let ks = s.k.compactMap { $0 }
        #expect(!ks.isEmpty && ks.allSatisfy { (0...100).contains($0) })
    }

    @Test func atrOfConstantRange() {
        let atr = Indicators.atr(high: high, low: low, close: close)
        #expect(abs(atr.last!! - 2) < 1e-9)
    }

    @Test func obvAccumulatesOnRises() {
        let obv = Indicators.obv(close: [1, 2, 3, 2], volume: [10, 10, 10, 10])
        #expect(obv.map { $0! } == [0, 10, 20, 10])
    }

    @Test func adxHighInStrongTrend() {
        #expect(Indicators.adx(high: high, low: low, close: close).last!! > 50)
    }

    @Test func newStudiesRoundTrip() {
        let config = ChartConfig(args: ["1Y", "STOCH", "ADX"])
        #expect(config.studies == [.stoch, .adx])
        #expect(ChartConfig(args: config.args) == config)
    }
}
