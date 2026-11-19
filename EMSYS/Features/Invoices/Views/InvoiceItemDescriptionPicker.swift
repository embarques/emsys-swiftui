import SwiftUI

/// Lets the user enter a description or select one from the available item catalog.
struct InvoiceItemDescriptionPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(NetworkConnection.self) private var connection
    @State private var text: String
    @State private var selectedItem: InvoiceCatalogItem?
    @State private var selection: TextSelection?
    @FocusState private var isDescriptionFocused: Bool

    private let model: InvoiceDraftEditorViewModel
    private let onConfirm: (String) -> Void

    /// Starts from the current description so an existing line can be edited in place.
    init(model: InvoiceDraftEditorViewModel, description: String, onConfirm: @escaping (String) -> Void) {
        self.model = model
        self.onConfirm = onConfirm
        _text = State(initialValue: description)
    }

    /// Allows typing over a catalog choice to enter a custom description.
    private var editableDescription: Binding<String> {
        Binding {
            text
        } set: { value in
            // Editing the text replaces a pending catalog choice with a manual entry.
            text = value
            selectedItem = nil
        }
    }

    /// Enables confirmation once the description is usable and the choice is authorized.
    private var canConfirm: Bool {
        // Manual entry is available without catalog permission.
        let hasDescription = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard let selectedItem else {
            return hasDescription
        }
        return hasDescription && selectedItem.isValid && model.canChooseCatalogItems
    }

    /// Uses one editable description to filter catalog suggestions and confirm manual or extended text.
    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("itemCatalog.enterDescription", text: editableDescription, selection: $selection, axis: .vertical)
                        .focused($isDescriptionFocused)
                }
                // The picker remains usable for manual entry when the catalog is unavailable.
                if model.canChooseCatalogItems {
                    catalogSection
                }
            }
            .refreshable { await reloadCatalog() }
            .navigationTitle("invoiceEdits.description")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("invoiceEdits.cancel", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("drafts.finishItem", systemImage: "checkmark", action: confirm)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderedProminent)
                        .disabled(!canConfirm)
                }
            }
            .task { await reloadCatalog() }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 480)
        #endif
    }

    /// Lists catalog descriptions and marks the pending selection.
    private var catalogSection: some View {
        Section("itemCatalog.title") {
            // Keep cached descriptions actionable when refresh fails.
            if model.isLoadingCatalog {
                ProgressView()
            }
            if let issue = model.catalogIssue {
                Text(LocalizedStringKey(issue)).foregroundStyle(.secondary)
                Button("itemCatalog.refresh") { Task { await reloadCatalog() } }
                    .disabled(model.isLoadingCatalog)
            }
            if model.catalogIsDownloaded {
                Text("itemCatalog.offlineHint").font(.caption).foregroundStyle(.secondary)
            }

            // The entered description is also the search term for catalog suggestions.
            let matches = InvoiceCatalogItem.matching(model.catalogItems, query: text)
            if matches.isEmpty && !model.isLoadingCatalog {
                Text("itemCatalog.empty").foregroundStyle(.secondary)
            }
            ForEach(matches) { item in
                catalogRow(item)
            }
        }
    }

    /// Marks the tapped description and leaves the sheet open for confirmation.
    private func catalogRow(_ item: InvoiceCatalogItem) -> some View {
        let isSelected = selectedItem?.id == item.id
        return Button {
            // Fill the single field and position the cursor for appending a custom suffix.
            text = item.name
            selectedItem = item
            selection = TextSelection(insertionPoint: text.endIndex)
            isDescriptionFocused = true
        } label: {
            HStack(spacing: AppStyle.Spacing.medium) {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
                    .opacity(isSelected ? 1 : 0)
                    .accessibilityHidden(true)
                Text(item.name)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Loads downloaded catalog entries and refreshes them when connected.
    private func reloadCatalog() async {
        // Leave manual entry available without trying to load an unauthorized catalog.
        if model.canChooseCatalogItems {
            await model.loadItemCatalog(online: connection.status != .unavailable)
        }
    }

    /// Applies the description only after the user taps the checkmark.
    private func confirm() {
        // Recheck permissions in case they changed while the sheet was open.
        guard canConfirm else {
            return
        }
        onConfirm(text)
        dismiss()
    }
}
