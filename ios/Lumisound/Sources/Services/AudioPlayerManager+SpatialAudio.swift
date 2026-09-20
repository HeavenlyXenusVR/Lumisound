@preconcurrency import AVFoundation
import AudioToolbox
import Foundation
import MediaPlayer
import UIKit

extension AudioPlayerManager {

    // MARK: - Spatial Audio routing

    /// Wires (or unwires) `AVAudioEnvironmentNode` into the signal path.
    /// When disabled — the default, and the only state existing users ever
    /// see unless they opt in — `limiter` connects straight to
    /// `mainMixerNode`, identical to the graph before this feature existed.
    /// When enabled, the final mix is routed through `spatialSourceMixer` (the
    /// HRTF-positionable source) and `environmentNode` (the binaural
    /// renderer + listener), anchored as a single source in front of the
    /// listener and head-tracked when compatible headphones are connected.
    func setSpatialAudioRouting(_ enabled: Bool, monoEnabled: Bool = false) {
        // Mono downmix only makes sense when spatial audio (which already
        // renders a single HRTF-positioned source) is off.
        let effectiveMono = monoEnabled && !enabled
        guard isEngineConfigured, enabled != isSpatialAudioRouted || effectiveMono != isMonoAudioRouted else { return }
        isSpatialAudioRouted = enabled
        isMonoAudioRouted = effectiveMono

        // This disconnects/reconnects nodes with a *different channel-count
        // format* (mono vs. stereo) than whatever was previously connected —
        // doing that while the engine is actively rendering is what crashed
        // the app when Mono Audio was toggled during playback. Stop first
        // and restart afterward so the topology change happens on a fully
        // stopped graph.
        let wasRunning = engine.isRunning
        if wasRunning { engine.stop() }

        engine.disconnectNodeOutput(limiter)
        engine.disconnectNodeOutput(spatialSourceMixer)
        engine.disconnectNodeOutput(environmentNode)

        if enabled {
            engine.connect(limiter, to: spatialSourceMixer, format: nil)
            // Force MONO on this specific connection so AVAudioEngine downmixes
            // the stereo bed at the boundary and the environment node treats it
            // as a single point source — genuinely HRTF-spatialized. Leaving
            // this connection stereo (format: nil) would instead pass it
            // through as an unspatialized ambient bed, i.e. do nothing audible.
            let monoFormat = AVAudioFormat(
                standardFormatWithSampleRate: spatialSourceMixer.outputFormat(forBus: 0).sampleRate,
                channels: 1
            )
            engine.connect(spatialSourceMixer, to: environmentNode, format: monoFormat)
            engine.connect(environmentNode, to: engine.mainMixerNode, format: nil)

            environmentNode.renderingAlgorithm = .HRTFHQ
            environmentNode.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
            environmentNode.listenerAngularOrientation = AVAudio3DAngularOrientation(yaw: 0, pitch: 0, roll: 0)
            // Anchor the whole mix directly in front of the listener — HRTF
            // rendering externalizes it ("outside your head") even without
            // head tracking; tracking (when available) then keeps it anchored
            // in place as the listener turns.
            spatialSourceMixer.destination(forMixer: environmentNode, bus: 0)?.position = AVAudio3DPoint(x: 0, y: 0, z: -1)

            if SpatialAudioService.shared.isHeadTrackingAvailable {
                SpatialAudioService.shared.onOrientationUpdate = { [weak self] orientation in
                    self?.environmentNode.listenerAngularOrientation = orientation
                }
                SpatialAudioService.shared.startTracking()
            }
        } else {
            SpatialAudioService.shared.stopTracking()
            SpatialAudioService.shared.onOrientationUpdate = nil
            // Mono Audio: connect through a single-channel format so
            // AVAudioEngine downmixes L+R at the boundary — both output
            // channels then carry the identical summed signal. `format: nil`
            // (the non-mono branch) is the original stereo passthrough,
            // unchanged from before this feature existed.
            let outputFormat: AVAudioFormat? = effectiveMono
                ? AVAudioFormat(
                    standardFormatWithSampleRate: engine.mainMixerNode.outputFormat(forBus: 0).sampleRate,
                    channels: 1
                )
                : nil
            engine.connect(limiter, to: engine.mainMixerNode, format: outputFormat)
        }

        if wasRunning { try? engine.start() }
    }

