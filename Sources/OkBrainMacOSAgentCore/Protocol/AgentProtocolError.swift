import Foundation

public enum AgentProtocolError: Error, Sendable {
  case invalidRequest(String)
  case protocolMismatch(String)
  case unsupportedAction(String)
  case unsupportedMode(String)
  case unsupportedFormat(String)
  case unsupportedParameter(String)
  case permissionDenied(String)
  case captureFailed(String)
  case responseTooLarge(Int)
  case socketError(String)

  public var code: String {
    switch self {
    case .invalidRequest:
      "invalid_request"
    case .protocolMismatch:
      "protocol_mismatch"
    case .unsupportedAction:
      "unsupported_action"
    case .unsupportedMode:
      "unsupported_mode"
    case .unsupportedFormat:
      "unsupported_format"
    case .unsupportedParameter:
      "unsupported_parameter"
    case .permissionDenied:
      "permission_denied"
    case .captureFailed:
      "capture_failed"
    case .responseTooLarge:
      "response_too_large"
    case .socketError:
      "socket_error"
    }
  }

  public var message: String {
    switch self {
    case .invalidRequest(let message),
         .protocolMismatch(let message),
         .unsupportedAction(let message),
         .unsupportedMode(let message),
         .unsupportedFormat(let message),
         .unsupportedParameter(let message),
         .permissionDenied(let message),
         .captureFailed(let message),
         .socketError(let message):
      message
    case .responseTooLarge(let size):
      "Screenshot response exceeds the configured limit: \(size) bytes"
    }
  }
}
