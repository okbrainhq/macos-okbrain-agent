import Foundation

final class IdleSleepPreventer {
  private static let activitySummary = "ProcessInfo activity: userInitiated + idleSystemSleepDisabled + idleDisplaySleepDisabled"

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
      options: [.userInitiated, .idleSystemSleepDisabled, .idleDisplaySleepDisabled],
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
