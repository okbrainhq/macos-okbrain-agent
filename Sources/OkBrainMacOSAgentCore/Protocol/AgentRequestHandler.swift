import Foundation

public protocol ScreenshotCapturing: Sendable {
  func capture(_ params: AgentRequestParams) throws -> CapturedImage
}

/// Captures the exact authorization target selected before AX dispatch. Global
/// AX actions use a category target; app actions retain the resolved PID for a
/// final identity check before control is sent.
private struct AXActionAuthorization {
  let targetResolution: AXResolvedTarget?
  let permissionTarget: PermissionTarget
}

public final class AgentRequestHandler: @unchecked Sendable {
  private let configuration: AgentConfiguration
  private let permissions: PermissionChecking
  private let screenshots: ScreenshotCapturing
  private let fileEditing: FileEditingServicing
  private let accessibility: AccessibilityServicing
  private let functionRegistry: FunctionRegistry
  private let functionState: FunctionRuntimeState
  private let automationPermissions: AutomationPermissionServicing
  private let axPermissionCoordinator: AXPermissionCoordinator
  private let axTargetResolver: AXTargetResolving
  private let shellExecution: ShellExecuting
  private let remoteControlEnabled: @Sendable () -> Bool
  private let makeDisplayWake: @Sendable (TimeInterval) -> (any DisplayWaking)?

  private let envelopeActions: Set<String> = [
    "agent.status",
    "agent.info",
    "permissions.status",
    "screenshot.capture"
  ]

  private let fileActions: Set<String> = [
    "workspace.describe",
    "fs.stat",
    "fs.list",
    "fs.read",
    "fs.write",
    "fs.patch",
    "fs.search"
  ]

  private let accessibilityActions: Set<String> = [
    "ax.list-apps",
    "ax.list-windows",
    "ax.get-tree",
    "ax.find",
    "ax.perform",
    "ax.get-value",
    "ax.set-value",
    "ax.type-text",
    "ax.key-press",
    "ax.click-at",
    "ax.scroll",
    "ax.drag"
  ]

  private let accessibilityWriteActions: Set<String> = [
    "ax.perform",
    "ax.set-value",
    "ax.type-text",
    "ax.key-press",
    "ax.click-at",
    "ax.scroll",
    "ax.drag"
  ]

  private let functionActions: Set<String> = [
    "functions.list",
    "functions.run",
    "functions.propose"
  ]

  private let shellActions: Set<String> = [
    "sh.exec",
    "sh.status"
  ]

  public init(
    configuration: AgentConfiguration,
    permissions: PermissionChecking = SystemPermissionService(),
    screenshots: ScreenshotCapturing = ScreenCaptureKitScreenshotService(),
    fileEditing: FileEditingServicing? = nil,
    accessibility: AccessibilityServicing = SystemAccessibilityService(),
    functionRegistry: FunctionRegistry? = nil,
    functionState: FunctionRuntimeState? = nil,
    automationPermissions: AutomationPermissionServicing = SystemAutomationPermissionService(),
    axPermissionCoordinator: AXPermissionCoordinator? = nil,
    axTargetResolver: AXTargetResolving = SystemAXTargetResolver(),
    shellExecution: ShellExecuting? = nil,
    remoteControlEnabled: (@Sendable () -> Bool)? = nil,
    displayWakeFactory: (@Sendable (TimeInterval) -> (any DisplayWaking)?)? = nil
  ) {
    self.configuration = configuration
    self.permissions = permissions
    self.screenshots = screenshots
    self.fileEditing = fileEditing ?? LocalFileEditingService(configuration: configuration.fileEditing)
    self.accessibility = accessibility
    self.functionRegistry = functionRegistry ?? FunctionRegistry.standard()
    self.functionState = functionState ?? FunctionRuntimeState()
    self.automationPermissions = automationPermissions
    self.axPermissionCoordinator = axPermissionCoordinator ?? AXPermissionCoordinator()
    self.axTargetResolver = axTargetResolver
    self.shellExecution = shellExecution ?? ShellExecutionService()
    self.remoteControlEnabled = remoteControlEnabled ?? { true }
    self.makeDisplayWake = displayWakeFactory ?? { settleDelay in DisplayWakeGuard(settleDelay: settleDelay) }
  }

