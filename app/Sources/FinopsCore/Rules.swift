import Foundation

/// One condition of a cross-source rule (see gateway intel/rules.py for the kinds).
public struct RuleCondition: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var kind: String          // price | chokepoint | conflict | unrest | disaster | quake | outage | keyword
    public var security: String?
    public var entity: String?
    public var op: String?
    public var value: Double?
    public var severity: Int?
    public var text: String?

    public init(kind: String, security: String? = nil, entity: String? = nil, op: String? = nil, value: Double? = nil,
                severity: Int? = nil, text: String? = nil) {
        id = UUID()
        self.kind = kind
        self.security = security
        self.entity = entity
        self.op = op
        self.value = value
        self.severity = severity
        self.text = text
    }

    private enum Keys: String, CodingKey { case id, kind, security, entity, op, value, severity, text }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decode(String.self, forKey: .kind)
        security = try c.decodeIfPresent(String.self, forKey: .security)
        entity = try c.decodeIfPresent(String.self, forKey: .entity)
        op = try c.decodeIfPresent(String.self, forKey: .op)
        value = try c.decodeIfPresent(Double.self, forKey: .value)
        severity = try c.decodeIfPresent(Int.self, forKey: .severity)
        text = try c.decodeIfPresent(String.self, forKey: .text)
    }
}

/// Fires when all its conditions hold at the same time.
public struct WatchRule: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var conditions: [RuleCondition]
    public var enabled: Bool
    public var lastFired: Date?

    public init(id: String = UUID().uuidString, name: String, conditions: [RuleCondition], enabled: Bool = true) {
        self.id = id
        self.name = name
        self.conditions = conditions
        self.enabled = enabled
    }

    private enum Keys: String, CodingKey { case id, name, conditions, enabled, lastFired }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        conditions = try c.decode([RuleCondition].self, forKey: .conditions)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        lastFired = try c.decodeIfPresent(Date.self, forKey: .lastFired)
    }
}

public struct RuleStatus: Codable, Sendable, Hashable {
    public struct Check: Codable, Sendable, Hashable {
        public let text: String
        public let met: Bool
        public let observed: String
    }

    public let id: String
    public let met: Bool
    public let conditions: [Check]
}

public struct RuleEvaluation: Codable, Sendable {
    public let rules: [RuleStatus]
    public let checked: Double
    public let unavailable: [String]
}

public struct RulePresets: Codable, Sendable {
    public struct EntityRef: Codable, Sendable, Hashable, Identifiable {
        public let id: String
        public let name: String
        public let kind: String
    }

    public let presets: [WatchRule]
    public let entities: [EntityRef]
}
