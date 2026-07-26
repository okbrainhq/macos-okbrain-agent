import Foundation

public enum AgentProtocolError: Error, Sendable {
  case invalidRequest(String)
  case protocolMismatch(String)
  case unsupportedProtocol(String)
  case unsupportedAction(String)
  case unknownAction(String)
  case unsupportedMode(String)
  case unsupportedFormat(String)
  case unsupportedParameter(String)
  case permissionDenied(String)
  case captureFailed(String)
  case responseTooLarge(Int)
  case socketError(String)
  case rootRequired(String)
  case rootNotAllowed(String)
  case pathOutsideRoot(String)
  case fileNotFound(String)
  case notAFile(String)
  case notADirectory(String)
  case fileTooLarge(String)
  case binaryFile(String)
  case contentConflict(String)
  case patchNotFound(String)
  case ambiguousPatch(String)
  case appNotFound(String)
  case elementNotFound(String)
  case actionFailed(String)
  case appPermissionRequired(String, details: JSONValue)
  case unknownFunction(String)
  case invalidArgs(String, details: JSONValue)
  case functionDisabled(String)
  case automationPermissionRequired(String, details: JSONValue)
  case functionFailed(String, details: JSONValue?)
  case operationTimeout(String)
  case internalError(String)

  public var code: String {
    switch self {
    case .invalidRequest:
      "invalid_request"
    case .protocolMismatch:
      "protocol_mismatch"
    case .unsupportedProtocol:
      "unsupported_protocol"
    case .unsupportedAction:
      "unsupported_action"
    case .unknownAction:
      "unknown_action"
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
    case .rootRequired:
      "root_required"
    case .rootNotAllowed:
      "root_not_allowed"
    case .pathOutsideRoot:
      "path_outside_root"
    case .fileNotFound:
      "file_not_found"
    case .notAFile:
      "not_a_file"
    case .notADirectory:
      "not_a_directory"
    case .fileTooLarge:
      "file_too_large"
    case .binaryFile:
      "binary_file"
    case .contentConflict:
      "content_conflict"
    case .patchNotFound:
      "patch_not_found"
    case .ambiguousPatch:
      "ambiguous_patch"
    case .appNotFound:
      "app_not_found"
    case .elementNotFound:
      "element_not_found"
    case .actionFailed:
      "action_failed"
    case .appPermissionRequired:
      "app_permission_required"
    case .unknownFunction:
      "unknown_function"
    case .invalidArgs:
      "invalid_args"
    case .functionDisabled:
      "function_disabled"
    case .automationPermissionRequired:
      "automation_permission_required"
    case .functionFailed:
      "function_failed"
    case .operationTimeout:
      "operation_timeout"
    case .internalError:
      "internal_error"
    }
  }

  public var message: String {
    switch self {
    case .invalidRequest(let message),
         .protocolMismatch(let message),
         .unsupportedProtocol(let message),
         .unsupportedAction(let message),
         .unknownAction(let message),
         .unsupportedMode(let message),
         .unsupportedFormat(let message),
         .unsupportedParameter(let message),
         .permissionDenied(let message),
         .captureFailed(let message),
         .socketError(let message),
         .rootRequired(let message),
         .rootNotAllowed(let message),
         .pathOutsideRoot(let message),
         .fileNotFound(let message),
         .notAFile(let message),
         .notADirectory(let message),
         .fileTooLarge(let message),
         .binaryFile(let message),
         .contentConflict(let message),
         .patchNotFound(let message),
         .ambiguousPatch(let message),
         .appNotFound(let message),
         .elementNotFound(let message),
         .actionFailed(let message),
         .appPermissionRequired(let message, _),
         .unknownFunction(let message),
         .invalidArgs(let message, _),
         .functionDisabled(let message),
         .automationPermissionRequired(let message, _),
         .functionFailed(let message, _),
         .operationTimeout(let message),
         .internalError(let message):
      message
    case .responseTooLarge(let size):
      "Screenshot response exceeds the configured limit: \(size) bytes"
    }
  }

  public var details: JSONValue? {
    switch self {
    case .appPermissionRequired(_, let details),
         .invalidArgs(_, let details),
         .automationPermissionRequired(_, let details):
      details
    case .functionFailed(_, let details):
      details
    default:
      nil
    }
  }
}
