import Darwin
import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
  if !condition() {
    FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
    exit(1)
  }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
  expect(actual == expected, "\(message). Expected \(expected), got \(actual)")
}

func runProtocolVerifier() throws {
  let configuration = AgentConfiguration(
    socketPath: "/tmp/test-agent.sock",
    version: "9.9.9",
    build: "test",
    maxScreenshotBytes: 1024,
    maxRequestBytes: 1024
  )
  let screenshot = CapturedImage(data: Data([0x52, 0x49, 0x46, 0x46]), mimeType: "image/webp", width: 64, height: 32)
  let handler = AgentRequestHandler(
    configuration: configuration,
    permissions: FakePermissionService(payload: .init(screenRecording: .granted, accessibility: .denied)),
    screenshots: FakeScreenshotService(capturedImage: screenshot)
  )

  let status: Envelope<AgentStatusPayload> = try send(
    AgentRequest(id: "req_status", action: "agent.status", params: AgentRequestParams()),
    to: handler
  )
  expect(status.ok, "status response should be ok")
  expectEqual(status.id, "req_status", "status id")
  expectEqual(status.data?.socketPath, "/tmp/test-agent.sock", "status socket path")
  expectEqual(status.data?.permissions.screenRecording, .granted, "screen permission")
  expectEqual(status.data?.permissions.accessibility, .denied, "accessibility permission")
  expectEqual(status.data?.capabilities, [
    "screenshot.full",
    "screenshot.window",
    "screenshot.region",
    "screenshot.cursor",
    "screenshot.webp",
    "screenshot.binary",
    "osascript.run"
  ], "capabilities")

  let capture = try sendFrame(
    AgentRequest(
      id: "req_capture",
      action: "screenshot.capture",
      params: AgentRequestParams(mode: "full", format: "webp", includeCursor: false, quality: 80)
    ),
    to: handler,
    as: ScreenshotCapturePayload.self
  )
  expect(capture.envelope.ok, "capture response should be ok")
  expectEqual(capture.envelope.data?.mimeType, "image/webp", "capture mime type")
  expectEqual(capture.envelope.data?.encoding, "binary", "capture encoding")
  expectEqual(capture.envelope.data?.byteLength, screenshot.data.count, "capture byte length")
  expectEqual(capture.bodyData, screenshot.data, "capture binary body")
  expectEqual(capture.envelope.data?.width, 64, "capture width")
  expectEqual(capture.envelope.data?.height, 32, "capture height")

  let deniedHandler = AgentRequestHandler(
    configuration: configuration,
    permissions: FakePermissionService(payload: .init(screenRecording: .denied, accessibility: .unknown)),
    screenshots: FakeScreenshotService(capturedImage: screenshot)
  )
  let denied: Envelope<EmptyPayload> = try send(
    AgentRequest(
      id: "req_denied",
      action: "screenshot.capture",
      params: AgentRequestParams(mode: "full", format: "webp", includeCursor: false, quality: 80)
    ),
    to: deniedHandler
  )
  expect(!denied.ok, "denied capture should fail")
  expectEqual(denied.id, "req_denied", "denied id")
  expectEqual(denied.error?.code, "permission_denied", "denied code")

  let wrongProtocol: Envelope<EmptyPayload> = try send(
    AgentRequest(protocolName: "wrong.protocol", id: "req_wrong_protocol", action: "agent.info", params: nil),
    to: handler
  )
  expect(!wrongProtocol.ok, "wrong protocol should fail")
  expectEqual(wrongProtocol.error?.code, "protocol_mismatch", "protocol mismatch code")

  try runAccessibilityVerifier(configuration: configuration)

  try runOsascriptVerifier(configuration: configuration)

  try runConfigurationVerifier()
  try runFileEditingVerifier(permissions: FakePermissionService(payload: .init(screenRecording: .denied, accessibility: .unknown)))
}