  public func handle(requestData: Data) -> Data {
    var responseID = "unknown"
    var responseProtocol = AgentConfiguration.protocolName

    do {
      guard !requestData.isEmpty else {
        throw AgentProtocolError.invalidRequest("Request frame header must contain a JSON object")
      }

      let request = try JSONDecoder().decode(AgentRequest.self, from: requestData)
      let requestID = normalizedID(request.id)
      responseID = requestID
      let action = request.action.trimmingCharacters(in: .whitespacesAndNewlines)

      guard !action.isEmpty else {
        throw AgentProtocolError.invalidRequest("Request action is required")
      }

      guard envelopeActions.contains(action)
              || fileActions.contains(action)
              || accessibilityActions.contains(action)
              || functionActions.contains(action)
              || shellActions.contains(action) else {
        throw AgentProtocolError.unknownAction("Unknown action: \(action)")
      }

      guard let protocolName = request.protocolName,
            AgentConfiguration.supportedProtocolVersions.contains(protocolName) else {
        throw AgentProtocolError.protocolMismatch("Expected protocol \(AgentConfiguration.protocolName)")
      }
      responseProtocol = protocolName

      // The global toggle disables all remote actions that execute a function
      // or drive UI, while discovery and proposal inbox operations remain safe.
      if accessibilityActions.contains(action) || action == "functions.run" || action == "sh.exec" {
        try requireRemoteControlEnabled()
      }

      var displayWake: (any DisplayWaking)?
      if accessibilityActions.contains(action) || action == "functions.run" {
        displayWake = makeDisplayWake(0.5)
      }
      defer { displayWake?.release() }

      switch action {
      case "agent.status":
        return try encodeSuccess(protocolName: responseProtocol, id: requestID, data: statusPayload())
      case "permissions.status":
        return try encodeSuccess(protocolName: responseProtocol, id: requestID, data: permissionsWithFileAccess())
      case "agent.info":
        return try encodeSuccess(protocolName: responseProtocol, id: requestID, data: infoPayload())
      case "screenshot.capture":
        return try capture(
          protocolName: responseProtocol,
          id: requestID,
          params: request.params ?? AgentRequestParams(mode: "full", format: "webp", quality: 80)
        )
      case "workspace.describe":
        return try encodeSuccess(protocolName: responseProtocol, id: requestID, data: fileEditing.describeWorkspace(request.params ?? AgentRequestParams()))
      case "fs.stat":
        return try encodeSuccess(protocolName: responseProtocol, id: requestID, data: fileEditing.stat(request.params ?? AgentRequestParams()))
      case "fs.list":
        return try encodeSuccess(protocolName: responseProtocol, id: requestID, data: fileEditing.list(request.params ?? AgentRequestParams()))
      case "fs.read":
        return try encodeSuccess(protocolName: responseProtocol, id: requestID, data: fileEditing.read(request.params ?? AgentRequestParams()))
      case "fs.write":
        return try encodeSuccess(protocolName: responseProtocol, id: requestID, data: fileEditing.write(request.params ?? AgentRequestParams()))
      case "fs.patch":
        return try encodeSuccess(protocolName: responseProtocol, id: requestID, data: fileEditing.patch(request.params ?? AgentRequestParams()))
      case "fs.search":
        return try encodeSuccess(protocolName: responseProtocol, id: requestID, data: fileEditing.search(request.params ?? AgentRequestParams()))
      case "functions.list":
        return try encodeSuccess(
          protocolName: responseProtocol,
          id: requestID,
          data: functionRegistry.catalog(state: functionState, automation: automationPermissions)
        )
      case "functions.propose":
        let params = request.params ?? AgentRequestParams()
        guard let name = params.name, let description = params.description, let rationale = params.rationale else {
          throw invalidArgsError("Proposal validation failed", violations: [
            .init(argument: "name", reason: "name is required."),
            .init(argument: "description", reason: "description is required."),
            .init(argument: "rationale", reason: "rationale is required.")
          ])
        }
        if functionRegistry.function(named: name, state: functionState) != nil {
          throw invalidArgsError("Proposal validation failed", violations: [
            .init(argument: "name", reason: "A built-in or approved function already uses this name.")
          ])
        }
        let proposal = try functionState.submitProposal(
          name: name,
          description: description,
          rationale: rationale,
          exampleScript: params.exampleScript
        )
        return try encodeSuccess(protocolName: responseProtocol, id: requestID, data: FunctionProposalPayload(proposal: proposal))
      case "functions.run":
        return try runFunction(protocolName: responseProtocol, id: requestID, params: request.params ?? AgentRequestParams())
      case "sh.status":
        return try encodeSuccess(
          protocolName: responseProtocol,
          id: requestID,
          data: shellExecution.statusPayload(
            fileRules: configuration.fileEditing.allowedRoots,
            enabled: configuration.shellAccessEnabled
          )
        )
      case "sh.exec":
        return try runShell(protocolName: responseProtocol, id: requestID, params: request.params ?? AgentRequestParams())
      default:
        return try dispatchAccessibility(action: action, protocolName: responseProtocol, id: requestID, params: request.params ?? AgentRequestParams())
      }
    } catch let error as AgentProtocolError {
      return errorResponseData(protocolName: responseProtocol, id: responseID, error: error)
    } catch {
      return errorResponseData(
        protocolName: responseProtocol,
        id: responseID,
        error: .invalidRequest("Unable to decode request JSON: \(error.localizedDescription)")
      )
    }
  }

