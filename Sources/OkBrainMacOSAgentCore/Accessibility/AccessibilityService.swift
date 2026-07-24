import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

public protocol AccessibilityServicing: Sendable {
  func listApps() throws -> AXAppListPayload
  func listWindows(query: AXElementQuery) throws -> AXWindowListPayload
  func tree(query: AXElementQuery) throws -> AXTreePayload
  func find(query: AXElementQuery, limit: Int) throws -> AXFindPayload
  func perform(query: AXElementQuery, action: String) throws -> AXPerformPayload
  func value(query: AXElementQuery) throws -> AXValuePayload
  func setValue(query: AXElementQuery, value: String) throws -> AXValuePayload
  func typeText(_ text: String, targetPid: Int32?) throws
  func keyPress(key: String, modifiers: [String], targetPid: Int32?) throws
  func clickAt(x: Double, y: Double, button: String, clickCount: Int, targetPid: Int32?) throws
  func scroll(query: AXElementQuery, deltaX: Int, deltaY: Int, x: Double?, y: Double?, targetPid: Int32?) throws
  func drag(fromX: Double, fromY: Double, toX: Double, toY: Double, targetPid: Int32?) throws
}

public final class SystemAccessibilityService: AccessibilityServicing, @unchecked Sendable {
  private static let maxValueLength = 2_000
  private static let maxTypeTextLength = 10_000

  private static let actionMap: [String: String] = [
    "press": kAXPressAction,
    "raise": kAXRaiseAction,
    "show-menu": kAXShowMenuAction,
    "showmenu": kAXShowMenuAction,
    "increment": kAXIncrementAction,
    "decrement": kAXDecrementAction,
    "confirm": kAXConfirmAction,
    "cancel": kAXCancelAction,
    "pick": kAXPickAction,
    "scroll-into-view": "AXScrollToVisible",
    "scrolltovisible": "AXScrollToVisible"
  ]

  private static let keyCodes: [String: CGKeyCode] = [
    "return": 36, "enter": 36, "tab": 48, "space": 49,
    "delete": 51, "backspace": 51, "forwarddelete": 117,
    "escape": 53, "esc": 53,
    "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
    "left": 123, "right": 124, "down": 125, "up": 126,
    "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
    "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
    "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
    "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
    "5": 23, "9": 25, "7": 26, "8": 28, "0": 29, "]": 30, "o": 31,
    "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39,
    "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46,
    ".": 47, "`": 50, "-": 27, "=": 24
  ]

  /// CGEvent field 89 = kCGEventTargetUnixProcessID — routes the event to a
  /// specific process without moving the real cursor or stealing focus.
  private static let cgEventTargetUnixProcessID = CGEventField(rawValue: 89)!

  /// Roles considered interactive or scrollable for compact tree mode.
  private static let interactiveRoles: Set<String> = [
    "AXButton", "AXCheckBox", "AXComboBox", "AXDisclosureTriangle",
    "AXImage", "AXLink", "AXList", "AXMenu", "AXMenuBar", "AXMenuBarItem",
    "AXMenuItem", "AXOutline", "AXPopUpButton", "AXRadioButton",
    "AXRow", "AXScrollBar", "AXSearchField", "AXSlider", "AXSplitGroup",
    "AXStaticText", "AXTab", "AXTabGroup", "AXTable", "AXTextArea",
    "AXTextField", "AXToolbar", "AXTree", "AXWindow", "AXGroup",
    "AXScrollArea", "AXColumn", "AXCell", "AXHeading"
  ]

