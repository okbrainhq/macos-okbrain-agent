import AppKit
import CoreWLAN
import Foundation
import IOKit.ps
import UserNotifications

/// A stable application identity used by name-based catalog functions before
/// authorization. The resolver deliberately exposes bundle IDs rather than
/// allowing a display name to bypass App Control rules.
public struct ApplicationDescriptor: Equatable, Sendable {
  public let bundleID: String
  public let appName: String
  public let pid: Int32?
  public let frontmost: Bool

  public init(bundleID: String, appName: String, pid: Int32? = nil, frontmost: Bool = false) {
    self.bundleID = bundleID
    self.appName = appName
    self.pid = pid
    self.frontmost = frontmost
  }
}

public enum ApplicationNameResolution: Equatable, Sendable {
  case resolved(ApplicationDescriptor)
  case notFound
  case ambiguous
}

/// Resolves catalog app names before the handler performs observation or
/// control authorization. Keeping this injectable makes name behavior
/// deterministic in protocol verification.
public protocol ApplicationResolving: Sendable {
  /// Resolves a caller-supplied bundle ID to an installed or currently running
  /// application before a permission prompt can name or grant it.
  func resolveApplication(bundleID: String) -> ApplicationDescriptor?
  func runningApplication(bundleID: String) -> ApplicationDescriptor?
  func resolveApplication(named name: String) -> ApplicationNameResolution
}

public final class SystemApplicationResolver: ApplicationResolving, @unchecked Sendable {
  public init() {}

  public func resolveApplication(bundleID rawBundleID: String) -> ApplicationDescriptor? {
    let bundleID = rawBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard PermissionTarget.isValidApplicationBundleID(bundleID) else { return nil }
    if let running = runningApplication(bundleID: bundleID) {
      return running
    }

    // Do not authorize or prompt for a syntactically valid but invented bundle
    // identifier. Launch Services must resolve an installed app whose own
    // bundle metadata matches the requested ID.
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
          let installedBundleID = Bundle(url: url)?.bundleIdentifier,
          installedBundleID.caseInsensitiveCompare(bundleID) == .orderedSame else {
      return nil
    }
    let appName = FileManager.default.displayName(atPath: url.path)
    return ApplicationDescriptor(
      bundleID: installedBundleID,
      appName: appName.isEmpty ? installedBundleID : appName
    )
  }

  public func runningApplication(bundleID rawBundleID: String) -> ApplicationDescriptor? {
    let bundleID = rawBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !bundleID.isEmpty else { return nil }
    return runningApplications().first {
      $0.bundleID.caseInsensitiveCompare(bundleID) == .orderedSame
    }
  }

  public func resolveApplication(named rawName: String) -> ApplicationNameResolution {
    let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return .notFound }

    var runningMatches: [String: ApplicationDescriptor] = [:]
    for app in runningApplications() where app.appName.caseInsensitiveCompare(name) == .orderedSame {
      runningMatches[app.bundleID.lowercased()] = app
    }
    switch runningMatches.count {
    case 1:
      guard let match = runningMatches.values.first else { return .notFound }
      return .resolved(match)
    case let count where count > 1:
      return .ambiguous
    default:
      break
    }

    // A non-running name query may only return false after we bind that name
    // to one installed bundle ID. Search standard application directories;
    // verify the display/bundle filename is an exact match so a fuzzy result
    // cannot select an unintended target.
    guard let url = Self.applicationURL(forName: name),
          let bundle = Bundle(url: url),
          let bundleID = bundle.bundleIdentifier else {
      return .notFound
    }
    let path = url.path
    let displayName = FileManager.default.displayName(atPath: path)
    let fileName = url.deletingPathExtension().lastPathComponent
    guard displayName.caseInsensitiveCompare(name) == .orderedSame
      || fileName.caseInsensitiveCompare(name) == .orderedSame else {
      return .notFound
    }
    return .resolved(ApplicationDescriptor(bundleID: bundleID, appName: displayName))
  }

  private func runningApplications() -> [ApplicationDescriptor] {
    NSWorkspace.shared.runningApplications.compactMap { app in
      guard !app.isTerminated, let bundleID = app.bundleIdentifier else { return nil }
      return ApplicationDescriptor(
        bundleID: bundleID,
        appName: app.localizedName ?? bundleID,
        pid: app.processIdentifier,
        frontmost: app.isActive
      )
    }
  }

  /// Searches standard application directories for an app matching `name`.
  private static func applicationURL(forName name: String) -> URL? {
    let fileName = name.hasSuffix(".app") ? name : "\(name).app"
    let searchDirs = [
      "/Applications",
      "/System/Applications",
      "/System/Applications/Utilities",
      "/Applications/Utilities",
      NSHomeDirectory() + "/Applications",
    ]
    for dir in searchDirs {
      let candidate = URL(fileURLWithPath: dir).appendingPathComponent(fileName)
      if FileManager.default.fileExists(atPath: candidate.path) {
        return candidate
      }
    }
    return nil
  }
}

public final class FunctionRegistry: @unchecked Sendable {
  private let builtIns: [String: any MacOSFunction]
  private let executor: FixedAppleScriptExecutor

  public convenience init(functions: [any MacOSFunction]) {
    self.init(functions: functions, executor: FixedAppleScriptExecutor())
  }

  private init(functions: [any MacOSFunction], executor: FixedAppleScriptExecutor) {
    var byName: [String: any MacOSFunction] = [:]
    for function in functions {
      byName[function.name.lowercased()] = function
    }
    builtIns = byName
    self.executor = executor
  }

  public static func standard(applicationResolver: ApplicationResolving = SystemApplicationResolver()) -> FunctionRegistry {
    let executor = FixedAppleScriptExecutor()
    return FunctionRegistry(
      functions: CuratedFunctionFactory.makeFunctions(executor: executor, applicationResolver: applicationResolver),
      executor: executor
    )
  }

  public func function(named rawName: String, state: FunctionRuntimeState) -> (any MacOSFunction)? {
    let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if let builtIn = builtIns[name] { return builtIn }
    if let template = state.executableTemplate(named: name) {
      return StoredTemplateFunction(template: template, executor: executor)
    }
    return nil
  }

