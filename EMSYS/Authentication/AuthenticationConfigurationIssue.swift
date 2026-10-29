import Foundation

/// Installation problems cannot be repaired by logging out or refreshing a token.
enum AuthenticationConfigurationIssue: String {
    case missing = "auth.configuration.missing"
    case identityMismatch = "auth.configuration.identityMismatch"
    case incomplete = "auth.configuration.incomplete"
}
