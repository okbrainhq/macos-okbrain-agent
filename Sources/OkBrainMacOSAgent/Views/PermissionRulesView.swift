import OkBrainMacOSAgentCore
import SwiftUI

struct PermissionRulesView: View {
  @EnvironmentObject private var store: AgentRuntimeStore

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        fileEditingToggleSection

        if store.fileEditingEnabled {
          FilePermissionRulesSection()
        } else {
          GroupBox("File Permissions") {
            Label("File editing is off. Turn it on above to manage folder rules.", systemImage: "lock.doc")
              .foregroundStyle(.secondary)
              .padding(4)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .padding(.bottom, 8)
    }
  }

  private var fileEditingToggleSection: some View {
    GroupBox("File Editing") {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Toggle(isOn: $store.fileEditingEnabled) {
            Text("File Editing").font(.headline)
          }
          .toggleStyle(.switch)
          Spacer(minLength: 12)
          StatusPill.feature(store.configuration.fileEditing.enabled)
        }
        Text("File access is default-deny and limited to the folder rules below. The sandboxed shell (Shell Access tab) reuses these same rules.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      .padding(4)
    }
  }
}
