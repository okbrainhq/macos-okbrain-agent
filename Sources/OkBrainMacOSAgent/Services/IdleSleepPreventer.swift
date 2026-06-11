import Foundation

final class IdleSleepPreventer {
  private static let activitySummary = "ProcessInfo activity: userInitiated + idleSystemSleepDisabled (display sleep allowed)"

  private var activity: NSObjectProtocol?

  var currentSummary: String? {
    activity == nil ? nil : Self.activitySummary
  }

  @discardableResult
  func start(reason: String) -> String {
    if activity != nil {
      return Self.activitySummary
    }

    activity = ProcessInfo.processInfo.beginActivity(
      options: [.userInitiated, .idleSystemSleepDisabled],
      reason: reason
    )

    return Self.activitySummary
  }

  func stop() {
    guard let activity else {
      return
    }

    ProcessInfo.processInfo.endActivity(activity)
    self.activity = nil
  }

  deinit {
    stop()
  }
}
