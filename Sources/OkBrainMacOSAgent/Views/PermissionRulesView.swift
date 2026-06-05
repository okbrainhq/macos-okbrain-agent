import AppKit
import OkBrainMacOSAgentCore
import SwiftUI

struct PermissionRulesView: View {
  @EnvironmentObject private var store: AgentRuntimeStore

  @State private var newRulePath = ""
  @State private var newRuleMode: FileEditingMode = .readOnly
  @State private var selectedRulePaths = Set<String>()
  @State private var errorMessage: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      if store.fileEditingEnabled {
        GroupBox {
          VStack(alignment: .leading, spacing: 14) {
            Text("File Permissions")
              .font(.headline)
            Text("Default is deny. A folder rule grants read or write access to that folder and its nested paths.")
              .font(.callout)
              .foregroundStyle(.secondary)
            Text("Most specific folder wins: add a child-folder rule to override a parent rule.")
              .font(.callout)
              .foregroundStyle(.secondary)
          }
          .padding(4)
        }

        GroupBox {
          VStack(alignment: .leading, spacing: 12) {
            Text("Add Rule")
              .font(.headline)

            HStack(spacing: 10) {
              TextField("/absolute/folder/path", text: $newRulePath)
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospaced())

              Button("Browse…", action: chooseFolder)
            }

            HStack(spacing: 12) {
              Picker("Access", selection: $newRuleMode) {
                Text("Read").tag(FileEditingMode.readOnly)
                Text("Write").tag(FileEditingMode.readWrite)
              }
              .pickerStyle(.segmented)
              .frame(width: 220)

              Button("Add Rule", action: addRule)
                .buttonStyle(.borderedProminent)
                .disabled(newRulePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

              if let errorMessage {
                Text(errorMessage)
                  .font(.callout)
                  .foregroundStyle(.red)
                  .textSelection(.enabled)
              }
            }
          }
          .padding(4)
        }

        GroupBox {
          VStack(alignment: .leading, spacing: 10) {
            HStack {
              Text("Permission Rules")
                .font(.headline)

              Spacer()

              Button(role: .destructive, action: removeSelectedRules) {
                Label("Remove", systemImage: "trash")
              }
              .disabled(selectedRulePaths.isEmpty)
            }

            if store.filePermissionRules.isEmpty {
              VStack(alignment: .leading, spacing: 6) {
                Text("No rules yet")
                  .font(.headline)
                Text("All file paths are denied until you add a folder rule.")
                  .foregroundStyle(.secondary)
              }
              .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            } else {
              permissionRulesTable
            }
          }
          .padding(4)
        }
      } else {
        VStack(spacing: 12) {
          Image(systemName: "lock.doc")
            .font(.system(size: 40))
            .foregroundStyle(.secondary)
          Text("File Editing is Disabled")
            .font(.headline)
          Text("Enable file editing from the Settings page to manage permission rules.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 200, alignment: .center)
        .padding(.vertical, 20)
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }

  private var permissionRulesTable: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Text("Folder")
          .frame(maxWidth: .infinity, alignment: .leading)
        Text("Access")
          .frame(width: 140, alignment: .leading)
        Text("Inheritance")
          .frame(width: 180, alignment: .leading)
      }
      .font(.caption.weight(.semibold))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .background(Color.secondary.opacity(0.08))

      Divider()

      ScrollView {
        LazyVStack(spacing: 0) {
          ForEach(store.filePermissionRules) { rule in
            PermissionRuleRow(
              rule: rule,
              isSelected: selectedRulePaths.contains(rule.path),
              onSelect: { toggleSelection(for: rule) },
              onModeChange: { mode in store.updateFilePermissionRule(path: rule.path, mode: mode) }
            )
            Divider()
          }
        }
      }
      .frame(minHeight: 160, maxHeight: 280)
    }
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .stroke(Color.secondary.opacity(0.18))
    }
  }

  private func chooseFolder() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    panel.prompt = "Use Folder"

    if panel.runModal() == .OK, let url = panel.url {
      newRulePath = url.path
      errorMessage = nil
    }
  }

  private func addRule() {
    do {
      try store.upsertFilePermissionRule(path: newRulePath, mode: newRuleMode)
      selectedRulePaths = [try FilePermissionRuleEngine.normalizedRulePath(newRulePath)]
      newRulePath = ""
      errorMessage = nil
    } catch let error as AgentProtocolError {
      errorMessage = error.message
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func removeSelectedRules() {
    store.removeFilePermissionRules(paths: selectedRulePaths)
    selectedRulePaths.removeAll()
  }

  private func toggleSelection(for rule: FileEditingAllowedRoot) {
    if selectedRulePaths.contains(rule.path) {
      selectedRulePaths.remove(rule.path)
    } else {
      selectedRulePaths.insert(rule.path)
    }
  }
}

private struct PermissionRuleRow: View {
  let rule: FileEditingAllowedRoot
  let isSelected: Bool
  let onSelect: () -> Void
  let onModeChange: (FileEditingMode) -> Void

  var body: some View {
    HStack(spacing: 12) {
      Text(rule.path)
        .font(.callout.monospaced())
        .lineLimit(1)
        .truncationMode(.middle)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)

      Picker("Access", selection: modeBinding) {
        Text("Read").tag(FileEditingMode.readOnly)
        Text("Write").tag(FileEditingMode.readWrite)
      }
      .labelsHidden()
      .pickerStyle(.menu)
      .frame(width: 140, alignment: .leading)

      Label("Nested", systemImage: "arrow.down.right")
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(width: 180, alignment: .leading)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .contentShape(Rectangle())
    .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
    .onTapGesture(perform: onSelect)
  }

  private var modeBinding: Binding<FileEditingMode> {
    Binding(
      get: { rule.mode },
      set: { onModeChange($0) }
    )
  }
}
