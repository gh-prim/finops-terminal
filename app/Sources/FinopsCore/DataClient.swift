import Foundation

public struct GatewayError: Error, LocalizedError, Sendable {
    public let code: String
    public let message: String
    public var errorDescription: String? { message }
}

public enum StreamEvent: Sendable {
    case tick(Quote)
    case status(String, reason: String?)
    case error(String)
}

/// One WebSocket to the gateway. Requests and subscriptions are matched to
/// replies by correlation ID (cid).
public actor DataClient {
    private let socket: URLSessionWebSocketTask
    private var pending: [String: CheckedContinuation<Data, Error>] = [:]
    private var streams: [String: AsyncStream<StreamEvent>.Continuation] = [:]
    private var nextID = 0
    private var closedError: Error?
    private let unhandledContinuation: AsyncStream<Data>.Continuation

    /// Messages the data protocol doesn't know (e.g. `remote.*` from a paired Mac).
    public nonisolated let unhandled: AsyncStream<Data>

    public init(url: URL) {
        socket = URLSession.shared.webSocketTask(with: url)
        (unhandled, unhandledContinuation) = AsyncStream<Data>.makeStream()
    }

    /// Opens the socket. `hello` (e.g. a pairing/auth message) is sent before anything else.
    public func start(hello: Data? = nil) async {
        socket.resume()
        if let hello {
            try? await socket.send(.string(String(decoding: hello, as: UTF8.self)))
        }
        Task { await receiveLoop() }
    }

    /// Send an arbitrary JSON message on the same socket.
    public func sendRaw(_ json: Data) async throws {
        if let closedError { throw closedError }
        try await socket.send(.string(String(decoding: json, as: UTF8.self)))
    }

    public func close() {
        socket.cancel(with: .goingAway, reason: nil)
    }

    // MARK: Requests

    public func request<T: Decodable & Sendable>(
        _ service: String, _ params: [String: String], as type: T.Type
    ) async throws -> T {
        if let closedError { throw closedError }
        let cid = makeID()
        let message = Outgoing(t: "request", cid: cid, service: service, params: params, security: nil)
        let data = try await withCheckedThrowingContinuation { continuation in
            pending[cid] = continuation
            Task { await send(message) }
        }
        return try JSONDecoder().decode(Envelope<T>.self, from: data).data
    }

    public func refData(_ security: String) async throws -> RefData {
        try await request("refdata", ["security": security], as: RefData.self)
    }

    public func history(_ security: String, range: ChartRange, interval: ChartConfig.Interval? = nil) async throws -> History {
        var params = ["security": security, "range": range.rawValue]
        if let interval { params["interval"] = interval.rawValue }
        return try await request("history", params, as: History.self)
    }

    public func lookup(_ query: String) async throws -> LookupResult {
        try await request("lookup", ["query": query], as: LookupResult.self)
    }

    /// Any document-shaped service (profile, news, financials, market, …).
    public func document(_ service: String, _ params: [String: String] = [:]) async throws -> GatewayDocument {
        try await request(service, params, as: GatewayDocument.self)
    }

    /// News, earnings, macro releases and world events to mark on a chart.
    public func markers(_ security: String, range: ChartRange) async throws -> [ChartMarker] {
        try await request("markers", ["security": security, "range": range.rawValue], as: ChartMarkers.self).markers
    }

    /// Evaluate cross-source rules against live data.
    public func evaluate(_ rules: [WatchRule]) async throws -> RuleEvaluation {
        let json = String(decoding: try JSONEncoder().encode(rules), as: UTF8.self)
        return try await request("rules", ["rules": json], as: RuleEvaluation.self)
    }

    public func rulePresets() async throws -> RulePresets {
        try await request("rule_presets", [:], as: RulePresets.self)
    }

    /// Readable text of a web article, extracted by the gateway.
    public func article(_ url: String) async throws -> Article {
        try await request("article", ["url": url], as: Article.self)
    }

    public func econSeries(_ id: String, range: String, yoy: Bool) async throws -> EconSeries {
        try await request("econ_series", ["id": id, "range": range, "units": yoy ? "pc1" : "lin"], as: EconSeries.self)
    }

    public func yieldCurves() async throws -> YieldCurves {
        try await request("curve", [:], as: YieldCurves.self)
    }

    /// Push provider settings. Empty values are omitted so they never erase what the server already has.
    public func configure(edgarContact: String, fredApiKey: String, anthropicApiKey: String = "") async throws {
        var params: [String: String] = [:]
        if !edgarContact.isEmpty { params["edgarContact"] = edgarContact }
        if !fredApiKey.isEmpty { params["fredApiKey"] = fredApiKey }
        if !anthropicApiKey.isEmpty { params["anthropicApiKey"] = anthropicApiKey }
        guard !params.isEmpty else { return }
        _ = try await request("config", params, as: ConfigAck.self)
    }

    // MARK: Subscriptions

    public func subscribe(_ security: String) -> AsyncStream<StreamEvent> {
        let cid = makeID()
        let (stream, continuation) = AsyncStream<StreamEvent>.makeStream()
        if let closedError {
            continuation.yield(.error(closedError.localizedDescription))
            continuation.finish()
            return stream
        }
        streams[cid] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(cid) }
        }
        Task { await send(Outgoing(t: "subscribe", cid: cid, service: nil, params: nil, security: security)) }
        return stream
    }

    private func unsubscribe(_ cid: String) async {
        guard streams.removeValue(forKey: cid) != nil, closedError == nil else { return }
        await send(Outgoing(t: "unsubscribe", cid: cid, service: nil, params: nil, security: nil))
    }

    // MARK: Transport

    private func makeID() -> String {
        nextID += 1
        return String(nextID)
    }

    private func send(_ message: Outgoing) async {
        do {
            let json = try JSONEncoder().encode(message)
            try await socket.send(.string(String(decoding: json, as: UTF8.self)))
        } catch {
            pending.removeValue(forKey: message.cid)?.resume(throwing: error)
            streams.removeValue(forKey: message.cid)?.finish()
        }
    }

    private func receiveLoop() async {
        while true {
            do {
                let data: Data
                switch try await socket.receive() {
                case .string(let text): data = Data(text.utf8)
                case .data(let bytes): data = bytes
                @unknown default: continue
                }
                route(data)
            } catch {
                fail(error)
                return
            }
        }
    }

    private func route(_ data: Data) {
        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(Header.self, from: data) else {
            unhandledContinuation.yield(data)
            return
        }
        switch header.t {
        case "response":
            pending.removeValue(forKey: header.cid)?.resume(returning: data)
        case "error":
            let error = GatewayError(code: header.code ?? "error", message: header.message ?? "Unknown error")
            if let continuation = pending.removeValue(forKey: header.cid) {
                continuation.resume(throwing: error)
            } else {
                streams[header.cid]?.yield(.error(error.message))
            }
        case "tick":
            if let tick = try? decoder.decode(Envelope<Quote>.self, from: data) {
                streams[header.cid]?.yield(.tick(tick.data))
            }
        case "subStatus":
            streams[header.cid]?.yield(.status(header.status ?? "unknown", reason: header.reason))
        default:
            unhandledContinuation.yield(data)
        }
    }

    private func fail(_ error: Error) {
        let lost = GatewayError(code: "disconnected", message: "Lost connection to the data gateway")
        closedError = lost
        for continuation in pending.values { continuation.resume(throwing: lost) }
        pending.removeAll()
        for continuation in streams.values {
            continuation.yield(.error(lost.message))
            continuation.finish()
        }
        streams.removeAll()
        unhandledContinuation.finish()
    }
}

private struct ConfigAck: Decodable, Sendable {
    let ok: Bool
}

private struct Outgoing: Encodable {
    let t: String
    let cid: String
    let service: String?
    let params: [String: String]?
    let security: String?
}

private struct Header: Decodable {
    let t: String
    let cid: String
    let code: String?
    let message: String?
    let status: String?
    let reason: String?
}

private struct Envelope<T: Decodable>: Decodable {
    let data: T
}
