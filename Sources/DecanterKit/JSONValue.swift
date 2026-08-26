import Foundation

/// A JSON value we do not have a type for.
///
/// Exists so that reading and rewriting a state file cannot silently discard
/// fields the running binary has never heard of. `decodeIfPresent` protects the
/// forward direction — a new field arriving in an old file — but says nothing
/// about the reverse: an older binary loading a newer file, dropping every key
/// it lacks a property for, and writing that loss back to disk.
///
/// That reverse case is not hypothetical here. The app and the CLI are separate
/// binaries sharing one store, installed together but updatable apart, and both
/// are routinely open at once.
public enum JSONValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "unrepresentable JSON")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v):   try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v):  try c.encode(v)
        case .null:          try c.encodeNil()
        }
    }
}

/// Collects the keys of a JSON object that a given type does not claim.
///
/// Used at decode time: whatever is left over is carried in memory and written
/// back out unchanged, so a round trip through an older binary is lossless.
public enum UnknownKeys {
    public static func capture(from decoder: Decoder, known: [String]) -> [String: JSONValue] {
        guard let all = try? decoder.singleValueContainer().decode([String: JSONValue].self)
        else { return [:] }
        let claimed = Set(known)
        return all.filter { !claimed.contains($0.key) }
    }

    /// Merges preserved keys back into an encoded object, never overwriting a
    /// key the type itself wrote.
    public static func merge(_ extra: [String: JSONValue], into data: Data) -> Data {
        guard !extra.isEmpty,
              var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let extraData = try? JSONEncoder().encode(extra),
              let extraObj = (try? JSONSerialization.jsonObject(with: extraData)) as? [String: Any]
        else { return data }
        for (k, v) in extraObj where obj[k] == nil { obj[k] = v }
        return (try? JSONSerialization.data(withJSONObject: obj,
                                            options: [.prettyPrinted, .sortedKeys])) ?? data
    }
}
