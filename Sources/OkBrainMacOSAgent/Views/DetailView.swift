import SwiftUI

struct DetailView: View {
  let section: AppSection

  private enum Layout {
    static let defaultPadding: CGFloat = 32
    static let filePermissionsTopPadding: CGFloat = 80
  }

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
    .padding(.horizontal, Layout.defaultPadding)
    .padding(.top, detailTopPadding)
    .padding(.bottom, Layout.defaultPadding)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private var detailTopPadding: CGFloat {
    section == .filePermissions ? Layout.filePermissionsTopPadding : Layout.defaultPadding
  }
}
