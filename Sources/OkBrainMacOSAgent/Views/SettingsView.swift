import AppKit
import OkBrainMacOSAgentCore
import SwiftUI

struct SettingsView: View {
  @EnvironmentObject private var store: AgentRuntimeStore

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        idleSleepGroup
        fileEditingGroup
        remoteControlGroup
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .padding(.bottom, 8)
    }
  }

  private var idleSleepGroup: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 14) {
        HStack {
          Toggle(isOn: $store.preventIdleSleepEnabled) {
            Text("Prevent Idle Sleep").font(.headline)
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
          InfoRow(icon: "display", text: "Keeps your Mac awake while the agent is running. The display can still turn off normally.")
          InfoRow(icon: "wake", text: "The agent briefly wakes the display for screenshots and approved remote-control requests, then lets it sleep again.")
          InfoRow(icon: "shield.checkered", text: "No system-wide sleep settings are changed; this applies only while this app is running.")
        }
        if let errorMessage = store.idleSleepPrevention.errorMessage {
          Text(errorMessage).font(.callout).foregroundStyle(.red).textSelection(.enabled)
        }
      }
      .padding(4)
    } label: { Text("Sleep") }
  }

  private var fileEditingGroup: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 14) {
        HStack {
          Toggle(isOn: $store.fileEditingEnabled) {
            Text("File Editing").font(.headline)
          }
          .toggleStyle(.switch)
          Spacer(minLength: 12)
          StatusPill(
            title: store.configuration.fileEditing.enabled ? "Enabled" : "Disabled",
            systemImage: store.configuration.fileEditing.enabled ? "checkmark.circle.fill" : "lock.doc",
            tint: store.configuration.fileEditing.enabled ? .green : .secondary
          )
        }
        Divider()
        VStack(alignment: .leading, spacing: 10) {
          InfoRow(icon: "folder.badge.gearshape", text: "File access is default-deny and limited to the folder rules in File Permissions.")
          InfoRow(icon: "lock.open", text: "Each folder rule can be read-only or read-write; more-specific child rules override parent rules.")
          Text("\(store.filePermissionRules.count) folder rule\(store.filePermissionRules.count == 1 ? "" : "s") configured")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }
      .padding(4)
    } label: { Text("File Editing") }
  }

  private var remoteControlGroup: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 14) {
        HStack {
          Text("Remote Control APIs").font(.headline)
          Spacer(minLength: 12)
          StatusPill(
            title: store.remoteControlAPIsEnabled ? "Enabled" : "Disabled",
            systemImage: "hand.raised.square",
            tint: store.remoteControlAPIsEnabled ? .green : .secondary
          )
        }
        Divider()
        Toggle(isOn: $store.remoteControlAPIsEnabled) {
          VStack(alignment: .leading, spacing: 2) {
            Text("Enable Remote Control APIs").font(.callout.weight(.medium))
            Text("Allows the Accessibility (ax.*) API and enabled curated macOS functions. It never re-enables arbitrary AppleScript execution.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .toggleStyle(.switch)
        VStack(alignment: .leading, spacing: 10) {
          InfoRow(icon: "hand.raised", text: "App & Global Access grants Observe or Control. New app and global-category requests ask for the exact level of approval.")
          InfoRow(icon: "slider.horizontal.3", text: "Write and elevated catalog functions are individually disabled until you enable them in Computer Use.")
          InfoRow(icon: "exclamationmark.triangle", text: "macOS may separately request Automation permission for functions that control Safari, Finder, Music, Spotify, or Chrome.")
        }
        Button {
          openAutomationSystemSettings()
        } label: {
          Label("Open Automation Settings", systemImage: "gear")
        }
        .buttonStyle(.borderedProminent)
      }
      .padding(4)
    } label: { Text("Remote Control") }
  }

  private func openAutomationSystemSettings() {
    guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") else { return }
    NSWorkspace.shared.open(url)
  }
}

private struct InfoRow: View {
  let icon: String
  let text: String

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: icon)
        .foregroundStyle(.secondary)
        .frame(width: 16)
        .padding(.top, 1)
      Text(text).font(.callout).foregroundStyle(.secondary)
    }
  }
}

private extension IdleSleepPreventionSnapshot.State {
  var label: String {
    switch self {
    case .disabled: "Disabled"
    case .inactive: "Inactive"
    case .active: "Active"
    case .failed: "Failed"
    }
  }

  var systemImage: String {
    switch self {
    case .disabled: "pause.circle"
    case .inactive: "clock"
    case .active: "checkmark.circle.fill"
    case .failed: "xmark.octagon.fill"
    }
  }

  var tint: Color {
    switch self {
    case .disabled, .inactive: .secondary
    case .active: .green
    case .failed: .red
    }
  }
}
