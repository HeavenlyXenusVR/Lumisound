import SwiftUI
import AVFoundation

/// Separate Vocals / Instrumental — see StemSeparationService and
/// stem_separation.py (Demucs). A genuinely heavier operation than most of
/// this sheet's neighbors: real server-side AI processing, routinely a
/// minute or more.
struct StemSeparationView: View {
    let song: Song

    @StateObject private var service = StemSeparationService()
    @Environment(\.dismiss) private var dismiss
    @State private var vocalsPlayer: AVAudioPlayer?
    @State private var instrumentalPlayer: AVAudioPlayer?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                header

                switch service.state {
                case .idle:
                    idleContent
                case .uploading, .separating:
                    progressContent
                case .done(let vocalsURL, let instrumentalURL):
                    resultContent(vocalsURL: vocalsURL, instrumentalURL: instrumentalURL)
                case .failed(let message):
                    failedContent(message)
                }

                Spacer()
            }
            .padding(20)
            .background(GalleryBackgroundView().ignoresSafeArea())
            .navigationTitle("Separate Vocals")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        stopPreviewPlayback()
                        dismiss()
                    }
                }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Text(song.title)
                .font(AppTheme.headlineFont(size: 17))
                .foregroundStyle(AppTheme.textPrimary)
                .multilineTextAlignment(.center)
            if !song.artist.isEmpty {
                Text(song.artist)
                    .font(AppTheme.bodyFont(size: 13))
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
        .padding(.top, 12)
    }

    private var idleContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.badge.minus")
                .font(.system(size: 40))
                .foregroundStyle(AppTheme.dynamicAccent)
            Text("Real AI source separation — splits this track into a vocals-only and an instrumental-only version. Takes a minute or more; runs on the server, not on your phone.")
                .font(AppTheme.bodyFont(size: 13))
                .foregroundStyle(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
            Button {
                Task { await service.separate(song: song) }
            } label: {
                Text("Separate")
                    .font(AppTheme.bodyFont(size: 15).weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 10)
                    .background(AppTheme.dynamicAccent, in: Capsule())
            }
        }
    }

    private var progressContent: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text(service.state == .uploading ? "Sending audio…" : "Separating — this can take a few minutes…")
                .font(AppTheme.bodyFont(size: 13))
                .foregroundStyle(AppTheme.textSecondary)
        }
        .padding(.top, 20)
    }

    private func resultContent(vocalsURL: URL, instrumentalURL: URL) -> some View {
        VStack(spacing: 14) {
            stemRow(title: "Vocals", icon: "music.mic", url: vocalsURL, player: $vocalsPlayer, otherPlayer: $instrumentalPlayer)
            stemRow(title: "Instrumental", icon: "guitars", url: instrumentalURL, player: $instrumentalPlayer, otherPlayer: $vocalsPlayer)
        }
    }

    private func stemRow(title: String, icon: String, url: URL, player: Binding<AVAudioPlayer?>, otherPlayer: Binding<AVAudioPlayer?>) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(AppTheme.dynamicAccent)
                .frame(width: 28)
            Text(title)
                .font(AppTheme.bodyFont(size: 15))
                .foregroundStyle(AppTheme.textPrimary)
            Spacer()
            Button {
                togglePreview(url: url, player: player, otherPlayer: otherPlayer)
            } label: {
                Image(systemName: (player.wrappedValue?.isPlaying ?? false) ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(AppTheme.dynamicAccent)
            }
            ShareLink(item: url) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 16))
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
        .padding(14)
        .background(AppTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
            Button("Try Again") {
                service.reset()
            }
            .font(AppTheme.bodyFont(size: 14).weight(.semibold))
        }
    }

    private func togglePreview(url: URL, player: Binding<AVAudioPlayer?>, otherPlayer: Binding<AVAudioPlayer?>) {
        otherPlayer.wrappedValue?.pause()
        if let existing = player.wrappedValue {
            if existing.isPlaying {
                existing.pause()
            } else {
                existing.play()
            }
            return
        }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            let newPlayer = try AVAudioPlayer(contentsOf: url)
            newPlayer.play()
            player.wrappedValue = newPlayer
        } catch {
            appWarn("StemSeparationView: preview playback failed: \(error.localizedDescription)", category: "audio")
        }
    }

    private func stopPreviewPlayback() {
        vocalsPlayer?.stop()
        instrumentalPlayer?.stop()
    }
}
