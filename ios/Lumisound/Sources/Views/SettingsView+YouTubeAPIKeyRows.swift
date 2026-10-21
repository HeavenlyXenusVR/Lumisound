import MediaPlayer
import SwiftUI

extension SettingsView {

    // MARK: — YouTube API Key Rows

    /// Masked display of the configured key (or a placeholder if none set).
    var youtubeKeyDisplay: String {
        guard let config = youtubeKeyConfig, config.configured, let masked = config.apiKey else {
            return "Not set"
        }
        return masked
    }

    @ViewBuilder
    var youtubeAPIKeySection: some View {
        // Status / masked key row
        HStack {
            Label("YouTube API Key", systemImage: "key.horizontal")
                .foregroundStyle(AppTheme.textPrimary)
            Spacer()
            Text(youtubeKeyDisplay)
                .font(AppTheme.monoFont(size: 13))
                .foregroundStyle(AppTheme.textSecondary)
        }

        // Entry field for setting/replacing the key — hidden once a key is
        // configured, unless that key's quota has been exhausted (so the
        // user can drop in a replacement).
        if youtubeKeyConfig?.configured != true || youtubeKeyQuotaExceeded {
            HStack {
                Label("Set Key", systemImage: "pencil")
                    .foregroundStyle(AppTheme.textPrimary)
                SecureField("Paste YouTube Data API v3 key", text: $youtubeKeyInput)
                    .keyboardType(.asciiCapable)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(AppTheme.textSecondary)
            }

            if !youtubeKeyInput.isEmpty {
                Button {
                    Task {
                        isSavingYouTubeKey = true
                        let ok = await account.setYoutubeApiKey(youtubeKeyInput)
                        isSavingYouTubeKey = false
                        if ok {
                            youtubeKeyInput = ""
                            youtubeKeyQuotaExceeded = false
                            ToastCenter.shared.show("YouTube API key saved", category: .success, icon: "key.horizontal")
                            await refreshYouTubeKeyStatus()
                        } else {
                            ToastCenter.shared.show("Couldn't save key — check connection", category: .error, icon: "exclamationmark.triangle")
                        }
                    }
                } label: {
                    HStack {
                        Label("Save Key", systemImage: "checkmark.circle")
                            .foregroundStyle(AppTheme.dynamicAccent)
                        Spacer()
                        if isSavingYouTubeKey {
                            ProgressView().tint(.cyan)
                        }
                    }
                }
                .disabled(isSavingYouTubeKey)
            }
        }

        // Validate API Key button — always visible once a key is configured.
        Button {
            Task {
                isValidatingYouTubeKey = true
                let result = await account.validateYouTubeAPIKey()
                isValidatingYouTubeKey = false
                // Estimate only — the Data API has no endpoint for a key's
                // real remaining quota. See `AccountService.YouTubeKeyValidation`.
                let quotaSuffix = result.quotaUnitsUsedToday.map { " — ~\($0) quota units used today (est.)" } ?? ""
                switch result.status {
                case "valid":
                    youtubeKeyQuotaExceeded = false
                    ToastCenter.shared.show("YouTube API key is valid\(quotaSuffix)", category: .success, icon: "checkmark.seal")
                case "invalid":
                    ToastCenter.shared.show("YouTube API key is invalid", category: .error, icon: "xmark.seal")
                case "quota_exceeded":
                    youtubeKeyQuotaExceeded = true
                    ToastCenter.shared.show("YouTube API quota exceeded for today\(quotaSuffix)", category: .warning, icon: "exclamationmark.triangle")
                default:
                    ToastCenter.shared.show("Couldn't validate key — check connection", category: .error, icon: "wifi.exclamationmark")
                }
            }
        } label: {
            HStack {
                Label("Validate API Key", systemImage: "checkmark.shield")
                    .foregroundStyle(AppTheme.dynamicAccent)
                Spacer()
                if isValidatingYouTubeKey {
                    ProgressView().tint(.cyan)
                }
            }
        }
        .disabled(isValidatingYouTubeKey || youtubeKeyConfig?.configured != true)

        // Remove key
        if youtubeKeyConfig?.configured == true {
            Button(role: .destructive) {
                Task {
                    let ok = await account.deleteYoutubeApiKey()
                    if ok {
                        youtubeKeyQuotaExceeded = false
                        ToastCenter.shared.show("YouTube API key removed", category: .info, icon: "key.horizontal")
                        await refreshYouTubeKeyStatus()
                    } else {
                        ToastCenter.shared.show("Couldn't remove key — check connection", category: .error, icon: "exclamationmark.triangle")
                    }
                }
            } label: {
                Label("Remove Key", systemImage: "trash")
                    .foregroundStyle(AppTheme.error)
            }
        }

        Text("Used by Lumisound's bridge to enumerate full YouTube playlists. Falls back to a shared server key if unset. Never displayed in full once saved.")
            .font(.caption)
            .foregroundStyle(AppTheme.textSecondary)
            .padding(.leading, 16)
    }
}
