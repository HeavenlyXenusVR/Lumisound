import AVFoundation

/// Turns an `AIDJService.sessionLog` into one downloadable audio file — a
/// short clip of each track in the session, back-to-back with Aria's actual
/// spoken transition lines between them.
///
/// Scope note: this concatenates clips SEQUENTIALLY (track clip, then the
/// transition speech, then the next track clip...) rather than reproducing
/// the live experience's ducked-volume OVERLAP (speech starting under the
/// tail of the outgoing track while it fades). True overlapping offline
/// mixing needs AVAudioEngine's manual/offline rendering mode driven frame
/// by frame — real, but a much larger and fiddlier surface for a feature
/// that's fundamentally "save the set so it isn't gone the moment it
/// ends." Sequential splicing via AVMutableComposition is simpler, still a
/// genuine continuous file with the real commentary in the right order,
/// and reuses the same composition approach already proven out in
/// LyricVideoExportService.
@MainActor
final class AIDJSessionExportService: ObservableObject {
    enum State: Equatable {
        case idle
        case rendering(progress: Double)
        case done(URL)
        case failed(String)
    }

    @Published var state: State = .idle

    static let clipDuration: TimeInterval = 20

    func export(log: [AIDJSessionEntry], streaming: StreamingService) async {
        let trackCount = log.reduce(0) { if case .track = $1 { return $0 + 1 } else { return $0 } }
        guard trackCount > 0 else {
            state = .failed("Nothing to export yet — play a few tracks with AI DJ Mode on first.")
            return
        }
        state = .rendering(progress: 0)
        do {
            let url = try await render(log: log, streaming: streaming)
            state = .done(url)
        } catch {
            state = .failed((error as? LocalizedError)?.errorDescription ?? "Couldn't export this session.")
        }
    }

    func reset() { state = .idle }

    private func render(log: [AIDJSessionEntry], streaming: StreamingService) async throws -> URL {
        let composition = AVMutableComposition()
        guard let compTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw AIDJExportError.compositionFailed
        }
        var cursor = CMTime.zero
        let tempDir = FileManager.default.temporaryDirectory
        var scratchFiles: [URL] = []

