import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case dominicanSpanish = "es-DO"
    case english = "en"

    var id: String { rawValue }
    var locale: Locale { Locale(identifier: rawValue) }
    var displayName: String {
        switch self {
        case .dominicanSpanish: "Español"
        case .english: "English"
        }
    }

    /// Native window titles can resolve outside SwiftUI's locale environment.
    func localizedString(_ key: String, bundle: Bundle = .main) -> String {
        let path = bundle.path(forResource: rawValue, ofType: "lproj")
            ?? bundle.path(forResource: AppLanguage.dominicanSpanish.rawValue, ofType: "lproj")
        let localizedBundle = path.flatMap(Bundle.init(path:)) ?? bundle
        return localizedBundle.localizedString(forKey: key, value: nil, table: nil)
    }
}
