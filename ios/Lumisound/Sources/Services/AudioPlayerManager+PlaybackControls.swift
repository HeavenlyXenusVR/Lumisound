@preconcurrency import AVFoundation
import AudioToolbox
import Foundation
import MediaPlayer
import UIKit

extension AudioPlayerManager {

    // MARK: - Public Playback Controls

    func setQueue(_ songs: [Song], startIndex: Int = 0, autoplay: Bool = true, playlistID: UUID? = nil) {
        guard !songs.isEmpty else { return }
        queue = songs
        currentPlaylistID = playlistID
        currentIndex = min(max(startIndex, 0), songs.count - 1)
        currentSong = queue[currentIndex]
        position = 0
        gaplessScheduled = false
        pendingNextIndex = nil
        // A new queue invalidates any stashed pre-shuffle order from the previous one.
        preShuffleQueue = nil
        if shuffleEnabled {
            shuffleQueue()
        }
        if autoplay {
            playCurrent(from: 0)
        } else {
            prepareCurrent()
        }
        applyAutoEQIfNeeded(bpm: currentSong?.bpm ?? bpmCache[currentSong?.id ?? ""])
    }

    func play(song: Song, in songs: [Song], playlistID: UUID? = nil) {
        let source = songs.isEmpty ? [song] : songs
        let index = source.firstIndex(where: { $0.id == song.id }) ?? 0
        appLog("Play: \"\(song.displayName)\" by \(song.artistName) (\(source.count) in queue)", category: "audio")
        appBreadcrumb("Playing \"\(song.displayName)\"")
        setQueue(source, startIndex: index, autoplay: true, playlistID: playlistID)
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { resume() }
    }

    func pause() {
        // Any pause clears the "resume me after the interruption" memory, so an
        // interruption that ends AFTER the listener has deliberately paused does
        // not start the music up again behind them. The interruption handler sets
        // the flag immediately after calling this, so its own pause still arms it
        // — see handleAudioInterruption.
        wasInterrupted = false
        if isUsingOpusPlayer {
            opusPlayer?.pause()
            isPlaying = false
            updateNowPlaying()
            savePlaybackState()
            armIdleTeardown()
            return
        }
        updatePositionFromPlayer()
        primaryNode.pause()
        secondaryNode.pause()
        isPlaying = false
        stopTimer()
        updateNowPlaying()
        savePlaybackState()
        armIdleTeardown()
        appLog("Paused at \(String(format: "%.1f", position))s — \(currentSong?.displayName ?? "?")", category: "audio")
    }

    /// Arms (or re-arms) the grace-period timer that releases the audio
    /// engine/session if playback is still paused once it fires — see
    /// `teardownEngineIfIdle()`. Called from every `pause()` path.
    private func armIdleTeardown() {
        idleTeardownTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 45, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.teardownEngineIfIdle()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        idleTeardownTimer = timer
    }

