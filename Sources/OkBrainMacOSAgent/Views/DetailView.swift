import SwiftUI

struct DetailView: View {
  let section: AppSection

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(spacing: 12) {
        Image(systemName: section.systemImage)
          .font(.title2)
          .foregroundStyle(.secondary)
          .frame(width: 30)

        Text(section.title)
          .font(.largeTitle.weight(.semibold))
      }

      Divider()

      switch section {
      case .overview:
        OverviewView()
      case .screenshot:
        ScreenshotView()
      case .filePermissions:
        PermissionRulesView()
      case .settings:
        SettingsView()
      case .diagnostics:
        DiagnosticsView()
      }

      Spacer(minLength: 0)
    }
    .padding(32)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}