  public func errorResponseData(id: String, error: AgentProtocolError) -> Data {
    errorResponseData(protocolName: AgentConfiguration.protocolName, id: id, error: error)
  }

  private func dispatchAccessibility(
    action: String,
    protocolName: String,
    id: String,
    params: AgentRequestParams
  ) throws -> Data {
    try requireAccessibility()
    let authorization = try guardAccessibilityAction(action: action, params: params)
    let targetResolution = authorization.targetResolution
    let query = axQuery(params, resolvedTarget: targetResolution)
    let targetPID = targetResolution?.pid ?? params.targetPid
    let ensureDispatchAuthorized: () throws -> Void = {
      try self.finalizeAccessibilityAuthorization(action: action, authorization: authorization)
    }

    switch action {
    case "ax.list-apps":
      try ensureDispatchAuthorized()
      // Application Discovery is its own explicit global Observe grant. It is
      // not an implicit per-app exemption and therefore returns the list only
      // after the local user approves that category.
      return try encodeSuccess(protocolName: protocolName, id: id, data: accessibility.listApps())
    case "ax.list-windows":
      try ensureDispatchAuthorized()
      return try encodeSuccess(protocolName: protocolName, id: id, data: accessibility.listWindows(query: query))
    case "ax.get-tree":
      try ensureDispatchAuthorized()
      return try encodeSuccess(protocolName: protocolName, id: id, data: accessibility.tree(query: query))
    case "ax.find":
      try ensureDispatchAuthorized()
      return try encodeSuccess(protocolName: protocolName, id: id, data: accessibility.find(query: axQuery(params, defaultDepth: 30, resolvedTarget: targetResolution), limit: params.maxResults ?? 20))
    case "ax.perform":
      try ensureDispatchAuthorized()
      return try encodeSuccess(
        protocolName: protocolName,
        id: id,
        data: accessibility.perform(query: axQuery(params, defaultDepth: 30, resolvedTarget: targetResolution), action: params.action ?? "press")
      )
    case "ax.get-value":
      try ensureDispatchAuthorized()
      return try encodeSuccess(protocolName: protocolName, id: id, data: accessibility.value(query: axQuery(params, defaultDepth: 30, resolvedTarget: targetResolution)))
    case "ax.set-value":
      guard let value = params.value else {
        throw AgentProtocolError.invalidRequest("value is required for ax.set-value")
      }
      try ensureDispatchAuthorized()
      return try encodeSuccess(
        protocolName: protocolName,
        id: id,
        data: accessibility.setValue(query: axQuery(params, defaultDepth: 30, resolvedTarget: targetResolution), value: value)
      )
    case "ax.type-text":
      guard let text = params.text, !text.isEmpty else {
        throw AgentProtocolError.invalidRequest("text is required for ax.type-text")
      }
      try ensureDispatchAuthorized()
      try accessibility.typeText(text, targetPid: targetPID)
      return try encodeSuccess(protocolName: protocolName, id: id, data: AXSimpleResultPayload(action: "ax.type-text", detail: "Typed \(text.count) characters"))
    case "ax.key-press":
      guard let key = params.key, !key.isEmpty else {
        throw AgentProtocolError.invalidRequest("key is required for ax.key-press")
      }
      try ensureDispatchAuthorized()
      try accessibility.keyPress(key: key, modifiers: params.modifiers ?? [], targetPid: targetPID)
      let modifierText = params.modifiers?.isEmpty == false ? "\((params.modifiers ?? []).joined(separator: "+"))+" : ""
      return try encodeSuccess(protocolName: protocolName, id: id, data: AXSimpleResultPayload(action: "ax.key-press", detail: "Pressed \(modifierText)\(key)"))
    case "ax.click-at":
      guard let x = params.x, let y = params.y else {
        throw AgentProtocolError.invalidRequest("x and y are required for ax.click-at")
      }
      try ensureDispatchAuthorized()
      try accessibility.clickAt(x: x, y: y, button: params.button ?? "left", clickCount: params.clickCount ?? 1, targetPid: targetPID)
      return try encodeSuccess(protocolName: protocolName, id: id, data: AXSimpleResultPayload(action: "ax.click-at", detail: "Clicked at (\(x), \(y))"))
    case "ax.scroll":
      try ensureDispatchAuthorized()
      try accessibility.scroll(
        query: axQuery(params, defaultDepth: 30, resolvedTarget: targetResolution),
        deltaX: params.deltaX ?? 0,
        deltaY: params.deltaY ?? 0,
        x: params.x,
        y: params.y,
        targetPid: targetPID
      )
      return try encodeSuccess(
        protocolName: protocolName,
        id: id,
        data: AXSimpleResultPayload(action: "ax.scroll", detail: "Scrolled by (\(params.deltaX ?? 0), \(params.deltaY ?? 0))")
      )
    case "ax.drag":
      guard let x = params.x, let y = params.y, let toX = params.toX, let toY = params.toY else {
        throw AgentProtocolError.invalidRequest("x, y, toX, and toY are required for ax.drag")
      }
      try ensureDispatchAuthorized()
      try accessibility.drag(fromX: x, fromY: y, toX: toX, toY: toY, targetPid: targetPID)
      return try encodeSuccess(protocolName: protocolName, id: id, data: AXSimpleResultPayload(action: "ax.drag", detail: "Dragged from (\(x), \(y)) to (\(toX), \(toY))"))
    default:
      throw AgentProtocolError.unknownAction("Unknown action: \(action)")
    }
  }

