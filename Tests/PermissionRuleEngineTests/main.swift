import Foundation
import OkBrainMacOSAgentCore

@main
enum PermissionRuleEngineTests {
  static func main() throws {
    try defaultDenyWhenNoRulesMatch()
    try readRuleInheritedByNestedPaths()
    try nestedWriteRuleOverridesParentReadRule()
    try nestedReadRuleOverridesParentWriteRule()
    try mostSpecificRuleWinsRegardlessOfOrder()
    try pathBoundaryPreventsSiblingPrefixMatch()
    try laterRuleWinsWhenPathsAreIdentical()
    try serviceDeniesEverythingWithoutRules()
    try serviceAllowsReadsAndDeniesWritesForReadRule()
    try serviceAllowsNestedWriteOverride()
    try serviceDeniesWriteWhenNestedReadOverridesParentWrite()
    try statusKeepsLegacyAllowedRootsEmptyAndReportsPermissionRules()
    print("✅ Permission rule engine + integration tests passed")
  }

  private static func defaultDenyWhenNoRulesMatch() throws {
    let fixture = try TemporaryDirectory()
    defer { fixture.remove() }
    let project = try fixture.makeDirectory("Project")
    let projectPath = try FilePermissionRuleEngine.normalizedRulePath(project.path)
    let engine = FilePermissionRuleEngine(rules: [])

    let decision = engine.decision(for: projectPath)

    try expect(decision.mode == .disabled, "Expected unmatched paths to be denied")
    try expect(decision.matchedRule == nil, "Expected no matched rule")
    try expect(!decision.canRead, "Denied paths must not be readable")
    try expect(!decision.canWrite, "Denied paths must not be writable")
  }

  private static func readRuleInheritedByNestedPaths() throws {
    let fixture = try TemporaryDirectory()
    defer { fixture.remove() }
    let project = try fixture.makeDirectory("Project")
    let sources = try fixture.makeDirectory("Project/Sources")
    let projectPath = try FilePermissionRuleEngine.normalizedRulePath(project.path)
    let sourcesPath = try FilePermissionRuleEngine.normalizedRulePath(sources.path)
    let engine = FilePermissionRuleEngine(rules: [
      FileEditingAllowedRoot(path: projectPath, mode: .readOnly)
    ])

    let decision = engine.decision(for: sourcesPath + "/App.swift")

    try expect(decision.mode == .readOnly, "Expected parent read rule to apply to nested path")
    try expect(decision.matchedRule?.path == projectPath, "Expected parent rule to be matched")
    try expect(decision.canRead, "Read rule should allow reads")
    try expect(!decision.canWrite, "Read rule should deny writes")
  }

  private static func nestedWriteRuleOverridesParentReadRule() throws {
    let fixture = try TemporaryDirectory()
    defer { fixture.remove() }
    let project = try fixture.makeDirectory("Project")
    let editable = try fixture.makeDirectory("Project/Editable")
    let projectPath = try FilePermissionRuleEngine.normalizedRulePath(project.path)
    let editablePath = try FilePermissionRuleEngine.normalizedRulePath(editable.path)
    let engine = FilePermissionRuleEngine(rules: [
      FileEditingAllowedRoot(path: projectPath, mode: .readOnly),
      FileEditingAllowedRoot(path: editablePath, mode: .readWrite)
    ])

    let decision = engine.decision(for: editablePath + "/Allowed.swift")

    try expect(decision.mode == .readWrite, "Expected nested write rule to override parent read rule")
    try expect(decision.matchedRule?.path == editablePath, "Expected nested write rule to be matched")
    try expect(decision.canRead, "Write rule should allow reads")
    try expect(decision.canWrite, "Write rule should allow writes")
  }

  private static func nestedReadRuleOverridesParentWriteRule() throws {
    let fixture = try TemporaryDirectory()
    defer { fixture.remove() }
    let project = try fixture.makeDirectory("Project")
    let locked = try fixture.makeDirectory("Project/Locked")
    let projectPath = try FilePermissionRuleEngine.normalizedRulePath(project.path)
    let lockedPath = try FilePermissionRuleEngine.normalizedRulePath(locked.path)
    let engine = FilePermissionRuleEngine(rules: [
      FileEditingAllowedRoot(path: projectPath, mode: .readWrite),
      FileEditingAllowedRoot(path: lockedPath, mode: .readOnly)
    ])

    let decision = engine.decision(for: lockedPath + "/ReadOnly.swift")

    try expect(decision.mode == .readOnly, "Expected nested read rule to override parent write rule")
    try expect(decision.matchedRule?.path == lockedPath, "Expected nested read rule to be matched")
    try expect(decision.canRead, "Read rule should allow reads")
    try expect(!decision.canWrite, "Nested read rule should deny writes")
  }

