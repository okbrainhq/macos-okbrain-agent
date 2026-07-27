import OkBrainMacOSAgentCore
import SwiftUI

struct StatusPill: View {
  let title: String
  let systemImage: String
  let tint: Color

  var body: some View {
    Label(title, systemImage: systemImage)
      .font(.callout.weight(.medium))
      .foregroundStyle(tint)
      .padding(.horizontal, 10)
      .padding(.vertical, 5)
      .background(tint.opacity(0.10), in: Capsule())
  }
}

extension StatusPill {
  /// Shared enabled/disabled status pill for feature toggles.
  static func feature(_ enabled: Bool) -> StatusPill {
    StatusPill(
      title: enabled ? "Enabled" : "Disabled",
      systemImage: enabled ? "checkmark.circle.fill" : "circle.dashed",
      tint: enabled ? .green : .secondary
    )
  }
}

extension PermissionState {
  var label: String {
    switch self {
    case .granted:
      "Granted"
    case .denied:
      "Denied"
    case .unknown:
      "Unknown"
    }
  }

  var tint: Color {
    switch self {
    case .granted:
      .green
    case .denied:
      .orange
    case .unknown:
      .secondary
    }
  }

  var systemImage: String {
    switch self {
    case .granted:
      "checkmark.circle.fill"
    case .denied:
      "exclamationmark.triangle.fill"
    case .unknown:
      "questionmark.circle"
    }
  }
}

extension SocketServerStatus {
  var label: String {
    switch self {
    case .stopped:
      "Stopped"
    case .starting:
      "Starting"
    case .running:
      "Running"
    case .failed:
      "Failed"
    }
  }

  var tint: Color {
    switch self {
    case .running:
      .green
    case .starting:
      .blue
    case .failed:
      .red
    case .stopped:
      .secondary
    }
  }

  var systemImage: String {
    switch self {
    case .running:
      "checkmark.circle.fill"
    case .starting:
      "clock"
    case .failed:
      "xmark.octagon.fill"
    case .stopped:
      "pause.circle"
    }
  }
}
