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