  private static func mostSpecificRuleWinsRegardlessOfOrder() throws {
    let fixture = try TemporaryDirectory()
    defer { fixture.remove() }
    let project = try fixture.makeDirectory("Project")
    let editable = try fixture.makeDirectory("Project/Editable")
    let projectPath = try FilePermissionRuleEngine.normalizedRulePath(project.path)
    let editablePath = try FilePermissionRuleEngine.normalizedRulePath(editable.path)
    let engine = FilePermissionRuleEngine(rules: [
      FileEditingAllowedRoot(path: editablePath, mode: .readWrite),
      FileEditingAllowedRoot(path: projectPath, mode: .readOnly)
    ])

    let decision = engine.decision(for: editablePath + "/Allowed.swift")

    try expect(decision.mode == .readWrite, "Expected most specific rule to win")
    try expect(decision.matchedRule?.path == editablePath, "Expected most specific rule to be matched")
  }

  private static func pathBoundaryPreventsSiblingPrefixMatch() throws {
    let fixture = try TemporaryDirectory()
    defer { fixture.remove() }
    let project = try fixture.makeDirectory("Project")
    let projectSibling = try fixture.makeDirectory("ProjectSibling")
    let projectPath = try FilePermissionRuleEngine.normalizedRulePath(project.path)
    let projectSiblingPath = try FilePermissionRuleEngine.normalizedRulePath(projectSibling.path)
    let engine = FilePermissionRuleEngine(rules: [
      FileEditingAllowedRoot(path: projectPath, mode: .readWrite)
    ])

    let decision = engine.decision(for: projectSiblingPath)

    try expect(decision.mode == .disabled, "Expected sibling prefix path to stay denied")
    try expect(decision.matchedRule == nil, "Expected sibling prefix path not to match")
  }

  private static func laterRuleWinsWhenPathsAreIdentical() throws {
    let fixture = try TemporaryDirectory()
    defer { fixture.remove() }
    let project = try fixture.makeDirectory("Project")
    let projectPath = try FilePermissionRuleEngine.normalizedRulePath(project.path)
    let engine = FilePermissionRuleEngine(rules: [
      FileEditingAllowedRoot(path: projectPath, mode: .readOnly),
      FileEditingAllowedRoot(path: projectPath, mode: .readWrite)
    ])

    let decision = engine.decision(for: projectPath)

    try expect(decision.mode == .readWrite, "Expected later duplicate-path rule to win")
  }

  private static func serviceDeniesEverythingWithoutRules() throws {
    let fixture = try TemporaryDirectory()
    defer { fixture.remove() }
    let project = try fixture.makeDirectory("Project")
    let projectPath = try FilePermissionRuleEngine.normalizedRulePath(project.path)
    let service = LocalFileEditingService(configuration: FileEditingConfiguration(enabled: true, mode: .readWrite))

    try expectProtocolError("root_not_allowed") {
      _ = try service.read(AgentRequestParams(root: projectPath, path: "README.md"))
    }
  }

  private static func serviceAllowsReadsAndDeniesWritesForReadRule() throws {
    let fixture = try TemporaryDirectory()
    defer { fixture.remove() }
    let project = try fixture.makeDirectory("Project")
    let projectPath = try FilePermissionRuleEngine.normalizedRulePath(project.path)
    let readmeURL = URL(fileURLWithPath: projectPath).appendingPathComponent("README.md")
    try "hello".write(to: readmeURL, atomically: true, encoding: .utf8)
    let service = LocalFileEditingService(configuration: FileEditingConfiguration(
      enabled: true,
      mode: .readWrite,
      allowedRoots: [FileEditingAllowedRoot(path: projectPath, mode: .readOnly)]
    ))

    let payload = try service.read(AgentRequestParams(root: projectPath, path: "README.md"))
    try expect(payload.content == "hello", "Expected read rule to allow reading file content")

    try expectProtocolError("permission_denied") {
      _ = try service.write(AgentRequestParams(root: projectPath, path: "README.md", content: "updated"))
    }
  }

  private static func serviceAllowsNestedWriteOverride() throws {
    let fixture = try TemporaryDirectory()
    defer { fixture.remove() }
    let project = try fixture.makeDirectory("Project")
    let editable = try fixture.makeDirectory("Project/Editable")
    let projectPath = try FilePermissionRuleEngine.normalizedRulePath(project.path)
    let editablePath = try FilePermissionRuleEngine.normalizedRulePath(editable.path)
    let service = LocalFileEditingService(configuration: FileEditingConfiguration(
      enabled: true,
      mode: .readWrite,
      allowedRoots: [
        FileEditingAllowedRoot(path: projectPath, mode: .readOnly),
        FileEditingAllowedRoot(path: editablePath, mode: .readWrite)
      ]
    ))

    let payload = try service.write(AgentRequestParams(
      root: projectPath,
      path: "Editable/Allowed.txt",
      content: "allowed"
    ))

    try expect(payload.bytesWritten == "allowed".utf8.count, "Expected nested write override to allow writes")
  }