  /// Revalidates the exact function object selected at request start. This is
  /// intentionally stronger than a name lookup so an in-flight stored template
  /// cannot execute after being removed and re-approved under the same name.
  public func isCurrent(_ identity: FunctionExecutionIdentity, state: FunctionRuntimeState) -> Bool {
    switch identity {
    case .builtIn(let name):
      return builtIns[name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] != nil
    case .template(let id, let sourceDigest):
      return state.executableTemplate(id: id, sourceDigest: sourceDigest) != nil
    }
  }

  public func catalog(
    state: FunctionRuntimeState,
    automation: AutomationPermissionServicing
  ) -> FunctionListPayload {
    var entries = builtIns.values.map { function in
      let targetBundleID = function.catalogTargetBundleID
      return FunctionCatalogEntry(
        name: function.name,
        summary: function.summary,
        tier: function.tier,
        args: function.argSchema,
        enabled: state.isEnabled(function.name, tier: function.tier),
        targetBundleID: targetBundleID,
        permissionTarget: function.catalogPermissionTarget,
        automationStatus: targetBundleID.map { automation.status(forBundleID: $0) }
      )
    }

    let templates = state.snapshot().templates.map { template in
      let function = StoredTemplateFunction(template: template, executor: executor)
      let executable = state.isTemplateExecutable(template)
      return FunctionCatalogEntry(
        name: function.name,
        summary: function.summary,
        tier: function.tier,
        args: function.argSchema,
        enabled: executable,
        targetBundleID: template.targetBundleID,
        permissionTarget: template.targetBundleID.map {
          PermissionTarget(applicationBundleID: $0, appName: template.targetAppName ?? $0)
        },
        automationStatus: template.targetBundleID.map { automation.status(forBundleID: $0) }
      )
    }
    entries.append(contentsOf: templates)
    entries.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    return FunctionListPayload(functions: entries)
  }

  /// Metadata for the local settings UI. It does not expose executable source.
  public func localCatalogEntries(state: FunctionRuntimeState) -> [FunctionCatalogEntry] {
    var entries = builtIns.values.map { function in
      FunctionCatalogEntry(
        name: function.name,
        summary: function.summary,
        tier: function.tier,
        args: function.argSchema,
        enabled: state.isEnabled(function.name, tier: function.tier),
        targetBundleID: function.catalogTargetBundleID,
        permissionTarget: function.catalogPermissionTarget,
        automationStatus: nil
      )
    }
    entries.append(contentsOf: state.snapshot().templates.map { template in
      FunctionCatalogEntry(
        name: template.name,
        summary: template.summary,
        tier: .elevated,
        args: template.argumentNames.map {
          FunctionArg(name: $0, type: .string, required: true, description: "Template placeholder \($0)", maxLength: 10_000)
        },
        enabled: state.isTemplateExecutable(template),
        targetBundleID: template.targetBundleID,
        permissionTarget: template.targetBundleID.map {
          PermissionTarget(applicationBundleID: $0, appName: template.targetAppName ?? $0)
        },
        automationStatus: nil
      )
    })
    return entries.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }
}

private final class ClosureFunction: MacOSFunction, @unchecked Sendable {
  let name: String
  let summary: String
  let tier: FunctionTier
  let argSchema: [FunctionArg]
  let catalogTargetBundleID: String?
  let catalogPermissionTarget: PermissionTarget?
  private let planBuilder: @Sendable ([String: JSONValue]) throws -> FunctionExecutionPlan
  private let runner: @Sendable (FunctionExecutionPlan, FunctionExecutionContext) throws -> FunctionResult

  init(
    name: String,
    summary: String,
    tier: FunctionTier,
    argSchema: [FunctionArg] = [],
    catalogTargetBundleID: String? = nil,
    catalogPermissionTarget: PermissionTarget? = nil,
    planBuilder: @escaping @Sendable ([String: JSONValue]) throws -> FunctionExecutionPlan = { args in
      FunctionExecutionPlan(args: args)
    },
    runner: @escaping @Sendable (FunctionExecutionPlan) throws -> FunctionResult
  ) {
    self.name = name
    self.summary = summary
    self.tier = tier
    self.argSchema = argSchema
    self.catalogTargetBundleID = catalogTargetBundleID
    self.catalogPermissionTarget = catalogPermissionTarget
      ?? catalogTargetBundleID.map { PermissionTarget(applicationBundleID: $0, appName: $0) }
    self.planBuilder = planBuilder
    self.runner = { plan, _ in try runner(plan) }
  }

  init(
    name: String,
    summary: String,
    tier: FunctionTier,
    argSchema: [FunctionArg] = [],
    catalogTargetBundleID: String? = nil,
    catalogPermissionTarget: PermissionTarget? = nil,
    planBuilder: @escaping @Sendable ([String: JSONValue]) throws -> FunctionExecutionPlan = { args in
      FunctionExecutionPlan(args: args)
    },
    contextRunner: @escaping @Sendable (FunctionExecutionPlan, FunctionExecutionContext) throws -> FunctionResult
  ) {
    self.name = name
    self.summary = summary
    self.tier = tier
    self.argSchema = argSchema
    self.catalogTargetBundleID = catalogTargetBundleID
    self.catalogPermissionTarget = catalogPermissionTarget
      ?? catalogTargetBundleID.map { PermissionTarget(applicationBundleID: $0, appName: $0) }
    self.planBuilder = planBuilder
    self.runner = contextRunner
  }

  func makeExecutionPlan(args: [String: JSONValue]) throws -> FunctionExecutionPlan {
    try planBuilder(args)
  }

  func run(plan: FunctionExecutionPlan) throws -> FunctionResult {
    try runner(plan, .unrestricted)
  }

  func run(plan: FunctionExecutionPlan, context: FunctionExecutionContext) throws -> FunctionResult {
    try runner(plan, context)
  }
}

