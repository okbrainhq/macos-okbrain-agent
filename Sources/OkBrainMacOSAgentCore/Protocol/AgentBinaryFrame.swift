import Foundation

public struct AgentBinaryFrame: Equatable, Sendable {
  public static let magic = Data([0x4F, 0x4B, 0x42, 0x31]) // OKB1
  public static let preludeByteCount = 16

  public let headerData: Data
  public let bodyData: Data

  public init(headerData: Data, bodyData: Data = Data()) {
    self.headerData = headerData
    self.bodyData = bodyData
  }

  public func encoded() throws -> Data {
    try Self.encode(headerData: headerData, bodyData: bodyData)
  }

  public static func encode(headerData: Data, bodyData: Data = Data()) throws -> Data {
    guard headerData.count <= UInt32.max else {
      throw AgentProtocolError.responseTooLarge(headerData.count)
    }

    var frame = Data()
    frame.reserveCapacity(preludeByteCount + headerData.count + bodyData.count)
    frame.append(magic)
    frame.appendUInt32BigEndian(UInt32(headerData.count))
    frame.appendUInt64BigEndian(UInt64(bodyData.count))
    frame.append(headerData)
    frame.append(bodyData)
    return frame
  }

  public static func decode(
    _ data: Data,
    maxHeaderBytes: Int? = nil,
    maxBodyBytes: Int? = nil
  ) throws -> AgentBinaryFrame {
    guard data.count >= preludeByteCount else {
      throw AgentProtocolError.invalidRequest("Binary frame is missing the 16-byte prelude")
    }

    let prelude = data.prefix(preludeByteCount)
    let lengths = try decodePrelude(Data(prelude))
    guard lengths.headerByteCount <= data.count - preludeByteCount else {
      throw AgentProtocolError.invalidRequest("Binary frame header is truncated")
    }
    guard lengths.bodyByteCount <= data.count - preludeByteCount - lengths.headerByteCount else {
      throw AgentProtocolError.invalidRequest("Binary frame body is truncated")
    }

    if let maxHeaderBytes, lengths.headerByteCount > maxHeaderBytes {
      throw AgentProtocolError.invalidRequest("Binary frame header exceeds \(maxHeaderBytes) bytes")
    }
    if let maxBodyBytes, lengths.bodyByteCount > maxBodyBytes {
      throw AgentProtocolError.responseTooLarge(lengths.bodyByteCount)
    }

    let expectedByteCount = preludeByteCount + lengths.headerByteCount + lengths.bodyByteCount
    guard data.count == expectedByteCount else {
      throw AgentProtocolError.invalidRequest("Binary frame has trailing bytes")
    }

    let headerStart = preludeByteCount
    let bodyStart = headerStart + lengths.headerByteCount
    return AgentBinaryFrame(
      headerData: data[headerStart..<bodyStart],
      bodyData: data[bodyStart..<expectedByteCount]
    )
  }

  public static func decodePrelude(_ prelude: Data) throws -> (headerByteCount: Int, bodyByteCount: Int) {
    guard prelude.count == preludeByteCount else {
      throw AgentProtocolError.invalidRequest("Binary frame prelude must be exactly \(preludeByteCount) bytes")
    }

    guard prelude.prefix(4) == magic else {
      throw AgentProtocolError.invalidRequest("Binary frame magic must be OKB1")
    }

    let headerByteCount = UInt64(prelude.uint32BigEndian(at: 4))
    let bodyByteCount = prelude.uint64BigEndian(at: 8)
    guard headerByteCount <= UInt64(Int.max), bodyByteCount <= UInt64(Int.max) else {
      throw AgentProtocolError.responseTooLarge(Int.max)
    }

    return (Int(headerByteCount), Int(bodyByteCount))
  }
}

private extension Data {
  mutating func appendUInt32BigEndian(_ value: UInt32) {
    var bigEndian = value.bigEndian
    Swift.withUnsafeBytes(of: &bigEndian) { bytes in
      append(contentsOf: bytes)
    }
  }

  mutating func appendUInt64BigEndian(_ value: UInt64) {
    var bigEndian = value.bigEndian
    Swift.withUnsafeBytes(of: &bigEndian) { bytes in
      append(contentsOf: bytes)
    }
  }

  func uint32BigEndian(at offset: Int) -> UInt32 {
    var value: UInt32 = 0
    for byte in self[offset..<(offset + 4)] {
      value = (value << 8) | UInt32(byte)
    }
    return value
  }

  func uint64BigEndian(at offset: Int) -> UInt64 {
    var value: UInt64 = 0
    for byte in self[offset..<(offset + 8)] {
      value = (value << 8) | UInt64(byte)
    }
    return value
  }
}
