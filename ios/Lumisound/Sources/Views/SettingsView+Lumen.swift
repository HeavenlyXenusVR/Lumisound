import SwiftUI

// MARK: - Lumen pages
//
// Lumen's Settings index (`LumenSettingsView`) pushes one SettingsView page
// per category instead of Classic's tab picker. The sections themselves are
// the same `accountSection`, `playbackAudioSection`, … Classic renders —
// every setting keeps exactly one implementation — laid out as a single
// grouped list on Lumen's surfaces, inside the caller's navigation stack.

extension SettingsView {
    init(lumenPage: SettingsTab) {
        self.lumenPage = lumenPage
    }

    func lumenPageBody(_ page: SettingsTab) -> some View {
        List {
            Group {
                if updater.updateAvailable {
                    Section {
                        UpdateBannerView()
                            .environmentObject(updater)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }

                switch page {
                case .general:
                    accountSection
                    notificationsSection
                    appearanceSection
                    sleepTimerSection
                    appLockSection
                case .audio:
                    playbackAudioSection
                    carModeSection
                case .library:
                    librarySection
                    streamingDownloadsSection
                case .ytdlp:
                    ytdlpSection
                case .app:
                    updatesSection
                    helpSection
                    aboutSection
                }
            }
            .listRowBackground(LumenPalette.surface.opacity(0.78))
            .listRowSeparatorTint(LumenPalette.hairline)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(LumenBackdrop())
        .navigationTitle(page.lumenTitle)
        .navigationBarTitleDisplayMode(.large)
        .sheet(isPresented: $showLogin) {
            LoginView()
                .environmentObject(account)
        }
        .task {
            await refreshYouTubeKeyStatus()
            startYouTubeExposureMonitor()
            await refreshAcoustIDKeyStatus()
        }
        .onDisappear {
            youtubeExposureTimer?.invalidate()
            youtubeExposureTimer = nil
        }
    }
}

extension SettingsView.SettingsTab {
    var lumenTitle: String {
        switch self {
        case .general: return "General"
        case .audio:   return "Sound"
        case .library: return "Library & Downloads"
        case .ytdlp:   return "yt-dlp"
        case .app:     return "About & Updates"
        }
    }

    var lumenSubtitle: String {
        switch self {
        case .general: return "Account, notifications, appearance, sleep, app lock"
        case .audio:   return "Playback, EQ defaults, crossfade, car mode"
        case .library: return "Scanning, storage, health, streaming & downloads"
        case .ytdlp:   return "Download engine, cookies, API keys"
        case .app:     return "Updates, help, bug reports, credits"
        }
    }
}
