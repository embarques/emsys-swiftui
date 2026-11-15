import Observation
import Foundation

@MainActor
@Observable
final class InvoicePreviewViewModel {
    private(set) var isGenerating = false
    var failed = false
    var document: InvoiceDocument?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var generationTask: Task<Void, Never>?
    @ObservationIgnored private var isAuthorized: () -> Bool = { false }

    /// Checks whether the current preview still belongs to an authorized session.
    var isAvailable: Bool { isAuthorized() }

    /// Starts one preview task and publishes its document only if still current.
    @discardableResult
    func generate(isAuthorized: @escaping () -> Bool,
                  operation: @escaping () async throws -> InvoiceDocument) -> Task<Void, Never>? {
        guard !isGenerating, isAuthorized() else {
            return nil
        }
        // Identify this attempt independently of any previous cancelled task.
        let request = UUID()
        generation = request
        self.isAuthorized = isAuthorized
        isGenerating = true
        failed = false
        document = nil
        let task = Task {
            defer {
                // A stale task must never reset a newer preview.
                if generation == request {
                    isGenerating = false
                    generationTask = nil
                }
            }
            do {
                let generated = try await operation()
                guard generation == request, isAuthorized(), !Task.isCancelled else {
                    return
                }
                document = generated
            } catch is CancellationError {
                return
            } catch {
                guard generation == request, isAuthorized(), !Task.isCancelled else {
                    return
                }
                InvoiceLocalPrinting.logPreparationFailure(error)
                failed = true
            }
        }
        generationTask = task
        return task
    }

    /// Dismisses the preview and prevents work already in progress from publishing.
    func cancel() {
        // Invalidate the running task before clearing presentation state.
        generation = UUID()
        generationTask?.cancel()
        generationTask = nil
        isGenerating = false
        document = nil
        failed = false
        isAuthorized = { false }
    }
}
