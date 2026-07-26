import AppKit
import OkBrainMacOSAgentCore
import SwiftUI

struct SettingsView: View {
  @EnvironmentObject private var store: AgentRuntimeStore
  @State private var proposalError: String?
  @State private var proposalAwaitingFullSourceReview: FunctionProposal?
  @State private var proposalApprovalPreview: FunctionProposalApprovalPreview?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        idleSleepGroup
        fileEditingGroup
        remoteControlGroup
        curatedFunctionsGroup
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
          InfoRow(icon: "slider.horizontal.3", text: "Write and elevated catalog functions are individually disabled until you enable them below.")
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