  private func guardAccessibilityAction(action: String, params: AgentRequestParams) throws -> AXActionAuthorization {
    // Listing applications is a global discovery capability, not an implicit
    // observation exemption for every installed/running app.
    if action == "ax.list-apps" {
      let target = GlobalPermissionCategory.applicationDiscovery.permissionTarget
      try axPermissionCoordinator.authorizeObservation(
        target: target,
        action: action,
        context: "Requested through the Accessibility API."
      )
      return AXActionAuthorization(targetResolution: nil, permissionTarget: target)
    }

    let isWrite = accessibilityWriteActions.contains(action)
    let resolved = try axTargetResolver.resolve(params: params, useFrontmostFallback: isWrite)
    guard resolved.wasResolved, resolved.target.isValidated else {
      throw unresolvedAccessibilityTargetError(action: action, intent: isWrite ? .control : .observe)
    }

    if isWrite {
      try axPermissionCoordinator.authorizeControl(
        target: resolved.target,
        action: action,
        context: "Requested through the Accessibility API."
      )
    } else {
      try axPermissionCoordinator.authorizeObservation(
        target: resolved.target,
        action: action,
        context: "Requested through the Accessibility API."
      )
    }
    return AXActionAuthorization(targetResolution: resolved, permissionTarget: resolved.target)
  }