    /// Configures `limiter` as a fast brick-wall peak limiter: threshold just
    /// under 0 dBFS with a very high ratio, near-instant attack, and a short
    /// release. With this in place, raising `crossfadeMixer.outputVolume`
    /// above 1.0 (via `audioSettings.volume`, up to `AudioSettings.maxVolume`)
    /// makes playback louder without the output signal hard-clipping.
    func configureLimiter() {
        let unit = limiter.audioUnit
        AudioUnitSetParameter(unit, kDynamicsProcessorParam_Threshold, kAudioUnitScope_Global, 0, -1.0, 0)    // dB — start limiting just below full scale
        AudioUnitSetParameter(unit, kDynamicsProcessorParam_HeadRoom, kAudioUnitScope_Global, 0, 1.0, 0)      // dB of headroom above the threshold
        AudioUnitSetParameter(unit, kDynamicsProcessorParam_AttackTime, kAudioUnitScope_Global, 0, 0.001, 0)  // seconds — fast enough to catch transients
        AudioUnitSetParameter(unit, kDynamicsProcessorParam_ReleaseTime, kAudioUnitScope_Global, 0, 0.05, 0)  // seconds — short so it doesn't pump audibly
        AudioUnitSetParameter(unit, kDynamicsProcessorParam_OverallGain, kAudioUnitScope_Global, 0, 0, 0)
        limiter.bypass = false
    }

    /// Configures `nightModeCompressor` as a gentle "evener" — engages much
    /// earlier and releases much slower than `limiter` (a peak-catching
    /// brick-wall limiter further down the chain), so quiet passages get
    /// pulled up and loud ones pulled down well before either would clip.
    /// A few dB of makeup gain compensates for the level compression removes,
    /// so Night Mode evens dynamics out rather than just making everything
    /// quieter. Always attached/connected (see `configureEngine`) — toggled
    /// purely via `.bypass` in `applyAudioSettings`, matching how EQ bands
    /// are bypassed rather than disconnected.
    func configureNightModeCompressor() {
        let unit = nightModeCompressor.audioUnit
        AudioUnitSetParameter(unit, kDynamicsProcessorParam_Threshold, kAudioUnitScope_Global, 0, -24.0, 0)  // dB — engage well below peak level
        AudioUnitSetParameter(unit, kDynamicsProcessorParam_HeadRoom, kAudioUnitScope_Global, 0, 10.0, 0)    // dB — soft knee, gradual compression above threshold
        AudioUnitSetParameter(unit, kDynamicsProcessorParam_AttackTime, kAudioUnitScope_Global, 0, 0.01, 0)  // seconds
        AudioUnitSetParameter(unit, kDynamicsProcessorParam_ReleaseTime, kAudioUnitScope_Global, 0, 0.2, 0)  // seconds — slower than the limiter, for smoother leveling
        AudioUnitSetParameter(unit, kDynamicsProcessorParam_OverallGain, kAudioUnitScope_Global, 0, 6.0, 0)  // dB makeup gain
        nightModeCompressor.bypass = true  // off by default — see applyAudioSettings
    }

    func configureEqualizer() {
        let frequencies: [Float] = [32, 64, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]
        // Use shelf filters for the frequency extremes so gain is applied to everything
        // below 32 Hz or above 16 kHz, not just a narrow peak at those frequencies.
        // All mid bands use parametric (bell/peak) filters.
        let filterTypes: [AVAudioUnitEQFilterType] = [
            .lowShelf,   // 32 Hz  — boosts/cuts all sub-bass below shelf point
            .parametric, // 64 Hz
            .parametric, // 125 Hz
            .parametric, // 250 Hz
            .parametric, // 500 Hz
            .parametric, // 1 kHz
            .parametric, // 2 kHz
            .parametric, // 4 kHz
            .parametric, // 8 kHz
            .highShelf   // 16 kHz — boosts/cuts all air-band above shelf point
        ]
        for (index, band) in equalizer.bands.enumerated() {
            band.filterType = filterTypes[index]
            band.frequency  = frequencies[index]
            band.bandwidth  = 1.0   // 1-octave bandwidth — musical, smooth boost/cut response
            band.gain       = 0
            band.bypass     = true
        }
    }

