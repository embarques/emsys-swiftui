import XCTest
@testable import EMSYS

@MainActor
final class AppPreferencesTests: XCTestCase {
    func testPreferenceDefaultsAndPersistence() throws {
        let name = "EMSYS.Tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = AppPreferences(userDefaults: defaults)
        XCTAssertEqual(preferences.language, .dominicanSpanish)
        XCTAssertEqual(preferences.appearance, .system)
        XCTAssertNil(preferences.appearance.colorScheme)
        preferences.language = .english
        preferences.appearance = .dark
        let restored = AppPreferences(userDefaults: defaults)
        XCTAssertEqual(restored.language, .english)
        XCTAssertEqual(restored.appearance, .dark)
        XCTAssertEqual(restored.appearance.colorScheme, .dark)
        preferences.appearance = .light
        XCTAssertEqual(AppPreferences(userDefaults: defaults).appearance, .light)
    }

    func testUnknownStoredPreferencesRecoverToDefaults() throws {
        let name = "EMSYS.Tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("unknown", forKey: "preferences.language")
        defaults.set("unknown", forKey: "preferences.appearance")
        let preferences = AppPreferences(userDefaults: defaults)
        XCTAssertEqual(preferences.language, .dominicanSpanish)
        XCTAssertEqual(preferences.appearance, .system)
    }
}