  public init() {
    // Bound synchronous AX messaging so a hung target app cannot block the socket handler.
    _ = AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 5.0)
  }

  // MARK: - Discovery

  public func listApps() throws -> AXAppListPayload {
    let apps = runningGUIApps()
      .map { app in
        AXAppPayload(
          pid: app.processIdentifier,
          name: app.localizedName ?? "Unknown",
          bundleId: app.bundleIdentifier,
          active: app.isActive,
          windowCount: windows(of: app.processIdentifier).count
        )
      }
      .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    return AXAppListPayload(apps: apps)
  }

  public func listWindows(query: AXElementQuery) throws -> AXWindowListPayload {
    let app = try resolveApp(query)
    let appElement = AXUIElementCreateApplication(app.processIdentifier)
    let mainWindow = axElement(from: copyAttribute(appElement, kAXMainWindowAttribute))
    let payloads = windows(of: app.processIdentifier).enumerated().map { index, window in
      AXWindowPayload(
        index: index,
        title: stringAttribute(window, kAXTitleAttribute),
        frame: frame(of: window),
        main: mainWindow.map { CFEqual($0, window) } ?? false
      )
    }
    return AXWindowListPayload(
      pid: app.processIdentifier,
      app: app.localizedName ?? "Unknown",
      windows: payloads
    )
  }

  public func tree(query: AXElementQuery) throws -> AXTreePayload {
    let app = try resolveApp(query)
    let appElement = AXUIElementCreateApplication(app.processIdentifier)
    enableWebAccessibility(on: appElement)
    let appWindows = windows(of: app.processIdentifier)

    let rootElement: AXUIElement
    var windowPayload: AXWindowPayload?

    if query.allWindows && query.windowTitle == nil && query.windowIndex == nil {
      rootElement = appElement
    } else {
      let window = try pickWindow(appWindows, query: query, appElement: appElement)
      rootElement = window
      let index = appWindows.firstIndex { CFEqual($0, window) } ?? 0
      windowPayload = AXWindowPayload(
        index: index,
        title: stringAttribute(window, kAXTitleAttribute),
        frame: frame(of: window),
        main: true
      )
    }

    var budget = max(1, query.maxElements)
    guard let root = buildNode(
      rootElement,
      depthRemaining: max(0, query.maxDepth),
      budget: &budget,
      includeChildren: true,
      compact: query.compact
    ) else {
      throw AgentProtocolError.internalError("Unable to read the accessibility tree")
    }

    return AXTreePayload(
      pid: app.processIdentifier,
      app: app.localizedName ?? "Unknown",
      window: windowPayload,
      truncated: budget <= 0,
      root: root
    )
  }

  public func find(query: AXElementQuery, limit: Int) throws -> AXFindPayload {
    guard query.hasMatchCriteria else {
      throw AgentProtocolError.invalidRequest("Provide at least one of role, title, label, or identifier")
    }
    let app = try resolveApp(query)
    let roots = try searchRoots(for: app, query: query)
    var matches = collectMatches(roots: roots, query: query, limit: max(1, limit))
    let truncated = matches.count >= max(1, limit)
    if truncated {
      matches = Array(matches.prefix(max(1, limit)))
    }
    return AXFindPayload(matches: matches, truncated: truncated)
  }

  // MARK: - Actions

  public func perform(query: AXElementQuery, action: String) throws -> AXPerformPayload {
    let normalizedAction = action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let app = try resolveApp(query)

    if normalizedAction == "activate" {
      // NSRunningApplication.activate() is unreliable from a background agent on
      // macOS 14+ (user-activation policy). AX frontmost works with AX trust.
      let appElement = AXUIElementCreateApplication(app.processIdentifier)
      let axResult = AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
      if axResult != .success {
        app.activate(options: [.activateIgnoringOtherApps])
      }
      return AXPerformPayload(
        action: "activate",
        element: AXElementNode(
          role: "AXApplication", subrole: nil, title: app.localizedName, label: nil,
          identifier: app.bundleIdentifier, value: nil, valueTruncated: nil,
          frame: nil, enabled: nil, focused: true, children: nil
        )
      )
    }

    let roots = try searchRoots(for: app, query: query)
    let element = try locate(query: query, roots: roots)

    if normalizedAction == "focus" {
      try checkAX(
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue),
        "Unable to focus element"
      )
      return AXPerformPayload(action: "focus", element: snapshot(element))
    }

    guard let axAction = Self.actionMap[normalizedAction] else {
      throw AgentProtocolError.unsupportedParameter(
        "Unknown action '\(action)'. Supported: press, raise, show-menu, increment, decrement, confirm, cancel, pick, focus, activate"
      )
    }
    try checkAX(AXUIElementPerformAction(element, axAction as CFString), "Perform '\(normalizedAction)' failed")
    return AXPerformPayload(action: normalizedAction, element: snapshot(element))
  }

  public func value(query: AXElementQuery) throws -> AXValuePayload {
    let app = try resolveApp(query)
    let roots = try searchRoots(for: app, query: query)
    let element = try locate(query: query, roots: roots)
    return AXValuePayload(element: snapshot(element))
  }

  public func setValue(query: AXElementQuery, value: String) throws -> AXValuePayload {
    let app = try resolveApp(query)
    let roots = try searchRoots(for: app, query: query)
    let element = try locate(query: query, roots: roots)

    var settable = DarwinBoolean(false)
    let settableResult = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
    guard settableResult == .success, settable.boolValue else {
      throw AgentProtocolError.actionFailed("Element value is not settable")
    }

    let currentValue = copyAttribute(element, kAXValueAttribute)
    let newValue: CFTypeRef
    if let currentValue, CFGetTypeID(currentValue) == CFBooleanGetTypeID() {
      newValue = ["1", "true", "yes", "on"].contains(value.lowercased()) ? kCFBooleanTrue : kCFBooleanFalse
    } else if currentValue is NSNumber {
      if let intValue = Int(value) {
        newValue = intValue as CFNumber
      } else if let doubleValue = Double(value) {
        newValue = doubleValue as CFNumber
      } else {
        newValue = value as CFString
      }
    } else {
      newValue = value as CFString
    }

    try checkAX(
      AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, newValue),
      "Set value failed"
    )
    return AXValuePayload(element: snapshot(element))
  }

  // MARK: - Input synthesis

  public func typeText(_ text: String, targetPid: Int32? = nil) throws {
    guard !text.isEmpty else {
      throw AgentProtocolError.invalidRequest("text is required")
    }
    guard text.count <= Self.maxTypeTextLength else {
      throw AgentProtocolError.invalidRequest("text exceeds \(Self.maxTypeTextLength) characters")
    }

    let source = CGEventSource(stateID: .hidSystemState)
    for character in text {
      var utf16 = Array(String(character).utf16)
      let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
      keyDown?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
      postEvent(keyDown, targetPid: targetPid)
      let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
      keyUp?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
      postEvent(keyUp, targetPid: targetPid)
      usleep(2_000)
    }
  }

  public func keyPress(key: String, modifiers: [String], targetPid: Int32? = nil) throws {
    let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard let keyCode = Self.keyCodes[normalizedKey] else {
      throw AgentProtocolError.unsupportedParameter(
        "Unknown key '\(key)'. Use return, tab, space, delete, escape, arrows, home, end, pageup, pagedown, f1-f12, or a single US-layout character"
      )
    }

    var flags = CGEventFlags()
    for modifier in modifiers {
      switch modifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
      case "command", "cmd", "meta":
        flags.insert(.maskCommand)
      case "shift":
        flags.insert(.maskShift)
      case "option", "alt":
        flags.insert(.maskAlternate)
      case "control", "ctrl":
        flags.insert(.maskControl)
      case "":
        continue
      default:
        throw AgentProtocolError.unsupportedParameter("Unknown modifier '\(modifier)'")
      }
    }

    let source = CGEventSource(stateID: .hidSystemState)
    let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
    keyDown?.flags = flags
    postEvent(keyDown, targetPid: targetPid)
    let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
    keyUp?.flags = flags
    postEvent(keyUp, targetPid: targetPid)
  }

  public func clickAt(x: Double, y: Double, button: String, clickCount: Int, targetPid: Int32? = nil) throws {
    let point = CGPoint(x: x, y: y)
    let downType: CGEventType
    let upType: CGEventType
    let mouseButton: CGMouseButton

    switch button.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "left", "":
      downType = .leftMouseDown
      upType = .leftMouseUp
      mouseButton = .left
    case "right":
      downType = .rightMouseDown
      upType = .rightMouseUp
      mouseButton = .right
    case "middle":
      downType = .otherMouseDown
      upType = .otherMouseUp
      mouseButton = .center
    default:
      throw AgentProtocolError.unsupportedParameter("Unknown button '\(button)'. Use left, right, or middle")
    }

    let source = CGEventSource(stateID: .hidSystemState)
    let clicks = max(1, min(3, clickCount))
    for click in 1...clicks {
      let mouseDown = CGEvent(mouseEventSource: source, mouseType: downType, mouseCursorPosition: point, mouseButton: mouseButton)
      mouseDown?.setIntegerValueField(.mouseEventClickState, value: Int64(click))
      postEvent(mouseDown, targetPid: targetPid)
      usleep(10_000)
      let mouseUp = CGEvent(mouseEventSource: source, mouseType: upType, mouseCursorPosition: point, mouseButton: mouseButton)
      mouseUp?.setIntegerValueField(.mouseEventClickState, value: Int64(click))
      postEvent(mouseUp, targetPid: targetPid)
      usleep(30_000)
    }
  }

  /// Scrolls at a point. Point resolution order:
  /// explicit `x`/`y` → center of the element matched by `query` → center of the target window.
  /// `deltaY` > 0 scrolls content down (reveals content below), `deltaX` > 0 scrolls right.
  /// One unit ≈ 40 px.
  public func scroll(query: AXElementQuery, deltaX: Int, deltaY: Int, x: Double?, y: Double?, targetPid: Int32? = nil) throws {
    guard deltaX != 0 || deltaY != 0 else {
      throw AgentProtocolError.invalidRequest("deltaX or deltaY must be non-zero")
    }

    let point: CGPoint
    if let x, let y {
      point = CGPoint(x: x, y: y)
    } else {
      let app = try resolveApp(query)
      let roots = try searchRoots(for: app, query: query)
      let target: AXUIElement
      if query.hasMatchCriteria {
        target = try locate(query: query, roots: roots)
      } else {
        target = roots[0]
      }
      guard let targetFrame = frame(of: target) else {
        throw AgentProtocolError.actionFailed("Scroll target has no frame; pass x/y explicitly")
      }
      point = CGPoint(x: targetFrame.x + targetFrame.width / 2, y: targetFrame.y + targetFrame.height / 2)
    }

    let pixelsPerUnit = 40
    // CGEvent wheel1 > 0 scrolls content up, so negate to make deltaY > 0 scroll down.
    let wheel1 = Int32(-deltaY * pixelsPerUnit)
    let wheel2 = Int32(-deltaX * pixelsPerUnit)
    guard let event = CGEvent(
      scrollWheelEvent2Source: CGEventSource(stateID: .hidSystemState),
      units: .pixel,
      wheelCount: 2,
      wheel1: wheel1,
      wheel2: wheel2,
      wheel3: 0
    ) else {
      throw AgentProtocolError.actionFailed("Unable to create scroll event")
    }
    event.location = point
    postEvent(event, targetPid: targetPid)
  }

  /// Drags from one point to another with smooth interpolation.
  public func drag(fromX: Double, fromY: Double, toX: Double, toY: Double, targetPid: Int32? = nil) throws {
    let source = CGEventSource(stateID: .hidSystemState)
    let from = CGPoint(x: fromX, y: fromY)
    let to = CGPoint(x: toX, y: toY)

    // Move to start
    let moveEvent = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: from, mouseButton: .left)
    postEvent(moveEvent, targetPid: targetPid)
    usleep(50_000)

    // Mouse down
    let downEvent = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: from, mouseButton: .left)
    postEvent(downEvent, targetPid: targetPid)
    usleep(100_000)

    // Interpolated drag with smoothstep
    let steps = 20
    for i in 1...steps {
      let t = Double(i) / Double(steps)
      let tSmooth = t * t * (3.0 - 2.0 * t)
      let x = fromX + (toX - fromX) * tSmooth
      let y = fromY + (toY - fromY) * tSmooth
      let dragEvent = CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)
      postEvent(dragEvent, targetPid: targetPid)
      usleep(8_000)
    }

    usleep(50_000)

    // Mouse up
    let upEvent = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: to, mouseButton: .left)
    postEvent(upEvent, targetPid: targetPid)
  }

  // MARK: - Event posting

  /// Posts a CGEvent globally or to a specific process via field 89.
  private func postEvent(_ event: CGEvent?, targetPid: Int32?) {
    guard let event else { return }
    if let pid = targetPid {
      event.setIntegerValueField(Self.cgEventTargetUnixProcessID, value: Int64(pid))
    }
    event.post(tap: .cghidEventTap)
  }

  // MARK: - App / window resolution

  /// Chromium/Electron apps only expose web content in the AX tree when an
  /// assistive client opts in. Setting these attributes is a no-op for apps
  /// that don't support them, so we do it opportunistically.
  private func enableWebAccessibility(on appElement: AXUIElement) {
    _ = AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    _ = AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
  }

  private func runningGUIApps() -> [NSRunningApplication] {
    NSWorkspace.shared.runningApplications.filter {
      $0.activationPolicy == .regular && !$0.isTerminated
    }
  }

  private func resolveApp(_ query: AXElementQuery) throws -> NSRunningApplication {
    let apps = runningGUIApps()

    if let pid = query.pid {
      guard let app = apps.first(where: { $0.processIdentifier == pid })
              ?? NSRunningApplication(processIdentifier: pid) else {
        throw AgentProtocolError.appNotFound("No running app found with pid \(pid)")
      }
      return app
    }

    if let name = query.appName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
      if let exact = apps.first(where: { $0.localizedName?.caseInsensitiveCompare(name) == .orderedSame }) {
        return exact
      }
      if let bundle = apps.first(where: { $0.bundleIdentifier?.caseInsensitiveCompare(name) == .orderedSame }) {
        return bundle
      }
      if let partial = apps.first(where: { $0.localizedName?.localizedCaseInsensitiveContains(name) == true }) {
        return partial
      }
      throw AgentProtocolError.appNotFound("No running GUI app matches '\(name)'")
    }

    throw AgentProtocolError.invalidRequest("Provide appName or pid to target an app")
  }

  private func windows(of pid: pid_t) -> [AXUIElement] {
    let appElement = AXUIElementCreateApplication(pid)
    guard let value = copyAttribute(appElement, kAXWindowsAttribute),
          let windows = value as? [AXUIElement] else {
      return []
    }
    return windows
  }

  private func pickWindow(
    _ windows: [AXUIElement],
    query: AXElementQuery,
    appElement: AXUIElement
  ) throws -> AXUIElement {
    if let title = query.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
      guard let window = windows.first(where: {
        stringAttribute($0, kAXTitleAttribute)?.localizedCaseInsensitiveContains(title) == true
      }) else {
        throw AgentProtocolError.elementNotFound("No window matches title '\(title)'")
      }
      return window
    }

    if let index = query.windowIndex {
      guard windows.indices.contains(index) else {
        throw AgentProtocolError.elementNotFound("Window index \(index) is out of range (\(windows.count) windows)")
      }
      return windows[index]
    }

    if let main = axElement(from: copyAttribute(appElement, kAXMainWindowAttribute)) {
      return main
    }

    guard let first = windows.first else {
      throw AgentProtocolError.elementNotFound("App has no windows")
    }
    return first
  }

  private func searchRoots(for app: NSRunningApplication, query: AXElementQuery) throws -> [AXUIElement] {
    let appElement = AXUIElementCreateApplication(app.processIdentifier)
    enableWebAccessibility(on: appElement)
    let appWindows = windows(of: app.processIdentifier)
    let scope = query.scope?.lowercased()

    if scope == "menubar" {
      guard let menuBar = axElement(from: copyAttribute(appElement, kAXMenuBarAttribute)) else {
        throw AgentProtocolError.elementNotFound("App has no menu bar")
      }
      return [menuBar]
    }

    if scope == "all" {
      var roots: [AXUIElement] = appWindows
      if let menuBar = axElement(from: copyAttribute(appElement, kAXMenuBarAttribute)) {
        roots.append(menuBar)
      }
      if roots.isEmpty {
        roots = [appElement]
      }
      return roots
    }

    guard scope == nil || scope == "windows" else {
      throw AgentProtocolError.unsupportedParameter("scope must be one of: windows, menubar, all")
    }

    if query.allWindows && query.windowTitle == nil && query.windowIndex == nil {
      return appWindows.isEmpty ? [appElement] : appWindows
    }

    return [try pickWindow(appWindows, query: query, appElement: appElement)]
  }

  // MARK: - Element lookup

  private func locate(query: AXElementQuery, roots: [AXUIElement]) throws -> AXUIElement {
    guard query.hasMatchCriteria else {
      throw AgentProtocolError.invalidRequest("Provide at least one of role, title, label, or identifier")
    }
    let wanted = max(0, query.index)
    let matches = collectElements(roots: roots, query: query, limit: wanted + 1)
    guard matches.count > wanted else {
      throw AgentProtocolError.elementNotFound("No element matches the given criteria")
    }
    return matches[wanted]
  }

  private enum WalkControl {
    case `continue`
    case stop
  }

  private func collectMatches(roots: [AXUIElement], query: AXElementQuery, limit: Int) -> [AXElementNode] {
    collectElements(roots: roots, query: query, limit: limit).map { snapshot($0) }
  }

  private func collectElements(roots: [AXUIElement], query: AXElementQuery, limit: Int) -> [AXUIElement] {
    var results: [AXUIElement] = []

    func walk(_ element: AXUIElement, depthRemaining: Int) -> WalkControl {
      if elementMatches(element, query: query) {
        results.append(element)
        if results.count >= limit {
          return .stop
        }
      }
      guard depthRemaining > 0 else { return .continue }
      for child in children(of: element) {
        if walk(child, depthRemaining: depthRemaining - 1) == .stop {
          return .stop
        }
      }
      return .continue
    }

    for root in roots {
      if walk(root, depthRemaining: max(0, query.maxDepth)) == .stop {
        break
      }
    }
    return results
  }

  private func elementMatches(_ element: AXUIElement, query: AXElementQuery) -> Bool {
    if let role = query.role?.trimmingCharacters(in: .whitespacesAndNewlines), !role.isEmpty {
      let elementRole = stringAttribute(element, kAXRoleAttribute)
      let elementSubrole = stringAttribute(element, kAXSubroleAttribute)
      guard elementRole?.caseInsensitiveCompare(role) == .orderedSame
              || elementSubrole?.caseInsensitiveCompare(role) == .orderedSame else {
        return false
      }
    }
    if let title = query.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
      guard stringAttribute(element, kAXTitleAttribute)?.localizedCaseInsensitiveContains(title) == true else {
        return false
      }
    }
    if let label = query.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
      guard stringAttribute(element, kAXDescriptionAttribute)?.localizedCaseInsensitiveContains(label) == true else {
        return false
      }
    }
    if let identifier = query.identifier?.trimmingCharacters(in: .whitespacesAndNewlines), !identifier.isEmpty {
      guard stringAttribute(element, kAXIdentifierAttribute)?.localizedCaseInsensitiveContains(identifier) == true else {
        return false
      }
    }
    if let valueNeedle = query.valueContains?.trimmingCharacters(in: .whitespacesAndNewlines), !valueNeedle.isEmpty {
      let (value, _) = valueAttribute(element)
      let valueString: String?
      switch value {
      case .string(let text): valueString = text
      case .int(let number): valueString = String(number)
      case .double(let number): valueString = String(number)
      case .bool(let flag): valueString = flag ? "true" : "false"
      case nil: valueString = nil
      }
      guard valueString?.localizedCaseInsensitiveContains(valueNeedle) == true else {
        return false
      }
    }
    return true
  }

  // MARK: - Snapshots

  private func snapshot(_ element: AXUIElement) -> AXElementNode {
    var budget = 1
    return buildNode(element, depthRemaining: 0, budget: &budget, includeChildren: false, compact: false)
      ?? AXElementNode(
        role: nil, subrole: nil, title: nil, label: nil, identifier: nil,
        value: nil, valueTruncated: nil, frame: nil, enabled: nil, focused: nil, children: nil
      )
  }

  /// Attributes fetched in a single batch call per element.
  private static let batchAttributes: [String] = [
    kAXRoleAttribute,        // 0
    kAXSubroleAttribute,     // 1
    kAXTitleAttribute,       // 2
    kAXDescriptionAttribute, // 3
    kAXIdentifierAttribute,  // 4
    kAXValueAttribute,       // 5
    kAXPositionAttribute,    // 6
    kAXSizeAttribute,        // 7
    kAXEnabledAttribute,     // 8
    kAXFocusedAttribute,     // 9
    kAXChildrenAttribute     // 10
  ]

  private func buildNode(
    _ element: AXUIElement,
    depthRemaining: Int,
    budget: inout Int,
    includeChildren: Bool,
    compact: Bool
  ) -> AXElementNode? {
    guard budget > 0 else { return nil }
    budget -= 1

    // Batch-read all attributes in one IPC round-trip.
    let attrs = batchAttributes(of: element)

    let role = stringValue(from: attrs?[0])
    let subrole = stringValue(from: attrs?[1])
    let title = stringValue(from: attrs?[2])
    let label = stringValue(from: attrs?[3])
    let identifier = stringValue(from: attrs?[4])
    let (value, valueTruncated) = valueFromCFType(attrs?[5])
    let frame = frameFromCFTypes(position: attrs?[6], size: attrs?[7])
    let enabled = boolValue(from: attrs?[8])
    let focused = boolValue(from: attrs?[9])

    var childNodes: [AXElementNode]?
    if includeChildren, depthRemaining > 0 {
      let childElements: [AXUIElement]
      if let childrenRef = attrs?[10], let children = childrenRef as? [AXUIElement] {
        childElements = children
      } else if let visibleChildren = copyAttribute(element, kAXVisibleChildrenAttribute) as? [AXUIElement] {
        childElements = visibleChildren
      } else {
        childElements = []
      }

      if !childElements.isEmpty {
        var nodes: [AXElementNode] = []
        for child in childElements {
          guard budget > 0 else { break }
          // In compact mode, skip non-interactive leaf nodes.
          if compact {
            let childRole = stringAttribute(child, kAXRoleAttribute)
            if let childRole, !Self.interactiveRoles.contains(childRole) {
              // Still recurse into containers that might have interactive descendants.
              let childChildren = children(of: child)
              if childChildren.isEmpty { continue }
            }
          }
          if let node = buildNode(child, depthRemaining: depthRemaining - 1, budget: &budget, includeChildren: true, compact: compact) {
            nodes.append(node)
          }
        }
        childNodes = nodes.isEmpty ? nil : nodes
      }
    }

    return AXElementNode(
      role: role,
      subrole: subrole,
      title: title,
      label: label,
      identifier: identifier,
      value: value,
      valueTruncated: valueTruncated,
      frame: frame,
      enabled: enabled,
      focused: focused,
      children: childNodes
    )
  }

  // MARK: - Batch AX attribute reading

  /// Reads all batch attributes in a single AXUIElementCopyMultipleAttributeValues call.
  /// Returns nil if the batch call fails (falls back to individual reads via buildNode helpers).
  private func batchAttributes(of element: AXUIElement) -> [CFTypeRef?]? {
    let cfAttrNames: [CFString] = Self.batchAttributes.map { $0 as CFString }
    let attrArray = cfAttrNames as CFArray

    var outValues: CFArray?
    let result = AXUIElementCopyMultipleAttributeValues(element, attrArray, [], &outValues)

    guard result == .success, let values = outValues else { return nil }

    let count = CFArrayGetCount(values)
    guard count == Self.batchAttributes.count else { return nil }

    var out: [CFTypeRef?] = []
    out.reserveCapacity(count)
    for i in 0..<count {
      guard let raw = CFArrayGetValueAtIndex(values, i) else {
        out.append(nil)
        continue
      }
      let obj = Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue()
      // Failed attributes come back as AXError values (CFNumber with codes ≤ -25200).
      if let num = obj as? NSNumber, num.intValue <= -25200, CFGetTypeID(obj) == CFNumberGetTypeID() {
        out.append(nil)
      } else {
        out.append(obj as CFTypeRef)
      }
    }
    return out
  }

  private func stringValue(from cfType: CFTypeRef?) -> String? {
    guard let cfType else { return nil }
    if let str = cfType as? String, !str.isEmpty { return str }
    if let attributed = cfType as? NSAttributedString, !attributed.string.isEmpty { return attributed.string }
    if let num = cfType as? NSNumber { return num.stringValue }
    return nil
  }

  private func boolValue(from cfType: CFTypeRef?) -> Bool? {
    guard let cfType else { return nil }
    if CFGetTypeID(cfType) == CFBooleanGetTypeID() {
      return CFBooleanGetValue((cfType as! CFBoolean))
    }
    if let num = cfType as? NSNumber { return num.boolValue }
    return nil
  }

  private func valueFromCFType(_ cfType: CFTypeRef?) -> (AXAttributeValue?, Bool?) {
    guard let value = cfType else { return (nil, nil) }

    if CFGetTypeID(value) == CFBooleanGetTypeID() {
      return (.bool(CFBooleanGetValue((value as! CFBoolean))), nil)
    }
    if let stringValue = value as? String {
      if stringValue.count > Self.maxValueLength {
        return (.string(String(stringValue.prefix(Self.maxValueLength))), true)
      }
      return (.string(stringValue), nil)
    }
    if let attributed = value as? NSAttributedString {
      let stringValue = attributed.string
      if stringValue.count > Self.maxValueLength {
        return (.string(String(stringValue.prefix(Self.maxValueLength))), true)
      }
      return (.string(stringValue), nil)
    }
    if let numberValue = value as? NSNumber {
      if let intValue = Int(exactly: numberValue) {
        return (.int(intValue), nil)
      }
      return (.double(numberValue.doubleValue), nil)
    }
    return (nil, nil)
  }

  private func frameFromCFTypes(position: CFTypeRef?, size: CFTypeRef?) -> CaptureRect? {
    guard let positionValue = position,
          let sizeValue = size,
          CFGetTypeID(positionValue) == AXValueGetTypeID(),
          CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
      return nil
    }
    var point = CGPoint.zero
    var cgSize = CGSize.zero
    AXValueGetValue((positionValue as! AXValue), .cgPoint, &point)
    AXValueGetValue((sizeValue as! AXValue), .cgSize, &cgSize)
    return CaptureRect(x: point.x, y: point.y, width: cgSize.width, height: cgSize.height)
  }

  // MARK: - AX attribute helpers

  private func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
      return nil
    }
    return value
  }

  private func axElement(from value: CFTypeRef?) -> AXUIElement? {
    guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
      return nil
    }
    return (value as! AXUIElement)
  }

  private func children(of element: AXUIElement) -> [AXUIElement] {
    if let value = copyAttribute(element, kAXChildrenAttribute), let children = value as? [AXUIElement] {
      return children
    }
    if let value = copyAttribute(element, kAXVisibleChildrenAttribute), let children = value as? [AXUIElement] {
      return children
    }
    return []
  }

  private func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
    guard let value = copyAttribute(element, attribute) else { return nil }
    if let stringValue = value as? String {
      return stringValue
    }
    if let attributed = value as? NSAttributedString {
      return attributed.string
    }
    if let numberValue = value as? NSNumber {
      return numberValue.stringValue
    }
    return nil
  }

  private func boolAttribute(_ element: AXUIElement, _ attribute: String) -> Bool? {
    guard let value = copyAttribute(element, attribute) else { return nil }
    if CFGetTypeID(value) == CFBooleanGetTypeID() {
      return CFBooleanGetValue((value as! CFBoolean))
    }
    if let numberValue = value as? NSNumber {
      return numberValue.boolValue
    }
    return nil
  }

  private func valueAttribute(_ element: AXUIElement) -> (AXAttributeValue?, Bool?) {
    guard let value = copyAttribute(element, kAXValueAttribute) else {
      return (nil, nil)
    }

    if CFGetTypeID(value) == CFBooleanGetTypeID() {
      return (.bool(CFBooleanGetValue((value as! CFBoolean))), nil)
    }
    if let stringValue = value as? String {
      if stringValue.count > Self.maxValueLength {
        return (.string(String(stringValue.prefix(Self.maxValueLength))), true)
      }
      return (.string(stringValue), nil)
    }
    if let attributed = value as? NSAttributedString {
      let stringValue = attributed.string
      if stringValue.count > Self.maxValueLength {
        return (.string(String(stringValue.prefix(Self.maxValueLength))), true)
      }
      return (.string(stringValue), nil)
    }
    if let numberValue = value as? NSNumber {
      if let intValue = Int(exactly: numberValue) {
        return (.int(intValue), nil)
      }
      return (.double(numberValue.doubleValue), nil)
    }
    return (nil, nil)
  }

  private func frame(of element: AXUIElement) -> CaptureRect? {
    guard let positionValue = copyAttribute(element, kAXPositionAttribute),
          let sizeValue = copyAttribute(element, kAXSizeAttribute),
          CFGetTypeID(positionValue) == AXValueGetTypeID(),
          CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
      return nil
    }

    var point = CGPoint.zero
    var size = CGSize.zero
    AXValueGetValue((positionValue as! AXValue), .cgPoint, &point)
    AXValueGetValue((sizeValue as! AXValue), .cgSize, &size)
    return CaptureRect(x: point.x, y: point.y, width: size.width, height: size.height)
  }

  private func checkAX(_ result: AXError, _ context: String) throws {
    guard result == .success else {
      throw AgentProtocolError.actionFailed("\(context) (\(describe(result)))")
    }
  }

  private func describe(_ error: AXError) -> String {
    switch error {
    case .apiDisabled:
      return "accessibility API is disabled"
    case .actionUnsupported:
      return "action is not supported by the element"
    case .attributeUnsupported:
      return "attribute is not supported by the element"
    case .invalidUIElement:
      return "element is no longer valid"
    case .cannotComplete:
      return "target app could not complete the request"
    case .noValue:
      return "element has no value"
    case .illegalArgument:
      return "illegal argument"
    case .notImplemented:
      return "not implemented by the target app"
    case .failure:
      return "generic failure"
    default:
      return "AXError \(error.rawValue)"
    }
  }
}
