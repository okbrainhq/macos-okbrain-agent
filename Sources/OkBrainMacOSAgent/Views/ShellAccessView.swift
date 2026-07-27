import AppKit
import OkBrainMacOSAgentCore
import SwiftUI

/// Shell Access tab (protocol/08 §7): the sandboxed-shell toggle, the shared
/// default-deny folder rules that scope the sandbox, the Ask-tier capability
/// grants, the pending-request inbox, and the bounded audit log. The folder-rule
/// manager is the same `FilePermissionRulesSection` rendered on the File
/// Permissions tab.
struct ShellAccessView: View {
  @EnvironmentObject private var store: AgentRuntimeStore

  @State private var newCapabilityKind: ShellCapabilityKind = .processExec
  @State private var newCapabilityValue = ""
  @State private var newCapabilityMode: ShellCapabilityMode = .alwaysAllow
  @State private var selectedCapabilityIDs = Set<String>()

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        shellToggleSection

        if store.shellAccessEnabled {
          FilePermissionRulesSection()
          shellCapabilitiesSection
        } else {
          GroupBox("Shell Access") {
            Label("Shell access is off. Turn it on above to manage sandboxed shell rules and capabilities.", systemImage: "terminal")
              .foregroundStyle(.secondary)
              .padding(4)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .padding(.bottom, 8)
    }
  }

  // MARK: - Toggle

  private var shellToggleSection: some View {
    GroupBox("Shell Access") {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Toggle(isOn: $store.shellAccessEnabled) {
            Text("Shell Access").font(.headline)
          }
          .toggleStyle(.switch)
          Spacer(minLength: 12)
          StatusPill.feature(shellEffective)
        }
        Text("Sandboxed shell commands run inside a per-execution sandbox scoped to the folder rules below. Rare, high-consequence operations — running an executable outside the trusted system prefixes, or automating another app with Apple events — ask for approval first. Dangerous invocations and administrative tools are always blocked.")
          .font(.callout)
          .foregroundStyle(.secondary)
        if store.shellAccessEnabled && store.filePermissionRules.isEmpty {
          Label("Add at least one folder rule below to enable shell execution.", systemImage: "exclamationmark.triangle")
            .font(.callout)
            .foregroundStyle(.orange)
        }
      }
      .padding(4)
    }
  }

  private var shellEffective: Bool {
    store.shellAccessEnabled && !store.filePermissionRules.isEmpty
  }

  // MARK: - Capability management

  private var shellCapabilitiesSection: some View {
    GroupBox("Shell Capabilities") {
      VStack(alignment: .leading, spacing: 14) {
        grantCapabilitySection
        grantedCapabilitiesSection

        if !store.pendingShellCapabilityRequests.isEmpty {
          pendingRequestsSection
        }

        auditLogSection
      }
      .padding(4)
    }
  }

  // MARK: - Grant capability

  private var grantCapabilitySection: some View {
    GroupBox("Grant Shell Capability") {
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 12) {
          Picker("Capability", selection: $newCapabilityKind) {
            ForEach(ShellCapabilityKind.allCases, id: \.self) { kind in
              Text(kind.label).tag(kind)
            }
          }
          .pickerStyle(.menu)
          .frame(width: 220)

          TextField(valuePlaceholder, text: $newCapabilityValue)
            .textFieldStyle(.roundedBorder)
            .font(.callout.monospaced())
        }
        HStack(spacing: 12) {
          Picker("Access", selection: $newCapabilityMode) {
            ForEach(ShellCapabilityMode.allCases, id: \.self) { mode in
              Text(mode.label).tag(mode)
            }
          }
          .pickerStyle(.segmented)
          .frame(width: 220)

          Button("Add Rule", action: addCapabilityRule)
            .buttonStyle(.borderedProminent)
            .disabled(newCapabilityValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        Text(newCapabilityKind.summary)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(4)
    }
  }

  private var valuePlaceholder: String {
    switch newCapabilityKind {
    case .processExec: "/path/prefix"
    case .appleEventSend: "Application name"
    }
  }

  // MARK: - Granted capabilities

  private var grantedCapabilitiesSection: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Text("Granted Capabilities").font(.headline)
          Spacer()
          Button(role: .destructive, action: removeSelectedCapabilities) {
            Label("Remove", systemImage: "trash")
          }
          .disabled(selectedCapabilityIDs.isEmpty)
        }
        if store.shellCapabilityRules.isEmpty {
          Text("No grants yet — rare shell capabilities prompt on first use (default Ask).")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .center)
        } else {
          capabilityRulesTable
        }
      }
      .padding(4)
    }
  }

  private var capabilityRulesTable: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Text("Capability").frame(width: 150, alignment: .leading)
        Text("Value").frame(maxWidth: .infinity, alignment: .leading)
        Text("Access").frame(width: 150, alignment: .leading)
      }
      .font(.caption.weight(.semibold))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .background(Color.secondary.opacity(0.08))
      Divider()
      ScrollView {
        LazyVStack(spacing: 0) {
          ForEach(store.shellCapabilityRules) { rule in
            ShellCapabilityRuleRow(
              rule: rule,
              isSelected: selectedCapabilityIDs.contains(rule.id),
              onSelect: { toggleSelection(for: rule) },
              onModeChange: { store.updateShellCapabilityRule(kind: rule.kind, value: rule.value, mode: $0) }
            )
            Divider()
          }
        }
      }
      .frame(minHeight: 100, maxHeight: 220)
    }
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .overlay { RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.18)) }
  }

  // MARK: - Pending requests

  private var pendingRequestsSection: some View {
    GroupBox("Pending Shell Requests (\(store.pendingShellCapabilityRequests.count))") {
      VStack(alignment: .leading, spacing: 10) {
        ForEach(store.pendingShellCapabilityRequests) { request in
          ShellPendingRequestRow(
            request: request,
            onResolve: { resolution in
              store.resolvePendingShellCapabilityRequest(id: request.id, resolution: resolution)
            }
          )
          if request.id != store.pendingShellCapabilityRequests.last?.id { Divider() }
        }
      }
      .padding(4)
    }
  }

  // MARK: - Audit log

  private var auditLogSection: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Text("Shell Audit Log").font(.headline)
          Spacer()
          Text("\(store.shellAuditEvents.count) recent")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        if store.shellAuditEvents.isEmpty {
          Text("No shell executions yet. Commands and decisions are logged here (never output contents).")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .center)
        } else {
          auditLogTable
        }
      }
      .padding(4)
    } label: { Text("Audit") }
  }

  private var auditLogTable: some View {
    VStack(spacing: 0) {
      ScrollView {
        LazyVStack(spacing: 0) {
          ForEach(store.shellAuditEvents) { event in
            ShellAuditRow(event: event)
            Divider()
          }
        }
      }
      .frame(minHeight: 100, maxHeight: 240)
    }
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .overlay { RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.18)) }
  }

  // MARK: - Actions

  private func addCapabilityRule() {
    store.upsertShellCapabilityRule(kind: newCapabilityKind, value: newCapabilityValue, mode: newCapabilityMode)
    let trimmed = newCapabilityValue.trimmingCharacters(in: .whitespacesAndNewlines)
    selectedCapabilityIDs = [ShellCapabilityRule(kind: newCapabilityKind, value: trimmed, mode: newCapabilityMode).id]
    newCapabilityValue = ""
  }

  private func removeSelectedCapabilities() {
    store.removeShellCapabilityRules(ids: selectedCapabilityIDs)
    selectedCapabilityIDs.removeAll()
  }

  private func toggleSelection(for rule: ShellCapabilityRule) {
    if selectedCapabilityIDs.contains(rule.id) { selectedCapabilityIDs.remove(rule.id) }
    else { selectedCapabilityIDs.insert(rule.id) }
  }
}