private enum CuratedFunctionFactory {
  static func makeFunctions(
    executor: FixedAppleScriptExecutor,
    applicationResolver: ApplicationResolving
  ) -> [any MacOSFunction] {
    [
      appList(),
      appIsRunning(applicationResolver: applicationResolver),
      systemGetVolume(executor: executor),
      systemGetClipboard(),
      systemGetBattery(),
      systemGetWiFiName(),
      mediaNowPlaying(executor: executor),
      browserGetURL(executor: executor),
      browserGetTitle(executor: executor),
      browserListTabs(executor: executor),
      finderGetSelection(executor: executor),
      finderGetFrontPath(executor: executor),
      appLaunch(),
      appActivate(),
      appQuit(),
      systemSetVolume(executor: executor),
      systemMute(executor: executor),
      systemSetClipboard(),
      systemNotify(),
      mediaControl(name: "media.play-pause", verb: "playpause", executor: executor),
      mediaControl(name: "media.next", verb: "next track", executor: executor),
      mediaControl(name: "media.previous", verb: "previous track", executor: executor),
      browserOpenURL(executor: executor),
      finderReveal(),
      dialogAskUser(executor: executor),
      browserRunJavaScript(executor: executor)
    ]
  }

  private static func appList() -> any MacOSFunction {
    ClosureFunction(
      name: "app.list",
      summary: "List running GUI applications after Application Discovery is approved.",
      tier: .read,
      catalogPermissionTarget: GlobalPermissionCategory.applicationDiscovery.permissionTarget,
      planBuilder: { args in
        FunctionExecutionPlan(
          args: try validateFunctionArgs(args, schema: []),
          permissionTarget: GlobalPermissionCategory.applicationDiscovery.permissionTarget
        )
      }
    ) { _ in
      let apps = NSWorkspace.shared.runningApplications
        .filter { $0.activationPolicy == .regular && !$0.isTerminated }
        .sorted { ($0.localizedName ?? "").localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending }
        .map { app -> JSONValue in
          .object(
            "name", .string(app.localizedName ?? "Unknown"),
            "bundleID", app.bundleIdentifier.map(JSONValue.string) ?? .null,
            "pid", .number(Double(app.processIdentifier)),
            "frontmost", .bool(app.isActive)
          )
        }
      return FunctionResult(value: .object("apps", .array(apps)))
    }
  }

  private static func appIsRunning(applicationResolver: ApplicationResolving) -> any MacOSFunction {
    let schema = [
      FunctionArg(name: "bundleID", type: .string, required: false, description: "Application bundle identifier", maxLength: 255),
      FunctionArg(name: "name", type: .string, required: false, description: "Application name", maxLength: 255)
    ]
    return ClosureFunction(
      name: "app.is-running",
      summary: "Check whether an application is running.",
      tier: .read,
      argSchema: schema,
      planBuilder: { args in
        let args = try validateFunctionArgs(args, schema: schema)
        let bundleID = args["bundleID"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let name = args["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        guard (bundleID != nil) != (name != nil) else {
          throw invalidArgsError("Function argument validation failed", violations: [
            .init(argument: "bundleID", reason: "Provide exactly one of bundleID or name."),
            .init(argument: "name", reason: "Provide exactly one of bundleID or name.")
          ])
        }

        if let bundleID {
          // A syntactically valid bundle ID alone is not enough to create a
          // popup or persistent permission rule. Bind it to an installed or
          // running application before asking for Observe.
          guard let app = applicationResolver.resolveApplication(bundleID: bundleID) else {
            throw AgentProtocolError.appNotFound("No installed or running application matches '\(bundleID)'")
          }
          return FunctionExecutionPlan(
            args: args,
            target: FunctionTarget(
              bundleID: app.bundleID,
              appName: app.appName,
              requiresAutomation: false
            )
          )
        }

        // Name queries must bind to one bundle ID before the handler can apply
        // default-deny observation rules. Returning false for an unresolved
        // display name would otherwise disclose an unapproved app status.
        switch applicationResolver.resolveApplication(named: name!) {
        case .resolved(let app):
          return FunctionExecutionPlan(
            args: args,
            target: FunctionTarget(
              bundleID: app.bundleID,
              appName: app.appName,
              requiresAutomation: false
            )
          )
        case .notFound:
          throw AgentProtocolError.appNotFound("No installed or running application matches '\(name!)'")
        case .ambiguous:
          throw AgentProtocolError.appNotFound("Use bundleID when application name '\(name!)' is ambiguous")
        }
      }
    ) { plan in
      guard let target = plan.target else {
        throw AgentProtocolError.functionFailed("Application target was not resolved", details: nil)
      }
      let app = applicationResolver.runningApplication(bundleID: target.bundleID)
      return FunctionResult(value: .object(
        "running", .bool(app != nil),
        "app", app.map(appJSON) ?? .null
      ))
    }
  }

  private static func systemGetVolume(executor: FixedAppleScriptExecutor) -> any MacOSFunction {
    ClosureFunction(
      name: "system.get-volume",
      summary: "Read the output volume and mute state.",
      tier: .read,
      catalogPermissionTarget: GlobalPermissionCategory.systemAudio.permissionTarget,
      planBuilder: { args in
        FunctionExecutionPlan(
          args: try validateFunctionArgs(args, schema: []),
          permissionTarget: GlobalPermissionCategory.systemAudio.permissionTarget
        )
      }
    ) { _ in
      let output = try executor.runAppleScript("""
      set settings to get volume settings
      return (output volume of settings as text) & "|" & (output muted of settings as text)
      """)
      let fields = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "|", maxSplits: 1).map(String.init)
      guard let volume = fields.first.flatMap(Double.init) else {
        throw FixedAppleScriptExecutor.ExecutionError.failed("The volume response was invalid.")
      }
      let muted = fields.count > 1 && fields[1].lowercased() == "true"
      return FunctionResult(value: .object("volume", .number(volume), "muted", .bool(muted)))
    }
  }