func runAccessibilityVerifier(configuration: AgentConfiguration) throws {
  let screenshot = CapturedImage(data: Data([0x52, 0x49]), mimeType: "image/webp", width: 1, height: 1)
  let axPermissions = FakePermissionService(payload: .init(screenRecording: .denied, accessibility: .granted))
  let handler = AgentRequestHandler(
    configuration: configuration,
    permissions: axPermissions,
    screenshots: FakeScreenshotService(capturedImage: screenshot),
    accessibility: FakeAccessibilityService()
  )

  let status: Envelope<AgentStatusPayload> = try send(
    AgentRequest(id: "req_ax_status", action: "agent.status", params: AgentRequestParams()),
    to: handler
  )
  expect(status.ok, "ax status should be ok")
  expect(status.data?.capabilities.contains("ax.find") == true, "ax capabilities should be listed when accessibility is granted")

  let apps: Envelope<AXAppListPayload> = try send(
    AgentRequest(id: "req_ax_apps", action: "ax.list-apps", params: AgentRequestParams()),
    to: handler
  )
  expect(apps.ok, "ax.list-apps should be ok")
  expectEqual(apps.data?.apps.first?.name, "TextEdit", "ax.list-apps app name")
  expectEqual(apps.data?.apps.first?.pid, 4242, "ax.list-apps pid")

  let windows: Envelope<AXWindowListPayload> = try send(
    AgentRequest(id: "req_ax_windows", action: "ax.list-windows", params: AgentRequestParams(appName: "TextEdit")),
    to: handler
  )
  expect(windows.ok, "ax.list-windows should be ok")
  expectEqual(windows.data?.windows.first?.title, "Untitled", "ax.list-windows window title")

  let tree: Envelope<AXTreePayload> = try send(
    AgentRequest(id: "req_ax_tree", action: "ax.get-tree", params: AgentRequestParams(appName: "TextEdit", depth: 4)),
    to: handler
  )
  expect(tree.ok, "ax.get-tree should be ok")
  expectEqual(tree.data?.root.role, "AXWindow", "ax.get-tree root role")
  expectEqual(tree.data?.root.children?.first?.title, "OK", "ax.get-tree child title")

  let find: Envelope<AXFindPayload> = try send(
    AgentRequest(id: "req_ax_find", action: "ax.find", params: AgentRequestParams(appName: "TextEdit", role: "AXButton", title: "OK")),
    to: handler
  )
  expect(find.ok, "ax.find should be ok")
  expectEqual(find.data?.matches.first?.identifier, "okButton", "ax.find identifier")

  let perform: Envelope<AXPerformPayload> = try send(
    AgentRequest(id: "req_ax_perform", action: "ax.perform", params: AgentRequestParams(appName: "TextEdit", role: "AXButton", title: "OK", action: "press")),
    to: handler
  )
  expect(perform.ok, "ax.perform should be ok")
  expectEqual(perform.data?.action, "press", "ax.perform action")

  let getValue: Envelope<AXValuePayload> = try send(
    AgentRequest(id: "req_ax_get_value", action: "ax.get-value", params: AgentRequestParams(appName: "TextEdit", identifier: "nameField")),
    to: handler
  )
  expect(getValue.ok, "ax.get-value should be ok")
  expectEqual(getValue.data?.element.value, .string("hello"), "ax.get-value value")

  let setValue: Envelope<AXValuePayload> = try send(
    AgentRequest(id: "req_ax_set_value", action: "ax.set-value", params: AgentRequestParams(appName: "TextEdit", identifier: "nameField", value: "world")),
    to: handler
  )
  expect(setValue.ok, "ax.set-value should be ok")

  let typeText: Envelope<AXSimpleResultPayload> = try send(
    AgentRequest(id: "req_ax_type", action: "ax.type-text", params: AgentRequestParams(text: "hello world")),
    to: handler
  )
  expect(typeText.ok, "ax.type-text should be ok")

  let keyPress: Envelope<AXSimpleResultPayload> = try send(
    AgentRequest(id: "req_ax_key", action: "ax.key-press", params: AgentRequestParams(key: "s", modifiers: ["command"])),
    to: handler
  )
  expect(keyPress.ok, "ax.key-press should be ok")

  let scroll: Envelope<AXSimpleResultPayload> = try send(
    AgentRequest(id: "req_ax_scroll", action: "ax.scroll", params: AgentRequestParams(appName: "TextEdit", deltaY: 5)),
    to: handler
  )
  expect(scroll.ok, "ax.scroll should be ok")

  let clickAt: Envelope<AXSimpleResultPayload> = try send(
    AgentRequest(id: "req_ax_click", action: "ax.click-at", params: AgentRequestParams(x: 120, y: 340)),
    to: handler
  )
  expect(clickAt.ok, "ax.click-at should be ok")

  let missingValue: Envelope<EmptyPayload> = try send(
    AgentRequest(id: "req_ax_set_value_missing", action: "ax.set-value", params: AgentRequestParams(appName: "TextEdit", identifier: "nameField")),
    to: handler
  )
  expect(!missingValue.ok, "ax.set-value without value should fail")
  expectEqual(missingValue.error?.code, "invalid_request", "missing value error code")

  let missingCoords: Envelope<EmptyPayload> = try send(
    AgentRequest(id: "req_ax_click_missing", action: "ax.click-at", params: AgentRequestParams(x: 1)),
    to: handler
  )
  expect(!missingCoords.ok, "ax.click-at without y should fail")
  expectEqual(missingCoords.error?.code, "invalid_request", "missing coords error code")

  let deniedHandler = AgentRequestHandler(
    configuration: configuration,
    permissions: FakePermissionService(payload: .init(screenRecording: .granted, accessibility: .denied)),
    screenshots: FakeScreenshotService(capturedImage: screenshot),
    accessibility: FakeAccessibilityService()
  )
  let denied: Envelope<EmptyPayload> = try send(
    AgentRequest(id: "req_ax_denied", action: "ax.list-apps", params: AgentRequestParams()),
    to: deniedHandler
  )
  expect(!denied.ok, "ax action should fail without accessibility permission")
  expectEqual(denied.error?.code, "permission_denied", "ax permission denied code")

  let deniedStatus: Envelope<AgentStatusPayload> = try send(
    AgentRequest(id: "req_ax_denied_status", action: "agent.status", params: AgentRequestParams()),
    to: deniedHandler
  )
  expect(deniedStatus.ok, "denied status should be ok")
  expect(deniedStatus.data?.capabilities.contains("ax.find") == false, "ax capabilities must be hidden when accessibility is denied")
}

