import Foundation

/// Bounds the optional Firebase profile lookup without waiting for the SDK's
/// network timeout. Late callbacks must not resume the same request twice.
@MainActor
enum CompanyProfileLookup {
    typealias Completion = (String?, Error?) -> Void

    static func read(
        timeout: Duration = .seconds(5),
        load: (@escaping Completion) -> Void
    ) async throws -> String? {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            let request = PendingRead(continuation: continuation)
            request.deadline = Task { @MainActor in
                do {
                    try await Task.sleep(for: timeout)
                    request.finish(.failure(URLError(.timedOut)))
                } catch {
                    // A completed lookup cancels its deadline.
                }
            }
            load { companyID, error in
                Task { @MainActor in
                    if let error {
                        request.finish(.failure(error))
                    } else {
                        request.finish(.success(companyID))
                    }
                }
            }
        }
    }

    @MainActor
    private final class PendingRead {
        var deadline: Task<Void, Never>?
        private var continuation: CheckedContinuation<String?, Error>?

        init(continuation: CheckedContinuation<String?, Error>) {
            self.continuation = continuation
        }

        func finish(_ result: Result<String?, Error>) {
            guard let continuation else { return }
            self.continuation = nil
            deadline?.cancel()
            deadline = nil
            continuation.resume(with: result)
        }
    }
}
