import AppKit
import OkBrainMacOSAgentCore
import SwiftUI
import UniformTypeIdentifiers

struct PermissionRulesView: View {
  @EnvironmentObject private var store: AgentRuntimeStore

  @State private var newRulePath = ""
  @State private var newRuleMode: FileEditingMode = .readOnly
  @State private var selectedRulePaths = Set<String>()
  @State private var selectedPermissionTargetID = ""
  @State private var selectedApplicationTarget: PermissionTarget?
  @State private var selectedPermissionRuleTargetIDs = Set<String>()
  @State private var newPermissionMode: AXAppPermissionMode = .observe
  @State private var errorMessage: String?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        filePermissionsSection
        appControlSection
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .padding(.bottom, 8)
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
        Label("File editing is disabled. Enable it in Settings to manage folder rules.", systemImage: "lock.doc")
          .foregroundStyle(.secondary)
          .padding(4)
      }
    }
  }

  private var appControlSection: some View {
    GroupBox("App & Global Access") {
      VStack(alignment: .leading, spacing: 14) {
        HStack(alignment: .top, spacing: 8) {
          Image(systemName: "hand.raised.square")
            .foregroundStyle(.secondary)
            .frame(width: 16)
            .padding(.top, 1)
          Text("Everything is denied by default. Grant Observe to inspect an app or global capability; grant Control to inspect it and perform changes. You can grant access here or when a local permission popup appears.")
            .font(.callout)
            .foregroundStyle(.secondary)
        }

        GroupBox("Grant Access") {
          VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
              Picker("Target", selection: $selectedPermissionTargetID) {
                Text("Choose a target…").tag("")
                Section("Global capabilities") {
                  ForEach(store.globalPermissionTargetOptions) { option in
                    Text("\(option.target.displayName) — \(option.subtitle)")
                      .tag(option.id)
                  }
                }
                if let selectedApplicationTarget {
                  Section("Chosen application") {
                    Text("\(selectedApplicationTarget.displayName) (\(selectedApplicationTarget.identifier))")
                      .tag(selectedApplicationTarget.id)
                  }
                }
              }
              .frame(maxWidth: 520)

              Button("Choose Application…", action: chooseApplication)
                .help("Browse for an installed .app bundle. Running applications are not used as the permission source.")
            }

            HStack(spacing: 12) {
              Picker("Access", selection: $newPermissionMode) {
                Text("Observe").tag(AXAppPermissionMode.observe)
                Text("Control").tag(AXAppPermissionMode.control)
              }
              .pickerStyle(.segmented)
              .frame(width: 220)

              Button("Grant Access", action: addPermissionRule)
                .buttonStyle(.borderedProminent)
                .disabled(selectedPermissionTarget == nil)
            }
          }
          .padding(4)
        }

        GroupBox {
          VStack(alignment: .leading, spacing: 10) {
            HStack {
              Text("Granted Access").font(.headline)
              Spacer()
              Button(role: .destructive, action: removeSelectedPermissionRules) {
                Label("Remove Access", systemImage: "trash")
              }
              .disabled(selectedPermissionRuleTargetIDs.isEmpty)
            }
            if store.permissionRules.isEmpty {
              Text("No grants yet — applications and global capabilities remain blocked until you approve Observe or Control.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
            } else {
              permissionRulesTable
            }
          }
          .padding(4)
        }

        if !store.pendingAXPermissionRequests.isEmpty {
          GroupBox("Pending Permission Requests (\(store.pendingAXPermissionRequests.count))") {
            VStack(alignment: .leading, spacing: 10) {
              ForEach(store.pendingAXPermissionRequests) { request in
                PendingPermissionRequestRow(
                  request: request,
                  onResolve: { resolution in
                    store.resolvePendingAXPermissionRequest(id: request.id, resolution: resolution)
                  }
                )
                if request.id != store.pendingAXPermissionRequests.last?.id { Divider() }
              }
            }
            .padding(4)
          }
        }

        if let errorMessage {
          Text(errorMessage)
            .font(.callout)
            .foregroundStyle(.red)
            .textSelection(.enabled)
        }
      }
      .padding(4)
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

  private var permissionRulesTable: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Text("Target").frame(maxWidth: .infinity, alignment: .leading)
        Text("Access").frame(width: 180, alignment: .leading)
      }
      .font(.caption.weight(.semibold))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .background(Color.secondary.opacity(0.08))
      Divider()
      ScrollView {
        LazyVStack(spacing: 0) {
          ForEach(store.permissionRules) { rule in
            PermissionRuleRow(
              rule: rule,
              isSelected: selectedPermissionRuleTargetIDs.contains(rule.target.id),
              onSelect: { togglePermissionRuleSelection(for: rule) },
              onModeChange: { store.updatePermissionRule(targetID: rule.target.id, mode: $0) }
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

  private var availablePermissionTargets: [PermissionTargetOption] {
    var options = store.globalPermissionTargetOptions
    if let selectedApplicationTarget {
      options.append(PermissionTargetOption(target: selectedApplicationTarget, subtitle: selectedApplicationTarget.identifier))
    }
    return options
  }

  private var selectedPermissionTarget: PermissionTarget? {
    availablePermissionTargets.first(where: { $0.id == selectedPermissionTargetID })?.target
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

  private func chooseApplication() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = false
    panel.treatsFilePackagesAsDirectories = false
    panel.allowedContentTypes = [.applicationBundle]
    panel.prompt = "Use Application"

    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      let target = try store.permissionTarget(forApplicationBundleURL: url)
      selectedApplicationTarget = target
      selectedPermissionTargetID = target.id
      errorMessage = nil
    } catch let error as AgentProtocolError {
      errorMessage = error.message
    } catch {
      errorMessage = error.localizedDescription
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

  private func addPermissionRule() {
    guard let target = selectedPermissionTarget else { return }
    store.upsertPermissionRule(target: target, mode: newPermissionMode)
    selectedPermissionRuleTargetIDs = [target.id]
    errorMessage = nil
  }

  private func removeSelectedRules() {
    store.removeFilePermissionRules(paths: selectedRulePaths)
    selectedRulePaths.removeAll()
  }

  private func removeSelectedPermissionRules() {
    store.removePermissionRules(targetIDs: selectedPermissionRuleTargetIDs)
    selectedPermissionRuleTargetIDs.removeAll()
  }

  private func toggleFileSelection(for rule: FileEditingAllowedRoot) {
    if selectedRulePaths.contains(rule.path) { selectedRulePaths.remove(rule.path) }
    else { selectedRulePaths.insert(rule.path) }
  }

  private func togglePermissionRuleSelection(for rule: AXAppPermissionRule) {
    if selectedPermissionRuleTargetIDs.contains(rule.target.id) { selectedPermissionRuleTargetIDs.remove(rule.target.id) }
    else { selectedPermissionRuleTargetIDs.insert(rule.target.id) }
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

private struct PermissionRuleRow: View {
  let rule: AXAppPermissionRule
  let isSelected: Bool
  let onSelect: () -> Void
  let onModeChange: (AXAppPermissionMode) -> Void

  var body: some View {
    HStack(spacing: 10) {
      PermissionTargetIcon(target: rule.target)
      VStack(alignment: .leading, spacing: 2) {
        Text(rule.target.displayName).font(.callout.weight(.medium))
        Text("\(rule.target.kind.label) · \(rule.target.identifier)")
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Picker("Mode", selection: Binding(get: { rule.mode }, set: onModeChange)) {
        Text("Observe").tag(AXAppPermissionMode.observe)
        Text("Control").tag(AXAppPermissionMode.control)
      }
      .labelsHidden()
      .pickerStyle(.menu)
      .frame(width: 180, alignment: .leading)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .contentShape(Rectangle())
    .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
    .onTapGesture(perform: onSelect)
  }
}

private struct PermissionTargetIcon: View {
  let target: PermissionTarget

  var body: some View {
    switch target.kind {
    case .application:
      if let url = target.bundleID.flatMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }) {
        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
          .resizable()
          .frame(width: 24, height: 24)
      } else {
        Image(systemName: "app.fill")
          .frame(width: 24, height: 24)
          .foregroundStyle(.secondary)
      }
    case .category:
      Image(systemName: target.category?.symbolName ?? "slider.horizontal.3")
        .frame(width: 24, height: 24)
        .foregroundStyle(.secondary)
    }
  }
}

private struct PendingPermissionRequestRow: View {
  let request: AXPendingPermissionRequest
  let onResolve: (AXPendingPermissionResolution) -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      PermissionTargetIcon(target: request.target)
      VStack(alignment: .leading, spacing: 3) {
        Text("\(request.intent.label) — \(request.target.displayName)").font(.callout.weight(.medium))
        Text(request.action).font(.caption.monospaced()).foregroundStyle(.secondary)
        Text(request.context).font(.caption).foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
      Menu("Decide") {
        Button("Allow \(request.intent.label) Once") { onResolve(.allowOnce) }
        Button("Always Allow \(request.intent.label)") { onResolve(.allowAlways) }
        Divider()
        Button("Dismiss", role: .cancel) { onResolve(.dismiss) }
      }
    }
  }
}
