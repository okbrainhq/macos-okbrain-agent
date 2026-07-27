import AppKit
import OkBrainMacOSAgentCore
import SwiftUI
import UniformTypeIdentifiers

struct ComputerUseView: View {
  @EnvironmentObject private var store: AgentRuntimeStore

  // App & global access state
  @State private var selectedPermissionTargetID = ""
  @State private var selectedApplicationTarget: PermissionTarget?
  @State private var selectedPermissionRuleTargetIDs = Set<String>()
  @State private var newPermissionMode: AXAppPermissionMode = .observe
  @State private var accessErrorMessage: String?

  // Curated functions / proposal state
  @State private var proposalError: String?
  @State private var proposalAwaitingFullSourceReview: FunctionProposal?
  @State private var proposalApprovalPreview: FunctionProposalApprovalPreview?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        remoteControlSection
        if store.remoteControlAPIsEnabled {
          appControlSection
          curatedFunctionsGroup
        } else {
          GroupBox("Computer Use") {
            Label("Remote Control is off. Turn it on above to manage access grants and functions.", systemImage: "hand.raised.square")
              .foregroundStyle(.secondary)
              .padding(4)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .padding(.bottom, 8)
    }
    .sheet(item: $proposalAwaitingFullSourceReview) { proposal in
      if let preview = proposalApprovalPreview, preview.proposalID == proposal.id {
        FunctionProposalApprovalSheet(
          proposal: proposal,
          preview: preview,
          onApprove: { sourceDigest in approveProposalAfterFullSourceReview(proposal, sourceDigest: sourceDigest) },
          onCancel: {
            proposalAwaitingFullSourceReview = nil
            proposalApprovalPreview = nil
          }
        )
      }
    }
  }

  // MARK: - Remote Control APIs