  private static func systemGetClipboard() -> any MacOSFunction {
    ClosureFunction(
      name: "system.get-clipboard",
      summary: "Read plain text from the clipboard.",
      tier: .read,
      catalogPermissionTarget: GlobalPermissionCategory.clipboard.permissionTarget,
      planBuilder: { args in
        FunctionExecutionPlan(
          args: try validateFunctionArgs(args, schema: []),
          permissionTarget: GlobalPermissionCategory.clipboard.permissionTarget
        )
      }
    ) { _ in
      FunctionResult(value: .object("text", NSPasteboard.general.string(forType: .string).map(JSONValue.string) ?? .null))
    }
  }

  private static func systemGetBattery() -> any MacOSFunction {
    ClosureFunction(
      name: "system.get-battery",
      summary: "Read battery capacity and charging state.",
      tier: .read,
      catalogPermissionTarget: GlobalPermissionCategory.power.permissionTarget,
      planBuilder: { args in
        FunctionExecutionPlan(
          args: try validateFunctionArgs(args, schema: []),
          permissionTarget: GlobalPermissionCategory.power.permissionTarget
        )
      }
    ) { _ in
      guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef],
            let source = sources.first,
            let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any] else {
        return FunctionResult(value: .object("available", .bool(false)))
      }
      let capacity = (description[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue
      let charging = (description[kIOPSIsChargingKey] as? NSNumber)?.boolValue
      return FunctionResult(value: .object(
        "available", .bool(true),
        "percentage", capacity.map(JSONValue.number) ?? .null,
        "charging", charging.map(JSONValue.bool) ?? .null
      ))
    }
  }

  private static func systemGetWiFiName() -> any MacOSFunction {
    ClosureFunction(
      name: "system.get-wifi-name",
      summary: "Read the current Wi‑Fi network name.",
      tier: .read,
      catalogPermissionTarget: GlobalPermissionCategory.network.permissionTarget,
      planBuilder: { args in
        FunctionExecutionPlan(
          args: try validateFunctionArgs(args, schema: []),
          permissionTarget: GlobalPermissionCategory.network.permissionTarget
        )
      }
    ) { _ in
      FunctionResult(value: .object("ssid", CWWiFiClient.shared().interface()?.ssid().map(JSONValue.string) ?? .null))
    }
  }

  private static func mediaNowPlaying(executor: FixedAppleScriptExecutor) -> any MacOSFunction {
    let schema = [FunctionArg(name: "player", type: .string, required: false, description: "Music or Spotify", enumValues: ["music", "spotify"])]
    return ClosureFunction(
      name: "media.now-playing",
      summary: "Read current track metadata from Music or Spotify.",
      tier: .read,
      argSchema: schema,
      planBuilder: { args in
        let args = try validateFunctionArgs(args, schema: schema)
        let player = try mediaPlayer(from: args["player"]?.stringValue)
        return FunctionExecutionPlan(args: args, target: player.target)
      }
    ) { plan in
      let player = try mediaPlayer(from: plan.args["player"]?.stringValue)
      let output = try executor.runAppleScript(player.nowPlayingScript)
      return FunctionResult(value: parseDelimitedMediaOutput(output.stdout, player: player.name))
    }
  }

  private static func browserGetURL(executor: FixedAppleScriptExecutor) -> any MacOSFunction {
    browserReadFunction(name: "browser.get-url", summary: "Read the URL of the active browser tab.", executor: executor) { browser in
      browser.activeURLScript
    } result: { output in
      .object("url", .string(output.trimmingCharacters(in: .whitespacesAndNewlines)))
    }
  }

  private static func browserGetTitle(executor: FixedAppleScriptExecutor) -> any MacOSFunction {
    browserReadFunction(name: "browser.get-title", summary: "Read the title of the active browser tab.", executor: executor) { browser in
      browser.activeTitleScript
    } result: { output in
      .object("title", .string(output.trimmingCharacters(in: .whitespacesAndNewlines)))
    }
  }

  private static func browserListTabs(executor: FixedAppleScriptExecutor) -> any MacOSFunction {
    browserReadFunction(name: "browser.list-tabs", summary: "List open tabs in the front browser window.", executor: executor) { browser in
      browser.listTabsScript
    } result: { output in
      let tabs = output.split(separator: "\n").filter { !$0.isEmpty }.map { line -> JSONValue in
        let fields = line.split(separator: "|", maxSplits: 1).map(String.init)
        return .object(
          "title", fields.first.map(JSONValue.string) ?? .null,
          "url", fields.count > 1 ? .string(fields[1]) : .null
        )
      }
      return .object("tabs", .array(tabs))
    }
  }

  private static func finderGetSelection(executor: FixedAppleScriptExecutor) -> any MacOSFunction {
    ClosureFunction(
      name: "finder.get-selection",
      summary: "Read the selected paths in Finder.",
      tier: .read,
      catalogTargetBundleID: "com.apple.finder",
      planBuilder: { args in
        let validated = try validateFunctionArgs(args, schema: [])
        return FunctionExecutionPlan(args: validated, target: finderTarget(automation: true))
      }
    ) { _ in
      let output = try executor.runAppleScript("""
      tell application id "com.apple.finder"
        set selectedItems to selection
        set outputLines to {}
        repeat with selectedItem in selectedItems
          set end of outputLines to POSIX path of (selectedItem as alias)
        end repeat
        set AppleScript's text item delimiters to linefeed
        return outputLines as text
      end tell
      """)
      let paths = output.stdout.split(separator: "\n").filter { !$0.isEmpty }.map { JSONValue.string(String($0)) }
      return FunctionResult(value: .object("paths", .array(paths)))
    }
  }

  private static func finderGetFrontPath(executor: FixedAppleScriptExecutor) -> any MacOSFunction {
    ClosureFunction(
      name: "finder.get-front-path",
      summary: "Read the path of Finder’s front window.",
      tier: .read,
      catalogTargetBundleID: "com.apple.finder",
      planBuilder: { args in
        let validated = try validateFunctionArgs(args, schema: [])
        return FunctionExecutionPlan(args: validated, target: finderTarget(automation: true))
      }
    ) { _ in
      let output = try executor.runAppleScript("""
      tell application id "com.apple.finder"
        if (count of Finder windows) is 0 then return ""
        return POSIX path of (target of front Finder window as alias)
      end tell
      """)
      let path = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
      return FunctionResult(value: .object("path", path.isEmpty ? .null : .string(path)))
    }
  }

