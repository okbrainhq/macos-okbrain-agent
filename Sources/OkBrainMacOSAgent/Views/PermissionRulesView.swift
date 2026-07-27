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
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        fileEditingToggleSection
        filePermissionsSection

        if let errorMessage {
          Text(errorMessage)
            .font(.callout)
            .foregroundStyle(.red)
            .textSelection(.enabled)
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
        Text("File access is default-deny and limited to the folder rules below.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      .padding(4)
    }
  }

  @ViewBuilder
  private var filePermissionsSection: some View {
    if store.fileEditingEnabled {
      GroupBox("File Permissions") {
        VStack(alignment: .leading, spacing: 14) {
          HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.shield")
              .foregroundStyle(.secondary)
              .frame(width: 16)
              .padding(.top, 1)
            Text("Everything is denied by default. Folder rules grant read or write access to that folder and its children; the most specific rule wins.")
              .font(.callout)
              .foregroundStyle(.secondary)
          }

          GroupBox("Add Folder Rule") {
            VStack(alignment: .leading, spacing: 10) {
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
              }
            }
            .padding(4)
          }

          GroupBox {
            VStack(alignment: .leading, spacing: 10) {
              HStack {
                Text("Folder Rules").font(.headline)
                Spacer()
                Button(role: .destructive, action: removeSelectedRules) {
                  Label("Remove", systemImage: "trash")
                }
                .disabled(selectedRulePaths.isEmpty)
              }
              if store.filePermissionRules.isEmpty {
                Text("No rules yet — all file paths remain denied.")
                  .foregroundStyle(.secondary)
                  .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
              } else {
                filePermissionRulesTable
              }
            }
            .padding(4)
          }
        }
        .padding(4)
      }
    } else {
      GroupBox("File Permissions") {
        Label("File editing is off. Turn it on above to manage folder rules.", systemImage: "lock.doc")
          .foregroundStyle(.secondary)
          .padding(4)
      }
    }
  }

  private var filePermissionRulesTable: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Text("Folder").frame(maxWidth: .infinity, alignment: .leading)
        Text("Access").frame(width: 140, alignment: .leading)
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
            FilePermissionRuleRow(
              rule: rule,
              isSelected: selectedRulePaths.contains(rule.path),
              onSelect: { toggleFileSelection(for: rule) },
              onModeChange: { store.updateFilePermissionRule(path: rule.path, mode: $0) }
            )
            Divider()
          }
        }
      }
      .frame(minHeight: 140, maxHeight: 260)
    }
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .overlay { RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.18)) }
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

  private func toggleFileSelection(for rule: FileEditingAllowedRoot) {
    if selectedRulePaths.contains(rule.path) { selectedRulePaths.remove(rule.path) }
    else { selectedRulePaths.insert(rule.path) }
  }
}

private struct FilePermissionRuleRow: View {
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
      Picker("Access", selection: Binding(get: { rule.mode }, set: onModeChange)) {
        Text("Read").tag(FileEditingMode.readOnly)
        Text("Write").tag(FileEditingMode.readWrite)
      }
      .labelsHidden()
      .pickerStyle(.menu)
      .frame(width: 140, alignment: .leading)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .contentShape(Rectangle())
    .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
    .onTapGesture(perform: onSelect)
  }
}
