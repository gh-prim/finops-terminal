import Foundation

/// A JSON scalar from the gateway (table cells, key/value values).
public enum JSONValue: Codable, Sendable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else { self = .null }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        }
    }

    public var number: Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    public var string: String? {
        switch self {
        case .string(let s): s
        case .number(let n): n.formatted()
        case .bool(let b): b ? "yes" : "no"
        case .null: nil
        }
    }
}

/// How a value should be displayed. Unknown kinds fall back to `.text`.
public enum ValueKind: String, Codable, Sendable {
    case text, int, number, price, compact, percent, pctchange, change, date, datetime

    public init(from decoder: Decoder) throws {
        self = ValueKind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .text
    }
}

/// Generic screen returned by most gateway services (see gateway/documents.py).
public struct GatewayDocument: Decodable, Sendable {
    public let title: String
    public let subtitle: String?
    public let blocks: [Block]
    public let source: String
    public let notes: [String]
    public let asOf: Double
    /// Live screens: seconds after which the view reloads itself.
    public let refresh: Double?

    public enum Block: Decodable, Sendable, Identifiable {
        case table(TableBlock)
        case kv(KVBlock)
        case text(TextBlock)
        case choices(ChoicesBlock)
        case treemap(TreemapBlock)
        case matrix(MatrixBlock)
        case scatter(ScatterBlock)
        case graph(GraphBlock)
        case bars(BarsBlock)
        case series(SeriesBlock)
        case donut(DonutBlock)
        case sparkgrid(SparkGridBlock)
        case map(MapBlock)
        case unknown

        public var id: String {
            switch self {
            case .table(let t): "table-\(t.id)-\(t.title ?? "")"
            case .kv(let k): "kv-\(k.title ?? "")"
            case .text(let t): "text-\(t.title ?? "")"
            case .choices(let c): "choices-\(c.id)"
            case .treemap(let b): "treemap-\(b.id)"
            case .matrix(let b): "matrix-\(b.id)"
            case .scatter(let b): "scatter-\(b.id)"
            case .graph(let b): "graph-\(b.id)"
            case .bars(let b): "bars-\(b.id)"
            case .series(let b): "series-\(b.id)"
            case .donut(let b): "donut-\(b.id)"
            case .sparkgrid(let b): "sparkgrid-\(b.id)"
            case .map(let b): "map-\(b.id)"
            case .unknown: "unknown-\(UUID())"
            }
        }

        private enum Key: String, CodingKey { case type }

        public init(from decoder: Decoder) throws {
            let type = try decoder.container(keyedBy: Key.self).decode(String.self, forKey: .type)
            switch type {
            case "table": self = .table(try TableBlock(from: decoder))
            case "kv": self = .kv(try KVBlock(from: decoder))
            case "text": self = .text(try TextBlock(from: decoder))
            case "choices": self = .choices(try ChoicesBlock(from: decoder))
            case "treemap": self = .treemap(try TreemapBlock(from: decoder))
            case "matrix": self = .matrix(try MatrixBlock(from: decoder))
            case "scatter": self = .scatter(try ScatterBlock(from: decoder))
            case "graph": self = .graph(try GraphBlock(from: decoder))
            case "bars": self = .bars(try BarsBlock(from: decoder))
            case "series": self = .series(try SeriesBlock(from: decoder))
            case "donut": self = .donut(try DonutBlock(from: decoder))
            case "sparkgrid": self = .sparkgrid(try SparkGridBlock(from: decoder))
            case "map": self = .map(try MapBlock(from: decoder))
            default: self = .unknown
            }
        }
    }

    public struct Column: Decodable, Sendable, Hashable {
        public let id: String
        public let label: String
        public let kind: ValueKind
    }

    public struct Row: Decodable, Sendable, Hashable {
        public let cells: [JSONValue]
        public let cmd: String?
        public let url: String?
        /// Overrides the column kind for every value cell in this row (e.g. margin rows in FIN).
        public let kind: ValueKind?
    }

    public struct TableBlock: Decodable, Sendable {
        public let id: String
        public let title: String?
        public let columns: [Column]
        public let rows: [Row]
    }

    public struct KVBlock: Decodable, Sendable {
        public struct Item: Decodable, Sendable, Hashable {
            public let label: String
            public let value: JSONValue
            public let kind: ValueKind
            public let url: String?
        }

        public let title: String?
        public let items: [Item]
    }

    public struct TextBlock: Decodable, Sendable {
        public let title: String?
        public let text: String
    }

    public struct ChoicesBlock: Decodable, Sendable {
        public struct Item: Decodable, Sendable, Hashable {
            public let label: String
            public let cmd: String
        }