  private static func appLaunch() -> any MacOSFunction {
    appWriteFunction(name: "app.launch", summary: "Launch an application.") { target in
      guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: target.bundleID) else {
        throw AgentProtocolError.functionFailed("No installed application matches \(target.bundleID)", details: nil)
      }
      let configuration = NSWorkspace.OpenConfiguration()
      NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
        // Completion is intentionally asynchronous; launch was successfully requested.
        _ = error
      }
      return FunctionResult(value: .object("requested", .bool(true), "bundleID", .string(target.bundleID)))
    }
  }

  private static func appActivate() -> any MacOSFunction {
    appWriteFunction(name: "app.activate", summary: "Bring a running application to the foreground.") { target in
      guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier?.caseInsensitiveCompare(target.bundleID) == .orderedSame }) else {
        throw AgentProtocolError.appNotFound("\(target.appName) is not running")
      }
      app.activate()
      return FunctionResult(value: .object("activated", .bool(true), "bundleID", .string(target.bundleID)))
    }
  }

  private static func appQuit() -> any MacOSFunction {
    appWriteFunction(name: "app.quit", summary: "Request a graceful application quit.") { target in
      guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier?.caseInsensitiveCompare(target.bundleID) == .orderedSame }) else {
        throw AgentProtocolError.appNotFound("\(target.appName) is not running")
      }
      return FunctionResult(value: .object("requested", .bool(app.terminate()), "bundleID", .string(target.bundleID)))
    }
  }

  private static func systemSetVolume(executor: FixedAppleScriptExecutor) -> any MacOSFunction {
    let schema = [FunctionArg(name: "volume", type: .integer, required: true, description: "Output volume from 0 through 100", minimum: 0, maximum: 100)]
    return ClosureFunction(
      name: "system.set-volume",
      summary: "Set output volume.",
      tier: .write,
      argSchema: schema,
      catalogPermissionTarget: GlobalPermissionCategory.systemAudio.permissionTarget,
      planBuilder: { args in
        FunctionExecutionPlan(
          args: try validateFunctionArgs(args, schema: schema),
          permissionTarget: GlobalPermissionCategory.systemAudio.permissionTarget
        )
      }
    ) { plan in
      let volume = Int(plan.args["volume"]!.numberValue!)
      _ = try executor.runAppleScript("set volume output volume \(volume)")
      return FunctionResult(value: .object("volume", .number(Double(volume))))
    }
  }

  private static func systemMute(executor: FixedAppleScriptExecutor) -> any MacOSFunction {
    let schema = [FunctionArg(name: "muted", type: .boolean, required: true, description: "Whether output should be muted")]
    return ClosureFunction(
      name: "system.mute",
      summary: "Set output mute state.",
      tier: .write,
      argSchema: schema,
      catalogPermissionTarget: GlobalPermissionCategory.systemAudio.permissionTarget,
      planBuilder: { args in
        FunctionExecutionPlan(
          args: try validateFunctionArgs(args, schema: schema),
          permissionTarget: GlobalPermissionCategory.systemAudio.permissionTarget
        )
      }
    ) { plan in
      let muted = plan.args["muted"]!.boolValue!
      _ = try executor.runAppleScript(muted ? "set volume with output muted" : "set volume without output muted")
      return FunctionResult(value: .object("muted", .bool(muted)))
    }
  }

  private static func systemSetClipboard() -> any MacOSFunction {
    let schema = [FunctionArg(name: "text", type: .string, required: true, description: "Plain text to copy", maxLength: 1_000_000)]
    return ClosureFunction(
      name: "system.set-clipboard",
      summary: "Replace plain text on the clipboard.",
      tier: .write,
      argSchema: schema,
      catalogPermissionTarget: GlobalPermissionCategory.clipboard.permissionTarget,
      planBuilder: { args in
        FunctionExecutionPlan(
          args: try validateFunctionArgs(args, schema: schema),
          permissionTarget: GlobalPermissionCategory.clipboard.permissionTarget
        )
      }
    ) { plan in
      let text = plan.args["text"]!.stringValue!
      let board = NSPasteboard.general
      board.clearContents()
      guard board.setString(text, forType: .string) else {
        throw AgentProtocolError.functionFailed("Unable to write the clipboard", details: nil)
      }
      return FunctionResult(value: .object("copied", .bool(true), "characters", .number(Double(text.count))))
    }
  }

  private static func systemNotify() -> any MacOSFunction {
    let schema = [
      FunctionArg(name: "message", type: .string, required: true, description: "Notification body", maxLength: 2_000),
      FunctionArg(name: "subtitle", type: .string, required: false, description: "Optional notification subtitle", maxLength: 500)
    ]
    return ClosureFunction(
      name: "system.notify",
      summary: "Show a notification branded as OkBrain Agent.",
      tier: .write,
      argSchema: schema,
      catalogPermissionTarget: GlobalPermissionCategory.notifications.permissionTarget,
      planBuilder: { args in
        FunctionExecutionPlan(
          args: try validateFunctionArgs(args, schema: schema),
          permissionTarget: GlobalPermissionCategory.notifications.permissionTarget
        )
      }
    ) { plan in
      let content = UNMutableNotificationContent()
      content.title = "OkBrain Agent"
      content.subtitle = plan.args["subtitle"]?.stringValue ?? ""
      content.body = plan.args["message"]!.stringValue!
      let request = UNNotificationRequest(identifier: "okbrain-function-\(UUID().uuidString)", content: content, trigger: nil)
      let semaphore = DispatchSemaphore(value: 0)
      let lock = NSLock()
      var failure: Error?
      UNUserNotificationCenter.current().add(request) { error in
        lock.lock(); failure = error; lock.unlock()
        semaphore.signal()
      }
      guard semaphore.wait(timeout: .now() + 5) == .success else {
        throw AgentProtocolError.functionFailed("The notification request timed out", details: nil)
      }
      lock.lock(); let error = failure; lock.unlock()
      if let error {
        throw AgentProtocolError.functionFailed("Unable to schedule notification: \(error.localizedDescription)", details: nil)
      }
      return FunctionResult(value: .object("delivered", .bool(true)))
    }
  }

  private static func mediaControl(name: String, verb: String, executor: FixedAppleScriptExecutor) -> any MacOSFunction {
    let schema = [FunctionArg(name: "player", type: .string, required: true, description: "Music or Spotify", enumValues: ["music", "spotify"])]
    return ClosureFunction(
      name: name,
      summary: "Control playback in Music or Spotify.",
      tier: .write,
      argSchema: schema,
      planBuilder: { args in
        let args = try validateFunctionArgs(args, schema: schema)
        let player = try mediaPlayer(from: args["player"]?.stringValue)
        return FunctionExecutionPlan(args: args, target: player.target)
      }
    ) { plan in
      let player = try mediaPlayer(from: plan.args["player"]?.stringValue)
      _ = try executor.runAppleScript("tell application id \"\(player.target.bundleID)\" to \(verb)")
      return FunctionResult(value: .object("player", .string(player.name), "action", .string(name)))
    }
  }

  private static func browserOpenURL(executor: FixedAppleScriptExecutor) -> any MacOSFunction {
    let schema = browserSchema(extra: [FunctionArg(name: "url", type: .string, required: true, description: "HTTP or HTTPS URL", maxLength: 8_192)])
    return ClosureFunction(
      name: "browser.open-url",
      summary: "Open a URL in a new browser tab.",
      tier: .write,
      argSchema: schema,
      planBuilder: { args in
        let args = try validateFunctionArgs(args, schema: schema)
        guard let rawURL = args["url"]?.stringValue,
              let url = URL(string: rawURL),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
          throw invalidArgsError("Function argument validation failed", violations: [
            .init(argument: "url", reason: "Use an absolute http or https URL.")
          ])
        }
        let browser = try browser(from: args["browser"]?.stringValue)
        return FunctionExecutionPlan(args: args, target: browser.target)
      }
    ) { plan in
      let browser = try browser(from: plan.args["browser"]?.stringValue)
      let url = plan.args["url"]!.stringValue!
      let literal = executor.appleScriptStringLiteral(url)
      _ = try executor.runAppleScript(browser.openURLScript(urlLiteral: literal))
      return FunctionResult(value: .object("opened", .bool(true), "url", .string(url)))
    }
  }

  private static func finderReveal() -> any MacOSFunction {
    let schema = [FunctionArg(name: "path", type: .string, required: true, description: "Absolute path previously allowed for file access", maxLength: 16_384)]
    return ClosureFunction(
      name: "finder.reveal",
      summary: "Reveal an allowed file or folder in Finder.",
      tier: .write,
      argSchema: schema,
      catalogTargetBundleID: "com.apple.finder",
      planBuilder: { args in
        let args = try validateFunctionArgs(args, schema: schema)
        guard let path = args["path"]?.stringValue, (path as NSString).isAbsolutePath else {
          throw invalidArgsError("Function argument validation failed", violations: [
            .init(argument: "path", reason: "Use an absolute path.")
          ])
        }
        return FunctionExecutionPlan(
          args: args,
          target: finderTarget(automation: false),
          fileAccessRequirement: FunctionFileAccessRequirement(path: path, intent: .read)
        )
      }
    ) { plan in
      guard let canonicalPath = plan.resolvedFilePath else {
        throw AgentProtocolError.functionFailed("Finder reveal did not receive a canonical authorized path", details: nil)
      }
      let url = URL(fileURLWithPath: canonicalPath)
      NSWorkspace.shared.activateFileViewerSelecting([url])
      return FunctionResult(value: .object("revealed", .bool(true), "path", .string(canonicalPath)))
    }
  }

  private static func dialogAskUser(executor: FixedAppleScriptExecutor) -> any MacOSFunction {
    let schema = [
      FunctionArg(name: "message", type: .string, required: true, description: "Question to show", maxLength: 4_000),
      FunctionArg(name: "defaultAnswer", type: .string, required: false, description: "Optional default text", maxLength: 4_000),
      FunctionArg(name: "confirmLabel", type: .string, required: false, description: "Confirm button label", maxLength: 80),
      FunctionArg(name: "cancelLabel", type: .string, required: false, description: "Cancel button label", maxLength: 80)
    ]
    return ClosureFunction(
      name: "dialog.ask-user",
      summary: "Ask the local user a branded question.",
      tier: .write,
      argSchema: schema,
      catalogPermissionTarget: GlobalPermissionCategory.dialogs.permissionTarget,
      planBuilder: { args in
        FunctionExecutionPlan(
          args: try validateFunctionArgs(args, schema: schema),
          permissionTarget: GlobalPermissionCategory.dialogs.permissionTarget
        )
      }
    ) { plan in
      let message = executor.appleScriptStringLiteral(plan.args["message"]!.stringValue!)
      let confirm = executor.appleScriptStringLiteral(plan.args["confirmLabel"]?.stringValue ?? "OK")
      let cancel = executor.appleScriptStringLiteral(plan.args["cancelLabel"]?.stringValue ?? "Cancel")
      let defaultAnswer = plan.args["defaultAnswer"].flatMap(\.stringValue).map { " default answer " + executor.appleScriptStringLiteral($0) } ?? ""
      let output = try executor.runAppleScript("""
      set response to display dialog \(message) with title "OkBrain Agent" buttons {\(cancel), \(confirm)} default button \(confirm) cancel button \(cancel)\(defaultAnswer)
      return (button returned of response) & "|" & (text returned of response)
      """)
      let values = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "|", maxSplits: 1).map(String.init)
      return FunctionResult(value: .object(
        "button", values.first.map(JSONValue.string) ?? .null,
        "text", values.count > 1 ? .string(values[1]) : .string("")
      ))
    }
  }

  private static func browserRunJavaScript(executor: FixedAppleScriptExecutor) -> any MacOSFunction {
    let schema = browserSchema(extra: [FunctionArg(name: "script", type: .string, required: true, description: "JavaScript for the active tab", maxLength: 100_000)])
    return ClosureFunction(
      name: "browser.run-javascript",
      summary: "Run JavaScript in the active browser tab. Elevated and disabled by default.",
      tier: .elevated,
      argSchema: schema,
      planBuilder: { args in
        let args = try validateFunctionArgs(args, schema: schema)
        let browser = try browser(from: args["browser"]?.stringValue)
        return FunctionExecutionPlan(args: args, target: browser.target)
      }
    ) { plan in
      let browser = try browser(from: plan.args["browser"]?.stringValue)
      let source = plan.args["script"]!.stringValue!
      let output = try executor.runAppleScript(browser.javaScriptExecutionScript(sourceLiteral: executor.appleScriptStringLiteral(source)), timeout: 30)
      return FunctionResult(value: .object("result", .string(output.stdout.trimmingCharacters(in: .whitespacesAndNewlines))))
    }
  }

  private static func appWriteFunction(
    name: String,
    summary: String,
    operation: @escaping @Sendable (FunctionTarget) throws -> FunctionResult
  ) -> any MacOSFunction {
    let schema = [
      FunctionArg(name: "bundleID", type: .string, required: false, description: "Application bundle identifier", maxLength: 255),
      FunctionArg(name: "name", type: .string, required: false, description: "Application name", maxLength: 255)
    ]
    return ClosureFunction(
      name: name,
      summary: summary,
      tier: .write,
      argSchema: schema,
      planBuilder: { args in
        let args = try validateFunctionArgs(args, schema: schema)
        let target = try applicationTarget(args: args)
        return FunctionExecutionPlan(args: args, target: target)
      },
      runner: { plan in
        guard let target = plan.target else {
          throw AgentProtocolError.functionFailed("Application target was not resolved", details: nil)
        }
        return try operation(target)
      }
    )
  }

  private static func browserReadFunction(
    name: String,
    summary: String,
    executor: FixedAppleScriptExecutor,
    script: @escaping @Sendable (BrowserDescriptor) -> String,
    result: @escaping @Sendable (String) -> JSONValue
  ) -> any MacOSFunction {
    let schema = browserSchema()
    return ClosureFunction(
      name: name,
      summary: summary,
      tier: .read,
      argSchema: schema,
      planBuilder: { args in
        let args = try validateFunctionArgs(args, schema: schema)
        let browser = try browser(from: args["browser"]?.stringValue)
        return FunctionExecutionPlan(args: args, target: browser.target)
      }
    ) { plan in
      let browser = try browser(from: plan.args["browser"]?.stringValue)
      let output = try executor.runAppleScript(script(browser))
      return FunctionResult(value: result(output.stdout))
    }
  }

  private static func browserSchema(extra: [FunctionArg] = []) -> [FunctionArg] {
    [FunctionArg(name: "browser", type: .string, required: true, description: "Safari or Chrome", enumValues: ["safari", "chrome"])] + extra
  }
}

