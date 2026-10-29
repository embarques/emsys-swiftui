import PDFKit
import SwiftUI

#if os(macOS)
struct PrintDocumentButton: View {
    let document: InvoiceDocument
    let isAuthorized: () -> Bool

    var body: some View {
        Button {
            guard isAuthorized() else { return }
            InvoicePrintConfiguration.operation(pdf: document.pdf)?.run()
        } label: {
            Label("documents.print", systemImage: "printer")
        }
    }
}
#else
struct PrintDocumentButton: UIViewRepresentable {
    @Environment(AppPreferences.self) private var preferences
    let document: InvoiceDocument
    let isAuthorized: () -> Bool

    final class Coordinator {
        var pdf = Data()
        var isAuthorized: () -> Bool = { false }

        func printDocument(from button: UIButton) {
            guard isAuthorized() else { return }
            let controller = UIPrintInteractionController.shared
            InvoicePrintConfiguration.configure(controller, pdf: pdf)
            controller.present(from: button.bounds, in: button, animated: true)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        let coordinator = context.coordinator
        button.addAction(UIAction { [weak button, weak coordinator] _ in
            guard let button else { return }
            coordinator?.printDocument(from: button)
        }, for: .primaryActionTriggered)
        configure(button, coordinator: coordinator)
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        configure(button, coordinator: context.coordinator)
    }

    private func configure(_ button: UIButton, coordinator: Coordinator) {
        coordinator.pdf = document.pdf
        coordinator.isAuthorized = isAuthorized
        var configuration = UIButton.Configuration.plain()
        configuration.title = preferences.language.localizedString("documents.print")
        configuration.image = UIImage(systemName: "printer")
        configuration.imagePadding = 6
        button.configuration = configuration
        button.isEnabled = UIPrintInteractionController.isPrintingAvailable && isAuthorized()
    }
}
#endif
