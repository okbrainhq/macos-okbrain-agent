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
  private static let filePermissionRulesDefaultsKey = "filePermissionRules"
  private static let automationAppsDefaultsKey = "automationApps"
  private static let preventIdleSleepReason = "OkBrain Agent is running and ready for remote screenshots."

  @Published private(set) var configuration: AgentConfiguration
  @Published private(set) var socketSnapshot: SocketServerSnapshot
  @Published private(set) var permissions: AgentPermissionsPayload
  @Published private(set) var latestScreenshot: ScreenshotPreview?
  @Published private(set) var latestProtocolResponse = ""
  @Published private(set) var isCapturing = false
  @Published private(set) var filePermissionRules: [FileEditingAllowedRoot]
  @Published private(set) var automationApps: [AutomationAppInfo]
  @Published private(set) var automationStatuses: [String: AutomationPermissionStatus] = [:]
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
  private let automationPermissionService = SystemAutomationPermissionService()
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
    let filePermissionRules = Self.loadFilePermissionRules()
    let automationApps = Self.loadAutomationApps()
    let configuration = AgentConfiguration.current(
      fileEditingEnabled: fileEditingEnabled,
      filePermissionRules: filePermissionRules
    )
    self.configuration = configuration
    self.preventIdleSleepEnabled = preventIdleSleepEnabled
    self.fileEditingEnabled = fileEditingEnabled
    self.filePermissionRules = filePermissionRules
    self.automationApps = automationApps
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
    observeAppActivationForPermissionRefresh()
  }

  private func observeAppActivationForPermissionRefresh() {
    NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      // User may have toggled Automation permissions in System Settings while
      // we were in the background — re-read statuses when they come back.
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.refreshAutomationStatuses()
        self.permissions = self.permissionService.currentPermissions()
      }
    }
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

  func upsertFilePermissionRule(path rawPath: String, mode: FileEditingMode) throws {
    guard mode.canRead else {
      throw AgentProtocolError.invalidRequest("Permission rules must be read or write")
    }

    let normalizedPath = try FilePermissionRuleEngine.normalizedRulePath(rawPath)
    let newRule = FileEditingAllowedRoot(path: normalizedPath, mode: mode)
    let nextRules = filePermissionRules.filter { $0.path != normalizedPath } + [newRule]
    replaceFilePermissionRules(nextRules)
  }

  func updateFilePermissionRule(path: String, mode: FileEditingMode) {
    guard mode.canRead else {
      return
    }

    let normalizedPath = (try? FilePermissionRuleEngine.normalizedRulePath(path)) ?? path
    let nextRules = filePermissionRules.map { rule in
      rule.path == normalizedPath ? FileEditingAllowedRoot(path: rule.path, mode: mode) : rule
    }
    replaceFilePermissionRules(nextRules)
  }

  func removeFilePermissionRules(paths: Set<String>) {
    guard !paths.isEmpty else {
      return
    }

    replaceFilePermissionRules(filePermissionRules.filter { !paths.contains($0.path) })
  }

  private func replaceFilePermissionRules(_ nextRules: [FileEditingAllowedRoot]) {
    guard nextRules != filePermissionRules else {
      return
    }

    filePermissionRules = nextRules
    Self.saveFilePermissionRules(nextRules)
    applyFileEditingSetting()
  }

  private func applyFileEditingSetting() {
    let nextConfiguration = configuration.withFileEditingSettings(
      enabled: fileEditingEnabled,
      allowedRoots: filePermissionRules
    )
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

  // MARK: - AppleScript Automation Access

  func addAutomationApps(urls: [URL]) {
    var added = automationApps
    for url in urls {
      guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier, !bundleID.isEmpty else {
        continue
      }
      guard !added.contains(where: { $0.bundleID == bundleID }) else {
        continue
      }
      let name = (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
        ?? (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
        ?? url.deletingPathExtension().lastPathComponent
      added.append(AutomationAppInfo(bundleID: bundleID, name: name, path: url.path))
    }

    guard added != automationApps else {
      return
    }

    automationApps = added
    Self.saveAutomationApps(added)
    refreshAutomationStatuses()
  }

  func removeAutomationApps(bundleIDs: Set<String>) {
    guard !bundleIDs.isEmpty else {
      return
    }

    automationApps.removeAll { bundleIDs.contains($0.bundleID) }
    automationStatuses = automationStatuses.filter { !bundleIDs.contains($0.key) }
    Self.saveAutomationApps(automationApps)
  }

  func refreshAutomationStatuses() {
    var statuses: [String: AutomationPermissionStatus] = [:]
    for app in automationApps {
      statuses[app.bundleID] = automationPermissionService.status(forBundleID: app.bundleID)
    }
    automationStatuses = statuses
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
      params: AgentRequestParams(mode: "full", format: "webp", includeCursor: false, quality: 80)
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

      let responseFrame = try? AgentBinaryFrame.decode(responseData)
      let responseHeaderData = responseFrame?.headerData ?? responseData
      let responseText = String(data: responseHeaderData, encoding: .utf8) ?? ""

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

  private static func loadFilePermissionRules() -> [FileEditingAllowedRoot] {
    guard let data = UserDefaults.standard.data(forKey: filePermissionRulesDefaultsKey),
          let rules = try? JSONDecoder().decode([FileEditingAllowedRoot].self, from: data) else {
      return []
    }

    return rules.compactMap { rule in
      guard rule.mode.canRead,
            let normalizedPath = try? FilePermissionRuleEngine.normalizedRulePath(rule.path) else {
        return nil
      }

      return FileEditingAllowedRoot(path: normalizedPath, mode: rule.mode)
    }
  }

  private static func saveFilePermissionRules(_ rules: [FileEditingAllowedRoot]) {
    guard let data = try? JSONEncoder().encode(rules) else {
      return
    }

    UserDefaults.standard.set(data, forKey: filePermissionRulesDefaultsKey)
  }

  private static func loadAutomationApps() -> [AutomationAppInfo] {
    guard let data = UserDefaults.standard.data(forKey: automationAppsDefaultsKey),
          let apps = try? JSONDecoder().decode([AutomationAppInfo].self, from: data) else {
      return []
    }

    return apps.filter { !$0.bundleID.isEmpty }
  }

  private static func saveAutomationApps(_ apps: [AutomationAppInfo]) {
    guard let data = try? JSONEncoder().encode(apps) else {
      return
    }

    UserDefaults.standard.set(data, forKey: automationAppsDefaultsKey)
  }

  private static func preview(from responseData: Data) -> ScreenshotPreview? {
    guard
      let frame = try? AgentBinaryFrame.decode(responseData),
      let envelope = try? JSONDecoder().decode(CaptureProbeEnvelope.self, from: frame.headerData),
      envelope.ok,
      let payload = envelope.data,
      payload.encoding == "binary",
      payload.byteLength == frame.bodyData.count,
      let image = NSImage(data: frame.bodyData)
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