  /// Performs a no-prompt, fail-closed authorization check at the last safe
  /// point before an AX call. Any UI prompt or frontmost-app delay happened
  /// earlier, so rules/global controls/PID identity must be evaluated again.
  private func finalizeAccessibilityAuthorization(
    action: String,
    authorization: AXActionAuthorization
  ) throws {
    try requireRemoteControlEnabled()

    if accessibilityWriteActions.contains(action) {
      guard let targetResolution = authorization.targetResolution,
            axTargetResolver.isStillCurrent(targetResolution) else {
        throw unresolvedAccessibilityTargetError(action: action, intent: .control)
      }
      try axPermissionCoordinator.recheckControlWithoutPrompt(
        target: authorization.permissionTarget,
        action: action
      )
    } else {
      try axPermissionCoordinator.recheckObservationWithoutPrompt(
        target: authorization.permissionTarget,
        action: action
      )
    }
  }

  private func unresolvedAccessibilityTargetError(action: String, intent: AXPermissionIntent) -> AgentProtocolError {
    AgentProtocolError.appPermissionRequired(
      "The Accessibility target could not be resolved safely.",
      details: .object([
        "targetKind": .string(PermissionTargetKind.application.rawValue),
        "targetID": .string(""),
        "targetName": .string("Unknown app"),
        "intent": .string(intent.rawValue),
        "action": .string(action),
        "pending": .bool(false)
      ])
    )
  }

