import SwiftUI

struct HomeView: View {
    @Environment(AppPreferences.self) private var preferences

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppStyle.Spacing.large) {
                Image("BrandLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 172)
                    .accessibilityHidden(true)
                Text(verbatim: "EMSYS")
                    .font(AppStyle.Fonts.title)
                Text("home.welcome")
                    .font(.title2)
                Text("home.description")
                    .font(AppStyle.Fonts.body)
                    .foregroundStyle(AppStyle.Colors.secondaryText)
            }
            .frame(maxWidth: AppStyle.Layout.readableContentWidth, alignment: .leading)
            .padding(AppStyle.Spacing.large)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(preferences.language.localizedString("navigation.home"))
    }
}
