import Foundation

/// CFA-style quantitative formulas (time value of money, bonds, options).
public enum Quant {
    // MARK: Time value of money

    /// Future value of `pv` and a level payment `pmt` (paid at period end) after `n` periods at `rate`.
    public static func futureValue(pv: Double, pmt: Double, rate: Double, n: Double) -> Double {
        if rate == 0 { return pv + pmt * n }
        let g = pow(1 + rate, n)
        return pv * g + pmt * (g - 1) / rate
    }

    public static func presentValue(fv: Double, pmt: Double, rate: Double, n: Double) -> Double {
        if rate == 0 { return fv + pmt * n }
        let d = pow(1 + rate, -n)
        return fv * d + pmt * (1 - d) / rate
    }

    /// Level payment that amortises `pv` to `fv` over `n` periods.
    public static func payment(pv: Double, fv: Double = 0, rate: Double, n: Double) -> Double {
        if rate == 0 { return (pv - fv) / n }
        let g = pow(1 + rate, n)
        return (pv * g - fv) * rate / (g - 1)
    }

    /// Net present value of cash flows at t = 0, 1, 2, …
    public static func npv(rate: Double, cashFlows: [Double]) -> Double {
        cashFlows.enumerated().reduce(0) { $0 + $1.element / pow(1 + rate, Double($1.offset)) }
    }

    /// Internal rate of return by bisection; nil when the cash flows don't change sign.
    public static func irr(cashFlows: [Double]) -> Double? {
        guard cashFlows.contains(where: { $0 < 0 }), cashFlows.contains(where: { $0 > 0 }) else { return nil }
        var lo = -0.9999, hi = 10.0
        var fLo = npv(rate: lo, cashFlows: cashFlows)
        guard fLo * npv(rate: hi, cashFlows: cashFlows) < 0 else { return nil }
        for _ in 0..<200 {
            let mid = (lo + hi) / 2
            let f = npv(rate: mid, cashFlows: cashFlows)
            if abs(f) < 1e-10 { return mid }
            if (f < 0) == (fLo < 0) { lo = mid; fLo = f } else { hi = mid }
        }
        return (lo + hi) / 2
    }

    // MARK: Bonds

    public struct BondMetrics: Equatable, Sendable {
        public let price: Double
        public let macaulayDuration: Double
        public let modifiedDuration: Double
        public let convexity: Double
        public let currentYield: Double
    }

    /// Price and risk of a plain bullet bond. Rates are annual decimals; `frequency` coupons per year.
    public static func bond(face: Double = 100, couponRate: Double, ytm: Double, years: Double, frequency: Int = 2) -> BondMetrics {
        let f = Double(frequency)
        let periods = Int((years * f).rounded())
        let c = face * couponRate / f
        let y = ytm / f
        var price = 0.0, weighted = 0.0, convex = 0.0
        for t in 1...max(periods, 1) {
            let cf = Double(t) == Double(periods) ? c + face : c
            let pv = cf / pow(1 + y, Double(t))
            price += pv
            weighted += Double(t) * pv
            convex += Double(t) * Double(t + 1) * pv
        }
        let macaulay = weighted / price / f
        return BondMetrics(
            price: price,
            macaulayDuration: macaulay,
            modifiedDuration: macaulay / (1 + y),
            convexity: convex / (price * pow(1 + y, 2) * f * f),
            currentYield: face * couponRate / price
        )
    }

    /// Yield to maturity for a given price (bisection on 0…100%).
    public static func yieldToMaturity(price: Double, face: Double = 100, couponRate: Double, years: Double, frequency: Int = 2) -> Double? {
        var lo = 0.0, hi = 1.0
        func p(_ y: Double) -> Double { bond(face: face, couponRate: couponRate, ytm: y, years: years, frequency: frequency).price }
        guard (p(lo) - price) * (p(hi) - price) <= 0 else { return nil }
        for _ in 0..<200 {
            let mid = (lo + hi) / 2
            if (p(mid) - price) > 0 { lo = mid } else { hi = mid }
        }
        return (lo + hi) / 2
    }

    // MARK: Options (Black–Scholes–Merton)

    public struct OptionResult: Equatable, Sendable {
        public let price: Double
        public let delta: Double
        public let gamma: Double
        public let vega: Double     // per 1.00 change in vol
        public let theta: Double    // per year
        public let rho: Double      // per 1.00 change in rate
    }

    public static func blackScholes(call: Bool, spot: Double, strike: Double, years: Double, rate: Double,
                                    volatility: Double, dividendYield q: Double = 0) -> OptionResult {
        let sqrtT = years.squareRoot()
        let d1 = (log(spot / strike) + (rate - q + volatility * volatility / 2) * years) / (volatility * sqrtT)
        let d2 = d1 - volatility * sqrtT
        let dq = exp(-q * years), dr = exp(-rate * years)
        let gamma = dq * pdf(d1) / (spot * volatility * sqrtT)
        let vega = spot * dq * pdf(d1) * sqrtT
        if call {
            return OptionResult(
                price: spot * dq * cdf(d1) - strike * dr * cdf(d2),
                delta: dq * cdf(d1), gamma: gamma, vega: vega,
                theta: -spot * dq * pdf(d1) * volatility / (2 * sqrtT) - rate * strike * dr * cdf(d2) + q * spot * dq * cdf(d1),
                rho: strike * years * dr * cdf(d2))
        }
        return OptionResult(
            price: strike * dr * cdf(-d2) - spot * dq * cdf(-d1),
            delta: dq * (cdf(d1) - 1), gamma: gamma, vega: vega,
            theta: -spot * dq * pdf(d1) * volatility / (2 * sqrtT) + rate * strike * dr * cdf(-d2) - q * spot * dq * cdf(-d1),
            rho: -strike * years * dr * cdf(-d2))
    }

    static func pdf(_ x: Double) -> Double { exp(-x * x / 2) / (2 * Double.pi).squareRoot() }
    static func cdf(_ x: Double) -> Double { 0.5 * erfc(-x / 2.0.squareRoot()) }
}
