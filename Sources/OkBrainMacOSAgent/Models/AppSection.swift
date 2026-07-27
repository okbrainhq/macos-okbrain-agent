import Foundation

enum AppSection: String, CaseIterable, Hashable, Identifiable {
  case overview
  case computerUse
  case filePermissions

  var id: String {
    rawValue
  }

  var title: String {
    switch self {
    case .overview:
      "Agent"
    case .computerUse:
      "Computer Use"
    case .filePermissions:
      "File Permissions"
    }
  }

  var subtitle: String {
    switch self {
    case .overview:
      "Socket status, permissions, and runtime controls."
    case .computerUse:
      "App & global access grants and the curated function catalog."
    case .filePermissions:
      "Default-deny folder rules for file editing."
    }
  }

  var systemImage: String {
    switch self {
    case .overview:
      "antenna.radiowaves.left.and.right"
    case .computerUse:
      "hand.tap.fill"
    case .filePermissions:
      "folder.badge.gearshape"
    }
  }
}
