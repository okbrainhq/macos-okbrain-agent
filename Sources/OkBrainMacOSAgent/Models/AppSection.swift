import Foundation

enum AppSection: String, CaseIterable, Hashable, Identifiable {
  case overview
  case screenshot
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
    case .diagnostics:
      "stethoscope"
    }
  }
}
