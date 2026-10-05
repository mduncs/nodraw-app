import SwiftUI

@MainActor
final class MediaTransferFeedback: ObservableObject {
    static let shared = MediaTransferFeedback()
    @Published var error: String?
    @Published private(set) var failedURLs: [URL] = []
    @Published private(set) var isRetrying = false
    private var retryTargets: [DeleteService.RetryTarget] = []
    private var retryAction: (([DeleteService.RetryTarget]) async throws -> DeleteService.DeleteResult)?
    private var generation = 0
    var canRetry: Bool { retryAction != nil && !retryTargets.isEmpty }
    func report(_ error: Error) {
        dismiss()
        self.error = error.localizedDescription
    }
    func reportFileFailures(_ messages: [String], urls: [URL], retryTargets: [DeleteService.RetryTarget], service: DeleteService, excludingItemIDs: [UUID] = []) {
        dismiss()
        error = messages.joined(separator: "\n")
        failedURLs = urls
        self.retryTargets = retryTargets
        if !retryTargets.isEmpty {
            retryAction = { targets in try await service.retryTrashFiles(targets, excludingItemIDs: excludingItemIDs) }
        }
    }
    func retry() {
        guard let retryAction, !retryTargets.isEmpty, !isRetrying else { return }
        let targets = retryTargets
        let request = generation
        isRetrying = true
        Task {
            do {
                let result = try await retryAction(targets)
                guard generation == request else { return }
                isRetrying = false
                if result.hasFileErrors {
                    error = result.fileErrors.joined(separator: "\n")
                    failedURLs = result.failedFileURLs
                    retryTargets = result.retryTargets
                } else { dismiss() }
            } catch {
                guard generation == request else { return }
                isRetrying = false
                self.error = error.localizedDescription
            }
        }
    }
    func dismiss() {
        generation += 1
        error = nil
        failedURLs = []
        retryAction = nil
        retryTargets = []
        isRetrying = false
    }
}

struct MediaTransferFeedbackView: View {
    @ObservedObject private var feedback = MediaTransferFeedback.shared
    var body: some View {
        if let error = feedback.error {
            HStack(alignment: .top) {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout).textSelection(.enabled)
                Spacer()
                if !feedback.failedURLs.isEmpty {
                    Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting(feedback.failedURLs) }
                }
                if feedback.canRetry {
                    Button(feedback.isRetrying ? "Retrying…" : "Retry") { feedback.retry() }
                        .disabled(feedback.isRetrying)
                }
                Button("Dismiss") { feedback.dismiss() }
            }
            .padding(8)
            .background(.regularMaterial)
            .accessibilityIdentifier("file-operation-recovery")
        }
    }
}
