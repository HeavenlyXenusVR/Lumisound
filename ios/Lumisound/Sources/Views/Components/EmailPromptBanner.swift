import SwiftUI

/// A non-blocking prompt asking an account with no email on file to add one.
///
/// Registration made email optional for most of this app's life, and
/// sign-in-with-Discord auto-created accounts with no address at all, so a large
/// share of existing accounts have nothing on file. New accounts can no longer
/// be created that way, but that does nothing for the ones already out there.
///
/// The Account screen carries the same control, but a settings row only reaches
/// people who go looking for it — most never open that screen, so the gap would
/// close at essentially no rate. This surfaces the same request where it will
/// actually be seen.
///
/// Deliberately a prompt and not a gate. Nothing in the app is withheld until an
/// address is supplied: these are people already using the app, and locking them
/// out of it would cost far more than the missing address is worth. Hence the
/// snooze below rather than a modal that must be dealt with.
struct EmailPromptBanner: View {

    @EnvironmentObject var account: AccountService

    /// When the prompt may next appear, as a `timeIntervalSince1970`.
    ///
    /// Stored rather than held in view state so that "Later" survives an app
    /// relaunch — a dismissal that reappears on the next cold start reads as a
    /// bug and trains people to ignore the thing entirely.
    @AppStorage("email_prompt_snoozed_until_v1") private var snoozedUntil: Double = 0

    @State private var isPresentingEditor = false

    /// A week. Long enough not to nag, short enough that the prompt is still a
    /// real path to closing the gap rather than a one-shot people miss once.
    private static let snoozeInterval: TimeInterval = 7 * 24 * 60 * 60

    private var isSnoozed: Bool {
        Date().timeIntervalSince1970 < snoozedUntil
    }

    var body: some View {
        if account.needsEmail && !isSnoozed {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "envelope.badge")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(AppTheme.dynamicAccent)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Add an email address")
                        .font(AppTheme.bodyFont(size: 14).weight(.semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                    Text("Your account doesn't have one yet. It's how you can be reached about your account — nothing else.")
                        .font(AppTheme.bodyFont(size: 12))
                        .foregroundStyle(AppTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 14) {
                        Button("Add") { isPresentingEditor = true }
                            .font(.subheadline.bold())
                            .foregroundStyle(AppTheme.dynamicAccent)
                        Button("Later") {
                            snoozedUntil = Date().timeIntervalSince1970 + Self.snoozeInterval
                        }
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.textSecondary)
                    }
                    .padding(.top, 4)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .adaptiveGlass(tint: AppTheme.dynamicAccent, in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 16)
            .transition(.move(edge: .top).combined(with: .opacity))
            .sheet(isPresented: $isPresentingEditor) {
                EmailPromptEditor()
                    .environmentObject(account)
            }
        }
    }
}

/// The entry sheet behind the banner's "Add" button.
private struct EmailPromptEditor: View {

    @EnvironmentObject var account: AccountService
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var isSaving = false
    @State private var localError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("you@example.com", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .submitLabel(.done)
                        .onSubmit(save)
                } header: {
                    Text("Email")
                } footer: {
                    // The server is the authority and rejects more than the
                    // client checks (undeliverable domain, disposable provider,
                    // already in use), so its message is shown verbatim rather
                    // than replaced with a generic one.
                    if let err = localError ?? account.errorMessage {
                        Text(err).foregroundStyle(AppTheme.warning)
                    } else {
                        Text("Used only to reach you about your account.")
                    }
                }
            }
            .navigationTitle("Add Email")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save", action: save)
                            .disabled(email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
    }

    private func save() {
        guard !isSaving else { return }
        localError = AccountService.localEmailProblem(email)
        guard localError == nil else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            // Dismissed only on success. A rejected address must stay on screen
            // to be corrected — closing the sheet would silently discard it and
            // leave the banner up with no explanation of what went wrong.
            if await account.setEmail(email) {
                dismiss()
            }
        }
    }
}
