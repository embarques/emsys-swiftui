import Observation
import SwiftUI

@MainActor
@Observable
final class InvoicePreviewModel {
    private(set) var isGenerating = false
    var failed = false
    var document: InvoiceDocument?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var generationTask: Task<Void, Never>?
    @ObservationIgnored private var isAuthorized: () -> Bool = { false }

    var isAvailable: Bool { isAuthorized() }

    @discardableResult
    func generate(isAuthorized: @escaping () -> Bool,
                  operation: @escaping () async throws -> InvoiceDocument) -> Task<Void, Never>? {
        guard !isGenerating, isAuthorized() else { return nil }
        let request = UUID()
        generation = request
        self.isAuthorized = isAuthorized
        isGenerating = true
        failed = false
        document = nil
        let task = Task {
            defer {
                if generation == request { isGenerating = false; generationTask = nil }
            }
            do {
                let generated = try await operation()
                guard generation == request, isAuthorized(), !Task.isCancelled else { return }
                document = generated
            } catch is CancellationError {
                return
            } catch {
                guard generation == request, isAuthorized(), !Task.isCancelled else { return }
                InvoiceLocalPrinting.logPreparationFailure(error)
                failed = true
            }
        }
        generationTask = task
        return task
    }

    func cancel() {
        generation = UUID()
        generationTask?.cancel()
        generationTask = nil
        isGenerating = false
        document = nil
        failed = false
        isAuthorized = { false }
    }
}

struct InvoicePreviewModifier: ViewModifier {
    @Bindable var preview: InvoicePreviewModel

    func body(content: Content) -> some View {
        content
            #if os(iOS)
            .fullScreenCover(item: $preview.document, onDismiss: { preview.cancel() }) { document in
                InvoiceGeneratedDocumentView(document: document, isAuthorized: { preview.isAvailable })
            }
            #else
            .sheet(item: $preview.document, onDismiss: { preview.cancel() }) { document in
                InvoiceGeneratedDocumentView(document: document, isAuthorized: { preview.isAvailable })
            }
            #endif
            .overlay {
                if preview.isGenerating { ProgressView().padding().background(.regularMaterial, in: .capsule) }
            }
            .alert("documents.localPrintError", isPresented: $preview.failed) {
                Button("documents.close", role: .cancel) { }
            }
    }
}
