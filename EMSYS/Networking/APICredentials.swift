import Foundation

struct APICredentials: Equatable {
    let sessionID: UUID
    let userID: String
    let companyID: String
    let idToken: String
}
