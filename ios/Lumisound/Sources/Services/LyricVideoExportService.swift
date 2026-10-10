import AVFoundation
import SwiftUI
import UIKit

/// Renders a short (default 15s), vertical (1080x1920, Stories-sized) video
/// clip of a track: blurred artwork background, the synced lyric line
/// active at each moment, and a simple amplitude-driven bar visualizer —
/// for sharing to Instagram/TikTok/etc. Genuinely new territory for this
/// codebase (no prior video-composition code to mirror — `AudioEncoderService`'s
/// AVAssetWriter usage is audio-only), highest-risk-of-needing-a-fixup-pass
/// of anything built in this batch, for exactly that reason.
///
/// Strategy: render each video frame as a SwiftUI view via `ImageRenderer`
/// (simplest reliable way to rasterize UI-quality frames, far less error-prone
/// than hand-rolled Core Graphics for text/blur/layout), write frames through
/// an `AVAssetWriterInputPixelBufferAdaptor`, then mux that video-only movie
/// with a trimmed copy of the real track audio via `AVMutableComposition`.
@MainActor
final class LyricVideoExportService: ObservableObject {
    enum State: Equatable {
        case idle
        case rendering(progress: Double)
        case done(URL)
        case failed(String)
    }

    @Published var state: State = .idle

    static let outputSize = CGSize(width: 1080, height: 1920)
    static let frameRate: Int32 = 30
    static let clipDuration: TimeInterval = 15

    func export(song: Song, lyrics: [LrcLine], artwork: UIImage?) async {
        state = .rendering(progress: 0)
        do {
            let url = try await render(song: song, lyrics: lyrics, artwork: artwork)
            state = .done(url)
        } catch {
            state = .failed((error as? LocalizedError)?.errorDescription ?? "Couldn't create the clip.")
        }
    }

    func reset() { state = .idle }

    private func render(song: Song, lyrics: [LrcLine], artwork: UIImage?) async throws -> URL {
        guard let songURL = song.url else { throw LyricVideoError.noAudio }
        let playableURL = LumisoundExclusiveExtensionService.playableURL(for: songURL)
        let sourceAsset = AVURLAsset(url: playableURL)
        let fullDuration = try await sourceAsset.load(.duration).seconds
        guard fullDuration.isFinite, fullDuration > 0 else { throw LyricVideoError.noAudio }

        // Center the clip in the track rather than always starting at 0 —
        // intros are routinely silence/build-up, not what you'd want to
        // share. Falls back to the whole track if it's shorter than one clip.
        let clipDuration = min(Self.clipDuration, fullDuration)
        let clipStart = max(0, (fullDuration - clipDuration) / 2)

        let envelope = try await amplitudeEnvelope(url: playableURL, start: clipStart, duration: clipDuration)

        let tempDir = FileManager.default.temporaryDirectory
        let videoOnlyURL = tempDir.appendingPathComponent("lumisound-clip-video-\(UUID().uuidString).mov")
        try await writeVideoFrames(
            song: song, lyrics: lyrics, artwork: artwork, envelope: envelope,
            clipStart: clipStart, clipDuration: clipDuration, outputURL: videoOnlyURL
        )

        let finalURL = tempDir.appendingPathComponent("\(safeFilename(song.title))-clip.mp4")
        try? FileManager.default.removeItem(at: finalURL)
        try await mux(videoOnlyURL: videoOnlyURL, audioAsset: sourceAsset,
                       clipStart: clipStart, clipDuration: clipDuration, outputURL: finalURL)
        try? FileManager.default.removeItem(at: videoOnlyURL)
        return finalURL
    }

    // MARK: - Amplitude envelope (drives the bar visualizer)

