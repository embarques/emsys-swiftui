import SwiftUI

struct UnavailableDestinationView: View {
    let destination: AppDestination
    let isAuthorized: Bool

    var body: some View {
        ContentUnavailableView {
            Label(destination.title, systemImage: isAuthorized ? destination.systemImageName : "lock")
        } description: {
            Text(isAuthorized ? "navigation.notReady" : "auth.unavailable")
        }
        .navigationTitle(destination == .dailyIncome ? Text("navigation.dailyIncomeTitle") : Text(destination.title))
    }
}