  private func runFunction(protocolName: String, id: String, params: AgentRequestParams) throws -> Data {
    let rawName = (params.functionName ?? params.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !rawName.isEmpty else {
      throw invalidArgsError("Function argument validation failed", violations: [
        .init(argument: "name", reason: "Function name is required.")
      ])
    }
    guard let function = functionRegistry.function(named: rawName, state: functionState) else {
      throw AgentProtocolError.unknownFunction("Unknown function: \(rawName)")
    }
    guard functionState.isEnabled(function.name, tier: function.tier) else {
      throw AgentProtocolError.functionDisabled("Function '\(function.name)' is disabled. Enable it in the local OkBrain Agent settings.")
    }
    let executionIdentity = function.executionIdentity

    do {
      let plan = try function.makeExecutionPlan(args: params.args ?? [:])
      let permissionTarget = try validatedPermissionTarget(for: plan, functionName: function.name)
      var dispatchPlan = plan
      let permissionAction = "functions.run → \(function.name)"
      let intent: AXPermissionIntent = function.tier == .read ? .observe : .control
      if intent == .observe {
        try axPermissionCoordinator.authorizeObservation(
          target: permissionTarget,
          action: permissionAction,
          context: "Requested by the curated macOS function catalog."
        )
      } else {
        try axPermissionCoordinator.authorizeControl(
          target: permissionTarget,
          action: permissionAction,
          context: "Requested by the curated macOS function catalog."
        )
      }
      if let target = plan.target, target.requiresAutomation {
        try requireAutomationAccess(target)
      }
      if let fileRequirement = plan.fileAccessRequirement {
        dispatchPlan = plan.withResolvedFilePath(try resolveFunctionFileAccess(fileRequirement))
      }

      // Prompts and TCC preflight may have waited seconds. Recheck every mutable
      // gate immediately before a catalog backend performs the operation.
      try requireRemoteControlEnabled()
      guard functionState.isEnabled(function.name, tier: function.tier),
            functionRegistry.isCurrent(executionIdentity, state: functionState) else {
        throw AgentProtocolError.functionDisabled("Function '\(function.name)' was disabled, removed, or replaced before it could run.")
      }
      if intent == .observe {
        try axPermissionCoordinator.recheckObservationWithoutPrompt(target: permissionTarget, action: permissionAction)
      } else {
        try axPermissionCoordinator.recheckControlWithoutPrompt(target: permissionTarget, action: permissionAction)
      }

      let context = FunctionExecutionContext(canObserveApp: { [axPermissionCoordinator] target in
        axPermissionCoordinator.allowsObservation(of: target)
      })
      let result = try function.run(plan: dispatchPlan, context: context)
      try FunctionOutputLimits.validate(result)
      return try encodeSuccess(protocolName: protocolName, id: id, data: FunctionRunPayload(name: function.name, result: result))
    } catch let error as AgentProtocolError {
      throw error
    } catch {
      throw AgentProtocolError.functionFailed(
        "Function '\(function.name)' failed: \(error.localizedDescription)",
        details: .object("function", .string(function.name))
      )
    }
  }

  /// A function plan must bind its authorization to the resource it will use.
  /// App-backed plans cannot borrow a global category (or another app's grant),
  /// and genuinely global plans cannot borrow an arbitrary app rule.
  private func validatedPermissionTarget(
    for plan: FunctionExecutionPlan,
    functionName: String
  ) throws -> PermissionTarget {
    guard let permissionTarget = plan.permissionTarget, permissionTarget.isValidated else {
      throw AgentProtocolError.functionFailed(
        "Function '\(functionName)' did not declare a valid permission target.",
        details: .object("function", .string(functionName))
      )
    }

    if let target = plan.target {
      guard permissionTarget == target.permissionTarget else {
        throw AgentProtocolError.functionFailed(
          "Function '\(functionName)' declared a permission target that does not match its application target.",
          details: .object(
            "function", .string(functionName),
            "expectedTargetID", .string(target.permissionTarget.id),
            "declaredTargetID", .string(permissionTarget.id)
          )
        )
      }
    } else if permissionTarget.kind != .category {
      throw AgentProtocolError.functionFailed(
        "Function '\(functionName)' must use an allow-listed global category when it has no application target.",
        details: .object("function", .string(functionName), "declaredTargetID", .string(permissionTarget.id))
      )
    }

    return permissionTarget
  }

  private func requireAutomationAccess(_ target: FunctionTarget) throws {
    var status = automationPermissions.status(forBundleID: target.bundleID)
    if status == .notDetermined {
      status = automationPermissions.requestAccess(forBundleID: target.bundleID)
    }
    guard status == .authorized else {
      throw AgentProtocolError.automationPermissionRequired(
        "Automation access to \(target.appName) is required. Grant it in System Settings → Privacy & Security → Automation.",
        details: .object("bundleID", .string(target.bundleID), "status", .string(status.rawValue))
      )
    }
  }

  private func resolveFunctionFileAccess(_ requirement: FunctionFileAccessRequirement) throws -> String {
    guard requirement.intent == .read else {
      throw AgentProtocolError.permissionDenied("Curated functions may only request read access through the file permission service")
    }
    return try fileEditing.resolveExistingReadablePath(requirement.path)
  }

  private func runShell(protocolName: String, id: String, params: AgentRequestParams) throws -> Data {
    guard configuration.shellAccessEnabled, !configuration.fileEditing.allowedRoots.isEmpty else {
      throw AgentProtocolError.invalidRequest("sh.exec requires Shell Access to be enabled with at least one file permission rule")
    }
    guard let command = params.command, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw AgentProtocolError.invalidRequest("command is required for sh.exec")
    }
    guard let cwd = params.cwd, !cwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw AgentProtocolError.invalidRequest("cwd is required for sh.exec")
    }