        for (index, entry) in log.enumerated() {
            state = .rendering(progress: Double(index) / Double(log.count))
            switch entry {
            case .track(let song):
                guard let clipURL = try? await trimmedClip(for: song, streaming: streaming, tempDir: tempDir) else { continue }
                scratchFiles.append(clipURL)
                let asset = AVURLAsset(url: clipURL)
                guard let track = try await asset.loadTracks(withMediaType: .audio).first else { continue }
                let duration = try await asset.load(.duration)
                try compTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: cursor)
                cursor = cursor + duration

            case .transition(let text):
                guard let speechURL = try? await synthesizeToFile(text: text, tempDir: tempDir) else { continue }
                scratchFiles.append(speechURL)
                let asset = AVURLAsset(url: speechURL)
                guard let track = try await asset.loadTracks(withMediaType: .audio).first else { continue }
                let duration = try await asset.load(.duration)
                try compTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: cursor)
                cursor = cursor + duration
            }
        }

        guard cursor.seconds > 0 else { throw AIDJExportError.nothingToExport }

        let outputURL = tempDir.appendingPathComponent("lumisound-ai-dj-set-\(UUID().uuidString).m4a")
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw AIDJExportError.compositionFailed
        }
        export.outputURL = outputURL
        export.outputFileType = .m4a
        await export.export()
        for scratch in scratchFiles { try? FileManager.default.removeItem(at: scratch) }
        guard export.status == .completed else {
            throw AIDJExportError.exportFailed(export.error?.localizedDescription ?? "unknown")
        }
        return outputURL
    }

    /// Same "clip from the middle" idea as `LyricVideoExportService` — a
    /// DJ set samples tracks, it doesn't play them in full.
    private func trimmedClip(for song: Song, streaming: StreamingService, tempDir: URL) async throws -> URL {
        let sourceURL: URL
        if let localURL = song.url, localURL.isFileURL {
            sourceURL = LumisoundExclusiveExtensionService.playableURL(for: localURL)
        } else if let sourceTrackID = song.sourceTrackID {
            let parts = sourceTrackID.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { throw AIDJExportError.noAudio }
            let track = StreamTrack(id: String(parts[1]), title: song.title, artist: song.artist,
                                     durationSeconds: 0, thumbnailURL: "", source: String(parts[0]), youtubeURL: "")
            sourceURL = try await streaming.streamURL(for: track)
        } else {
            throw AIDJExportError.noAudio
        }

        let asset = AVURLAsset(url: sourceURL)
        let fullDuration = try await asset.load(.duration).seconds
        guard fullDuration.isFinite, fullDuration > 0 else { throw AIDJExportError.noAudio }
        let clipDuration = min(Self.clipDuration, fullDuration)
        let clipStart = max(0, (fullDuration - clipDuration) / 2)

        let clipComposition = AVMutableComposition()
        guard let track = try await asset.loadTracks(withMediaType: .audio).first,
              let compTrack = clipComposition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw AIDJExportError.noAudio }
        let range = CMTimeRange(start: CMTime(seconds: clipStart, preferredTimescale: 600),
                                 duration: CMTime(seconds: clipDuration, preferredTimescale: 600))
        try compTrack.insertTimeRange(range, of: track, at: .zero)

        let dest = tempDir.appendingPathComponent("lumisound-dj-clip-\(UUID().uuidString).m4a")
        guard let export = AVAssetExportSession(asset: clipComposition, presetName: AVAssetExportPresetAppleM4A) else {
            throw AIDJExportError.noAudio
        }
        export.outputURL = dest
        export.outputFileType = .m4a
        await export.export()
        guard export.status == .completed else { throw AIDJExportError.noAudio }
        return dest
    }

    /// Renders `text` through `AVSpeechSynthesizer.write(_:toBufferCallback:)`
    /// (the offline/non-speaking-aloud render path, distinct from
    /// `AIDJService`'s live `speak()`) into a standalone audio file.
    private func synthesizeToFile(text: String, tempDir: URL) async throws -> URL {
        let synthesizer = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate

        let dest = tempDir.appendingPathComponent("lumisound-dj-speech-\(UUID().uuidString).caf")
        try? FileManager.default.removeItem(at: dest)

        return try await withCheckedThrowingContinuation { continuation in
            var audioFile: AVAudioFile?
            var resumed = false
            synthesizer.write(utterance) { buffer in
                guard let pcmBuffer = buffer as? AVAudioPCMBuffer else { return }
                if pcmBuffer.frameLength == 0 {
                    // Empty buffer signals completion (per
                    // AVSpeechSynthesizer.write's documented contract).
                    if !resumed {
                        resumed = true
                        if audioFile != nil {
                            continuation.resume(returning: dest)
                        } else {
                            continuation.resume(throwing: AIDJExportError.speechSynthesisFailed)
                        }
                    }
                    return
                }
                do {
                    if audioFile == nil {
                        audioFile = try AVAudioFile(forWriting: dest, settings: pcmBuffer.format.settings)
                    }
                    try audioFile?.write(from: pcmBuffer)
                } catch {
                    if !resumed {
                        resumed = true
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }
}

enum AIDJExportError: LocalizedError {
    case compositionFailed
    case nothingToExport
    case noAudio
    case speechSynthesisFailed
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .compositionFailed: return "Couldn't build the export."
        case .nothingToExport: return "Nothing to export yet."
        case .noAudio: return "A track in this session had no usable audio source."
        case .speechSynthesisFailed: return "Couldn't render Aria's commentary."
        case .exportFailed(let message): return "Export failed (\(message))."
        }
    }
}
