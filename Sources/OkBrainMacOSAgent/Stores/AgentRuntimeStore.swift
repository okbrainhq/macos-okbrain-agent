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

struct PermissionTargetOption: Identifiable, Hashable {
  let target: PermissionTarget
  let subtitle: String

  var id: String { target.id }
}

@MainActor
final class AgentRuntimeStore: ObservableObject {
  static let shared = AgentRuntimeStore()

  private static let preventIdleSleepDefaultsKey = "preventIdleSleepEnabled"
  private static let fileEditingEnabledDefaultsKey = "fileEditingEnabled"
  private static let filePermissionRulesDefaultsKey = "filePermissionRules"
  private nonisolated static let remoteControlAPIsEnabledDefaultsKey = "remoteControlAPIsEnabled"
  private nonisolated static let axPermissionStateDefaultsKey = "axPermissionState"
  private nonisolated static let functionRuntimeStateDefaultsKey = "functionRuntimeState"
  private nonisolated static let axPermissionStateChangedNotification = Notification.Name("OkBrainAXPermissionStateChanged")
  private nonisolated static let functionRuntimeStateChangedNotification = Notification.Name("OkBrainFunctionRuntimeStateChanged")
  private static let preventIdleSleepReason = "OkBrain Agent is running and ready for remote screenshots."

  @Published private(set) var configuration: AgentConfiguration
  @Published private(set) var socketSnapshot: SocketServerSnapshot
  @Published private(set) var permissions: AgentPermissionsPayload
  @Published private(set) var latestScreenshot: ScreenshotPreview?
  @Published private(set) var latestProtocolResponse = ""
  @Published private(set) var isCapturing = false
  @Published private(set) var filePermissionRules: [FileEditingAllowedRoot]
  @Published private(set) var permissionRules: [AXAppPermissionRule]
  @Published private(set) var pendingAXPermissionRequests: [AXPendingPermissionRequest]
  @Published private(set) var functionCatalog: [FunctionCatalogEntry]
  @Published private(set) var functionProposals: [FunctionProposal]
  @Published private(set) var storedFunctionTemplates: [StoredFunctionTemplate]
  @Published var remoteControlAPIsEnabled: Bool {
    didSet {
      guard remoteControlAPIsEnabled != oldValue else { return }
      UserDefaults.standard.set(remoteControlAPIsEnabled, forKey: Self.remoteControlAPIsEnabledDefaultsKey)
    }
  }
  @Published var preventIdleSleepEnabled: Bool {
    didSet {
      guard preventIdleSleepEnabled != oldValue else { return }
      UserDefaults.standard.set(preventIdleSleepEnabled, forKey: Self.preventIdleSleepDefaultsKey)
      applyIdleSleepPreventionSetting()
    }
  }
  @Published var fileEditingEnabled: Bool {
    didSet {
      guard fileEditingEnabled != oldValue else { return }
      UserDefaults.standard.set(fileEditingEnabled, forKey: Self.fileEditingEnabledDefaultsKey)
      applyFileEditingSetting()
    }
  }
  @Published private(set) var idleSleepPrevention: IdleSleepPreventionSnapshot

  private let permissionService = SystemPermissionService()
  private let screenshotService = ScreenCaptureKitScreenshotService()
  private let idleSleepPreventer = IdleSleepPreventer()
  private let axPermissionCoordinator: AXPermissionCoordinator
  private let functionRuntimeState: FunctionRuntimeState
  private let functionRegistry: FunctionRegistry
  private var requestHandler: AgentRequestHandler
  private var server: UnixSocketServer?
  private var isAgentRuntimeActive = false
  private var observers: [NSObjectProtocol] = []

