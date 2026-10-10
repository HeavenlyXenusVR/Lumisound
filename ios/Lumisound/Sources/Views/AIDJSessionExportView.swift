import SwiftUI

/// Export the current AI DJ Mode session (see AIDJService.sessionLog /
/// AIDJSessionExportService) as one downloadable file.
struct AIDJSessionExportView: View {
    let log: [AIDJSessionEntry]

    @StateObject private var service = AIDJSessionExportService()
    @Environment(\.dismiss) private var dismiss

    private var trackCount: Int {
        log.reduce(0) { if case .track = $1 { return $0 + 1 } else { return $0 } }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                switch service.state {
                case .idle:
                    idleContent
                case .rendering(let progress):
                    renderingContent(progress: progress)
                case .done(let url):
                    doneContent(url: url)
                case .failed(let message):
                    failedContent(message)
                }
                Spacer()
            }
            .padding(20)
            .background(GalleryBackgroundView().ignoresSafeArea())
            .navigationTitle("Export AI DJ Set")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private var idleContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "mic.and.signal.meter.fill")
                .font(.system(size: 40))
                .foregroundStyle(AppTheme.dynamicAccent)
            Text(trackCount > 0
                 ? "Saves this session — \(trackCount) track clip\(trackCount == 1 ? "" : "s") with Aria's actual commentary between them — as one file you can keep or share."
                 : "Nothing to export yet. Turn on AI DJ Mode and play a few tracks first.")
                .font(AppTheme.bodyFont(size: 13))
                .foregroundStyle(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
            if trackCount > 0, let streaming = StreamingService.shared {
                Button {
                    Task { await service.export(log: log, streaming: streaming) }
                } label: {
                    Text("Export")
                        .font(AppTheme.bodyFont(size: 15).weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 10)
                        .background(AppTheme.dynamicAccent, in: Capsule())
                }
            }
        }
        .padding(.top, 40)
    }

    private func renderingContent(progress: Double) -> some View {
        VStack(spacing: 14) {
            ProgressView(value: progress)
                .frame(width: 200)
            Text("Mixing the set…")
                .font(AppTheme.bodyFont(size: 13))
                .foregroundStyle(AppTheme.textSecondary)
        }
        .padding(.top, 60)
    }

    private func doneContent(url: URL) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.green)
            Text("Set ready")
                .font(AppTheme.headlineFont(size: 17))
                .foregroundStyle(AppTheme.textPrimary)
            ShareLink(item: url) {
                Text("Share")
                    .font(AppTheme.bodyFont(size: 15).weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 10)
                    .background(AppTheme.dynamicAccent, in: Capsule())
            }
        }
        .padding(.top, 40)
    }

    private func failedContent(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundStyle(.orange)
            Text(message)
                .font(AppTheme.bodyFont(size: 13))
                .foregroundStyle(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
            Button("Try Again") { service.reset() }
                .font(AppTheme.bodyFont(size: 14).weight(.semibold))
        }
        .padding(.top, 40)
    }
}
