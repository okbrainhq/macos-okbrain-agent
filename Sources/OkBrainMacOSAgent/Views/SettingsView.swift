import AppKit
import OkBrainMacOSAgentCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
  @EnvironmentObject private var store: AgentRuntimeStore

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
      // MARK: - Prevent Idle Sleep
      GroupBox {
        VStack(alignment: .leading, spacing: 14) {
          HStack(alignment: .center) {
            Toggle(
              isOn: Binding(
                get: { store.preventIdleSleepEnabled },
                set: { store.preventIdleSleepEnabled = $0 }
              )
            ) {
              Text("Prevent Idle Sleep")
                .font(.headline)
            }
            .toggleStyle(.switch)

            Spacer(minLength: 12)

            StatusPill(
              title: store.idleSleepPrevention.state.label,
              systemImage: store.idleSleepPrevention.state.systemImage,
              tint: store.idleSleepPrevention.state.tint
            )
          }

          Divider()

          VStack(alignment: .leading, spacing: 10) {
            InfoRow(
              icon: "display",
              text: "Keeps your Mac awake so the agent can always respond. Your screen can still turn off normally to save power."
            )

            InfoRow(
              icon: "wake",
              text: "When the display is off, the agent will briefly wake it to take screenshots and run accessibility commands, then let it sleep again."
            )

            InfoRow(
              icon: "lock.screen",
              text: "You can lock your screen — the agent keeps working. However, screenshots are unavailable while locked."
            )

            InfoRow(
              icon: "gearshape",
              text: "Tip: Set your Mac's auto-lock to \"Never\" so the screen turns off without locking, allowing screenshots to work."
            )

            InfoRow(
              icon: "shield.checkered",
              text: "No system settings are changed. Sleep prevention only applies while this app is running."
            )
          }

          if let errorMessage = store.idleSleepPrevention.errorMessage {
            Text(errorMessage)
              .font(.callout)
              .foregroundStyle(.red)
              .textSelection(.enabled)
          }
        }
        .padding(4)
      }

      // MARK: - File Editing
      GroupBox {
        VStack(alignment: .leading, spacing: 14) {
          HStack(alignment: .center) {
            Toggle(
              isOn: Binding(
                get: { store.fileEditingEnabled },
                set: { store.fileEditingEnabled = $0 }
              )
            ) {
              Text("File Editing")
                .font(.headline)
            }
            .toggleStyle(.switch)

            Spacer(minLength: 12)

            StatusPill(
              title: fileEditingStatus,
              systemImage: store.configuration.fileEditing.enabled ? "checkmark.circle.fill" : "lock.doc",
              tint: store.configuration.fileEditing.enabled ? .green : .secondary
            )
          }

          Divider()

          VStack(alignment: .leading, spacing: 10) {
            InfoRow(
              icon: "doc.text",
              text: "Allows the agent to read and write files on your Mac. Disabled by default — you stay in control."
            )

            InfoRow(
              icon: "folder.badge.gearshape",
              text: "Access is restricted to folders you explicitly allow. The agent cannot touch anything outside those boundaries."
            )

            InfoRow(
              icon: "lock.open",
              text: "Each folder rule can be set to read-only or read-write, so you decide exactly what the agent can do."
            )

            InfoRow(
              icon: "shield.checkered",
              text: "Built-in size limits protect against accidental huge writes. Access stays limited to the folders you allow."
            )

            HStack(spacing: 6) {
              Image(systemName: "folder.fill")
                .foregroundStyle(.secondary)
                .frame(width: 16)
              Text("\(store.filePermissionRules.count) folder rule\(store.filePermissionRules.count == 1 ? "" : "s") configured")
                .font(.callout)
                .foregroundStyle(.secondary)
            }
          }
        }
        .padding(4)
      }

      // MARK: - AppleScript App Access
      automationAccessGroupBox
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
    }
  }

  private var fileEditingStatus: String {
    store.configuration.fileEditing.enabled ? "Enabled" : "Disabled"
  }

  // MARK: - AppleScript App Access

  private var automationAccessGroupBox: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 14) {
        HStack(alignment: .center) {
          Text("AppleScript App Access")
            .font(.headline)

          Spacer(minLength: 12)

          StatusPill(
            title: "\(authorizedAutomationCount) authorized",
            systemImage: "apple.terminal",
            tint: authorizedAutomationCount > 0 ? .green : .secondary
          )
        }

        Divider()

        VStack(alignment: .leading, spacing: 10) {
          InfoRow(
            icon: "apple.terminal",
            text: "Lets the agent run AppleScript / osascript against apps you choose — e.g. pause Music, set volume, control Finder."
          )

          InfoRow(
            icon: "hand.raised",
            text: "macOS asks for your approval once per app. Add apps below, then click \"Request Access\" to trigger the system prompt ahead of time."
          )

          InfoRow(
            icon: "exclamationmark.triangle",
            text: "Clicking \"Request Access\" makes macOS show its consent prompt for that app up front, so real tasks aren't blocked later. To re-approve a denied app or revoke an authorized one, use System Settings → Privacy & Security → Automation (button below)."
          )
        }

        HStack(spacing: 10) {
          Button("Add Apps…", action: chooseAutomationApps)

          Button("Request All Access", action: store.requestAllAutomationAccess)
            .buttonStyle(.borderedProminent)
            .disabled(store.automationApps.isEmpty || store.isRequestingAutomationAccess)

          Button {
            openAutomationSystemSettings()
          } label: {
            Label("System Settings", systemImage: "gear")
          }
          .help("Open System Settings → Privacy & Security → Automation to review or revoke per-app access")

          Spacer()
        }

        automationAppsTable
      }
      .padding(4)
    }
  }

  private var authorizedAutomationCount: Int {
    store.automationApps.filter { store.automationStatuses[$0.bundleID] == .authorized }.count
  }

  @ViewBuilder
  private var automationAppsTable: some View {
    if store.automationApps.isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        Text("No apps added")
          .font(.headline)
        Text("Click \"Add Apps…\" to pick apps from your Applications folder.")
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
    } else {
      VStack(spacing: 0) {
        HStack(spacing: 12) {
          Text("App")
            .frame(maxWidth: .infinity, alignment: .leading)
          Text("Status")
            .frame(width: 150, alignment: .leading)
          Text("Action")
            .frame(width: 130, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.08))

        Divider()

        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(store.automationApps) { app in
              AutomationAppRow(
                app: app,
                status: store.automationStatuses[app.bundleID] ?? .unknown,
                isBusy: store.isRequestingAutomationAccess,
                onRequest: { store.requestAutomationAccess(bundleID: app.bundleID) }
              )
              Divider()
            }
          }
        }
        .frame(minHeight: 120, maxHeight: 240)
      }
      .clipShape(RoundedRectangle(cornerRadius: 8))
      .overlay {
        RoundedRectangle(cornerRadius: 8)
          .stroke(Color.secondary.opacity(0.18))
      }
    }
  }

  private func chooseAutomationApps() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = true
    panel.allowedContentTypes = [UTType.application]
    panel.prompt = "Add"
    panel.message = "Select applications to pre-authorize for AppleScript control"
    panel.directoryURL = URL(fileURLWithPath: "/Applications")

    if panel.runModal() == .OK {
      store.addAutomationApps(urls: panel.urls)
    }
  }

  private func openAutomationSystemSettings() {
    guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") else {
      return
    }
    NSWorkspace.shared.open(url)
  }
}

