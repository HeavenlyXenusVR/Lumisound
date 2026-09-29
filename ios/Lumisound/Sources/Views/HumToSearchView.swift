import AVFoundation
import SwiftUI

// MARK: - HumToSearchView
//
// UI for PitchContourService (see that file's doc comment for the honest
// scope/limitations — this is a best-effort, key-independent melodic-
// contour match against the user's own downloaded library, not a lab-grade
// query-by-humming system and not a search of any external database).
struct HumToSearchView: View {
    @EnvironmentObject private var library: LibraryManager
    @EnvironmentObject private var player: AudioPlayerManager
    @Environment(\.dismiss) private var dismiss

    private enum Stage: Equatable {
        case idle
        case recording
        case analyzing
        case results
        case permissionDenied
    }

    @State private var stage: Stage = .idle
    @State private var recorder: AVAudioRecorder?
    @State private var recordingURL: URL?
    @State private var elapsed: TimeInterval = 0
    @State private var recordTimer: Timer?
    @State private var matches: [PitchContourService.Match] = []
    @State private var errorText: String?

    private static let maxRecordSeconds: TimeInterval = 8

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                switch stage {
                case .idle:
                    idleState
                case .recording:
                    recordingState
                case .analyzing:
                    analyzingState
                case .results:
                    resultsState
                case .permissionDenied:
                    permissionDeniedState
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Hum to Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        stopRecording(cancelled: true)
                        dismiss()
                    }
                }
            }
        }
    }

    private var idleState: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform")
                .font(.system(size: 48))
                .foregroundStyle(AppTheme.dynamicAccent)
            Text("Hum a few seconds of the tune")
                .font(.headline)
            Text("Searches your own downloaded library by melody — a best-effort match, not exact recognition.")
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            Button {
                startRecording()
            } label: {
                Label("Start Humming", systemImage: "mic.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.dynamicAccent)
        }
    }

    private var recordingState: some View {
        VStack(spacing: 16) {
            Image(systemName: "mic.fill")
                .font(.system(size: 48))
                .foregroundStyle(.red)
            Text(String(format: "%.0fs / %.0fs", elapsed, Self.maxRecordSeconds))
                .font(.system(.title2, design: .rounded).weight(.semibold))
            Button {
                stopRecording(cancelled: false)
            } label: {
                Label("Stop & Search", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
    }

    private var analyzingState: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Listening to your library…")
                .font(.subheadline)
                .foregroundStyle(AppTheme.textSecondary)
            Text("The first search can take a moment while unanalyzed tracks are processed.")
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
    }

    private var resultsState: some View {
        VStack(alignment: .leading, spacing: 12) {
            if matches.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 32))
                        .foregroundStyle(AppTheme.textSecondary)
                    Text("No confident matches")
                        .font(.headline)
                    Text("Try humming a more distinctive part of the melody, a bit longer.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                Text("Possible Matches")
                    .font(.headline)
                List(matches) { match in
                    if let song = library.songsByID[match.songID] {
                        Button {
                            player.play(song: song, in: [song])
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(song.title)
                                        .foregroundStyle(AppTheme.textPrimary)
                                        .lineLimit(1)
                                    Text(song.artist)
                                        .font(.caption)
                                        .foregroundStyle(AppTheme.textSecondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Text("\(Int(match.score * 100))%")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(AppTheme.dynamicAccent)
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
            Button {
                stage = .idle
                matches = []
            } label: {
                Text("Try Again")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    private var permissionDeniedState: some View {
        VStack(spacing: 10) {
            Image(systemName: "mic.slash")
                .font(.system(size: 32))
                .foregroundStyle(AppTheme.textSecondary)
            Text("Microphone Access Needed")
                .font(.headline)
            Text("Enable microphone access in Settings to use Hum to Search.")
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        }
    }

    // MARK: - Recording

    private func startRecording() {
        errorText = nil
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            DispatchQueue.main.async {
                guard granted else {
                    stage = .permissionDenied
                    return
                }
                beginRecordingSession()
            }
        }
    }

    private func beginRecordingSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)
        } catch {
            errorText = "Couldn't access the microphone: \(error.localizedDescription)"
            return
        }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hum_\(UUID().uuidString).caf")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 8_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        do {
            let newRecorder = try AVAudioRecorder(url: url, settings: settings)
            newRecorder.record(forDuration: Self.maxRecordSeconds)
            recorder = newRecorder
            recordingURL = url
        } catch {
            errorText = "Couldn't start recording: \(error.localizedDescription)"
            return
        }

        elapsed = 0
        stage = .recording
        recordTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            elapsed += 0.1
            if elapsed >= Self.maxRecordSeconds {
                stopRecording(cancelled: false)
            }
        }
    }

    private func stopRecording(cancelled: Bool) {
        recordTimer?.invalidate()
        recordTimer = nil
        recorder?.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        guard !cancelled, let url = recordingURL else {
            stage = .idle
            return
        }
        stage = .analyzing
        Task {
            let songs = library.importedSongs.compactMap { song -> (id: String, url: URL)? in
                guard let songURL = song.url else { return nil }
                return (song.id, songURL)
            }
            matches = await PitchContourService.shared.search(humURL: url, songs: songs)
            try? FileManager.default.removeItem(at: url)
            stage = .results
        }
    }
}