private struct StoredTemplateFunction: MacOSFunction, @unchecked Sendable {
  let template: StoredFunctionTemplate
  let executor: FixedAppleScriptExecutor

  var name: String { template.name }
  var summary: String { template.summary }
  var tier: FunctionTier { .elevated }
  var executionIdentity: FunctionExecutionIdentity {
    .template(id: template.id, sourceDigest: template.sourceDigest)
  }
  var argSchema: [FunctionArg] {
    template.argumentNames.map {
      FunctionArg(name: $0, type: .string, required: true, description: "Approved template placeholder \($0)", maxLength: 10_000)
    }
  }
  var catalogTargetBundleID: String? { template.targetBundleID }

  func makeExecutionPlan(args: [String: JSONValue]) throws -> FunctionExecutionPlan {
    guard template.isReviewed,
          let bundleID = template.targetBundleID,
          let appName = template.targetAppName else {
      throw AgentProtocolError.functionDisabled("Template '\(template.name)' needs a new local full-source review before it can run.")
    }
    let args = try validateFunctionArgs(args, schema: argSchema)
    return FunctionExecutionPlan(
      args: args,
      target: FunctionTarget(bundleID: bundleID, appName: appName, requiresAutomation: template.requiresAutomation)
    )
  }

  func run(plan: FunctionExecutionPlan) throws -> FunctionResult {
    guard template.isReviewed,
          template.sourceDigest == TemplateSourceReview.digest(for: template.script),
          template.argumentNames == TemplateSourceReview.placeholderNames(in: template.script) else {
      throw AgentProtocolError.functionDisabled("Template '\(template.name)' no longer matches its approved source metadata.")
    }
    var source = template.script
    for name in template.argumentNames.sorted(by: { $0.count > $1.count }) {
      guard let value = plan.args[name]?.stringValue else {
        throw invalidArgsError("Function argument validation failed", violations: [.init(argument: name, reason: "Expected string.")])
      }
      source = source.replacingOccurrences(of: "$\(name)", with: executor.appleScriptStringLiteral(value))
    }
    let output = try executor.runAppleScript(source, timeout: 30)
    return FunctionResult(value: .object("stdout", .string(output.stdout), "stderr", .string(output.stderr)))
  }
}

