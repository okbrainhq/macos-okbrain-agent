import CoreGraphics
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

/// Abstraction over display-wake behaviour so callers (and tests) can inject
/// a mock instead of touching real IOKit assertions.
public protocol DisplayWaking: AnyObject {
  func release()
}

/// Wakes the display only when it is currently asleep, then waits briefly so
/// the display can become ready. Use to wrap operations that need a live
/// display (screenshots, accessibility queries, synthetic input events).
/// When the display is already awake this is a no-op, so there is no added
/// latency on the hot path.
final class DisplayWakeGuard: DisplayWaking {
  private var assertion: DisplayWakeAssertion?

  init(settleDelay: TimeInterval = 1.0) {
    guard CGDisplayIsAsleep(CGMainDisplayID()) != 0 else { return }
    assertion = DisplayWakeAssertion()
    if settleDelay > 0 {
      Thread.sleep(forTimeInterval: settleDelay)
    }
  }

  func release() {
    assertion?.release()
    assertion = nil
  }

  deinit {
    release()
  }
}
