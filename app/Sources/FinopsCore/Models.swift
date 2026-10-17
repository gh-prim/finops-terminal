import Foundation

/// A security as resolved by the gateway from what the user typed.
public struct SecurityInfo: Codable, Sendable, Hashable {
    public let typed: String
    public let symbol: String
    public let assetClass: String?
    public let name: String?
}

public struct Quote: Codable, Sendable, Hashable {
    public let symbol: String
    public let last: Double
    public let previousClose: Double?
    public let change: Double?
    public let changePct: Double?
    public let open: Double?
    public let dayHigh: Double?
    public let dayLow: Double?
    public let volume: Double?
    public let currency: String?
    public let exchange: String?
    public let marketCap: Double?
    public let asOf: Double

    public var asOfDate: Date { Date(timeIntervalSince1970: asOf) }
}

public struct RefData: Codable, Sendable, Hashable {
    public let security: SecurityInfo
    public let quote: Quote
}

public struct Bar: Codable, Sendable, Hashable, Identifiable {
    public let t: Double
    public let o: Double?
    public let h: Double?
    public let l: Double?
    public let c: Double
    public let v: Double?

    public var id: Double { t }
    public var date: Date { Date(timeIntervalSince1970: t) }
}

public struct History: Codable, Sendable, Hashable {
    public let security: SecurityInfo
    public let range: String
    public let interval: String
    public let bars: [Bar]
}

public struct LookupResult: Codable, Sendable, Hashable {
    public struct Match: Codable, Sendable, Hashable {
        public let symbol: String
        public let name: String?
        public let type: String?
        public let exchange: String?
    }

    public let query: String
    public let results: [Match]
}

/// Chart ranges understood by the gateway's `history` service.
public enum ChartRange: String, CaseIterable, Sendable {
    case d1 = "1D", d5 = "5D", m1 = "1M", m3 = "3M", m6 = "6M", ytd = "YTD"
    case y1 = "1Y", y2 = "2Y", y5 = "5Y", y10 = "10Y", max = "MAX"
}
