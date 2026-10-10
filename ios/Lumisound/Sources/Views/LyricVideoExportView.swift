import SwiftUI

/// Share sheet for `LyricVideoExportService` — renders a short vertical
/// clip (visualizer + synced lyric + artwork) sized for Instagram/TikTok
/// Stories.
struct LyricVideoExportView: View {
    let song: Song
    let lyrics: [LrcLine]

    @StateObject private var service = LyricVideoExportService()
    @Environment(\.dismiss) private var dismiss

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
            .navigationTitle("Share as Video")
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
            Image(systemName: "video.badge.waveform")
                .font(.system(size: 40))
                .foregroundStyle(AppTheme.dynamicAccent)
            Text(lyrics.isEmpty
                 ? "Creates a short (15s) vertical video with artwork and a waveform — no synced lyrics are loaded for this track, so it won't include lyric text."
                 : "Creates a short (15s) vertical video with artwork, a waveform, and the synced lyric line, sized for Instagram/TikTok Stories.")
                .font(AppTheme.bodyFont(size: 13))
                .foregroundStyle(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
            Button {
                Task {
                    let artwork = ArtworkService.shared.artwork(for: song)
                    await service.export(song: song, lyrics: lyrics, artwork: artwork)
                }
            } label: {
                Text("Create Clip")
                    .font(AppTheme.bodyFont(size: 15).weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 10)
                    .background(AppTheme.dynamicAccent, in: Capsule())
            }
        }
        .padding(.top, 40)
    }

    private func renderingContent(progress: Double) -> some View {
        VStack(spacing: 14) {
            ProgressView(value: progress)
                .frame(width: 200)
            Text("Rendering…")
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
            Text("Clip ready")
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
