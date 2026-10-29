import Foundation
import Observation

/// Stores only device preferences. Credentials and business records belong elsewhere.
@MainActor
@Observable
final class AppPreferences {
    private let userDefaults: UserDefaults

    private enum StorageKey {
        static let language = "preferences.language"
        static let appearance = "preferences.appearance"
    }

    var language: AppLanguage {
        didSet { userDefaults.set(language.rawValue, forKey: StorageKey.language) }
    }

    var appearance: AppAppearance {
        didSet { userDefaults.set(appearance.rawValue, forKey: StorageKey.appearance) }
    }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        language = userDefaults.string(forKey: StorageKey.language)
            .flatMap(AppLanguage.init(rawValue:)) ?? .dominicanSpanish
        appearance = userDefaults.string(forKey: StorageKey.appearance)
            .flatMap(AppAppearance.init(rawValue:)) ?? .system
    }
}
