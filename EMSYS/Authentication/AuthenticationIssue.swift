import Foundation

enum AuthenticationIssue: String, Error {
    case configuration = "auth.error.configuration"
    case signIn = "auth.error.signIn"
    case company = "auth.error.company"
    case authorization = "auth.error.authorization"
    case connection = "auth.error.connection"
    case signOut = "auth.error.signOut"
}