func runOsascriptVerifier(configuration: AgentConfiguration) throws {
  let screenshot = CapturedImage(data: Data([0x52, 0x49]), mimeType: "image/webp", width: 1, height: 1)
  let fakeOsascript = FakeOsascriptService(
    result: OsascriptRunPayload(language: "applescript", exitCode: 0, stdout: "paused\n", stderr: "", timedOut: false)
  )
  let handler = AgentRequestHandler(
    configuration: configuration,
    permissions: FakePermissionService(payload: .init(screenRecording: .denied, accessibility: .denied)),
    screenshots: FakeScreenshotService(capturedImage: screenshot),
    osascript: fakeOsascript
  )

  // osascript.run must work without accessibility or screen recording permission.
  let run: Envelope<OsascriptRunPayload> = try send(
    AgentRequest(
      id: "req_osascript_run",
      action: "osascript.run",
      params: AgentRequestParams(script: "tell application \"Music\" to pause", language: "applescript", timeout: 10)
    ),
    to: handler
  )
  expect(run.ok, "osascript.run should be ok")
  expectEqual(run.data?.exitCode, 0, "osascript.run exit code")
  expectEqual(run.data?.stdout, "paused\n", "osascript.run stdout")
  expectEqual(run.data?.language, "applescript", "osascript.run language")
  expectEqual(run.data?.timedOut, false, "osascript.run timedOut")
  expectEqual(fakeOsascript.lastScript, "tell application \"Music\" to pause", "osascript.run passes script through")
  expectEqual(fakeOsascript.lastLanguage, "applescript", "osascript.run passes language through")
  expectEqual(fakeOsascript.lastTimeout, 10, "osascript.run passes timeout through")

  // Missing script must fail with invalid_request.
  let missingScript: Envelope<EmptyPayload> = try send(
    AgentRequest(id: "req_osascript_missing", action: "osascript.run", params: AgentRequestParams()),
    to: handler
  )
  expect(!missingScript.ok, "osascript.run without script should fail")
  expectEqual(missingScript.error?.code, "invalid_request", "osascript.run missing script error code")
}