  private init() {
    UserDefaults.standard.register(defaults: [
      Self.preventIdleSleepDefaultsKey: true,
      Self.fileEditingEnabledDefaultsKey: false,
      Self.remoteControlAPIsEnabledDefaultsKey: true
    ])

    let preventIdleSleepEnabled = UserDefaults.standard.bool(forKey: Self.preventIdleSleepDefaultsKey)
    let fileEditingEnabled = UserDefaults.standard.bool(forKey: Self.fileEditingEnabledDefaultsKey)
    let remoteControlAPIsEnabled = UserDefaults.standard.bool(forKey: Self.remoteControlAPIsEnabledDefaultsKey)
    let filePermissionRules = Self.loadFilePermissionRules()
    let axState = Self.loadAXPermissionState()
    let functionStateSnapshot = Self.loadFunctionRuntimeState()
    let axCoordinator = AXPermissionCoordinator(
      rules: axState.rules,
      pendingRequests: axState.pendingRequests,
      onStateChange: { snapshot in
        Self.persistAXPermissionState(snapshot)
      }
    )
    let functionRuntimeState = FunctionRuntimeState(
      enabledFunctionNames: functionStateSnapshot.enabledFunctionNames,
      proposals: functionStateSnapshot.proposals,
      templates: functionStateSnapshot.templates,
      onStateChange: { snapshot in
        Self.persistFunctionRuntimeState(snapshot)
      }
    )
    let functionRegistry = FunctionRegistry.standard()
    let configuration = AgentConfiguration.current(
      fileEditingEnabled: fileEditingEnabled,
      filePermissionRules: filePermissionRules
    )

    self.configuration = configuration
    self.preventIdleSleepEnabled = preventIdleSleepEnabled
    self.fileEditingEnabled = fileEditingEnabled
    self.remoteControlAPIsEnabled = remoteControlAPIsEnabled
    self.filePermissionRules = filePermissionRules
    self.axPermissionCoordinator = axCoordinator
    self.functionRuntimeState = functionRuntimeState
    self.functionRegistry = functionRegistry
    self.permissionRules = axState.rules
    self.pendingAXPermissionRequests = axState.pendingRequests
    self.functionProposals = functionStateSnapshot.proposals
    self.storedFunctionTemplates = functionStateSnapshot.templates
    self.functionCatalog = functionRegistry.localCatalogEntries(state: functionRuntimeState)
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
      screenshots: screenshotService,
      functionRegistry: functionRegistry,
      functionState: functionRuntimeState,
      axPermissionCoordinator: axCoordinator,
      remoteControlEnabled: { UserDefaults.standard.bool(forKey: Self.remoteControlAPIsEnabledDefaultsKey) }
    )