private struct MediaPlayerDescriptor: Sendable {
  let name: String
  let applicationName: String
  let target: FunctionTarget
  let nowPlayingScript: String
}

private func mediaPlayer(from raw: String?) throws -> MediaPlayerDescriptor {
  let player: String
  if let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty {
    player = raw
  } else if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.spotify.client" }) {
    player = "spotify"
  } else {
    player = "music"
  }

  switch player {
  case "music":
    return MediaPlayerDescriptor(
      name: "music",
      applicationName: "Music",
      target: FunctionTarget(bundleID: "com.apple.Music", appName: "Music", requiresAutomation: true),
      nowPlayingScript: """
      tell application id "com.apple.Music"
        if player state is stopped then return "| |stopped"
        return (name of current track) & "|" & (artist of current track) & "|" & (player state as text)
      end tell
      """
    )
  case "spotify":
    return MediaPlayerDescriptor(
      name: "spotify",
      applicationName: "Spotify",
      target: FunctionTarget(bundleID: "com.spotify.client", appName: "Spotify", requiresAutomation: true),
      nowPlayingScript: """
      tell application id "com.spotify.client"
        if player state is stopped then return "| |stopped"
        return (name of current track) & "|" & (artist of current track) & "|" & (player state as text)
      end tell
      """
    )
  default:
    throw invalidArgsError("Function argument validation failed", violations: [
      .init(argument: "player", reason: "Must be one of: music, spotify.")
    ])
  }
}