    func startEngineIfNeeded() {
        // Every play/resume path funnels through here — cancel any pending
        // idle-teardown grace-period timer (armed by `pause()`) right at the
        // choke point rather than in each individual caller.
        idleTeardownTimer?.invalidate()
        idleTeardownTimer = nil
        guard !engine.isRunning else { return }
        // Activate the audio session lazily, right before the engine starts —
        // not at launch — so the app only holds the audio system while actually
        // playing (see `configureAudioSession`).
        try? AVAudioSession.sharedInstance().setActive(true)
        do {
            try engine.start()
            errorMessage = nil
        } catch {
            // Full teardown + rebuild, then reactivate the audio session before retry.
            // engine.reset() detaches all nodes and clears connections, so configureEngine()
            // can re-attach them cleanly without duplicates.
            appWarn("Audio engine start failed — rebuilding: \(error.localizedDescription)", category: "audio")
            engine.reset()
            isEngineConfigured = false
            // engine.reset() wipes all connections, including any spatial-audio
            // or mono-downmix routing — clear both tracking flags too so
            // configureEngine()'s default (unrouted) connection isn't skipped
            // by a stale "already routed" guard once applyAudioSettings()
            // re-runs below.
            isSpatialAudioRouted = false
            isMonoAudioRouted = false
            configureEngine()
            configureEqualizer()

            // The session activation result is no longer discarded.
            //
            // This was `try? ... setActive(true)`, which swallowed the one error
            // that explains the whole failure: `CannotInterruptOthers` (OSStatus
            // '!int'), raised when another app owns audio and ours is not in a
            // position to take it. The code then started the engine regardless,
            // which cannot work without an active session, and reported a
            // generic AudioUnit error — so the logs blamed the engine for a
            // session problem. Across all users the rebuild path was 74 attempts
            // and 74 failures with not one recovery, and the real reason was
            // invisible in every one of them.
            //
            // Bailing out here is not giving up: nothing about the engine has been
            // left broken (it is configured and merely not started), and the
            // existing retry paths — `timerTick`'s "playing but the engine stopped"
            // check and the interruption-ended handler — come back to it once the
            // session can actually be had. Retrying in a moment when it is
            // impossible only produced noise.
            do {
                try AVAudioSession.sharedInstance().setActive(true)
            } catch {
                errorMessage = error.localizedDescription
                appWarn("Audio engine rebuild: audio session would not activate (\(error.localizedDescription)) — leaving the engine stopped; it will be retried when the session is available", category: "audio")
                return
            }

            do {
                try engine.start()
                appLog("Audio engine recovered after rebuild", category: "audio")
                errorMessage = nil
                // `configureEqualizer()` resets every band to gain=0/bypass=true —
                // without reapplying the user's EQ/effects settings here, an engine
                // rebuild (triggered by an interruption, route change, or hardware
                // config change) silently wipes the EQ until the user next touches
                // a slider. Reapply so it picks up exactly where it left off.
                applyAudioSettings()
            } catch {
                errorMessage = error.localizedDescription
                appError("Audio engine failed to recover: \(error.localizedDescription)", category: "audio")
            }
        }
    }

    /// Matches the audio session's preferred sample rate to the source file
    /// before the engine starts. This keeps CD-quality 44.1 kHz ALAC and
    /// genuinely hi-res FLAC/ALAC from being needlessly converted through a
    /// fixed 48 kHz intermediate. The graph uses `format: nil`, so the
    /// hardware still negotiates its supported rate (and may resample when
    /// the route cannot provide the source rate).
    func ensureSampleRate(matching fileSampleRate: Double) {
        let desired = fileSampleRate.rounded()
        guard desired > 0,
              abs(desired - lastRequestedSampleRate) > 0.5 else { return }
        lastRequestedSampleRate = desired

        let session = AVAudioSession.sharedInstance()
        let wasRunning = engine.isRunning
        // Stop (not pause) — changing the session's preferred sample rate
        // needs the hardware I/O unit fully torn down first, the same way
        // startEngineIfNeeded()'s own rebuild path always stops before it
        // reconfigures anything.
        if wasRunning { engine.stop() }
        do {
            try session.setPreferredSampleRate(desired)
        } catch {
            appWarn("ensureSampleRate: setPreferredSampleRate(\(desired)) failed: \(error.localizedDescription)", category: "audio")
        }
        guard wasRunning else { return }
        try? session.setActive(true)
        do {
            try engine.start()
        } catch {
            // Same recovery path startEngineIfNeeded() falls back to — a
            // sample-rate change is exactly the kind of hardware
            // reconfiguration that can leave the engine needing a full
            // rebuild, not just a restart.
            appWarn("ensureSampleRate: engine restart failed after rate change — rebuilding: \(error.localizedDescription)", category: "audio")
            engine.reset()
            isEngineConfigured = false
            isSpatialAudioRouted = false
            isMonoAudioRouted = false
            configureEngine()
            configureEqualizer()
            try? session.setActive(true)
            try? engine.start()
            applyAudioSettings()
        }
    }
}