    let request = ShellExecutionRequest(
      command: command,
      cwd: cwd,
      env: params.env ?? [:],
      timeoutSeconds: params.timeoutSeconds ?? ShellExecutionService.defaultTimeoutSeconds
    )
    let outcome = try shellExecution.execute(request, fileRules: configuration.fileEditing.allowedRoots)
    let payload = ShellExecPayload(
      command: command,
      cwd: cwd,
      exitCode: outcome.exitCode,
      stdout: outcome.stdout,
      stderr: outcome.stderr,
      timedOut: outcome.timedOut,
      outputTruncated: outcome.outputTruncated
    )
    return try encodeSuccess(protocolName: protocolName, id: id, data: payload)
  }

  private func capture(protocolName: String, id: String, params: AgentRequestParams) throws -> Data {
    let currentPermissions = permissions.currentPermissions()
    guard currentPermissions.screenRecording == .granted else {
      throw AgentProtocolError.permissionDenied("Screen Recording permission is not granted")
    }

    let image = try screenshots.capture(params)
    guard image.data.count <= configuration.maxScreenshotBytes else {
      throw AgentProtocolError.responseTooLarge(image.data.count)
    }

    return try encodeSuccess(
      protocolName: protocolName,
      id: id,
      data: ScreenshotCapturePayload(image: image),
      bodyData: image.data
    )
  }

  private func requireAccessibility() throws {
    guard permissions.currentPermissions().accessibility == .granted else {
      throw AgentProtocolError.permissionDenied("Accessibility permission is not granted")
    }
  }

  private func requireRemoteControlEnabled() throws {
    guard remoteControlEnabled() else {
      throw AgentProtocolError.invalidRequest("Remote control APIs (Accessibility ax.* and curated functions.run) are disabled in the agent's settings")
    }
  }

  private func axQuery(
    _ params: AgentRequestParams,
    defaultDepth: Int = 10,
    resolvedTarget: AXResolvedTarget? = nil
  ) -> AXElementQuery {
    AXElementQuery(
      appName: params.appName,
      pid: resolvedTarget?.pid ?? params.pid,
      windowTitle: params.windowTitle,
      windowIndex: params.windowIndex,
      role: params.role,
      title: params.title,
      label: params.label,
      identifier: params.identifier,
      valueContains: params.valueContains,
      index: params.index ?? 0,
      maxDepth: params.depth ?? defaultDepth,
      maxElements: params.maxElements ?? 500,
      allWindows: params.allWindows ?? false,
      scope: params.scope,
      compact: params.compact ?? false
    )
  }

  private func statusPayload() -> AgentStatusPayload {
    let currentPermissions = permissionsWithFileAccess()
    var capabilities = [
      "screenshot.full",
      "screenshot.window",
      "screenshot.region",
      "screenshot.cursor",
      "screenshot.webp",
      "screenshot.binary",
      "functions.list",
      "functions.run",
      "functions.propose"
    ]

    if configuration.fileEditing.enabled {
      capabilities.append(contentsOf: [
        "workspace.describe",
        "fs.stat",
        "fs.list",
        "fs.read",
        "fs.write",
        "fs.patch",
        "fs.search"
      ])
    }

    if configuration.shellAccessEnabled, !configuration.fileEditing.allowedRoots.isEmpty {
      capabilities.append(contentsOf: [
        "sh.exec",
        "sh.status"
      ])
    }

    if currentPermissions.accessibility == .granted {
      capabilities.append(contentsOf: [
        "ax.list-apps",
        "ax.list-windows",
        "ax.get-tree",
        "ax.find",
        "ax.perform",
        "ax.get-value",
        "ax.set-value",
        "ax.type-text",
        "ax.key-press",
        "ax.click-at",
        "ax.scroll",
        "ax.drag"
      ])
    }

    return AgentStatusPayload(
      installed: true,
      running: true,
      available: currentPermissions.screenRecording == .granted
        || currentPermissions.accessibility == .granted
        || configuration.fileEditing.enabled
        || (configuration.shellAccessEnabled && !configuration.fileEditing.allowedRoots.isEmpty),
      version: configuration.version,
      socketPath: configuration.socketPath,
      permissions: currentPermissions,
      capabilities: capabilities,
      protocolVersions: AgentConfiguration.supportedProtocolVersions,
      fileEditing: FileEditingStatusPayload(configuration: configuration.fileEditing)
    )
  }

  private func permissionsWithFileAccess() -> AgentPermissionsPayload {
    let current = permissions.currentPermissions()
    return AgentPermissionsPayload(
      screenRecording: current.screenRecording,
      accessibility: current.accessibility,
      fileAccess: configuration.fileEditing.enabled ? .granted : .unknown
    )
  }

  private func infoPayload() -> AgentInfoPayload {
    AgentInfoPayload(
      version: configuration.version,
      build: configuration.build,
      protocolName: AgentConfiguration.protocolName,
      socketPath: configuration.socketPath,
      transport: "ssh-unix-socket-binary-frame",
      protocolVersions: AgentConfiguration.supportedProtocolVersions
    )
  }

  private func normalizedID(_ id: String?) -> String {
    let trimmedID = id?.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmedID?.isEmpty == false ? trimmedID! : "req_\(UUID().uuidString)"
  }

  private func encodeSuccess<T: Encodable>(
    protocolName: String,
    id: String,
    data: T,
    bodyData: Data = Data()
  ) throws -> Data {
    let headerData = try JSONEncoder().encode(SuccessEnvelope(protocolName: protocolName, id: id, data: data))
    return try AgentBinaryFrame.encode(headerData: headerData, bodyData: bodyData)
  }

  private func errorResponseData(protocolName: String, id: String, error: AgentProtocolError) -> Data {
    do {
      let headerData = try JSONEncoder().encode(ErrorEnvelope(
        protocolName: protocolName,
        id: id,
        error: ErrorPayload(code: error.code, message: error.message, details: error.details)
      ))
      return try AgentBinaryFrame.encode(headerData: headerData)
    } catch {
      let fallback = "{\"protocol\":\"\(protocolName)\",\"id\":\"unknown\",\"ok\":false,\"error\":{\"code\":\"encode_failed\",\"message\":\"Unable to encode response\"}}"
      let headerData = Data(fallback.utf8)
      return (try? AgentBinaryFrame.encode(headerData: headerData)) ?? headerData
    }
  }
}

private struct SuccessEnvelope<T: Encodable>: Encodable {
  let protocolName: String
  let id: String
  let ok = true
  let data: T

  private enum CodingKeys: String, CodingKey {
    case protocolName = "protocol"
    case id
    case ok
    case data
  }
}

private struct ErrorEnvelope: Encodable {
  let protocolName: String
  let id: String
  let ok = false
  let error: ErrorPayload

  private enum CodingKeys: String, CodingKey {
    case protocolName = "protocol"
    case id
    case ok
    case error
  }
}

private struct ErrorPayload: Encodable {
  let code: String
  let message: String
  let details: JSONValue?

  private enum CodingKeys: String, CodingKey {
    case code
    case message
    case details
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(code, forKey: .code)
    try container.encode(message, forKey: .message)
    try container.encodeIfPresent(details, forKey: .details)
  }
}
