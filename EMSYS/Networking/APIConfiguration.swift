import Foundation

nonisolated enum APIConfiguration {
    static let defaultRoot = "https://api.embarqueros.com/v1"

    static var baseURL: URL? {
        URL(string: Bundle.main.object(forInfoDictionaryKey: "EMSYSAPIBaseURL") as? String ?? defaultRoot)
    }
}
