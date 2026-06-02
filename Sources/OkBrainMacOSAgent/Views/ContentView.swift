import SwiftUI

struct ContentView: View {
  @SceneStorage("selectedAppSection") private var selectedSectionID = AppSection.overview.rawValue

  private var selection: Binding<AppSection?> {
    Binding {
      AppSection(rawValue: selectedSectionID) ?? .overview
    } set: { newSelection in
      selectedSectionID = (newSelection ?? .overview).rawValue
    }
  }

  var body: some View {
    NavigationSplitView {
      SidebarView(selection: selection)
    } detail: {
      DetailView(section: selection.wrappedValue ?? .overview)
    }
  }
}