        public let id: String
        public let title: String?
        public let items: [Item]
        public let selected: String?
    }
}

// MARK: Visual blocks

public extension GatewayDocument {
    struct TreemapBlock: Decodable, Sendable {
        public struct Item: Decodable, Sendable, Hashable {
            public let label: String
            public let detail: String?
            public let weight: Double
            public let value: Double?
            public let cmd: String?
        }

        public struct Group: Decodable, Sendable, Hashable {
            public let label: String
            public let items: [Item]
        }

        public let id: String
        public let title: String?
        public let kind: ValueKind
        public let groups: [Group]
    }

    struct MatrixBlock: Decodable, Sendable {
        public let id: String
        public let title: String?
        public let rows: [String]
        public let cols: [String]
        public let values: [[Double?]]
        public let kind: ValueKind
        /// "diverging" (around `center`), "correlation" (−1…1) or "none".
        public let scale: String
        public let center: Double
        public let rowCmds: [String?]?
    }

    struct ScatterBlock: Decodable, Sendable {
        public struct Point: Decodable, Sendable, Hashable {
            public let label: String
            public let x: Double
            public let y: Double
            public let size: Double?
            public let highlight: Bool?
            public let cmd: String?
        }

        public let id: String
        public let title: String?
        public let xLabel: String
        public let yLabel: String
        public let xKind: ValueKind
        public let yKind: ValueKind
        public let points: [Point]
    }

    struct GraphBlock: Decodable, Sendable {
        public struct Node: Decodable, Sendable, Hashable {
            public let label: String
            public let detail: String?
            public let value: Double?
            public let cmd: String?
        }

        public struct Group: Decodable, Sendable, Hashable {
            public let title: String
            public let side: String   // left | right | bottom
            public let nodes: [Node]
        }

        public struct Center: Decodable, Sendable, Hashable {
            public let label: String
            public let detail: String?
            public let lines: [String]?
        }

        public let id: String
        public let title: String?
        public let center: Center
        public let groups: [Group]
    }

    /// World map with severity-sized, kind-coloured points (WORLD, LINK).
    struct MapBlock: Decodable, Sendable {
        public struct Point: Decodable, Sendable, Hashable, Identifiable {
            public let lat: Double
            public let lon: Double
            public let label: String
            public let detail: String?
            public let kind: String?
            public let severity: Int?
            public let cmd: String?
            public let url: String?
            public var id: String { "\(lat),\(lon),\(label)" }
        }

        public let id: String
        public let title: String?
        public let points: [Point]
    }

    struct BarsBlock: Decodable, Sendable {
        public struct Item: Decodable, Sendable, Hashable {
            public let label: String
            public let value: Double
            public let cmd: String?
        }

        public let id: String
        public let title: String?
        public let kind: ValueKind
        public let items: [Item]
    }

    struct SeriesBlock: Decodable, Sendable {
        public struct Line: Decodable, Sendable {
            public let label: String
            public let points: [[Double]]   // [t, v]
        }

        public let id: String
        public let title: String?
        public let kind: ValueKind
        public let lines: [Line]
    }

    struct DonutBlock: Decodable, Sendable {
        public struct Item: Decodable, Sendable, Hashable {
            public let label: String
            public let value: Double
        }

        public let id: String
        public let title: String?
        public let kind: ValueKind
        public let items: [Item]
    }

    struct SparkGridBlock: Decodable, Sendable {
        public struct Item: Decodable, Sendable, Hashable {
            public let label: String
            public let detail: String?
            public let change: Double?
            public let points: [Double]
            public let cmd: String?
        }

        public let id: String
        public let title: String?
        public let items: [Item]
    }
}

public struct EconSeries: Decodable, Sendable {
    public struct Meta: Decodable, Sendable {
        public let id: String
        public let title: String
        public let units: String
        public let frequency: String
        public let lastUpdated: String
        public let notes: String
    }

    public struct Observation: Decodable, Sendable, Identifiable {
        public let t: Double
        public let v: Double
        public var id: Double { t }
        public var date: Date { Date(timeIntervalSince1970: t) }
    }

    public let series: Meta
    public let range: String
    public let transform: String
    public let observations: [Observation]
    public let source: String
}

public struct YieldCurves: Decodable, Sendable {
    public struct Point: Decodable, Sendable, Hashable {
        public let tenor: String
        public let years: Double
        public let yield: Double
    }

    public struct Curve: Decodable, Sendable, Identifiable {
        public let label: String
        public let date: Double
        public let points: [Point]
        public var id: String { label }
    }

    public let curves: [Curve]
    public let source: String
}