  private var remoteControlSection: some View {
    GroupBox("Remote Control APIs") {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Toggle(isOn: $store.remoteControlAPIsEnabled) {
            Text("Enable Remote Control APIs").font(.headline)
          }
          .toggleStyle(.switch)
          Spacer(minLength: 12)
          StatusPill.feature(store.remoteControlAPIsEnabled)
        }
        Text("Allows the Accessibility (ax.*) API and enabled curated macOS functions. macOS may still request Automation permission for apps like Safari, Finder, Music, Spotify, or Chrome.")
          .font(.callout)
          .foregroundStyle(.secondary)
        Button {
          openAutomationSystemSettings()
        } label: {
          Label("Open Automation Settings", systemImage: "gear")
        }
        .buttonStyle(.borderedProminent)
      }
      .padding(4)
    }
  }

  // MARK: - App & Global Access

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

        if let accessErrorMessage {
          Text(accessErrorMessage)
            .font(.callout)
            .foregroundStyle(.red)
            .textSelection(.enabled)
        }
      }
      .padding(4)
    }
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
      accessErrorMessage = nil
    } catch let error as AgentProtocolError {
      accessErrorMessage = error.message
    } catch {
      accessErrorMessage = error.localizedDescription
    }
  }

  private func addPermissionRule() {
    guard let target = selectedPermissionTarget else { return }
    store.upsertPermissionRule(target: target, mode: newPermissionMode)
    selectedPermissionRuleTargetIDs = [target.id]
    accessErrorMessage = nil
  }

  private func removeSelectedPermissionRules() {
    store.removePermissionRules(targetIDs: selectedPermissionRuleTargetIDs)
    selectedPermissionRuleTargetIDs.removeAll()
  }

  private func togglePermissionRuleSelection(for rule: AXAppPermissionRule) {
    if selectedPermissionRuleTargetIDs.contains(rule.target.id) { selectedPermissionRuleTargetIDs.remove(rule.target.id) }
    else { selectedPermissionRuleTargetIDs.insert(rule.target.id) }
  }

  // MARK: - Curated macOS Functions

  private var curatedFunctionsGroup: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 14) {
        HStack {
          Text("Curated macOS Functions").font(.headline)
          Spacer()
          Text("\(store.functionCatalog.count) available")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        Text("Read functions are catalog-enabled by default but still need Observe permission for their app or global category. Write and elevated functions require an explicit local toggle plus Control permission.")
          .font(.callout)
          .foregroundStyle(.secondary)

        functionCatalogTable

        if !store.functionProposals.isEmpty {
          proposalInbox
        }

        if !store.storedFunctionTemplates.isEmpty {
          approvedTemplates
        }

        if let proposalError {
          Text(proposalError)
            .font(.callout)
            .foregroundStyle(.red)
            .textSelection(.enabled)
        }
      }
      .padding(4)
    } label: { Text("Functions") }
  }

  private var functionCatalogTable: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Function").frame(maxWidth: .infinity, alignment: .leading)
        Text("Tier").frame(width: 90, alignment: .leading)
        Text("Enabled").frame(width: 80, alignment: .center)
      }
      .font(.caption.weight(.semibold))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .background(Color.secondary.opacity(0.08))
      Divider()
      ScrollView {
        LazyVStack(spacing: 0) {
          ForEach(store.functionCatalog) { function in
            HStack(spacing: 12) {
              VStack(alignment: .leading, spacing: 2) {
                Text(function.name).font(.callout.monospaced())
                Text(function.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if let target = function.permissionTarget {
                  Text("\(target.kind.label): \(target.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              Text(function.tier.label)
                .font(.caption.weight(.medium))
                .frame(width: 90, alignment: .leading)
              if function.tier == .read {
                Image(systemName: "checkmark.circle.fill")
                  .foregroundStyle(.green)
                  .frame(width: 80)
                  .help("Catalog-enabled by default; execution still requires an Observe grant for its app or global category")
              } else {
                Toggle("", isOn: Binding(
                  get: { function.enabled },
                  set: { store.setFunctionEnabled($0, name: function.name) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .frame(width: 80)
              }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Divider()
          }
        }
      }
      .frame(minHeight: 180, maxHeight: 320)
    }
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .overlay { RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.18)) }
  }

  private var proposalInbox: some View {
    GroupBox("Function Proposals (\(store.functionProposals.count))") {
      VStack(alignment: .leading, spacing: 10) {
        ForEach(store.functionProposals) { proposal in
          VStack(alignment: .leading, spacing: 6) {
            HStack {
              Text(proposal.name).font(.callout.monospaced().weight(.medium))
              Spacer()
              Button("Review & Approve") { beginProposalReview(proposal) }
                .buttonStyle(.borderedProminent)
                .disabled(proposal.exampleScript?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false)
              Button("Reject", role: .destructive) { store.rejectFunctionProposal(id: proposal.id) }
            }
            Text(proposal.description).font(.callout)
            Text(proposal.rationale).font(.caption).foregroundStyle(.secondary)
            if let script = proposal.exampleScript {
              Text(script)
                .font(.caption.monospaced())
                .lineLimit(5)
                .textSelection(.enabled)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
            } else {
              Text("No template script supplied; approval is unavailable.")
                .font(.caption)
                .foregroundStyle(.orange)
            }
          }
          if proposal.id != store.functionProposals.last?.id { Divider() }
        }
      }
      .padding(4)
    }
  }

  private var approvedTemplates: some View {
    GroupBox("Approved Templates") {
      VStack(alignment: .leading, spacing: 8) {
        ForEach(store.storedFunctionTemplates) { template in
          HStack {
            VStack(alignment: .leading, spacing: 2) {
              Text(template.name).font(.callout.monospaced())
              Text(template.summary).font(.caption).foregroundStyle(.secondary)
              if let bundleID = template.targetBundleID, template.isReviewed {
                Text("Reviewed target: \(template.targetAppName ?? bundleID) (\(bundleID))")
                  .font(.caption.monospaced())
                  .foregroundStyle(.secondary)
              } else {
                Text("Legacy template disabled — re-review its full source before use.")
                  .font(.caption)
                  .foregroundStyle(.orange)
              }
            }
            Spacer()
            if !template.isReviewed {
              Button("Re-review") { store.requeueLegacyFunctionTemplateForReview(id: template.id) }
                .buttonStyle(.borderedProminent)
            }
            Button(role: .destructive) { store.removeStoredFunctionTemplate(id: template.id) } label: {
              Label("Remove", systemImage: "trash")
            }
          }
          if template.id != store.storedFunctionTemplates.last?.id { Divider() }
        }
      }
      .padding(4)
    }
  }

  private func beginProposalReview(_ proposal: FunctionProposal) {
    do {
      proposalApprovalPreview = try store.previewFunctionProposalApproval(id: proposal.id)
      proposalError = nil
      proposalAwaitingFullSourceReview = proposal
    } catch let error as AgentProtocolError {
      proposalError = error.message
    } catch {
      proposalError = error.localizedDescription
    }
  }

  private func approveProposalAfterFullSourceReview(_ proposal: FunctionProposal, sourceDigest: String) {
    do {
      try store.approveFunctionProposal(id: proposal.id, sourceDigest: sourceDigest)
      proposalError = nil
      proposalAwaitingFullSourceReview = nil
      proposalApprovalPreview = nil
    } catch let error as AgentProtocolError {
      proposalError = error.message
    } catch {
      proposalError = error.localizedDescription
    }
  }

  private func openAutomationSystemSettings() {
    guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") else { return }
    NSWorkspace.shared.open(url)
  }
}

// MARK: - Private subviews

private struct FunctionProposalApprovalSheet: View {
  let proposal: FunctionProposal
  let preview: FunctionProposalApprovalPreview
  let onApprove: (String) -> Void
  let onCancel: () -> Void

  @State private var reviewedEntireSource = false

  private var source: String {
    proposal.exampleScript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }

  private var sourceDigest: String { preview.sourceDigest }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Review Full Template Source").font(.title2.weight(.semibold))
      Text("Approving stores this exact source, its SHA-256 digest, and one reviewed application target. Source changes or dynamic/multi-target scripts are rejected.")
        .font(.callout)
        .foregroundStyle(.secondary)
      Text(proposal.name).font(.callout.monospaced().weight(.medium))
      VStack(alignment: .leading, spacing: 3) {
        Text("Resolved target: \(preview.targetAppName) (\(preview.targetBundleID))")
          .font(.caption.monospaced())
        Text("Tier: \(preview.tier.label) · Placeholders: \(preview.argumentNames.isEmpty ? "none" : preview.argumentNames.joined(separator: ", "))")
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(preview.approvalEnablesExecution
          ? "Approving enables this elevated template. You can disable it later in the function catalog."
          : "Approval stores the template but does not enable execution.")
          .font(.caption)
          .foregroundStyle(.orange)
      }

      VStack(alignment: .leading, spacing: 6) {
        Text("Complete source").font(.caption.weight(.semibold))
        ScrollView([.horizontal, .vertical]) {
          Text(source.isEmpty ? "No source provided." : source)
            .font(.callout.monospaced())
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
        .frame(minHeight: 260, maxHeight: 420)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
      }

      VStack(alignment: .leading, spacing: 3) {
        Text("Source SHA-256 (submitted with this approval)").font(.caption.weight(.semibold))
        Text(sourceDigest).font(.caption.monospaced()).textSelection(.enabled)
      }

      Toggle("I reviewed the entire source shown above and approve exactly this digest.", isOn: $reviewedEntireSource)
        .toggleStyle(.checkbox)

      HStack {
        Spacer()
        Button("Cancel", action: onCancel)
        Button("Approve Exact Source") { onApprove(sourceDigest) }
          .buttonStyle(.borderedProminent)
          .disabled(source.isEmpty || !reviewedEntireSource)
      }
    }
    .padding(22)
    .frame(minWidth: 640, minHeight: 560)
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
