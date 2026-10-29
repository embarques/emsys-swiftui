import XCTest
@testable import EMSYS

@MainActor
final class AppLanguageTests: XCTestCase {
    func testBundledTranslationsResolveInBothLanguages() throws {
        let bundle = Bundle(for: AppPreferences.self)
        for (locale, expected) in [("es-DO", "Ajustes"), ("en", "Settings")] {
            let path = try XCTUnwrap(bundle.path(forResource: locale, ofType: "lproj"))
            let localized = try XCTUnwrap(Bundle(path: path))
            XCTAssertEqual(localized.localizedString(forKey: "navigation.settings", value: nil, table: nil), expected)
            let language = try XCTUnwrap(AppLanguage(rawValue: locale))
            XCTAssertEqual(language.localizedString("navigation.settings", bundle: bundle), expected)
            for key in [
                "navigation.home",
                "navigation.menu",
                "navigation.workspace",
                "navigation.work",
                "navigation.preferences",
                "navigation.account",
                "navigation.homeHint",
                "navigation.invoicesHint",
                "navigation.settingsHint",
                "home.welcome",
                "home.description",
                "settings.preferences",
                "settings.language",
                "settings.appearance",
                "settings.devicePreferences",
                "appearance.system",
                "appearance.light",
                "appearance.dark"
            ] {
                XCTAssertNotEqual(localized.localizedString(forKey: key, value: nil, table: nil), key)
            }
        }
    }
}
