import AppKit
import Foundation
import OkBrainMacOSAgentCore

struct ScreenshotPreview: Identifiable {
  let id = UUID()
  let image: NSImage
  let width: Int
  let height: Int
  let capturedAt: Date
}

struct IdleSleepPreventionSnapshot: Equatable {
  enum State: Equatable {
    case disabled
    case inactive
    case active
    case failed
  }

  let state: State
  let activityDescription: String?
  let errorMessage: String?
}

@MainActor
final class AgentRuntimeStore: ObservableObject {
  static let shared = AgentRuntimeStore()

  private static let preventIdleSleepDefaultsKey = "preventIdleSleepEnabled"
  private static let fileEditingEnabledDefaultsKey = "fileEditingEnabled"
  private static let preventIdleSleepReason = "OkBrain Agent is running and ready for remote screenshots."

  @Published private(set) var configuration: AgentConfiguration
  @Published private(set) var socketSnapshot: SocketServerSnapshot
  @Published private(set) var permissions: AgentPermissionsPayload
  @Published private(set) var latestScreenshot: ScreenshotPreview?
  @Published private(set) var latestProtocolResponse = ""
  @Published private(set) var isCapturing = false
  @Published var preventIdleSleepEnabled: Bool {
    didSet {
      guard preventIdleSleepEnabled != oldValue else {
        return
      }

      UserDefaults.standard.set(preventIdleSleepEnabled, forKey: Self.preventIdleSleepDefaultsKey)
      applyIdleSleepPreventionSetting()
    }
  }
  @Published var fileEditingEnabled: Bool {
    didSet {
      guard fileEditingEnabled != oldValue else {
        return
      }

      UserDefaults.standard.set(fileEditingEnabled, forKey: Self.fileEditingEnabledDefaultsKey)
      applyFileEditingSetting()
    }
  }
  @Published private(set) var idleSleepPrevention: IdleSleepPreventionSnapshot

  private let permissionService = SystemPermissionService()
  private let screenshotService = ScreenCaptureKitScreenshotService()
  private let idleSleepPreventer = IdleSleepPreventer()
  private var requestHandler: AgentRequestHandler
  private var server: UnixSocketServer?
  private var isAgentRuntimeActive = false

  private init() {
    UserDefaults.standard.register(defaults: [
      Self.preventIdleSleepDefaultsKey: true,
      Self.fileEditingEnabledDefaultsKey: false
    ])

    let preventIdleSleepEnabled = UserDefaults.standard.bool(forKey: Self.preventIdleSleepDefaultsKey)
    let fileEditingEnabled = UserDefaults.standard.bool(forKey: Self.fileEditingEnabledDefaultsKey)
    let configuration = AgentConfiguration.current(fileEditingEnabled: fileEditingEnabled)
    self.configuration = configuration
    self.preventIdleSleepEnabled = preventIdleSleepEnabled
    self.fileEditingEnabled = fileEditingEnabled
    idleSleepPrevention = IdleSleepPreventionSnapshot(
      state: preventIdleSleepEnabled ? .inactive : .disabled,
      activityDescription: nil,
      errorMessage: nil
    )
    permissions = permissionService.currentPermissions()
    socketSnapshot = SocketServerSnapshot(status: .stopped, socketPath: configuration.socketPath)
    requestHandler = AgentRequestHandler(
      configuration: configuration,
      permissions: permissionService,
      screenshots: screenshotService
    )
  }

  func start() {
    isAgentRuntimeActive = true
    startSocketIfNeeded()
    applyIdleSleepPreventionSetting()
  }

