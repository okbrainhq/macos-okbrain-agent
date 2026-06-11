import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

public final class ScreenCaptureKitScreenshotService: ScreenshotCapturing, @unchecked Sendable {
  public init() {}

  public func capture(_ params: AgentRequestParams) throws -> CapturedImage {
    let format = (params.format ?? "webp").lowercased()
    guard format == "webp" else {
      throw AgentProtocolError.unsupportedFormat("Only WebP screenshot responses are supported")
    }

    let includeCursor = params.includeCursor ?? false
    let webPQuality = params.quality ?? 80

    // Wake the display briefly so ScreenCaptureKit can capture valid content
    // even when the display has gone to sleep. The assertion is released
    // automatically when the variable goes out of scope.
    let displayWake = DisplayWakeAssertion()
    defer { displayWake.release() }

    // Brief delay to let the display fully wake and render a valid frame
    Thread.sleep(forTimeInterval: 1.0)

    let image: CGImage
    switch (params.mode ?? "full").lowercased() {
    case "full":
      image = try captureFullScreen(includeCursor: includeCursor)
    case "window":
      image = try captureWindow(params, includeCursor: includeCursor)
    case "region":
      if includeCursor {
        throw AgentProtocolError.unsupportedParameter("includeCursor is not supported for region screenshots")
      }
      image = try captureRegion(params)
    case let mode:
      throw AgentProtocolError.unsupportedMode("Unsupported screenshot mode: \(mode)")
    }

    let webPData = try CWebPEncoder(quality: webPQuality).encode(image)
    return CapturedImage(data: webPData, mimeType: "image/webp", width: image.width, height: image.height)
  }

  private func captureFullScreen(includeCursor: Bool) throws -> CGImage {
    let content = try shareableContent()
    let display = content.displays.first { $0.displayID == CGMainDisplayID() } ?? content.displays.first
    guard let display else {
      throw AgentProtocolError.captureFailed("Unable to find a display to capture")
    }

    let filter = SCContentFilter(display: display, excludingWindows: [])
    if #available(macOS 14.2, *) {
      filter.includeMenuBar = true
    }

    let configuration = streamConfiguration(
      width: CGDisplayPixelsWide(display.displayID),
      height: CGDisplayPixelsHigh(display.displayID),
      includeCursor: includeCursor
    )

    return try captureImage(filter: filter, configuration: configuration)
  }

  private func captureWindow(_ params: AgentRequestParams, includeCursor: Bool) throws -> CGImage {
    let content = try shareableContent()
    let window: SCWindow
    if let requestedWindowID = params.windowId {
      guard let matchingWindow = content.windows.first(where: { $0.windowID == CGWindowID(requestedWindowID) }) else {
        throw AgentProtocolError.captureFailed("Unable to find window \(requestedWindowID)")
      }
      window = matchingWindow
    } else if let appName = params.appName?.trimmingCharacters(in: .whitespacesAndNewlines), !appName.isEmpty {
      window = try largestWindow(matchingAppName: appName, in: content.windows)
    } else {
      throw AgentProtocolError.invalidRequest("Window capture requires appName or windowId")
    }

    let filter = SCContentFilter(desktopIndependentWindow: window)
    let scale = CGFloat(filter.pointPixelScale)
    let configuration = streamConfiguration(
      width: Int(max(1, window.frame.width * scale)),
      height: Int(max(1, window.frame.height * scale)),
      includeCursor: includeCursor
    )
    configuration.ignoreShadowsSingleWindow = true
    configuration.ignoreGlobalClipSingleWindow = true

    return try captureImage(filter: filter, configuration: configuration)
  }

  private func captureRegion(_ params: AgentRequestParams) throws -> CGImage {
    guard let rect = params.rect else {
      throw AgentProtocolError.invalidRequest("Region capture requires rect")
    }

    guard rect.width > 0, rect.height > 0 else {
      throw AgentProtocolError.invalidRequest("Region rect width and height must be positive")
    }

    let cgRect = CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
    if #available(macOS 15.2, *) {
      return try captureImage(rect: cgRect)
    }

    throw AgentProtocolError.unsupportedMode("Region capture requires macOS 15.2 or newer")
  }

  private func largestWindow(matchingAppName appName: String, in windows: [SCWindow]) throws -> SCWindow {
    let normalizedAppName = appName.lowercased()
    let candidates: [(window: SCWindow, area: CGFloat)] = windows.compactMap { window in
      guard
        window.isOnScreen,
        window.windowLayer == 0,
        let applicationName = window.owningApplication?.applicationName,
        applicationName.lowercased().contains(normalizedAppName)
      else {
        return nil
      }

      guard window.frame.width > 1, window.frame.height > 1 else {
        return nil
      }

      return (window: window, area: window.frame.width * window.frame.height)
    }

    guard let candidate = candidates.max(by: { $0.area < $1.area }) else {
      throw AgentProtocolError.captureFailed("Unable to find an onscreen window for \(appName)")
    }

    return candidate.window
  }

  private func streamConfiguration(width: Int, height: Int, includeCursor: Bool) -> SCStreamConfiguration {
    let configuration = SCStreamConfiguration()
    configuration.width = max(1, width)
    configuration.height = max(1, height)
    configuration.showsCursor = includeCursor
    configuration.scalesToFit = false
    configuration.preservesAspectRatio = true
    configuration.queueDepth = 1
    configuration.capturesAudio = false
    configuration.captureResolution = .best
    configuration.shouldBeOpaque = true
    return configuration
  }

  private func shareableContent() throws -> SCShareableContent {
    try waitForValue("Unable to load shareable content") { completion in
      SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
        completion(content, error)
      }
    }
  }

  private func captureImage(filter: SCContentFilter, configuration: SCStreamConfiguration) throws -> CGImage {
    try waitForValue("Unable to capture screenshot") { completion in
      SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
        completion(image, error)
      }
    }
  }

  @available(macOS 15.2, *)
  private func captureImage(rect: CGRect) throws -> CGImage {
    try waitForValue("Unable to capture region") { completion in
      SCScreenshotManager.captureImage(in: rect) { image, error in
        completion(image, error)
      }
    }
  }

  private func waitForValue<T>(
    _ fallbackMessage: String,
    start: (@escaping (T?, Error?) -> Void) -> Void
  ) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var capturedValue: T?
    var capturedError: Error?

    start { value, error in
      lock.lock()
      capturedValue = value
      capturedError = error
      lock.unlock()
      semaphore.signal()
    }

    guard semaphore.wait(timeout: .now() + .seconds(15)) == .success else {
      throw AgentProtocolError.captureFailed("\(fallbackMessage): timed out")
    }

    lock.lock()
    defer { lock.unlock() }

    if let capturedError {
      throw AgentProtocolError.captureFailed("\(fallbackMessage): \(capturedError.localizedDescription)")
    }

    guard let capturedValue else {
      throw AgentProtocolError.captureFailed(fallbackMessage)
    }

    return capturedValue
  }
}
