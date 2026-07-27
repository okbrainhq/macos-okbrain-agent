import SwiftUI

struct DetailView: View {
  let section: AppSection

  private enum Layout {
    static let defaultPadding: CGFloat = 32
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: section.systemImage)
          .font(.title2)
          .foregroundStyle(.secondary)
          .frame(width: 30)
          .padding(.top, 4)

        VStack(alignment: .leading, spacing: 2) {
          Text(section.title)
            .font(.largeTitle.weight(.semibold))
          Text(section.subtitle)
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }

      Divider()

      switch section {
      case .overview:
        OverviewView()
      case .computerUse:
        ComputerUseView()
      case .filePermissions:
        PermissionRulesView()
      }

      Spacer(minLength: 0)
    }
    .padding(Layout.defaultPadding)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}
