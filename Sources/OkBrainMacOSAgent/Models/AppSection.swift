import Foundation

enum AppSection: String, CaseIterable, Hashable, Identifiable {
  case overview
  case screenshot
  case filePermissions
  case settings
  case diagnostics

  var id: String {
    rawValue
  }

  var title: String {
    switch self {
    case .overview:
      "Agent"
    case .screenshot:
      "Screenshot"
    case .filePermissions:
      "File Permissions"
    case .settings:
      "Settings"
    case .diagnostics:
      "Diagnostics"
    }
  }

  var systemImage: String {
    switch self {
    case .overview:
      "antenna.radiowaves.left.and.right"
    case .screenshot:
      "camera.viewfinder"
    case .filePermissions:
      "folder.badge.gearshape"
    case .settings:
      "gearshape"
    case .diagnostics:
      "stethoscope"
    }
  }
}
