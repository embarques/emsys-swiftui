import Foundation

struct APIResponse<Value: Decodable>: Decodable {
    let success: Bool
    let data: Value
}

enum APIClientError: Error, Equatable {
    case invalidBaseURL
    case invalidPath
    case missingCredentials
    case sessionChanged
    case invalidResponse
    case httpStatus(Int)
    case unsuccessfulResponse
}

struct APIServerFailure: Error {
    struct Envelope: Decodable {
        struct Details: Decodable { let code: String? }
        let message: String?
        let data: Details?
    }

    let status: Int
    let code: String?
    let message: String?
}