func runConfigurationVerifier() throws {  let fileManager = FileManager.default
  let bundleURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    .appendingPathComponent("okbrain-agent-config-\(UUID().uuidString).bundle", isDirectory: true)
  let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
  try fileManager.createDirectory(at: contentsURL, withIntermediateDirectories: true)
  defer { try? fileManager.removeItem(at: bundleURL) }

  let infoPlistURL = contentsURL.appendingPathComponent("Info.plist")
  let devPlist = """
  <?xml version=\"1.0\" encoding=\"UTF-8\"?>
  <!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
  <plist version=\"1.0\">
  <dict>
    <key>CFBundleIdentifier</key>
    <string>com.okbrain.macos-agent.dev</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>2.0.0</string>
    <key>AppEnvironment</key>
    <string>dev</string>
    <key>AppStateDirectoryName</key>
    <string>.okbrain-macos-agent-dev</string>
  </dict>
  </plist>
  """
  try devPlist.write(to: infoPlistURL, atomically: true, encoding: .utf8)

  guard let bundle = Bundle(url: bundleURL) else {
    throw NSError(domain: "Verifier", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not load test bundle"])
  }

  let devConfiguration = AgentConfiguration.current(environment: [:], bundle: bundle)
  expectEqual(devConfiguration.appEnvironment, "dev", "dev app environment")
  expectEqual(devConfiguration.stateDirectoryName, ".okbrain-macos-agent-dev", "dev state directory")
  expectEqual(devConfiguration.socketPath, AgentConfiguration.defaultDevSocketPath, "dev default socket")
  let toggledDevConfiguration = devConfiguration.withFileEditingSettings(enabled: true, allowedRoots: [])
  expectEqual(toggledDevConfiguration.appEnvironment, "dev", "dev app environment after file editing toggle")
  expectEqual(toggledDevConfiguration.stateDirectoryName, ".okbrain-macos-agent-dev", "dev state directory after file editing toggle")

  let overrideConfiguration = AgentConfiguration.current(
    environment: ["MACOS_AGENT_SOCKET_PATH": "/tmp/custom-okbrain.sock"],
    bundle: bundle
  )
  expectEqual(overrideConfiguration.socketPath, "/tmp/custom-okbrain.sock", "socket override precedence")

  let prodConfiguration = AgentConfiguration.current(environment: [:], bundle: .main)
  expectEqual(prodConfiguration.appEnvironment, "prod", "main app environment fallback")
  expectEqual(prodConfiguration.socketPath, AgentConfiguration.defaultSocketPath, "prod default socket")
}

func runFileEditingVerifier(permissions: FakePermissionService) throws {
  let fileManager = FileManager.default
  let rootURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    .appendingPathComponent(".build/okbrain-agent-fs-\(UUID().uuidString)", isDirectory: true)
  try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
  defer { try? fileManager.removeItem(at: rootURL) }

  func absolutePath(_ relativePath: String) -> String {
    rootURL.appendingPathComponent(relativePath).path
  }

  let ignoredEnvironmentConfiguration = AgentConfiguration.current(
    environment: ["MACOS_AGENT_ALLOWED_ROOTS": rootURL.path],
    bundle: .main,
    fileEditingEnabled: false
  )
  expect(!ignoredEnvironmentConfiguration.fileEditing.enabled, "allowed roots environment variable must not enable file editing")

  let configuration = AgentConfiguration(
    socketPath: "/tmp/test-agent.sock",
    version: "9.9.9",
    build: "test",
    fileEditing: FileEditingConfiguration.toggleEnabled(
      true,
      allowedRoots: [FileEditingAllowedRoot(path: rootURL.path, mode: .readWrite)]
    )
  )
  let handler = AgentRequestHandler(
    configuration: configuration,
    permissions: permissions,
    screenshots: FakeScreenshotService(capturedImage: CapturedImage(data: Data([0x52, 0x49]), mimeType: "image/webp", width: 1, height: 1))
  )

  let status: Envelope<AgentStatusPayload> = try send(
    AgentRequest(protocolName: AgentConfiguration.protocolName, id: "fs_status", action: "agent.status", params: AgentRequestParams()),
    to: handler
  )
  expect(status.ok, "v3 status response should be ok")
  expectEqual(status.protocolName, AgentConfiguration.protocolName, "binary status protocol")
  expect(status.data?.capabilities.contains("fs.read") == true, "v3 status should expose fs.read")
  expectEqual(status.data?.fileEditing?.mode, .readWrite, "file editing mode")

  let workspace: Envelope<WorkspaceDescribePayload> = try send(
    AgentRequest(
      protocolName: AgentConfiguration.protocolName,
      id: "fs_workspace",
      action: "workspace.describe",
      params: AgentRequestParams(path: rootURL.path)
    ),
    to: handler
  )
  expect(workspace.ok, "workspace.describe should be ok")
  expectEqual(workspace.data?.exists, true, "workspace exists")

  let write: Envelope<FileWritePayload> = try send(
    AgentRequest(
      protocolName: AgentConfiguration.protocolName,
      id: "fs_write",
      action: "fs.write",
      params: AgentRequestParams(
        path: absolutePath("src/app.txt"),
        content: "one\nreturn null\nthree\n",
        createDirs: true
      )
    ),
    to: handler
  )
  expect(write.ok, "fs.write should be ok")
  expectEqual(write.data?.path, absolutePath("src/app.txt"), "write path")
  expect(write.data?.sha256.isEmpty == false, "write sha")

  let read: Envelope<FileReadPayload> = try send(
    AgentRequest(
      protocolName: AgentConfiguration.protocolName,
      id: "fs_read",
      action: "fs.read",
      params: AgentRequestParams(path: absolutePath("src/app.txt"), startLine: 2, endLine: 2)
    ),
    to: handler
  )
  expect(read.ok, "fs.read should be ok")
  expectEqual(read.data?.content, "return null\n", "read line range")

  let patch: Envelope<FilePatchPayload> = try send(
    AgentRequest(
      protocolName: AgentConfiguration.protocolName,
      id: "fs_patch",
      action: "fs.patch",
      params: AgentRequestParams(
        path: absolutePath("src/app.txt"),
        expectedSha256: write.data?.sha256,
        edits: [FilePatchEdit(oldText: "return null", newText: "return 42", startLine: 2)]
      )
    ),
    to: handler
  )
  expect(patch.ok, "fs.patch should be ok")
  expectEqual(patch.data?.changedLines, [2], "patch changed lines")

  let freshReadAfterPatch: Envelope<FileReadPayload> = try send(
    AgentRequest(
      protocolName: AgentConfiguration.protocolName,
      id: "fs_read_after_patch",
      action: "fs.read",
      params: AgentRequestParams(path: absolutePath("src/app.txt"), startLine: 1, endLine: 4)
    ),
    to: handler
  )
  expect(freshReadAfterPatch.ok, "fs.read after fs.patch should be ok")
  expectEqual(freshReadAfterPatch.data?.content, "one\nreturn 42\nthree\n", "fs.read should reflect patched content")
  expectEqual(freshReadAfterPatch.data?.lineCount, 3, "fs.read after patch line count")
  expectEqual(freshReadAfterPatch.data?.sha256, patch.data?.sha256, "fs.read after patch sha")

  let overwrite: Envelope<FileWritePayload> = try send(
    AgentRequest(
      protocolName: AgentConfiguration.protocolName,
      id: "fs_write_overwrite",
      action: "fs.write",
      params: AgentRequestParams(
        path: absolutePath("src/app.txt"),
        content: "one\nreturn 42\ninserted\nthree\n",
        expectedSha256: patch.data?.sha256
      )
    ),
    to: handler
  )
  expect(overwrite.ok, "fs.write overwrite should be ok")

  let freshReadAfterWrite: Envelope<FileReadPayload> = try send(
    AgentRequest(
      protocolName: AgentConfiguration.protocolName,
      id: "fs_read_after_write",
      action: "fs.read",
      params: AgentRequestParams(path: absolutePath("src/app.txt"), startLine: 1, endLine: 10)
    ),
    to: handler
  )
  expect(freshReadAfterWrite.ok, "fs.read after fs.write should be ok")
  expectEqual(freshReadAfterWrite.data?.content, "one\nreturn 42\ninserted\nthree\n", "fs.read should reflect overwritten content")
  expectEqual(freshReadAfterWrite.data?.lineCount, 4, "fs.read after write line count")
  expectEqual(freshReadAfterWrite.data?.sha256, overwrite.data?.sha256, "fs.read after write sha")

  let search: Envelope<FileSearchPayload> = try send(
    AgentRequest(
      protocolName: AgentConfiguration.protocolName,
      id: "fs_search",
      action: "fs.search",
      params: AgentRequestParams(path: rootURL.path, glob: "*.txt", query: "return 42")
    ),
    to: handler
  )
  expect(search.ok, "fs.search should be ok")
  expectEqual(search.data?.matches.first?.file, "src/app.txt", "search match file")
  expectEqual(search.data?.matches.first?.line, 2, "search match line")

  let fileSearch: Envelope<FileSearchPayload> = try send(
    AgentRequest(
      protocolName: AgentConfiguration.protocolName,
      id: "fs_search_file",
      action: "fs.search",
      params: AgentRequestParams(path: absolutePath("src/app.txt"), query: "inserted")
    ),
    to: handler
  )
  expect(fileSearch.ok, "fs.search should accept a single-file path")
  expect(fileSearch.data?.matches.count == 1, "single-file search should return one match")
  expectEqual(fileSearch.data?.matches.first?.file, "app.txt", "single-file search match file")
  expectEqual(fileSearch.data?.matches.first?.line, 3, "single-file search match line")

  let list: Envelope<FileListPayload> = try send(
    AgentRequest(
      protocolName: AgentConfiguration.protocolName,
      id: "fs_list",
      action: "fs.list",
      params: AgentRequestParams(path: rootURL.path, recursive: true, glob: "*.txt")
    ),
    to: handler
  )
  expect(list.ok, "fs.list should be ok")
  expect(list.data?.entries.contains(where: { $0.path == "src/app.txt" }) == true, "list should include file")
  expect(list.data?.entries.contains(where: { $0.name == "src/app.txt" }) == true, "list should include file name")

  // --- Hidden file/directory tests ---
  // Create hidden files and directories
  let hiddenSubdir = absolutePath(".hidden_dir/subdir")
  try fileManager.createDirectory(at: URL(fileURLWithPath: hiddenSubdir, isDirectory: true), withIntermediateDirectories: true)
  try "secret content".write(to: URL(fileURLWithPath: absolutePath(".hidden_dir/inside.txt")), atomically: true, encoding: .utf8)
  try "deep secret".write(to: URL(fileURLWithPath: absolutePath(".hidden_dir/subdir/deep.txt")), atomically: true, encoding: .utf8)
  try "hidden root".write(to: URL(fileURLWithPath: absolutePath(".hidden_file")), atomically: true, encoding: .utf8)
  // Create a .git directory to verify it stays excluded via gitignore matcher
  try fileManager.createDirectory(at: URL(fileURLWithPath: absolutePath(".git"), isDirectory: true), withIntermediateDirectories: true)
  try "git config".write(to: URL(fileURLWithPath: absolutePath(".git/config")), atomically: true, encoding: .utf8)

  // fs.list should include hidden files by default (includeHidden defaults to true)
  let listHidden: Envelope<FileListPayload> = try send(
    AgentRequest(
      protocolName: AgentConfiguration.protocolName,
      id: "fs_list_hidden",
      action: "fs.list",
      params: AgentRequestParams(path: rootURL.path, recursive: true)
    ),
    to: handler
  )
  expect(listHidden.ok, "fs.list with hidden should be ok")
  expect(
    listHidden.data?.entries.contains(where: { $0.path == ".hidden_file" }) == true,
    "list should include hidden file .hidden_file"
  )
  expect(
    listHidden.data?.entries.contains(where: { $0.path == ".hidden_dir/inside.txt" }) == true,
    "list should include file inside .hidden_dir"
  )
  expect(
    listHidden.data?.entries.contains(where: { $0.path == ".hidden_dir/subdir/deep.txt" }) == true,
    "list should include file in subdir of .hidden_dir"
  )
  // .git must still be excluded by GitignoreMatcher (respectGitignore defaults to true)
  expect(
    listHidden.data?.entries.contains(where: { $0.path.hasPrefix(".git") }) == false,
    "list should exclude .git directory via gitignore matcher"
  )

  // fs.search should find content inside hidden files by default
  let searchHidden: Envelope<FileSearchPayload> = try send(
    AgentRequest(
      protocolName: AgentConfiguration.protocolName,
      id: "fs_search_hidden",
      action: "fs.search",
      params: AgentRequestParams(path: rootURL.path, query: "secret")
    ),
    to: handler
  )
  expect(searchHidden.ok, "fs.search hidden should be ok")
  expect(
    searchHidden.data?.matches.contains(where: { $0.file == ".hidden_dir/inside.txt" }) == true,
    "search should find match inside .hidden_dir"
  )
  expect(
    searchHidden.data?.matches.contains(where: { $0.file == ".hidden_dir/subdir/deep.txt" }) == true,
    "search should find match inside .hidden_dir/subdir"
  )
  // .git must still be excluded from search results
  expect(
    searchHidden.data?.matches.contains(where: { $0.file.hasPrefix(".git") }) == false,
    "search should exclude .git directory via gitignore matcher"
  )

  // fs.list with includeHidden: false should exclude hidden files
  let listExcludeHidden: Envelope<FileListPayload> = try send(
    AgentRequest(
      protocolName: AgentConfiguration.protocolName,
      id: "fs_list_exclude",
      action: "fs.list",
      params: AgentRequestParams(path: rootURL.path, recursive: true, includeHidden: false)
    ),
    to: handler
  )
  expect(listExcludeHidden.ok, "fs.list excludeHidden should be ok")
  expect(
    listExcludeHidden.data?.entries.contains(where: { $0.path == ".hidden_file" }) == false,
    "list with includeHidden:false should exclude .hidden_file"
  )
  expect(
    listExcludeHidden.data?.entries.contains(where: { $0.path.hasPrefix(".hidden_dir") }) == false,
    "list with includeHidden:false should exclude .hidden_dir"
  )
  // Regular files should still appear
  expect(
    listExcludeHidden.data?.entries.contains(where: { $0.path == "src/app.txt" }) == true,
    "list with includeHidden:false should still include regular files"
  )

  let escape: Envelope<EmptyPayload> = try send(
    AgentRequest(
      protocolName: AgentConfiguration.protocolName,
      id: "fs_escape",
      action: "fs.read",
      params: AgentRequestParams(path: rootURL.deletingLastPathComponent().appendingPathComponent("outside.txt").path)
    ),
    to: handler
  )
  expect(!escape.ok, "root escape should fail")
  expectEqual(escape.error?.code, "root_not_allowed", "root escape error code")
}

func runSocketVerifier() throws {
  let socketPath = "/private/tmp/oka-\(UUID().uuidString.prefix(8)).sock"
  defer { unlink(socketPath) }
  let stateLock = NSLock()
  var isRunning = false
  var latestSnapshot: SocketServerSnapshot?
  let requestHeader = Data(#"{"protocol":"okbrain.macos-agent.v3","id":"req_socket","action":"agent.info"}"#.utf8)
  let responseHeader = Data(#"{"protocol":"okbrain.macos-agent.v3","id":"req_socket","ok":true,"data":{"transport":"ssh-unix-socket-binary-frame"}}"#.utf8)
  let server = UnixSocketServer(socketPath: socketPath, maxRequestBytes: 1024) { requestData in
    expectEqual(requestData, requestHeader, "socket request frame header")
    return (try? AgentBinaryFrame.encode(headerData: responseHeader)) ?? Data()
  }

  server.onStateChange = { snapshot in
    stateLock.lock()
    latestSnapshot = snapshot
    if snapshot.status == .running {
      isRunning = true
    }
    stateLock.unlock()
  }
  server.start()
  defer { server.stop() }

  let deadline = Date().addingTimeInterval(2)
  while Date() < deadline {
    stateLock.lock()
    let ready = isRunning
    stateLock.unlock()
    if ready {
      break
    }
    usleep(10_000)
  }

  stateLock.lock()
  let ready = isRunning
  let snapshot = latestSnapshot
  stateLock.unlock()
  let snapshotLabel = snapshot.map { "\($0.status.rawValue): \($0.errorMessage ?? "no error")" } ?? "no state"
  expect(ready, "socket server did not start; latest state \(snapshotLabel)")

  let fd = try connectUnixSocket(path: socketPath)
  defer { Darwin.close(fd) }

  try writeAll(try AgentBinaryFrame.encode(headerData: requestHeader), to: fd)
  let responseFrame = try AgentBinaryFrame.decode(try readAll(from: fd))
  let response = String(data: responseFrame.headerData, encoding: .utf8) ?? ""
  expect(response.contains(#""ok":true"#), "socket response ok")
  expect(response.contains(#""transport":"ssh-unix-socket-binary-frame""#), "socket response transport")
}

func send<T: Decodable>(_ request: AgentRequest, to handler: AgentRequestHandler) throws -> Envelope<T> {
  try sendFrame(request, to: handler, as: T.self).envelope
}

func sendFrame<T: Decodable>(
  _ request: AgentRequest,
  to handler: AgentRequestHandler,
  as type: T.Type
) throws -> (envelope: Envelope<T>, bodyData: Data) {
  let requestData = try JSONEncoder().encode(request)
  let responseData = handler.handle(requestData: requestData)
  let frame = try AgentBinaryFrame.decode(responseData)
  let envelope = try JSONDecoder().decode(Envelope<T>.self, from: frame.headerData)
  return (envelope, frame.bodyData)
}

func connectUnixSocket(path: String) throws -> Int32 {
  let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
  expect(fd >= 0, "socket client fd")

  var address = sockaddr_un()
  address.sun_family = sa_family_t(AF_UNIX)
  let pathBytes = path.utf8CString
  withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
    for index in 0..<pathBytes.count {
      rawBuffer[index] = UInt8(bitPattern: pathBytes[index])
    }
  }

  let addressLength = socklen_t(MemoryLayout.offset(of: \sockaddr_un.sun_path)! + pathBytes.count)
  let result = withUnsafePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
      Darwin.connect(fd, socketAddress, addressLength)
    }
  }

  if result != 0 {
    let message = String(cString: strerror(errno))
    Darwin.close(fd)
    throw NSError(domain: "ProtocolVerifier", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }

  return fd
}

func writeAll(_ data: Data, to fd: Int32) throws {
  try data.withUnsafeBytes { rawBuffer in
    guard let baseAddress = rawBuffer.baseAddress else {
      return
    }

    var offset = 0
    while offset < data.count {
      let written = Darwin.write(fd, baseAddress.advanced(by: offset), data.count - offset)
      if written < 0 {
        throw NSError(domain: "ProtocolVerifier", code: 2)
      }
      offset += written
    }
  }
}

func readAll(from fd: Int32) throws -> Data {
  var data = Data()

  while true {
    var buffer = [UInt8](repeating: 0, count: 8192)
    let count = Darwin.read(fd, &buffer, buffer.count)
    if count == 0 {
      break
    }

    if count < 0 {
      throw NSError(domain: "ProtocolVerifier", code: 3)
    }

    data.append(contentsOf: buffer.prefix(count))
  }

  return data
}

struct FakePermissionService: PermissionChecking {
  let payload: AgentPermissionsPayload

  func currentPermissions() -> AgentPermissionsPayload {
    payload
  }

  func requestScreenRecordingAccess() -> Bool {
    payload.screenRecording == .granted
  }

  func requestAccessibilityAccess(prompt: Bool) -> Bool {
    payload.accessibility == .granted
  }
}

struct FakeScreenshotService: ScreenshotCapturing {
  let capturedImage: CapturedImage

  func capture(_ params: AgentRequestParams) throws -> CapturedImage {
    capturedImage
  }
}

struct FakeAccessibilityService: AccessibilityServicing {
  var apps: [AXAppPayload] = [
    AXAppPayload(pid: 4242, name: "TextEdit", bundleId: "com.apple.TextEdit", active: true, windowCount: 1)
  ]
  var windows = AXWindowListPayload(
    pid: 4242,
    app: "TextEdit",
    windows: [AXWindowPayload(index: 0, title: "Untitled", frame: CaptureRect(x: 10, y: 10, width: 400, height: 300), main: true)]
  )
  var findResult = AXFindPayload(
    matches: [
      AXElementNode(
        role: "AXButton", subrole: nil, title: "OK", label: nil, identifier: "okButton",
        value: nil, valueTruncated: nil,
        frame: CaptureRect(x: 20, y: 20, width: 80, height: 30),
        enabled: true, focused: false, children: nil
      )
    ],
    truncated: false
  )
  var performResult: AXPerformPayload?
  var valueResult = AXValuePayload(
    element: AXElementNode(
      role: "AXTextField", subrole: nil, title: nil, label: "Name", identifier: "nameField",
      value: .string("hello"), valueTruncated: nil,
      frame: CaptureRect(x: 20, y: 60, width: 200, height: 24),
      enabled: true, focused: true, children: nil
    )
  )
  var treeResult: AXTreePayload?

  func listApps() throws -> AXAppListPayload {
    AXAppListPayload(apps: apps)
  }

  func listWindows(query: AXElementQuery) throws -> AXWindowListPayload {
    windows
  }

  func tree(query: AXElementQuery) throws -> AXTreePayload {
    if let treeResult { return treeResult }
    return AXTreePayload(
      pid: query.pid ?? 4242,
      app: query.appName ?? "TextEdit",
      window: windows.windows.first,
      truncated: false,
      root: AXElementNode(
        role: "AXWindow", subrole: "AXStandardWindow", title: "Untitled", label: nil, identifier: nil,
        value: nil, valueTruncated: nil,
        frame: CaptureRect(x: 10, y: 10, width: 400, height: 300),
        enabled: true, focused: true,
        children: [
          AXElementNode(
            role: "AXButton", subrole: nil, title: "OK", label: nil, identifier: "okButton",
            value: nil, valueTruncated: nil,
            frame: CaptureRect(x: 20, y: 20, width: 80, height: 30),
            enabled: true, focused: false, children: nil
          )
        ]
      )
    )
  }

  func find(query: AXElementQuery, limit: Int) throws -> AXFindPayload {
    findResult
  }

  func perform(query: AXElementQuery, action: String) throws -> AXPerformPayload {
    if let performResult { return performResult }
    return AXPerformPayload(action: action, element: findResult.matches[0])
  }

  func value(query: AXElementQuery) throws -> AXValuePayload {
    valueResult
  }

  func setValue(query: AXElementQuery, value: String) throws -> AXValuePayload {
    valueResult
  }

  func typeText(_ text: String) throws {}

  func keyPress(key: String, modifiers: [String]) throws {}

  func clickAt(x: Double, y: Double, button: String, clickCount: Int) throws {}
  func scroll(query: AXElementQuery, deltaX: Int, deltaY: Int, x: Double?, y: Double?) throws {}
}

final class FakeOsascriptService: OsascriptServicing, @unchecked Sendable {
  let result: OsascriptRunPayload
  private let lock = NSLock()
  private var _lastScript: String?
  private var _lastLanguage: String?
  private var _lastTimeout: TimeInterval?

  var lastScript: String? {
    lock.lock(); defer { lock.unlock() }
    return _lastScript
  }

  var lastLanguage: String? {
    lock.lock(); defer { lock.unlock() }
    return _lastLanguage
  }

  var lastTimeout: TimeInterval? {
    lock.lock(); defer { lock.unlock() }
    return _lastTimeout
  }

  init(result: OsascriptRunPayload) {
    self.result = result
  }

  func run(script: String, language: String, timeout: TimeInterval) throws -> OsascriptRunPayload {
    lock.lock()
    _lastScript = script
    _lastLanguage = language
    _lastTimeout = timeout
    lock.unlock()
    return result
  }
}

struct Envelope<T: Decodable>: Decodable {
  let protocolName: String
  let id: String
  let ok: Bool
  let data: T?
  let error: VerifierErrorPayload?

  private enum CodingKeys: String, CodingKey {
    case protocolName = "protocol"
    case id
    case ok
    case data
    case error
  }
}

struct VerifierErrorPayload: Decodable {
  let code: String
  let message: String
}

struct EmptyPayload: Decodable {}

@main
struct ProtocolVerifier {
  static func main() {
    do {
      try runProtocolVerifier()
      try runSocketVerifier()
      print("Protocol verifier passed")
    } catch {
      FileHandle.standardError.write(Data("FAIL: \(error.localizedDescription)\n".utf8))
      exit(1)
    }
  }
}
