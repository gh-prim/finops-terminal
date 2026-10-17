import FinopsCore
import Foundation
import Observation

public struct Watchlist: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var securities: [String]
}

public struct Position: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var security: String
    public var quantity: Double
    public var cost: Double
}

public struct PriceAlert: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var security: String
    public var above: Bool
    public var price: Double
    public var created: Date
    public var triggeredAt: Date?

    public var condition: String { "\(above ? "≥" : "≤") \(Format.price(price))" }

    func isHit(by last: Double) -> Bool { above ? last >= price : last <= price }
}

/// JSON persistence in UserDefaults for small user collections.
struct Persisted<Value: Codable> {
    let key: String
    let defaults: UserDefaults

    func load() -> Value? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    func save(_ value: Value) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
}

/// Live quotes shared by the portfolio and alert monitor. Each consumer declares
/// the securities it needs under its own key; one subscription per security.
@MainActor
@Observable
public final class QuoteBoard {
    public private(set) var quotes: [String: Quote] = [:]
    @ObservationIgnored private var demand: [String: Set<String>] = [:]
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var client: DataClient?
    @ObservationIgnored var onTick: ((String, Quote) -> Void)?

    func setClient(_ client: DataClient) {
        self.client = client
        refresh()
    }

    public func track(_ securities: Set<String>, for key: String) {
        demand[key] = securities
        refresh()
    }

    private func refresh() {
        guard let client else { return }
        let wanted = demand.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        for (security, task) in tasks where !wanted.contains(security) {
            task.cancel()
            tasks[security] = nil
        }
        for security in wanted where tasks[security] == nil {
            tasks[security] = Task { [weak self] in
                for await event in await client.subscribe(security) {
                    guard !Task.isCancelled else { break }
                    if case .tick(let quote) = event {
                        self?.quotes[security] = quote
                        self?.onTick?(security, quote)
                    }
                }
            }
        }
    }
}
