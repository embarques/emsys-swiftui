import SwiftUI

/// Each tab owns its navigation stack and keeps it while another tab is selected.
struct AppTabNavigationView<Destination: View>: View {
    @Binding var selection: AppDestination
    @ViewBuilder var content: (AppDestination) -> Destination

    var body: some View {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .phone {
            tabs.tabViewStyle(.tabBarOnly)
        } else {
            tabs.tabViewStyle(.sidebarAdaptable)
                .defaultAdaptableTabBarPlacement(.sidebar)
        }
        #else
        tabs.tabViewStyle(.sidebarAdaptable)
        #endif
    }

    private var tabs: some View {
        TabView(selection: $selection) {
            ForEach(AppDestination.primaryTabs) { destination in
                Tab(value: destination) {
                    NavigationStack { content(destination) }
                } label: {
                    Label(destination.title, systemImage: destination.systemImageName)
                }
            }
        }
    }
}
