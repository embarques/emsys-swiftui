import Foundation
import Observation
import OSLog

/// Owns local screen preparation separately from network list loading. A failed
/// or cancelled preparation must leave a retry action, never a permanent spinner.
@MainActor
@Observable
final class InvoiceListLoader {
    private(set) var model: InvoiceListModel?
    private(set) var failed = false
    @ObservationIgnored private var generation = UUID()

    func prepare(timeout: Duration = .seconds(15), using factory: @escaping @MainActor () async throws -> InvoiceListModel) async {
        let token = UUID()
        generation = token
        model = nil
        failed = false
        let operation = Task { try await factory() }
        let deadline = Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
                guard let self, self.generation == token else { return }
                self.failed = true
                operation.cancel()
            } catch { /* Successful preparation or navigation cancels the deadline. */ }
        }
        defer { deadline.cancel() }
        do {
            // Navigation can cancel SwiftUI's presentation task while this
            // screen remains visible. This bounded local operation owns its
            // lifetime; the factory still checks the authenticated context.
            let result = try await operation.value
            guard generation == token, !failed else { return }
            model = result
        } catch {
            let failure = error as NSError
            Logger(subsystem: "com.embarqueros.emsys", category: "InvoicePreparation").error(
                "Local invoice preparation failed: domain=\(failure.domain, privacy: .public) code=\(failure.code) cancelled=\(Task.isCancelled)")
            if generation == token { failed = true }
        }
    }
}
