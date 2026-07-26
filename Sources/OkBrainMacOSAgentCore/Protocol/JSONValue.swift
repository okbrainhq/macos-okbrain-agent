import Foundation

/// A Codable, Sendable representation of JSON values used by the curated
/// function protocol. Keeping dynamic request data in this type avoids an
/// unsafe `[String: Any]` boundary in the socket handler.
public indirect enum JSONValue: Codable, Equatable, Sendable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: JSONValue].self))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null:
      try container.encodeNil()
    case .bool(let value):
      try container.encode(value)
    case .number(let value):
      try container.encode(value)
    case .string(let value):
      try container.encode(value)
    case .array(let value):
      try container.encode(value)
    case .object(let value):
      try container.encode(value)
    }
  }

  public var stringValue: String? {
    guard case .string(let value) = self else { return nil }
    return value
  }

  public var numberValue: Double? {
    guard case .number(let value) = self else { return nil }
    return value
  }

  public var boolValue: Bool? {
    guard case .bool(let value) = self else { return nil }
    return value
  }

  public static func object(_ key: String, _ value: JSONValue?) -> JSONValue {
    object(from: [(key, value)])
  }

  public static func object(
    _ key1: String, _ value1: JSONValue?,
    _ key2: String, _ value2: JSONValue?
  ) -> JSONValue {
    object(from: [(key1, value1), (key2, value2)])
  }

  public static func object(
    _ key1: String, _ value1: JSONValue?,
    _ key2: String, _ value2: JSONValue?,
    _ key3: String, _ value3: JSONValue?
  ) -> JSONValue {
    object(from: [(key1, value1), (key2, value2), (key3, value3)])
  }

  public static func object(
    _ key1: String, _ value1: JSONValue?,
    _ key2: String, _ value2: JSONValue?,
    _ key3: String, _ value3: JSONValue?,
    _ key4: String, _ value4: JSONValue?
  ) -> JSONValue {
    object(from: [(key1, value1), (key2, value2), (key3, value3), (key4, value4)])
  }

  public static func object(_ pairs: (String, JSONValue?)...) -> JSONValue {
    object(from: pairs)
  }

  private static func object(from pairs: [(String, JSONValue?)]) -> JSONValue {
    .object(Dictionary(uniqueKeysWithValues: pairs.compactMap { key, value in
      value.map { (key, $0) }
    }))
  }
}
