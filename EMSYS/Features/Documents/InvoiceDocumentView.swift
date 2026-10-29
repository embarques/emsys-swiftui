import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

struct InvoiceDocumentView: View {
    @Environment(AppPreferences.self) private var preferences
    @Environment(NetworkConnection.self) private var connection
    @Environment(SynchronizationState.self) private var synchronization
    @Environment(\.dismiss) private var dismiss
    @State var model: InvoiceDocumentModel
    @State private var includeSender = true
    @State private var receiverID = ""

    var body: some View {
        NavigationStack {
            Group {
                if model.isAvailable {
                    documentContent
                } else {
                    ContentUnavailableView("auth.unavailable", systemImage: "lock")
                }
            }
            .navigationTitle("documents.title")
            .toolbar { Button("documents.close") { dismiss() } }
            .task { await model.load() }
            .onChange(of: synchronization.requestedUploadVersion) { Task { await model.refreshPendingChanges() } }
            .onChange(of: synchronization.lastFinishedAt) { Task { await model.refreshPendingChanges() } }
        }
        .frame(minWidth: 300, minHeight: 450)
    }

    private var documentContent: some View {
        VStack(spacing: AppStyle.Spacing.medium) {
            if model.failed { Text("documents.error").foregroundStyle(.secondary) }
            if model.hasPendingChanges {
                Text("documents.pendingChanges").font(.callout).padding(.horizontal)
                Button("sync.now") { synchronization.requestUpload() }
                    .disabled(synchronization.isRunning || connection.status == .unavailable)
            }
            if let options = model.options {
                VStack(alignment: .leading, spacing: AppStyle.Spacing.small) {
                    if let sender = options.senderSignature {
                        Toggle("documents.includeSender", isOn: $includeSender)
                        Text(sender.signerName).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("documents.noSender").foregroundStyle(.secondary)
                    }
                    Picker("documents.receiver", selection: $receiverID) {
                        Text("documents.noReceiver").tag("")
                        ForEach(options.receiverSignatures) { signature in
                            Text(receiverTitle(signature)).tag(signature.id)
                        }
                    }
                    Button("documents.generate") {
                        Task {
                            await model.generate(includeSender: includeSender && options.senderSignature != nil,
                                receiverID: receiverID, language: preferences.language)
                        }
                    }
                    .disabled(model.isLoading || connection.status == .unavailable)
                }
                .padding(.horizontal)
                .disabled(model.isLoading)
            }
            if model.isLoading { ProgressView() }
            if let document = model.document {
                LabeledContent("documents.savedAt") {
                    Text(document.savedAt, format: .dateTime)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                PDFPreview(document: document)
                HStack {
                    PrintDocumentButton(document: document, isAuthorized: { model.isAvailable })
                        .frame(minWidth: 100, minHeight: 44)
                    ShareLink(item: PDFExport(document: document), preview: SharePreview("EMSYS")) {
                        Label("documents.share", systemImage: "square.and.arrow.up")
                    }
                }
                .padding(.bottom)
            } else if !model.isLoading {
                ContentUnavailableView("documents.empty", systemImage: "doc.richtext")
            }
            if model.options == nil && !model.isLoading {
                Button("auth.retry") { Task { await model.load() } }
                    .disabled(connection.status == .unavailable)
            }
        }
        .padding(.top)
    }

    private func receiverTitle(_ signature: InvoiceSignatureOptions.Receiver) -> String {
        var parts = [signature.signerName]
        if let delivery = signature.deliveryName { parts.append(delivery) }
        if let date = signature.signedDate {
            parts.append(date.formatted(.dateTime.locale(preferences.language.locale)))
        }
        return parts.joined(separator: " · ")
    }
}

nonisolated private struct PDFExport: Transferable {
    let document: InvoiceDocument

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .pdf) { $0.document.pdf }
            .suggestedFileName { "EMSYS-\($0.document.id.uuidString).pdf" }
    }
}
