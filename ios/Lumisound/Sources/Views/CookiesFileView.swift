import SwiftUI

// MARK: - CookiesFileView
//
// Uploads this account's yt-dlp cookies.txt (Netscape format) so the bridge
// can authenticate yt-dlp extraction (search/stream/resolve/download) as the
// user's own YouTube session — required for age-restricted videos and to
// avoid YouTube's anonymous-request bot-detection blocks. Mirrors
// YoutubeApiKeyView's upload/validate/remove pattern.

struct CookiesFileView: View {
    @EnvironmentObject private var account: AccountService

    @State private var status: YtdlpCookiesStatus?
    @State private var isUploading = false
    @State private var isValidating = false
    @State private var isShowingPicker = false
    @State private var errorText: String?
    @State private var validation: YtdlpCookiesValidation?

    var body: some View {
        List {
            Section {
                if status?.configured == true {
                    LabeledContent("Status") {
                        Text("Configured")
                            .foregroundStyle(AppTheme.success)
                    }
                    if let updatedAt = status?.updatedAt, let date = ISO8601DateFormatter().date(from: updatedAt) {
                        LabeledContent("Last Updated") {
                            Text(date.formatted(date: .abbreviated, time: .shortened))
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                    }
                } else {
                    Text("No cookies uploaded yet.")
                        .foregroundStyle(AppTheme.textSecondary)
                }

                Button {
                    isShowingPicker = true
                } label: {
                    if isUploading {
                        ProgressView()
                    } else {
                        Label(status?.configured == true ? "Replace Cookies File" : "Upload Cookies File", systemImage: "doc.badge.plus")
                    }
                }
                .disabled(isUploading)
                .foregroundStyle(AppTheme.dynamicAccent)
            } header: {
                sectionHeader("YouTube Cookies (cookies.txt)")
            } footer: {
                Text("Export cookies.txt from a browser you're logged into YouTube with (e.g. the \"Get cookies.txt LOCALLY\" extension), while signed in normally — not a guest/incognito session. This unlocks age-restricted videos and avoids YouTube blocking anonymous downloads. The file is stored on the server for your account only and is never shown back to you or any other user.")
            }
            .listRowBackground(tintedRowBackground(.yellow))

            if let errorText {
                Section {
                    Text(errorText)
                        .font(.footnote)
                        .foregroundStyle(AppTheme.error)
                }
                .listRowBackground(Color.clear)
            }

            if status?.configured == true {
                Section {
                    Button {
                        validate()
                    } label: {
                        HStack {
                            Label("Validate Cookies", systemImage: "checkmark.shield")
                                .foregroundStyle(AppTheme.dynamicAccent)
                            Spacer()
                            if isValidating {
                                ProgressView().tint(AppTheme.dynamicAccent)
                            }
                        }
                    }
                    .disabled(isValidating)

                    Button(role: .destructive) {
                        removeCookies()
                    } label: {
                        Text("Remove Cookies")
                    }
                }
                .listRowBackground(tintedRowBackground(.yellow))

                if let validation {
                    Section {
                        LabeledContent("Result") {
                            Text(validationStatusLabel(validation.status))
                                .foregroundStyle(validationStatusColor(validation.status))
                        }
                        Text(validation.detail)
                            .font(.footnote)
                            .foregroundStyle(AppTheme.textSecondary)
                        LabeledContent("Age-Restriction Ready") {
                            Image(systemName: validation.ageRestrictionReady ? "checkmark.circle.fill" : "xmark.circle")
                                .foregroundStyle(validation.ageRestrictionReady ? AppTheme.success : AppTheme.textSecondary)
                        }
                        if !validation.missing.isEmpty {
                            ForEach(validation.missing, id: \.self) { item in
                                Label(item, systemImage: "exclamationmark.triangle")
                                    .font(.footnote)
                                    .foregroundStyle(AppTheme.warning)
                            }
                        }
                    } header: {
                        sectionHeader("Last Validation")
                    }
                    .listRowBackground(tintedRowBackground(.yellow))
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.clear.ignoresSafeArea())
        .navigationTitle("YouTube Cookies")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(isPresented: $isShowingPicker) {
            DocumentPicker(mode: .textFile) { urls in
                guard let url = urls.first else { return }
                upload(from: url)
            }
        }
    }

    private func load() async {
        status = await account.fetchYtdlpCookiesStatus()
    }

    private func upload(from url: URL) {
        isUploading = true
        errorText = nil
        validation = nil
        Task {
            defer { isUploading = false }
            guard let text = try? String(contentsOf: url, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                errorText = "Couldn't read that file as text."
                return
            }
            if await account.setYtdlpCookies(text) {
                ToastCenter.shared.show("Cookies uploaded", category: .success, icon: "checkmark.seal")
                status = await account.fetchYtdlpCookiesStatus()
            } else {
                errorText = account.errorMessage ?? "Failed to upload cookies."
            }
        }
    }

    private func validate() {
        isValidating = true
        errorText = nil
        Task {
            defer { isValidating = false }
            validation = await account.validateYtdlpCookies()
            if validation == nil {
                errorText = account.errorMessage ?? "Couldn't validate cookies — check connection."
            }
        }
    }

    private func removeCookies() {
        Task {
            if await account.deleteYtdlpCookies() {
                status = await account.fetchYtdlpCookiesStatus()
                validation = nil
            }
        }
    }

    private func validationStatusLabel(_ status: String) -> String {
        switch status {
        case "valid":                    return "Valid"
        case "valid_no_age_restriction": return "Valid (no age-restriction support)"
        case "expired":                  return "Expired"
        case "incomplete":               return "Incomplete"
        case "missing":                  return "Missing"
        case "invalid":                  return "Invalid"
        default:                         return status.capitalized
        }
    }

    private func validationStatusColor(_ status: String) -> Color {
        switch status {
        case "valid":                    return AppTheme.success
        case "valid_no_age_restriction": return AppTheme.warning
        default:                         return AppTheme.error
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(AppTheme.bodyFont(size: 11))
            .foregroundStyle(AppTheme.textSecondary)
            .kerning(0.8)
    }
}