    /// One RMS amplitude value per video frame across the clip — cheap
    /// (single pass, no FFT) and more than enough for a few animated bars;
    /// real spectral analysis would be wasted precision for this.
    private func amplitudeEnvelope(url: URL, start: TimeInterval, duration: TimeInterval) async throws -> [Float] {
        try await Task.detached(priority: .utility) {
            guard let file = try? AVAudioFile(forReading: url) else { return [] }
            let sampleRate = file.processingFormat.sampleRate
            let channels = Int(file.processingFormat.channelCount)
            guard channels > 0, sampleRate > 0 else { return [] }

            let startFrame = AVAudioFramePosition(start * sampleRate)
            file.framePosition = max(0, min(startFrame, file.length))

            let frameCount = AVAudioFrameCount(min(Double(file.length - file.framePosition), duration * sampleRate))
            guard frameCount > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount),
                  (try? file.read(into: buffer, frameCount: frameCount)) != nil,
                  let channelData = buffer.floatChannelData
            else { return [] }

            let totalFrames = Int(buffer.frameLength)
            let videoFrameCount = max(1, Int(duration * Double(Self.frameRate)))
            let samplesPerVideoFrame = max(1, totalFrames / videoFrameCount)

            var envelope: [Float] = []
            envelope.reserveCapacity(videoFrameCount)
            var cursor = 0
            while cursor < totalFrames {
                let end = min(cursor + samplesPerVideoFrame, totalFrames)
                var sumSquares: Float = 0
                var count: Float = 0
                for ch in 0..<channels {
                    let p = channelData[ch]
                    for i in cursor..<end {
                        sumSquares += p[i] * p[i]
                        count += 1
                    }
                }
                let rms = count > 0 ? sqrt(sumSquares / count) : 0
                envelope.append(rms)
                cursor = end
            }
            // Normalize to 0...1 against this clip's own peak so quiet
            // sections still animate visibly instead of sitting flat.
            let peak = envelope.max() ?? 1
            guard peak > 0 else { return envelope }
            return envelope.map { min(1, $0 / peak) }
        }.value
    }

    // MARK: - Frame rendering

    private func writeVideoFrames(
        song: Song, lyrics: [LrcLine], artwork: UIImage?, envelope: [Float],
        clipStart: TimeInterval, clipDuration: TimeInterval, outputURL: URL
    ) async throws {
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(Self.outputSize.width),
            AVVideoHeightKey: Int(Self.outputSize.height),
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false

        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: Int(Self.outputSize.width),
            kCVPixelBufferHeightKey as String: Int(Self.outputSize.height),
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: pixelBufferAttributes)
        writer.add(input)

        guard writer.startWriting() else {
            throw LyricVideoError.writerFailed(writer.error?.localizedDescription ?? "unknown")
        }
        writer.startSession(atSourceTime: .zero)

        let totalFrames = max(1, Int(clipDuration * Double(Self.frameRate)))

        for frameIndex in 0..<totalFrames {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            let t = Double(frameIndex) / Double(Self.frameRate)
            let lyricText = activeLyric(lyrics, at: clipStart + t)
            let amplitude = frameIndex < envelope.count ? envelope[frameIndex] : 0

            let frameView = LyricVideoFrameView(
                title: song.title, artist: song.artist, artwork: artwork,
                lyricText: lyricText, amplitude: amplitude
            )
            let renderer = ImageRenderer(content: frameView)
            renderer.proposedSize = ProposedViewSize(Self.outputSize)
            renderer.scale = 1

            guard let uiImage = await MainActor.run(body: { renderer.uiImage }),
                  let pixelBuffer = Self.pixelBuffer(from: uiImage, size: Self.outputSize)
            else { continue }

            let presentationTime = CMTime(value: CMTimeValue(frameIndex), timescale: Self.frameRate)
            adaptor.append(pixelBuffer, withPresentationTime: presentationTime)

            if frameIndex % 10 == 0 {
                state = .rendering(progress: Double(frameIndex) / Double(totalFrames))
            }
        }

        input.markAsFinished()
        await writer.finishWriting()
        if writer.status == .failed {
            throw LyricVideoError.writerFailed(writer.error?.localizedDescription ?? "unknown")
        }
    }

    private func activeLyric(_ lyrics: [LrcLine], at time: TimeInterval) -> String {
        var current = ""
        for line in lyrics where line.time <= time {
            current = line.text
        }
        return current
    }

    private static func pixelBuffer(from image: UIImage, size: CGSize) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, Int(size.width), Int(size.height),
            kCVPixelFormatType_32ARGB, attrs as CFDictionary, &pixelBuffer
        )
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ), let cgImage = image.cgImage else { return nil }

        context.draw(cgImage, in: CGRect(origin: .zero, size: size))
        return buffer
    }

    // MARK: - Mux video + trimmed audio

    private func mux(videoOnlyURL: URL, audioAsset: AVURLAsset, clipStart: TimeInterval, clipDuration: TimeInterval, outputURL: URL) async throws {
        let videoAsset = AVURLAsset(url: videoOnlyURL)
        let composition = AVMutableComposition()

        guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first,
              let compVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw LyricVideoError.muxFailed }
        let videoDuration = try await videoAsset.load(.duration)
        try compVideoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: videoDuration), of: videoTrack, at: .zero)

        if let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first,
           let compAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let range = CMTimeRange(start: CMTime(seconds: clipStart, preferredTimescale: 600),
                                     duration: CMTime(seconds: clipDuration, preferredTimescale: 600))
            try? compAudioTrack.insertTimeRange(range, of: audioTrack, at: .zero)
        }

        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw LyricVideoError.muxFailed
        }
        export.outputURL = outputURL
        export.outputFileType = .mp4
        await export.export()
        guard export.status == .completed else {
            throw LyricVideoError.writerFailed(export.error?.localizedDescription ?? "mux failed")
        }
    }

    private func safeFilename(_ title: String) -> String {
        title.replacingOccurrences(of: "/", with: "-").prefix(60).description
    }
}