    /// Releases the audio engine and deactivates the session if nothing is
    /// currently playing — without this, `pause()` left the engine running
    /// and the session active indefinitely (only the queue-exhausted path
    /// through `stop()` ever tore it down), so the app sat as a "ghost"
    /// active-audio-session app — ducking other apps, keeping the transport
    /// UI live, draining battery — with nothing playing or even scheduled to
    /// resume. Safe to call opportunistically (backgrounding while paused,
    /// the grace-period timer) since it's a no-op once actually playing.
    func teardownEngineIfIdle() {
        idleTeardownTimer?.invalidate()
        idleTeardownTimer = nil
        guard !isPlaying else { return }
        if isUsingOpusPlayer {
            // AVPlayer has no persistent engine/session ownership the way
            // AVAudioEngine does; only the shared session needs releasing.
        } else if engine.isRunning {
            engine.stop()
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func resume() {
        idleTeardownTimer?.invalidate()
        idleTeardownTimer = nil
        if isUsingOpusPlayer {
            // `.play()` always resumes at 1.0× — set `.rate` directly so the
            // user's chosen Speed setting is honored on resume too.
            opusPlayer?.rate = Float(audioSettings.speed)
            isPlaying = true
            updateNowPlaying()
            return
        }
        guard currentSong != nil else {
            if !queue.isEmpty { playCurrent(from: position) }
            return
        }
        // A new track is mid-download/transcode (downloadAndSchedule/
        // transcodeAndSchedule) — `activeNode` still has the OUTGOING
        // track's segment scheduled on it (the switch's own `node.stop()` +
        // reschedule only happens once that async work finishes), so
        // `activeNode.isPlaying` reads `false` the moment something pauses
        // it mid-transition (a system audio interruption ending with
        // `.shouldResume`, or any other `resume()` caller racing the same
        // window) — resuming here would audibly bring back the OLD track,
        // then the new one silently never plays once its own download
        // finally lands (this was the exact "start streaming a cloud track
        // while a local one is playing — the local track keeps/resumes
        // playing and the stream never starts" bug). Once the async
        // scheduling finishes it calls `node.play()`/sets `isPlaying` itself
        // if playback should be active, so there's nothing for this to do
        // here anyway.
        guard !isSchedulingAsync else { return }
        if !activeNode.isPlaying {
            startEngineIfNeeded()
            activeNode.play()
            isPlaying = true
            startTimer()
            updateNowPlaying()
            reapplyActiveEffect()
            appLog("Resumed — \(currentSong?.displayName ?? "?")", category: "audio")
        }
    }

    func stop() {
        tearDownOpusPlayer()
        appLog("Stopped — \(currentSong?.displayName ?? "nothing playing")", category: "audio")
        primaryNode.stop()
        secondaryNode.stop()
        isCrossfading = false
        crossfadeTimer?.invalidate()
        crossfadeTimer = nil
        crossfadeTriggerPosition = nil
        gaplessScheduled = false
        pendingNextIndex = nil
        position = 0
        isPlaying = false
        stopTimer()
        // Stop any active special effects so their CADisplayLinks don't keep firing.
        stop8DRotation()
        stopTremolo()
        stopVibrato()
        // Fully release the audio system when stopped — see
        // `teardownEngineIfIdle()`'s doc comment for why this can't be
        // skipped. The next play() restarts the engine + reactivates the
        // session via `startEngineIfNeeded`.
        teardownEngineIfIdle()
        updateNowPlaying()
    }

    func seek(to newPosition: TimeInterval) {
        let target = max(0, min(newPosition, duration))
        position = target
        if isUsingOpusPlayer {
            opusPlayer?.seek(to: CMTime(seconds: target, preferredTimescale: 600))
            updateNowPlaying()
            return
        }
        gaplessScheduled = false
        pendingNextIndex = nil
        crossfadeTriggerPosition = nil
        if isPlaying {
            playCurrent(from: target)
        } else {
            scheduleCurrent(from: target)
        }
        updateNowPlaying()
        pushPlaybackStateToBridge()
    }

    func skipToNext() {
        guard !queue.isEmpty else { return }
        if repeatMode == .one {
            playCurrent(from: 0)
            return
        }

        // Shuffle mode reorders `queue` itself (see toggleShuffle/shuffleQueue) so the
        // Up Next/Queue UI always matches what plays — just advance sequentially here too.
        let nextIndex = currentIndex + 1

        if nextIndex < queue.count {
            currentIndex = nextIndex
            currentSong = queue[currentIndex]
            gaplessScheduled = false
            pendingNextIndex = nil
            appLog("Skip next → \"\(currentSong?.displayName ?? "?")\"", category: "audio")
            playCurrent(from: 0)
            savePlaybackState()
        } else if repeatMode == .all {
            currentIndex = 0
            currentSong = queue[currentIndex]
            gaplessScheduled = false
            pendingNextIndex = nil
            appLog("Skip next (loop) → \"\(currentSong?.displayName ?? "?")\"", category: "audio")
            playCurrent(from: 0)
            savePlaybackState()
        } else {
            if autoRadioEnabled {
                autoRadioSeed = currentSong
            }
            stop()
        }
    }

    func skipToPrevious() {
        guard !queue.isEmpty else { return }
        if position > 4 {
            seek(to: 0)
            return
        }
        currentIndex = max(currentIndex - 1, 0)
        currentSong = queue[currentIndex]
        gaplessScheduled = false
        pendingNextIndex = nil
        playCurrent(from: 0)
        savePlaybackState()
    }

    func cycleRepeatMode() {
        switch repeatMode {
        case .off:  repeatMode = .all
        case .all:  repeatMode = .one
        case .one:  repeatMode = .off
        }
        updateNowPlaying()
    }

    func toggleShuffle() {
        shuffleEnabled.toggle()
        if shuffleEnabled {
            shuffleQueue()
        } else {
            restoreUnshuffledQueue()
        }
        updateNowPlaying()
    }

    /// Reorders `queue` so everything after the currently-playing track is shuffled —
    /// this keeps the Up Next/Queue UI in sync with what `skipToNext()` will actually
    /// play next, and produces a fresh order every time shuffle is turned on (the
    /// previous unshuffled order is stashed so toggling shuffle off can restore it).
    func shuffleQueue() {
        guard queue.count > 1 else { return }
        if preShuffleQueue == nil {
            preShuffleQueue = queue
        }
        let currentSongID = currentSong?.id
        var rest = queue
        let current = rest.remove(at: currentIndex)
        rest.shuffle()
        let anchorBPM = current.bpm ?? bpmCache[current.id]
        queue = [current] + smartTempoOrder(rest, anchorBPM: anchorBPM)
        currentIndex = queue.firstIndex(where: { $0.id == currentSongID }) ?? 0
        gaplessScheduled = false
        pendingNextIndex = nil
    }

    /// Reorders an already-randomly-shuffled list so tracks with a known BPM
    /// form smoother tempo transitions: each step greedily picks the remaining
    /// known-BPM track closest to the previous track's tempo, avoiding jarring
    /// energetic→sleep whiplash between consecutive songs. Tracks with no
    /// known BPM (not yet analyzed) keep their shuffled relative order and are
    /// interleaved back in at roughly their original positions, so the queue
    /// doesn't degrade into two separate "known" / "unknown" blocks.
    func smartTempoOrder(_ songs: [Song], anchorBPM: Double?) -> [Song] {
        guard songs.count > 2 else { return songs }

        var withBPM: [(offset: Int, song: Song, bpm: Double)] = []
        var withoutBPM: [(offset: Int, song: Song)] = []
        for (offset, song) in songs.enumerated() {
            if let bpm = song.bpm ?? bpmCache[song.id] {
                withBPM.append((offset, song, bpm))
            } else {
                withoutBPM.append((offset, song))
            }
        }
        guard withBPM.count > 1 else { return songs }

        // Sort once by BPM, then walk outward from the entry closest to
        // `anchorBPM`. Because the list is sorted, the globally-nearest
        // remaining track to whichever BPM was picked last is always one of
        // the two entries immediately outside the already-picked contiguous
        // block — so this two-pointer walk produces the exact same order as
        // a naive "rescan everything remaining, every step" greedy search,
        // but in O(n log n) instead of O(n²). The O(n²) version ran
        // synchronously on the main thread on every shuffle; for a large
        // library (thousands of BPM-tagged tracks) that was a real multi-
        // second hang, the same bug class as the hasLocalCopy(of:) main-
        // thread hang fixed in v1.4.30.
        let sorted = withBPM.sorted { $0.bpm < $1.bpm }
        let startAnchor = anchorBPM ?? sorted[0].bpm
        var startIndex = 0
        var bestDiff = Double.greatestFiniteMagnitude
        for (index, entry) in sorted.enumerated() {
            let diff = abs(entry.bpm - startAnchor)
            if diff < bestDiff {
                bestDiff = diff
                startIndex = index
            }
        }

        var ordered: [Song] = [sorted[startIndex].song]
        var lastBPM = sorted[startIndex].bpm
        var lo = startIndex - 1
        var hi = startIndex + 1
        while lo >= 0 || hi < sorted.count {
            let leftDiff = lo >= 0 ? abs(sorted[lo].bpm - lastBPM) : Double.greatestFiniteMagnitude
            let rightDiff = hi < sorted.count ? abs(sorted[hi].bpm - lastBPM) : Double.greatestFiniteMagnitude
            if leftDiff <= rightDiff {
                ordered.append(sorted[lo].song)
                lastBPM = sorted[lo].bpm
                lo -= 1
            } else {
                ordered.append(sorted[hi].song)
                lastBPM = sorted[hi].bpm
                hi += 1
            }
        }

        guard !withoutBPM.isEmpty else { return ordered }
        var result = ordered
        for entry in withoutBPM {
            let fraction = Double(entry.offset) / Double(max(songs.count - 1, 1))
            let insertIndex = min(Int((fraction * Double(result.count)).rounded()), result.count)
            result.insert(entry.song, at: insertIndex)
        }
        return result
    }

    /// Restores the queue order captured before shuffle was turned on.
    func restoreUnshuffledQueue() {
        guard let original = preShuffleQueue else { return }
        let currentSongID = currentSong?.id
        queue = original
        preShuffleQueue = nil
        if let id = currentSongID, let idx = queue.firstIndex(where: { $0.id == id }) {
            currentIndex = idx
        }
        gaplessScheduled = false
        pendingNextIndex = nil
    }
}
