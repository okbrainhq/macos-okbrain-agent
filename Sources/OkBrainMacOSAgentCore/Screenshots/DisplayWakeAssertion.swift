import Foundation
import IOKit
import IOKit.pwr_mgt

/// Briefly wakes the display using `IOPMAssertionDeclareUserActivity` so that
/// screen capture APIs can grab valid framebuffer content. The assertion is
/// released on `deinit` or when `release()` is called, allowing the display
/// to return to its normal sleep schedule.
///
/// Usage:
/// ```swift
/// let wake = DisplayWakeAssertion()
/// let image = try captureSomething()
/// wake.release()   // or just let it go out of scope
/// ```
final class DisplayWakeAssertion {
  private var assertionID: IOPMAssertionID = .init(0)
  private var active = false

  init() {
    let result = IOPMAssertionDeclareUserActivity(
      "" as CFString,
      kIOPMUserActiveLocal,
      &assertionID
    )
    active = result == kIOReturnSuccess
  }

  func release() {
    guard active else { return }
    IOPMAssertionRelease(assertionID)
    active = false
  }

  deinit {
    release()
  }
}