  private static func serviceDeniesWriteWhenNestedReadOverridesParentWrite() throws {
    let fixture = try TemporaryDirectory()
    defer { fixture.remove() }
    let project = try fixture.makeDirectory("Project")
    let locked = try fixture.makeDirectory("Project/Locked")
    let projectPath = try FilePermissionRuleEngine.normalizedRulePath(project.path)
    let lockedPath = try FilePermissionRuleEngine.normalizedRulePath(locked.path)
    let lockedFileURL = URL(fileURLWithPath: lockedPath).appendingPathComponent("ReadOnly.txt")
    try "locked".write(to: lockedFileURL, atomically: true, encoding: .utf8)
    let service = LocalFileEditingService(configuration: FileEditingConfiguration(
      enabled: true,
      mode: .readWrite,
      allowedRoots: [
        FileEditingAllowedRoot(path: projectPath, mode: .readWrite),
        FileEditingAllowedRoot(path: lockedPath, mode: .readOnly)
      ]
    ))

    let payload = try service.read(AgentRequestParams(root: projectPath, path: "Locked/ReadOnly.txt"))
    try expect(payload.content == "locked", "Expected nested read override to still allow reads")

    try expectProtocolError("permission_denied") {
      _ = try service.write(AgentRequestParams(root: projectPath, path: "Locked/ReadOnly.txt", content: "updated"))
    }
  }

  private static func statusKeepsLegacyAllowedRootsEmptyAndReportsPermissionRules() throws {
    let fixture = try TemporaryDirectory()
    defer { fixture.remove() }
    let projects = try fixture.makeDirectory("Projects")
    let projectsPath = try FilePermissionRuleEngine.normalizedRulePath(projects.path)
    let configuration = AgentConfiguration(fileEditing: FileEditingConfiguration(
      enabled: true,
      mode: .readWrite,
      allowedRoots: [FileEditingAllowedRoot(path: projectsPath, mode: .readWrite)]
    ))
    let handler = AgentRequestHandler(configuration: configuration, permissions: StubPermissionService())
    let request = AgentRequest(
      protocolName: AgentConfiguration.protocolV2Name,
      id: "status-test",
      action: "agent.status"
    )
    let responseData = handler.handle(requestData: try JSONEncoder().encode(request))
    let response = try JSONSerialization.jsonObject(with: responseData) as? [String: Any]
    let data = response?["data"] as? [String: Any]
    let fileEditing = data?["fileEditing"] as? [String: Any]
    let allowedRoots = fileEditing?["allowedRoots"] as? [[String: Any]]
    let permissionRules = fileEditing?["permissionRules"] as? [[String: Any]]

    try expect(allowedRoots?.isEmpty == true, "Expected legacy status allowedRoots to stay empty for client compatibility")
    try expect(permissionRules?.count == 1, "Expected status to report one native permission rule")
    try expect(permissionRules?.first?["path"] as? String == projectsPath, "Expected status permissionRules to include configured rule path")
  }

  private static func expectProtocolError(_ code: String, operation: () throws -> Void) throws {
    do {
      try operation()
    } catch let error as AgentProtocolError {
      try expect(error.code == code, "Expected protocol error code \(code), got \(error.code)")
      return
    }

    throw TestFailure("Expected protocol error code \(code)")
  }

  private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
      throw TestFailure(message)
    }
  }
}

private struct TemporaryDirectory {
  let url: URL

  init() throws {
    url = FileManager.default.temporaryDirectory
      .appendingPathComponent("OkBrainPermissionRuleEngineTests")
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  func makeDirectory(_ relativePath: String) throws -> URL {
    let directoryURL = url.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    return directoryURL
  }

  func remove() {
    try? FileManager.default.removeItem(at: url)
  }
}

private struct StubPermissionService: PermissionChecking {
  func currentPermissions() -> AgentPermissionsPayload {
    AgentPermissionsPayload(screenRecording: .denied, accessibility: .denied)
  }

  func requestScreenRecordingAccess() -> Bool {
    false
  }

  func requestAccessibilityAccess(prompt: Bool) -> Bool {
    false
  }
}

private struct TestFailure: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) {
    self.description = description
  }
}
