import Foundation

/// The API returns an expiring download location, not the document bytes.
/// Download URLs must never receive the API's bearer or company headers.
struct GeneratedReport: Decodable {
    let reportID: String
    let fileName: String
    let url: URL
    let expiresAt: String
    let engine: String?

    private enum CodingKeys: String, CodingKey {
        case fileName, url, expiresAt, engine
        case reportID = "reportId"
    }
}