  func restartSocket() {
    stopSocket()
    socketSnapshot = SocketServerSnapshot(status: .stopped, socketPath: configuration.socketPath)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
      guard let self, self.isAgentRuntimeActive else {
        return
      }
      self.startSocketIfNeeded()
    }
  }

  func stop() {
    isAgentRuntimeActive = false
    stopSocket()
    applyIdleSleepPreventionSetting()
  }

  func refreshPermissions() {
    permissions = permissionService.currentPermissions()
  }

  private func applyFileEditingSetting() {
    let nextConfiguration = configuration.withFileEditingEnabled(fileEditingEnabled)
    guard nextConfiguration != configuration else {
      return
    }

    configuration = nextConfiguration
    requestHandler = AgentRequestHandler(
      configuration: nextConfiguration,
      permissions: permissionService,
      screenshots: screenshotService
    )

    if isAgentRuntimeActive {
      restartSocket()
    } else {
      socketSnapshot = SocketServerSnapshot(status: .stopped, socketPath: nextConfiguration.socketPath)
    }
  }

  func requestScreenRecordingAccess() {
    _ = permissionService.requestScreenRecordingAccess()
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
      self?.refreshPermissions()
    }
  }

  func requestAccessibilityAccess() {
    _ = permissionService.requestAccessibilityAccess(prompt: true)
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
      self?.refreshPermissions()
    }
  }

  func captureFullScreenProbe() {
    guard !isCapturing else {
      return
    }

    isCapturing = true
    let requestHandler = self.requestHandler
    let request = AgentRequest(
      id: "gui_capture_probe",
      action: "screenshot.capture",
      params: AgentRequestParams(mode: "full", format: "png", includeCursor: false)
    )

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let responseData: Data
      do {
        let requestData = try JSONEncoder().encode(request)
        responseData = requestHandler.handle(requestData: requestData)
      } catch {
        responseData = requestHandler.errorResponseData(
          id: "gui_capture_probe",
          error: .invalidRequest("Unable to encode GUI capture request: \(error.localizedDescription)")
        )
      }

      let responseText = String(data: responseData, encoding: .utf8) ?? ""

      DispatchQueue.main.async {
        let preview = Self.preview(from: responseData)
        self?.latestProtocolResponse = responseText
        self?.latestScreenshot = preview
        self?.isCapturing = false
        self?.refreshPermissions()
      }
    }
  }

  private func startSocketIfNeeded() {
    guard server == nil else {
      return
    }

    let handler = requestHandler
    let socketServer = UnixSocketServer(
      socketPath: configuration.socketPath,
      maxRequestBytes: configuration.maxRequestBytes
    ) { requestData in
      handler.handle(requestData: requestData)
    }

    socketServer.onStateChange = { [weak self, weak socketServer] snapshot in
      DispatchQueue.main.async {
        guard let self, let socketServer, self.server === socketServer else {
          return
        }

        self.socketSnapshot = snapshot
      }
    }

    server = socketServer
    socketServer.start()
  }

  private func stopSocket() {
    server?.stop()
    server = nil
  }

  private func applyIdleSleepPreventionSetting() {
    guard preventIdleSleepEnabled else {
      idleSleepPreventer.stop()
      idleSleepPrevention = IdleSleepPreventionSnapshot(state: .disabled, activityDescription: nil, errorMessage: nil)
      return
    }

    guard isAgentRuntimeActive else {
      idleSleepPreventer.stop()
      idleSleepPrevention = IdleSleepPreventionSnapshot(state: .inactive, activityDescription: nil, errorMessage: nil)
      return
    }

    let activityDescription = idleSleepPreventer.start(reason: Self.preventIdleSleepReason)
    idleSleepPrevention = IdleSleepPreventionSnapshot(
      state: .active,
      activityDescription: activityDescription,
      errorMessage: nil
    )
  }

  private static func preview(from responseData: Data) -> ScreenshotPreview? {
    guard
      let envelope = try? JSONDecoder().decode(CaptureProbeEnvelope.self, from: responseData),
      envelope.ok,
      let payload = envelope.data,
      let imageData = Data(base64Encoded: payload.base64),
      let image = NSImage(data: imageData)
    else {
      return nil
    }

    return ScreenshotPreview(
      image: image,
      width: payload.width,
      height: payload.height,
      capturedAt: Date()
    )
  }
}

private struct CaptureProbeEnvelope: Decodable {
  let ok: Bool
  let data: ScreenshotCapturePayload?
}