// MARK: - Info Row

private struct InfoRow: View {
  let icon: String
  let text: String

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: icon)
        .foregroundStyle(.secondary)
        .frame(width: 16)
        .padding(.top, 1)
      Text(text)
        .font(.callout)
        .foregroundStyle(.secondary)
    }
  }
}

// MARK: - Automation App Row

private struct AutomationAppRow: View {
  let app: AutomationAppInfo
  let status: AutomationPermissionStatus
  let isBusy: Bool
  let onRequest: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(app.name)
          .font(.callout)
          .lineLimit(1)
        Text(app.bundleID)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      StatusPill(
        title: status.label,
        systemImage: status.systemImage,
        tint: status.tint
      )
      .frame(width: 150, alignment: .leading)

      Button("Request Access", action: onRequest)
        .controlSize(.small)
        .disabled(status == .authorized || isBusy)
        .frame(width: 130, alignment: .trailing)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
  }
}

private extension AutomationPermissionStatus {
  var label: String {
    switch self {
    case .authorized:
      "Authorized"
    case .denied:
      "Denied"
    case .notDetermined:
      "Not Requested"
    case .unknown:
      "Unknown"
    }
  }

  var systemImage: String {
    switch self {
    case .authorized:
      "checkmark.circle.fill"
    case .denied:
      "xmark.octagon.fill"
    case .notDetermined:
      "questionmark.circle"
    case .unknown:
      "questionmark.circle"
    }
  }

  var tint: Color {
    switch self {
    case .authorized:
      .green
    case .denied:
      .red
    case .notDetermined, .unknown:
      .secondary
    }
  }
}

// MARK: - State Extensions

private extension IdleSleepPreventionSnapshot.State {
  var label: String {
    switch self {
    case .disabled:
      "Disabled"
    case .inactive:
      "Inactive"
    case .active:
      "Active"
    case .failed:
      "Failed"
    }
  }

  var systemImage: String {
    switch self {
    case .disabled:
      "pause.circle"
    case .inactive:
      "clock"
    case .active:
      "checkmark.circle.fill"
    case .failed:
      "xmark.octagon.fill"
    }
  }

  var tint: Color {
    switch self {
    case .disabled, .inactive:
      .secondary
    case .active:
      .green
    case .failed:
      .red
    }
  }
}
