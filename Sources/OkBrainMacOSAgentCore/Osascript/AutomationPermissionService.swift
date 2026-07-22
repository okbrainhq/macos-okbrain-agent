import CoreServices
import Foundation

/// Live macOS Automation (Apple Events / TCC) permission status for a target app.
public enum AutomationPermissionStatus: String, Codable, Equatable, Sendable {
  /// The user has granted this app permission to control the target.
  case authorized
  /// The user has denied permission.
  case denied
  /// No decision has been recorded yet (the prompt has never been shown/answered).
  case notDetermined
  /// Status could not be determined (e.g. target not resolvable).
  case unknown
}

/// A user-selected application that can be pre-authorized for AppleScript control.
public struct AutomationAppInfo: Codable, Equatable, Sendable, Identifiable {
  public let bundleID: String
  public let name: String
  public let path: String

  public var id: String { bundleID }

  public init(bundleID: String, name: String, path: String) {
    self.bundleID = bundleID
    self.name = name
    self.path = path
  }
}

public protocol AutomationPermissionServicing: Sendable {
  /// Reads the current Automation permission status without triggering a prompt.
  func status(forBundleID bundleID: String) -> AutomationPermissionStatus
  /// Prompts the user (if no decision exists yet) to grant Automation access to
  /// the target app, then returns the resulting status.
  func requestAccess(forBundleID bundleID: String) -> AutomationPermissionStatus
}

/// Checks and requests macOS Automation permission via
/// `AEDeterminePermissionToAutomateTarget`. Because the call is made from the
/// agent app process, any permission granted is attributed to the agent.
public final class SystemAutomationPermissionService: AutomationPermissionServicing, @unchecked Sendable {
  public init() {}

  public func status(forBundleID bundleID: String) -> AutomationPermissionStatus {
    determinePermission(forBundleID: bundleID, askUserIfNeeded: false)
  }

  public func requestAccess(forBundleID bundleID: String) -> AutomationPermissionStatus {
    determinePermission(forBundleID: bundleID, askUserIfNeeded: true)
  }

  private func determinePermission(forBundleID bundleID: String, askUserIfNeeded: Bool) -> AutomationPermissionStatus {
    var desc = AEAddressDesc()
    let createStatus: OSStatus = bundleID.withCString { pointer in
      OSStatus(AECreateDesc(DescType(typeApplicationBundleID), pointer, strlen(pointer), &desc))
    }
    guard createStatus == noErr else {
      return .unknown
    }
    defer { AEDisposeDesc(&desc) }

    let result = AEDeterminePermissionToAutomateTarget(
      &desc,
      AEEventClass(kAECoreSuite),
      AEEventID(kAEGetData),
      askUserIfNeeded
    )

    switch result {
    case noErr:
      return .authorized
    case OSStatus(errAEEventNotPermitted):
      return .denied
    case OSStatus(errAEEventWouldRequireUserConsent):
      return .notDetermined
    default:
      return .unknown
    }
  }
}
