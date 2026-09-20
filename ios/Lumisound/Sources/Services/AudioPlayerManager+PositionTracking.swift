@preconcurrency import AVFoundation
import AudioToolbox
import Foundation
import MediaPlayer
import UIKit

extension AudioPlayerManager {

    // MARK: - Position Tracking

    func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.timerTick()
            }
        }
    }

    func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    func timerTick() {
        updatePositionFromPlayer()

        // Checked immediately after the position refresh, and before anything
        // that might change tracks, so the fade is judged against the freshest
        // reading of where the audio actually is.
        checkCrossfadeTrigger()

        bridgePushTickCounter += 1
        if bridgePushTickCounter >= 10 {
            bridgePushTickCounter = 0
            pushPlaybackStateToBridge()
        }

        // Belt-and-braces recovery: if we think we're playing but the engine has
        // silently stopped (and no interruption/route/config-change notification
        // fired to tell us), restart it here. Without this, `isPlaying` stays true
        // forever with no audio and no track advance — the "music randomly stops"
        // bug — until the user manually pauses/resumes.
        if isPlaying, !isUsingOpusPlayer, !engine.isRunning {
            handleEngineConfigurationChange()
        }

        checkForPlaybackStall()

        // AB Repeat enforcement
        if abRepeatEnabled,
           let start = abRepeatStart,
           let end = abRepeatEnd,
           position >= end {
            seek(to: start)
        }

        // Keep the lock screen / Apple Watch / CarPlay "Now Playing" elapsed time and
        // playback-rate in sync with actual position — without this, those surfaces
        // only refresh on play/pause/track-change events and can visibly drift from
        // (or briefly disagree with) the in-app scrubber.
        updateNowPlaying()
    }

    /// Catches the case where the engine is running, we believe we are playing,
    /// and yet no audio is being rendered.
    ///
    /// The existing recovery above only notices a STOPPED engine. It cannot see the
    /// worse version: an engine that is running perfectly with nothing scheduled on
    /// its player node, which renders silence indefinitely while `isPlaying` stays
    /// true. Two real paths lead there, and both were live:
    ///
    ///   * `AVAudioEngineConfigurationChange` (logged 252 times across 27 accounts)
    ///     restarts the engine and calls `play()` again, but never re-schedules the
    ///     track — and a configuration change can invalidate the graph, taking the
    ///     scheduled segment with it.
    ///   * The rebuild inside `startEngineIfNeeded` calls `engine.reset()`, which
    ///     detaches every node and clears what was scheduled on them. `play()` on a
    ///     node with nothing left to play is silent.
    ///
    /// Rather than guess which happened, this watches the only thing that actually
    /// settles it: `position` is derived from frames the engine has RENDERED, so if
    /// it is not moving then audio is not flowing, whatever the engine claims. The
    /// track is then re-scheduled from where it had got to, which is the one repair
    /// that works for both causes.
    func checkForPlaybackStall() {
        // Every condition here is a state where position legitimately does not
        // advance, and treating any of them as a stall would restart playback on
        // top of itself.
        guard isPlaying, !isUsingOpusPlayer, engine.isRunning,
              !isCrossfading, !isSchedulingAsync,
              currentSong != nil,
              duration > 0, position < duration - 1.0
        else {
            stalledTickCount = 0
            lastStallCheckPosition = position
            return
        }

        // A tick is 0.5s, so anything genuinely playing moves well beyond this.
        if position > lastStallCheckPosition + 0.05 {
            stalledTickCount = 0
            lastStallCheckPosition = position
            return
        }

        stalledTickCount += 1
        // Six ticks — three seconds of believing we play while rendering nothing.
        // Deliberately not shorter: a brief hitch under load can stall the render
        // for a tick or two, and restarting playback over that would be worse than
        // the hitch.
        guard stalledTickCount >= 6 else { return }

        let resumeAt = position
        stalledTickCount = 0
        lastStallCheckPosition = resumeAt
        appWarn("Playback stalled — engine running but position frozen at \(String(format: "%.1f", resumeAt))s for 3s; rescheduling \"\(currentSong?.displayName ?? "?")\"", category: "audio")
        RemoteLogger.logError(category: "audio", event: "playback_stall_recovered",
                              message: "position frozen at \(Int(resumeAt))s",
                              detail: ["position": Int(resumeAt), "duration": Int(duration)])
        playCurrent(from: resumeAt)
    }

    /// Starts the crossfade once playback actually reaches
    /// `crossfadeTriggerPosition`.
    ///
    /// This replaced a wall-clock `Timer` — see `crossfadeTriggerPosition` for
    /// what that timer did wrong (pausing, then resuming, skipped the song).
    /// Running on the existing 0.5s tick means the check is driven by rendered
    /// audio and cannot fire while paused, because `pause()` stops the tick.
    ///
    /// 0.5s of granularity is immaterial here: the fade it starts runs for
    /// seconds, and the trigger point is itself an estimate of where the music
    /// stops (see `transitionLead`).
    func checkCrossfadeTrigger() {
        guard let trigger = crossfadeTriggerPosition else { return }
        guard isPlaying, !isCrossfading, !isUsingOpusPlayer else { return }
        // A zero/unknown duration means the track isn't really loaded yet;
        // triggering against a position of 0 would fade out of a track that has
        // not started.
        guard duration > 0, position >= trigger else { return }
        // Cleared BEFORE beginning, so a fade that somehow takes longer than one
        // tick cannot be started twice. `beginCrossfade` re-arms it for whatever
        // track becomes current.
        crossfadeTriggerPosition = nil
        appLog("Crossfade trigger reached at \(String(format: "%.1f", position))s of \(String(format: "%.1f", duration))s — \(currentSong?.displayName ?? "?")", category: "audio")
        beginCrossfade()
    }

    /// Mirrors the current track/position to the bridge (`/user/playback-state`)
    /// so other surfaces — e.g. the local Discord Rich Presence daemon — can
    /// show what this account is currently playing. Fires on play/pause/track
    /// changes and roughly every 5s during playback; no-ops if not logged in.
    func pushPlaybackStateToBridge() {
        AccountService.shared?.pushPlaybackState(
            song: currentSong,
            position: position,
            duration: duration,
            isPlaying: isPlaying,
            bpm: currentSong.flatMap { $0.bpm ?? bpmCache[$0.id] }
        )
        pushPodcastProgressIfNeeded()
    }

    /// Podcast episodes (see PodcastEpisodesView) are constructed as a plain
    /// `Song` with `genre = "Podcast"` and `album` repurposed to carry the
    /// episode's feed URL — `Song` has no dedicated podcast fields, and
    /// adding one would touch every `Song` call site/decoder for a value
    /// only this one flow needs. `id` is the episode's stable RSS guid.
    /// Same 5s-during-playback cadence as the music playback-state push
    /// above, piggybacking on the same timer tick rather than a second one.
    private func pushPodcastProgressIfNeeded() {
        guard let song = currentSong, song.genre == "Podcast", !song.album.isEmpty else { return }
        let completed = duration > 0 && position >= duration - 5
        Task {
            await AccountService.shared?.updatePodcastEpisodeProgress(
                feedURL: song.album,
                episodeGuid: song.id,
                title: song.title,
                position: position,
                duration: duration,
                completed: completed
            )
        }
    }

    /// Logs the current track to `/user/history` (`AccountService.logPlay`)
    /// ~5s after it starts playing — long enough to filter out rapid skips,
    /// but soon enough that a linked Discord "Now Playing" webhook and any
    /// Last.fm/ListenBrainz scrobble reflect the track the user is actually
    /// listening to. Without this, play history was never recorded and those
    /// integrations silently never fired.
    func scheduleHistoryLog() {
        historyLogTask?.cancel()
        guard let song = currentSong else { return }
        historyLogTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, let self else { return }
            guard self.currentSong?.id == song.id else { return }
            // Local play-history for the on-device Smart Playlists/Stats
            // features — same "still on this track 5s later" threshold as
            // the server-bound log below, so an instant skip doesn't count.
            PlayHistoryStore.shared.recordPlay(songID: song.id)
            await AccountService.shared?.logPlay(
                song: song,
                listenSeconds: Int(self.position),
                bpm: song.bpm ?? self.bpmCache[song.id]
            )
        }
    }

    /// Mirrors the "up next" queue to the bridge (`/user/queue`), debounced so
    /// rapid changes (drag-reorder, batch removals) don't fire a request per
    /// edit. No-ops if not logged in.
    func pushQueueToBridge() {
        queuePushTask?.cancel()
        let snapshot = queue
        queuePushTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await AccountService.shared?.pushQueue(snapshot)
        }
    }

    func updatePositionFromPlayer() {
        guard !isUsingOpusPlayer else { return }
        // Do not overwrite `position` while an async download is in progress.
        // The position was already set to the seek target in seek()/downloadAndSchedule();
        // letting the timer fire here would clobber it with a stale node time.
        guard !isSchedulingAsync else { return }

        let node = activeNode
        guard let nodeTime = node.lastRenderTime,
              let playerTime = node.playerTime(forNodeTime: nodeTime),
              let file = audioFile
        else { return }

        // Subtract `gaplessBaseFrame` so elapsed time is measured from the start
        // of the CURRENT segment, not the cumulative frame count of every
        // gapless segment played on this node since the last fresh schedule.
        let elapsedFrames = Double(playerTime.sampleTime) - gaplessBaseFrame
        let computed = Double(fileStartFrame) / file.processingFormat.sampleRate
            + elapsedFrames / playerTime.sampleRate
        position = min(duration, max(0, computed))
    }
}
