import ApplicationServices
import CoreGraphics
import Foundation

public enum PermissionState: String, Codable, Equatable, Sendable {
  case granted
  case denied
  case unknown
}

public struct AgentPermissionsPayload: Codable, Equatable, Sendable {
  public let screenRecording: PermissionState
  public let accessibility: PermissionState
  public let fileAccess: PermissionState?

  public init(
    screenRecording: PermissionState,
    accessibility: PermissionState,
    fileAccess: PermissionState? = nil
  ) {
    self.screenRecording = screenRecording
    self.accessibility = accessibility
    self.fileAccess = fileAccess
  }
}

public protocol PermissionChecking: Sendable {
  func currentPermissions() -> AgentPermissionsPayload
  func requestScreenRecordingAccess() -> Bool
  func requestAccessibilityAccess(prompt: Bool) -> Bool
}

public final class SystemPermissionService: PermissionChecking, @unchecked Sendable {
  public init() {}

  public func currentPermissions() -> AgentPermissionsPayload {
    AgentPermissionsPayload(
      screenRecording: CGPreflightScreenCaptureAccess() ? .granted : .denied,
      accessibility: AXIsProcessTrusted() ? .granted : .denied
    )
  }

  @discardableResult
  public func requestScreenRecordingAccess() -> Bool {
    CGRequestScreenCaptureAccess()
  }

  @discardableResult
  public func requestAccessibilityAccess(prompt: Bool) -> Bool {
    guard prompt else {
      return AXIsProcessTrusted()
    }

    let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    let options = [promptKey: true] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
  }
}