private func parseDelimitedMediaOutput(_ output: String, player: String) -> JSONValue {
  let parts = output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
  return .object(
    "player", .string(player),
    "track", parts.first?.nilIfEmpty.map(JSONValue.string) ?? .null,
    "artist", parts.count > 1 ? parts[1].nilIfEmpty.map(JSONValue.string) ?? .null : .null,
    "state", parts.count > 2 ? .string(parts[2]) : .null
  )
}

private struct BrowserDescriptor: Sendable {
  let name: String
  let applicationName: String
  let target: FunctionTarget

  var activeURLScript: String {
    switch name {
    case "safari": "tell application id \"\(target.bundleID)\" to return URL of front document"
    default: "tell application id \"\(target.bundleID)\" to return URL of active tab of front window"
    }
  }

  var activeTitleScript: String {
    switch name {
    case "safari": "tell application id \"\(target.bundleID)\" to return name of front document"
    default: "tell application id \"\(target.bundleID)\" to return title of active tab of front window"
    }
  }

  var listTabsScript: String {
    switch name {
    case "safari":
      """
      tell application id "com.apple.Safari"
        set outputLines to {}
        repeat with tabItem in tabs of front window
          set end of outputLines to (name of tabItem) & "|" & (URL of tabItem)
        end repeat
        set AppleScript's text item delimiters to linefeed
        return outputLines as text
      end tell
      """
    default:
      """
      tell application id "com.google.Chrome"
        set outputLines to {}
        repeat with tabItem in tabs of front window
          set end of outputLines to (title of tabItem) & "|" & (URL of tabItem)
        end repeat
        set AppleScript's text item delimiters to linefeed
        return outputLines as text
      end tell
      """
    }
  }

  func openURLScript(urlLiteral: String) -> String {
    switch name {
    case "safari": "tell application id \"\(target.bundleID)\" to make new document with properties {URL:\(urlLiteral)}"
    default: "tell application id \"\(target.bundleID)\" to make new tab at end of tabs of front window with properties {URL:\(urlLiteral)}"
    }
  }

  func javaScriptExecutionScript(sourceLiteral: String) -> String {
    switch name {
    case "safari": "tell application id \"\(target.bundleID)\" to do JavaScript \(sourceLiteral) in front document"
    default: "tell application id \"\(target.bundleID)\" to execute active tab of front window javascript \(sourceLiteral)"
    }
  }
}

private func browser(from raw: String?) throws -> BrowserDescriptor {
  switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
  case "safari":
    BrowserDescriptor(
      name: "safari",
      applicationName: "Safari",
      target: FunctionTarget(bundleID: "com.apple.Safari", appName: "Safari", requiresAutomation: true)
    )
  case "chrome":
    BrowserDescriptor(
      name: "chrome",
      applicationName: "Google Chrome",
      target: FunctionTarget(bundleID: "com.google.Chrome", appName: "Google Chrome", requiresAutomation: true)
    )
  default:
    throw invalidArgsError("Function argument validation failed", violations: [
      .init(argument: "browser", reason: "Must be one of: safari, chrome.")
    ])
  }
}

private func finderTarget(automation: Bool) -> FunctionTarget {
  FunctionTarget(bundleID: "com.apple.finder", appName: "Finder", requiresAutomation: automation)
}

private func applicationTarget(args: [String: JSONValue]) throws -> FunctionTarget {
  if let bundleID = args["bundleID"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !bundleID.isEmpty {
    let installedURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    let runningApp = NSWorkspace.shared.runningApplications.first {
      $0.bundleIdentifier?.caseInsensitiveCompare(bundleID) == .orderedSame
    }
    guard installedURL != nil || runningApp != nil else {
      throw AgentProtocolError.appNotFound("No installed or running application matches \(bundleID)")
    }
    let appName = installedURL.map { FileManager.default.displayName(atPath: $0.path) }
      ?? runningApp?.localizedName
      ?? bundleID
    return FunctionTarget(bundleID: bundleID, appName: appName, requiresAutomation: false)
  }

  guard let name = args["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
    throw invalidArgsError("Function argument validation failed", violations: [
      .init(argument: "bundleID", reason: "Provide bundleID or name."),
      .init(argument: "name", reason: "Provide bundleID or name.")
    ])
  }

  let candidates = NSWorkspace.shared.runningApplications.filter {
    $0.localizedName?.caseInsensitiveCompare(name) == .orderedSame
      || $0.localizedName?.localizedCaseInsensitiveContains(name) == true
  }
  guard candidates.count == 1, let app = candidates.first, let bundleID = app.bundleIdentifier else {
    throw AgentProtocolError.appNotFound("Use bundleID when application name '\(name)' is not a unique running application")
  }
  return FunctionTarget(bundleID: bundleID, appName: app.localizedName ?? name, requiresAutomation: false)
}

private func appJSON(_ app: ApplicationDescriptor) -> JSONValue {
  .object(
    "name", .string(app.appName),
    "bundleID", .string(app.bundleID),
    "pid", app.pid.map { .number(Double($0)) } ?? .null,
    "frontmost", .bool(app.frontmost)
  )
}

private extension String {
  var nilIfEmpty: String? { isEmpty ? nil : self }
}
