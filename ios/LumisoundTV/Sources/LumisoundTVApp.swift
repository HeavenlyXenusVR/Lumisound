import SwiftUI

// MARK: - Lumisound for Apple TV
//
// A focused, self-contained tvOS client: search the Lumisound bridge and stream
// results to the TV via the bridge's /api/stream/proxy endpoint (which serves
// the audio from the bridge's IP so it actually plays). Deliberately does not
// reuse the iOS codebase so it compiles cleanly for tvOS.

@main
struct LumisoundTVApp: App {
    init() {
        TVAppLogger.shared.configure(bridgeURL: TVBridgeClient.shared.baseURL)
    }

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            TVContentView()
                // Started from `.task`, not `init()`: the singletons the
                // snapshot reads (TVPlayerModel/TVAccount) are constructed as
                // the view hierarchy comes up, so a snapshot taken in `init()`
                // would report a blank app every launch.
                .task { TVDiagnosticsSnapshot.start() }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    // A tick that came due while the app was suspended is
                    // otherwise lost — the main run loop doesn't fire timers
                    // there. An Apple TV sits suspended far more of the time
                    // than a phone does, so without this the periodic snapshot
                    // would be almost entirely launch-time samples.
                    TVDiagnosticsSnapshot.noteDidBecomeActive()
                }
        }
    }
}