// MARK: - Private subviews

private struct ShellCapabilityRuleRow: View {
  let rule: ShellCapabilityRule
  let isSelected: Bool
  let onSelect: () -> Void
  let onModeChange: (ShellCapabilityMode) -> Void

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: rule.kind == .processExec ? "chevron.right.square" : "arrow.turn.down.right")
        .foregroundStyle(.secondary)
        .frame(width: 18)
      Text(rule.kind.label)
        .font(.callout)
        .frame(width: 132, alignment: .leading)
      Text(rule.value)
        .font(.callout.monospaced())
        .lineLimit(1)
        .truncationMode(.middle)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
      Picker("Access", selection: Binding(get: { rule.mode }, set: onModeChange)) {
        ForEach(ShellCapabilityMode.allCases, id: \.self) { mode in
          Text(mode.label).tag(mode)
        }
      }
      .labelsHidden()
      .pickerStyle(.menu)
      .frame(width: 150, alignment: .leading)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .contentShape(Rectangle())
    .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
    .onTapGesture(perform: onSelect)
  }
}

private struct ShellPendingRequestRow: View {
  let request: ShellPendingCapabilityRequest
  let onResolve: (ShellPendingResolution) -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: request.kind == .processExec ? "chevron.right.square" : "arrow.turn.down.right")
        .foregroundStyle(.secondary)
        .frame(width: 18)
      VStack(alignment: .leading, spacing: 3) {
        Text("\(request.kind.label) — \(request.value)").font(.callout.weight(.medium))
        Text(request.command).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
        Text(request.context).font(.caption).foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
      Menu("Decide") {
        Button("Allow Once") { onResolve(.allowOnce) }
        Button("Always Allow") { onResolve(.allowAlways) }
        Divider()
        Button("Dismiss", role: .cancel) { onResolve(.dismiss) }
      }
    }
  }
}

private struct ShellAuditRow: View {
  let event: ShellAuditEvent

  private static let timestampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter
  }()

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Text(Self.timestampFormatter.string(from: event.date))
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .frame(width: 64, alignment: .leading)
      VStack(alignment: .leading, spacing: 2) {
        Text(event.command)
          .font(.caption.monospaced())
          .lineLimit(2)
          .truncationMode(.tail)
          .textSelection(.enabled)
        Text("cwd: \(event.cwd) · \(event.classification)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      VStack(alignment: .trailing, spacing: 2) {
        Text(event.decision.rawValue)
          .font(.caption.weight(.semibold))
          .foregroundStyle(decisionColor)
        if let exitCode = event.exitCode {
          Text("exit \(exitCode)")
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
        }
      }
      .frame(width: 110, alignment: .trailing)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
  }

  private var decisionColor: Color {
    switch event.decision {
    case .allow, .askGrant: .green
    case .askDenied, .block, .deniedBySandbox: .red
    case .timeout, .outputLimit: .orange
    case .error: .secondary
    }
  }
}
