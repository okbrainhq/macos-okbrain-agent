import Foundation
import IOKit.pwr_mgt

struct IdleSleepAssertionError: LocalizedError, Equatable {
  let result: IOReturn

  var errorDescription: String? {
    "Unable to prevent idle system sleep. IOKit returned \(result)."
  }
}

final class IdleSleepPreventer {
  private var assertionID = IOPMAssertionID(0)

  var currentAssertionID: UInt32? {
    assertionID == 0 ? nil : UInt32(assertionID)
  }

  @discardableResult
  func start(reason: String) throws -> UInt32 {
    if let currentAssertionID {
      return currentAssertionID
    }

    var newAssertionID = IOPMAssertionID(0)
    let result = IOPMAssertionCreateWithName(
      kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
      IOPMAssertionLevel(kIOPMAssertionLevelOn),
      reason as CFString,
      &newAssertionID
    )

    guard result == kIOReturnSuccess else {
      throw IdleSleepAssertionError(result: result)
    }

    assertionID = newAssertionID
    return UInt32(newAssertionID)
  }

  func stop() {
    guard assertionID != 0 else {
      return
    }

    IOPMAssertionRelease(assertionID)
    assertionID = 0
  }

  deinit {
    stop()
  }
}