enum LyricVideoError: LocalizedError {
    case noAudio
    case writerFailed(String)
    case muxFailed

    var errorDescription: String? {
        switch self {
        case .noAudio: return "This track has no audio to use."
        case .writerFailed(let message): return "Couldn't render the clip (\(message))."
        case .muxFailed: return "Couldn't combine video and audio."
        }
    }
}

/// One rendered frame: blurred artwork fill, title/artist, the active lyric
/// line, and a simple amplitude-driven bar row.
private struct LyricVideoFrameView: View {
    let title: String
    let artist: String
    let artwork: UIImage?
    let lyricText: String
    let amplitude: Float

    var body: some View {
        ZStack {
            if let artwork {
                Image(uiImage: artwork)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 40)
                    .overlay(Color.black.opacity(0.45))
            } else {
                LinearGradient(colors: [.black, .purple.opacity(0.4)], startPoint: .top, endPoint: .bottom)
            }

            VStack {
                Spacer()
                if let artwork {
                    Image(uiImage: artwork)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 260, height: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .shadow(radius: 20)
                }

                VStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                    if !artist.isEmpty {
                        Text(artist)
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
                .padding(.top, 24)

                Spacer()

                HStack(spacing: 6) {
                    ForEach(0..<24, id: \.self) { i in
                        // Each bar gets a fixed phase offset so the row reads as a
                        // waveform shape, not 24 identical bars moving in lockstep —
                        // purely cosmetic, not derived from real per-band frequency data.
                        let shape = (sin(Double(i) * 0.8) + 1) / 2  // 0...1
                        let barHeight = max(10, CGFloat(amplitude) * CGFloat(shape) * 160)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(.white.opacity(0.85))
                            .frame(width: 10, height: barHeight)
                    }
                }
                .frame(height: 170)
                .padding(.bottom, 16)

                Text(lyricText)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 60)
                    .frame(minHeight: 100)
                    .shadow(radius: 8)

                Spacer()
                Text("Lumisound")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.bottom, 40)
            }
        }
        .frame(width: LyricVideoExportService.outputSize.width, height: LyricVideoExportService.outputSize.height)
        .background(Color.black)
    }
}
