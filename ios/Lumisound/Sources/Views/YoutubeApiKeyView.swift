import SwiftUI

// MARK: - YoutubeApiKeyView
//
// Configures this account's personal YouTube Data API v3 key
// (GET/PUT/DELETE /user/youtube-api-key). When set, the bridge's
// /api/resolve uses playlistItems.list to enumerate full YouTube playlists
// for this account — bypassing yt-dlp's ~205-entry flat-playlist cap. Falls
// back to the server-wide key (if any) when unset.

struct YoutubeApiKeyView: View {
    @EnvironmentObject private var account: AccountService

    @State private var status: YoutubeApiKeyConfig?
    @State private var apiKey = ""
    @State private var isSaving = false
    @State private var isValidating = false
    @State private var errorText: String?
    @State private var didSave = false

    /// Once a configured key is rejected for quota, re-show the entry field
    /// so the user can replace it. Shared with SettingsView's YouTube API
    /// Key section via the same UserDefaults key.
    @AppStorage("youtube_api_key_quota_exceeded") private var quotaExceeded = false

    var body: some View {
        List {
            Section {
                if status?.configured == true {
                    LabeledContent("API Key") {
                        Text(status?.apiKey ?? "")
                            .font(AppTheme.monoFont(size: 12))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                    .foregroundStyle(AppTheme.textPrimary)
                }

                // Entry field — hidden once a key is configured, unless that
                // key's quota has been exhausted (so the user can replace it).
                if status?.configured != true || quotaExceeded {
                    TextField("AIza...", text: $apiKey)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .foregroundStyle(AppTheme.textPrimary)
                }
            } header: {
                sectionHeader("YouTube Data API Key")
            } footer: {
                Text("Lets full YouTube playlists (beyond ~205 tracks) resolve completely when you import or play them. Create a free key in the Google Cloud Console by enabling \"YouTube Data API v3\" and generating an API key under Credentials.")
            }
            .listRowBackground(tintedRowBackground(.yellow))

            if status?.configured != true || quotaExceeded {
                Section {
                    Button {
                        save()
                    } label: {
                        if isSaving {
                            ProgressView()
                        } else {
                            Text(didSave ? "Saved" : "Save")
                        }
                    }
                    .disabled(isSaving || apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                    .foregroundStyle(AppTheme.dynamicAccent)
                }
                .listRowBackground(tintedRowBackground(.yellow))
            }

            if let errorText {
                Section {
                    Text(errorText)
                        .font(.footnote)
                        .foregroundStyle(AppTheme.error)
                }
                .listRowBackground(Color.clear)
            }

            // Validate / Remove — always visible once a key is configured.
            if status?.configured == true {
                Section {
                    Button {
                        validate()
                    } label: {
                        HStack {
                            Label("Validate API Key", systemImage: "checkmark.shield")
                                .foregroundStyle(AppTheme.dynamicAccent)
                            Spacer()
                            if isValidating {
                                ProgressView().tint(AppTheme.dynamicAccent)
                            }
                        }
                    }
                    .disabled(isValidating)

                    Button(role: .destructive) {
                        removeKey()
                    } label: {
                        Text("Remove API Key")
                    }
                }
                .listRowBackground(tintedRowBackground(.yellow))
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.clear.ignoresSafeArea())
        .navigationTitle("YouTube API Key")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        status = await account.fetchYoutubeApiKey()
    }

    private func save() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        isSaving = true
        errorText = nil
        Task {
            if await account.setYoutubeApiKey(trimmed) {
                didSave = true
                apiKey = ""
                quotaExceeded = false
                status = await account.fetchYoutubeApiKey()
            } else {
                errorText = account.errorMessage ?? "Failed to save API key."
            }
            isSaving = false
        }
    }

    private func validate() {
        isValidating = true
        errorText = nil
        Task {
            let result = await account.validateYouTubeAPIKey()
            switch result {
            case "valid":
                quotaExceeded = false
                ToastCenter.shared.show("YouTube API key is valid", category: .success, icon: "checkmark.seal")
            case "invalid":
                ToastCenter.shared.show("YouTube API key is invalid", category: .error, icon: "xmark.seal")
            case "quota_exceeded":
                quotaExceeded = true
                ToastCenter.shared.show("YouTube API quota exceeded for today", category: .warning, icon: "exclamationmark.triangle")
            default:
                ToastCenter.shared.show("Couldn't validate key — check connection", category: .error, icon: "wifi.exclamationmark")
            }
            isValidating = false
        }
    }

    private func removeKey() {
        Task {
            if await account.deleteYoutubeApiKey() {
                status = await account.fetchYoutubeApiKey()
                apiKey = ""
                didSave = false
                quotaExceeded = false
            }
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(AppTheme.bodyFont(size: 11))
            .foregroundStyle(AppTheme.textSecondary)
            .kerning(0.8)
    }
}