    installRuntimeStateObservers()
  }

  deinit {
    observers.forEach(NotificationCenter.default.removeObserver)
  }

  /// These capability choices are always available in the App & Global Access picker;
  /// unlike applications they do not depend on the process currently running.
  var globalPermissionTargetOptions: [PermissionTargetOption] {
    GlobalPermissionCategory.allCases.map { category in
      PermissionTargetOption(target: category.permissionTarget, subtitle: category.summary)
    }
  }

  /// Validates a locally chosen `.app` bundle before it can become a persistent
  /// permission target. The UI deliberately uses NSOpenPanel instead of a
  /// running-process list, so grants can be prepared before an app launches.
  func permissionTarget(forApplicationBundleURL url: URL) throws -> PermissionTarget {
    guard url.isFileURL,
          url.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
          let bundle = Bundle(url: url),
          let bundleID = bundle.bundleIdentifier,
          PermissionTarget.isValidApplicationBundleID(bundleID) else {
      throw AgentProtocolError.invalidRequest("Choose a valid macOS application bundle (.app) with a bundle identifier")
    }
    let appName = FileManager.default.displayName(atPath: url.path)
    return PermissionTarget(
      applicationBundleID: bundleID,
      appName: appName.isEmpty ? bundleID : appName
    )
  }

  func start() {
    isAgentRuntimeActive = true
    startSocketIfNeeded()
    applyIdleSleepPreventionSetting()
    observeAppActivationForPermissionRefresh()
    refreshControlStatePresentation()
  }

  private func observeAppActivationForPermissionRefresh() {
    observers.append(NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.permissions = self.permissionService.currentPermissions()
        self.refreshControlStatePresentation()
      }
    })
  }

  private func installRuntimeStateObservers() {
    observers.append(NotificationCenter.default.addObserver(
      forName: Self.axPermissionStateChangedNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in self?.refreshControlStatePresentation() }
    })
    observers.append(NotificationCenter.default.addObserver(
      forName: Self.functionRuntimeStateChangedNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in self?.refreshControlStatePresentation() }
    })
  }

  private func refreshControlStatePresentation() {
    let axSnapshot = axPermissionCoordinator.snapshot()
    permissionRules = axSnapshot.rules
    pendingAXPermissionRequests = axSnapshot.pendingRequests

    let functionSnapshot = functionRuntimeState.snapshot()
    functionProposals = functionSnapshot.proposals
    storedFunctionTemplates = functionSnapshot.templates
    functionCatalog = functionRegistry.localCatalogEntries(state: functionRuntimeState)
  }

  func restartSocket() {
    stopSocket()
    socketSnapshot = SocketServerSnapshot(status: .stopped, socketPath: configuration.socketPath)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
      guard let self, self.isAgentRuntimeActive else { return }
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

  // MARK: - File permissions

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
    guard mode.canRead else { return }
    let normalizedPath = (try? FilePermissionRuleEngine.normalizedRulePath(path)) ?? path
    let nextRules = filePermissionRules.map { rule in
      rule.path == normalizedPath ? FileEditingAllowedRoot(path: rule.path, mode: mode) : rule
    }
    replaceFilePermissionRules(nextRules)
  }

  func removeFilePermissionRules(paths: Set<String>) {
    guard !paths.isEmpty else { return }
    replaceFilePermissionRules(filePermissionRules.filter { !paths.contains($0.path) })
  }

  private func replaceFilePermissionRules(_ nextRules: [FileEditingAllowedRoot]) {
    guard nextRules != filePermissionRules else { return }
    filePermissionRules = nextRules
    Self.saveFilePermissionRules(nextRules)
    applyFileEditingSetting()
  }

  private func applyFileEditingSetting() {
    let nextConfiguration = configuration.withFileEditingSettings(enabled: fileEditingEnabled, allowedRoots: filePermissionRules)
    guard nextConfiguration != configuration else { return }

    configuration = nextConfiguration
    requestHandler = makeRequestHandler(configuration: nextConfiguration)
    if isAgentRuntimeActive {
      restartSocket()
    } else {
      socketSnapshot = SocketServerSnapshot(status: .stopped, socketPath: nextConfiguration.socketPath)
    }
  }

  // MARK: - Explicit Observe / Control permissions

  func upsertPermissionRule(target: PermissionTarget, mode: AXAppPermissionMode) {
    guard target.isValidated else { return }
    let nextRules = permissionRules.filter { $0.target.id != target.id }
      + [AXAppPermissionRule(target: target, mode: mode)]
    axPermissionCoordinator.replaceRules(nextRules)
    refreshControlStatePresentation()
  }

  func updatePermissionRule(targetID: String, mode: AXAppPermissionMode) {
    let nextRules = permissionRules.map { rule in
      rule.target.id == targetID ? AXAppPermissionRule(target: rule.target, mode: mode) : rule
    }
    axPermissionCoordinator.replaceRules(nextRules)
    refreshControlStatePresentation()
  }

  func removePermissionRules(targetIDs: Set<String>) {
    guard !targetIDs.isEmpty else { return }
    let nextRules = permissionRules.filter { !targetIDs.contains($0.target.id) }
    axPermissionCoordinator.replaceRules(nextRules)
    refreshControlStatePresentation()
  }

  func resolvePendingAXPermissionRequest(id: UUID, resolution: AXPendingPermissionResolution) {
    _ = axPermissionCoordinator.resolvePendingRequest(id: id, resolution: resolution)
    refreshControlStatePresentation()
  }

  // MARK: - Curated functions and proposals

  func setFunctionEnabled(_ enabled: Bool, name: String) {
    functionRuntimeState.setEnabled(enabled, for: name)
    refreshControlStatePresentation()
  }

  func previewFunctionProposalApproval(id: UUID) throws -> FunctionProposalApprovalPreview {
    try functionRuntimeState.approvalPreview(id: id)
  }

  func approveFunctionProposal(id: UUID, sourceDigest: String) throws {
    _ = try functionRuntimeState.approveProposal(id: id, approvedSourceDigest: sourceDigest)
    refreshControlStatePresentation()
  }

  func requeueLegacyFunctionTemplateForReview(id: UUID) {
    _ = functionRuntimeState.requeueLegacyTemplateForReview(id: id)
    refreshControlStatePresentation()
  }

  func rejectFunctionProposal(id: UUID) {
    _ = functionRuntimeState.rejectProposal(id: id)
    refreshControlStatePresentation()
  }

  func removeStoredFunctionTemplate(id: UUID) {
    _ = functionRuntimeState.removeTemplate(id: id)
    refreshControlStatePresentation()
  }

  // MARK: - System permissions

  func requestScreenRecordingAccess() {
    _ = permissionService.requestScreenRecordingAccess()
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refreshPermissions() }
  }

  func requestAccessibilityAccess() {
    _ = permissionService.requestAccessibilityAccess(prompt: true)
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refreshPermissions() }
  }

  // MARK: - Screenshot probe

  func captureFullScreenProbe() {
    guard !isCapturing else { return }
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
        responseData = requestHandler.handle(requestData: try JSONEncoder().encode(request))
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

  // MARK: - Socket lifecycle

  private func makeRequestHandler(configuration: AgentConfiguration) -> AgentRequestHandler {
    AgentRequestHandler(
      configuration: configuration,
      permissions: permissionService,
      screenshots: screenshotService,
      functionRegistry: functionRegistry,
      functionState: functionRuntimeState,
      axPermissionCoordinator: axPermissionCoordinator,
      remoteControlEnabled: { UserDefaults.standard.bool(forKey: Self.remoteControlAPIsEnabledDefaultsKey) }
    )
  }

  private func startSocketIfNeeded() {
    guard server == nil else { return }
    let handler = requestHandler
    let socketServer = UnixSocketServer(socketPath: configuration.socketPath, maxRequestBytes: configuration.maxRequestBytes) { requestData in
      handler.handle(requestData: requestData)
    }
    socketServer.onStateChange = { [weak self, weak socketServer] snapshot in
      DispatchQueue.main.async {
        guard let self, let socketServer, self.server === socketServer else { return }
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
    idleSleepPrevention = IdleSleepPreventionSnapshot(state: .active, activityDescription: activityDescription, errorMessage: nil)
  }

  // MARK: - Persistence

  private static func loadFilePermissionRules() -> [FileEditingAllowedRoot] {
    guard let data = UserDefaults.standard.data(forKey: filePermissionRulesDefaultsKey),
          let rules = try? JSONDecoder().decode([FileEditingAllowedRoot].self, from: data) else {
      return []
    }
    return rules.compactMap { rule in
      guard rule.mode.canRead,
            let normalizedPath = try? FilePermissionRuleEngine.normalizedRulePath(rule.path) else { return nil }
      return FileEditingAllowedRoot(path: normalizedPath, mode: rule.mode)
    }
  }

  private static func saveFilePermissionRules(_ rules: [FileEditingAllowedRoot]) {
    guard let data = try? JSONEncoder().encode(rules) else { return }
    UserDefaults.standard.set(data, forKey: filePermissionRulesDefaultsKey)
  }

  private nonisolated static func loadAXPermissionState() -> AXPermissionStateSnapshot {
    guard let data = UserDefaults.standard.data(forKey: axPermissionStateDefaultsKey),
          let state = try? JSONDecoder().decode(AXPermissionStateSnapshot.self, from: data) else {
      return AXPermissionStateSnapshot(rules: [], pendingRequests: [])
    }
    return state
  }

  private nonisolated static func persistAXPermissionState(_ state: AXPermissionStateSnapshot) {
    if let data = try? JSONEncoder().encode(state) {
      UserDefaults.standard.set(data, forKey: axPermissionStateDefaultsKey)
    }
    NotificationCenter.default.post(name: axPermissionStateChangedNotification, object: nil)
  }

  private nonisolated static func loadFunctionRuntimeState() -> FunctionRuntimeStateSnapshot {
    guard let data = UserDefaults.standard.data(forKey: functionRuntimeStateDefaultsKey),
          let state = try? JSONDecoder().decode(FunctionRuntimeStateSnapshot.self, from: data) else {
      return FunctionRuntimeStateSnapshot(enabledFunctionNames: [], proposals: [], templates: [])
    }
    return state
  }

  private nonisolated static func persistFunctionRuntimeState(_ state: FunctionRuntimeStateSnapshot) {
    if let data = try? JSONEncoder().encode(state) {
      UserDefaults.standard.set(data, forKey: functionRuntimeStateDefaultsKey)
    }
    NotificationCenter.default.post(name: functionRuntimeStateChangedNotification, object: nil)
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
    else { return nil }

    return ScreenshotPreview(image: image, width: payload.width, height: payload.height, capturedAt: Date())
  }
}

private struct CaptureProbeEnvelope: Decodable {
  let ok: Bool
  let data: ScreenshotCapturePayload?
}
