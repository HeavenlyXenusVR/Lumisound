import AuthenticationServices
import SwiftUI

struct LoginView: View {

    /// Pass `true` to open directly on the Register tab (e.g. from the "Create Account" button).
    var startOnRegister: Bool = false

    @EnvironmentObject var account: AccountService
    @EnvironmentObject var libraryManager: LibraryManager
    @EnvironmentObject var player: AudioPlayerManager
    @Environment(\.dismiss) var dismiss

    private let discordPresentationContext = DiscordAuthPresentationContext()

    @State private var isRegistering = false
    @State private var username = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var email = ""
    @State private var displayName = ""
    @State private var isLoading = false
    @State private var isDiscordLoggingIn = false

    // Local validation error (e.g. passwords don't match)
    @State private var localError: String? = nil

    // Two-factor auth code step — shown instead of the form below while
    // `account.pendingTOTPToken != nil` (set by `login()` when the account
    // has 2FA enabled; see AccountService+PublicAPI.swift).
    @State private var totpCode = ""
    @State private var isVerifyingTOTP = false

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 28) {

                        // MARK: Logo / Header
                        VStack(spacing: 8) {
                            Image(systemName: "waveform.circle.fill")
                                .font(.system(size: 60))
                                .foregroundStyle(AppTheme.dynamicAccent)
                                .shadow(color: AppTheme.dynamicAccent.opacity(0.4), radius: 12, x: 0, y: 6)

                            Text("Lumisound")
                                .font(.title2.bold())
                                .foregroundStyle(AppTheme.textPrimary)

                            Text("Sync your music across devices")
                                .font(AppTheme.bodyFont(size: 14))
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                        .padding(.top, 20)

                        if account.pendingTOTPToken != nil {
                            totpCodeStep
                        } else {
                        loginFormFields
                        }

                        Spacer(minLength: 20)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        account.cancelTOTPLogin()
                        dismiss()
                    }
                        .foregroundStyle(AppTheme.dynamicAccent)
                }
            }
            .onChange(of: account.isLoggedIn) { loggedIn in
                if loggedIn { dismiss() }
            }
            .onAppear {
                if startOnRegister { isRegistering = true }
            }
        }
    }

    // MARK: - Two-factor code step

    private var totpCodeStep: some View {
        VStack(spacing: 18) {
            Text("Two-Factor Authentication")
                .font(.headline)
                .foregroundStyle(AppTheme.textPrimary)
            Text("Enter the 6-digit code from your authenticator app.")
                .font(AppTheme.bodyFont(size: 13))
                .foregroundStyle(AppTheme.textSecondary)
                .multilineTextAlignment(.center)

            TextField("000000", text: $totpCode)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .font(.title2.monospacedDigit())
                .foregroundStyle(AppTheme.textPrimary)
                .padding(12)
                .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(AppTheme.dynamicAccent.opacity(0.3), lineWidth: 1)
                )
                .onChange(of: totpCode) { newValue in
                    // Codes are exactly 6 digits — clamp input so a pasted
                    // longer string (or an accidental extra tap) doesn't
                    // silently produce a request that can never verify.
                    let digitsOnly = newValue.filter(\.isNumber)
                    totpCode = String(digitsOnly.prefix(6))
                }

            if let err = account.errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 14))
                    Text(err)
                        .font(AppTheme.bodyFont(size: 13))
                        .multilineTextAlignment(.leading)
                }
                .foregroundStyle(AppTheme.error)
            }

            Button {
                isVerifyingTOTP = true
                Task {
                    defer { isVerifyingTOTP = false }
                    await account.completeTOTPLogin(code: totpCode)
                    if account.isLoggedIn {
                        await account.pullSync(library: libraryManager, player: player)
                        account.startAutoPushTimer(library: libraryManager)
                        await account.loadAvatar(forceRefresh: true)
                    }
                }
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(AppTheme.dynamicAccent)
                        .frame(height: 50)
                    if isVerifyingTOTP {
                        ProgressView().tint(.white)
                    } else {
                        Text("Verify").font(.headline).foregroundStyle(.white)
                    }
                }
            }
            .disabled(isVerifyingTOTP || totpCode.count != 6)
            .opacity((isVerifyingTOTP || totpCode.count != 6) ? 0.6 : 1.0)

            Button("Use a different account") {
                totpCode = ""
                account.cancelTOTPLogin()
            }
            .font(AppTheme.bodyFont(size: 13))
            .foregroundStyle(AppTheme.textSecondary)
        }
        .padding(.horizontal)
    }

    // MARK: - Sign in / register form

    private var loginFormFields: some View {
        VStack(spacing: 28) {
                        // MARK: Mode Picker
                        Picker("Mode", selection: $isRegistering) {
                            Text("Sign In").tag(false)
                            Text("Register").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal)
                        .onChange(of: isRegistering) { _ in
                            localError = nil
                            account.errorMessage = nil
                        }

                        // MARK: Sign in with Discord
                        //
                        // One button regardless of the Sign In/Register picker
                        // above — the bridge's /auth/discord/* pair transparently
                        // logs into an existing account or creates one on the
                        // fly (see AccountService+DiscordLogin.swift), so there's
                        // no separate "register with Discord" mode to pick.
                        VStack(spacing: 14) {
                            Button {
                                discordSignInTapped()
                            } label: {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(Color(red: 0.345, green: 0.396, blue: 0.949))
                                        .frame(height: 50)
                                    if isDiscordLoggingIn {
                                        ProgressView().tint(.white)
                                    } else {
                                        Label("Continue with Discord", systemImage: "checkmark.seal.fill")
                                            .font(.headline)
                                            .foregroundStyle(.white)
                                    }
                                }
                            }
                            .disabled(isDiscordLoggingIn || isLoading)
                            .opacity((isDiscordLoggingIn || isLoading) ? 0.6 : 1.0)

                            HStack(spacing: 10) {
                                Rectangle().fill(AppTheme.textSecondary.opacity(0.25)).frame(height: 1)
                                Text("or")
                                    .font(AppTheme.bodyFont(size: 12))
                                    .foregroundStyle(AppTheme.textSecondary)
                                Rectangle().fill(AppTheme.textSecondary.opacity(0.25)).frame(height: 1)
                            }
                        }
                        .padding(.horizontal)

                        // MARK: Form Fields
                        VStack(spacing: 14) {

                            // Username
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Username")
                                    .font(AppTheme.bodyFont(size: 12))
                                    .foregroundStyle(AppTheme.textSecondary)
                                    .padding(.leading, 4)
                                HStack {
                                    TextField("", text: $username)
                                        .textContentType(.username)
                                        .autocorrectionDisabled()
                                        .textInputAutocapitalization(.never)
                                        .foregroundStyle(AppTheme.textPrimary)
                                        .submitLabel(.next)
                                        .onSubmit { /* focus shifts to password via submitLabel */ }
                                    if !username.isEmpty {
                                        Button {
                                            username = ""
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundStyle(AppTheme.textSecondary)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(12)
                                .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 10))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(AppTheme.dynamicAccent.opacity(0.3), lineWidth: 1)
                                )
                            }

                            // Password
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Password")
                                    .font(AppTheme.bodyFont(size: 12))
                                    .foregroundStyle(AppTheme.textSecondary)
                                    .padding(.leading, 4)
                                SecureField("", text: $password)
                                    .textContentType(isRegistering ? .newPassword : .password)
                                    .foregroundStyle(AppTheme.textPrimary)
                                    .submitLabel(isRegistering ? .next : .done)
                                    .onSubmit { if !isRegistering { submitTapped() } }
                                    .padding(12)
                                    .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 10))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10)
                                            .stroke(AppTheme.dynamicAccent.opacity(0.3), lineWidth: 1)
                                    )
                            }

                            // Registration-only fields
                            if isRegistering {

                                // Confirm password
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Confirm Password")
                                        .font(AppTheme.bodyFont(size: 12))
                                        .foregroundStyle(AppTheme.textSecondary)
                                        .padding(.leading, 4)
                                    SecureField("", text: $confirmPassword)
                                        .textContentType(.newPassword)
                                        .foregroundStyle(AppTheme.textPrimary)
                                        .submitLabel(.next)
                                        .padding(12)
                                        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 10))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10)
                                                .stroke(AppTheme.dynamicAccent.opacity(0.3), lineWidth: 1)
                                        )
                                }

                                // Display name
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Display Name (optional)")
                                        .font(AppTheme.bodyFont(size: 12))
                                        .foregroundStyle(AppTheme.textSecondary)
                                        .padding(.leading, 4)
                                    TextField("", text: $displayName)
                                        .textContentType(.name)
                                        .autocorrectionDisabled()
                                        .foregroundStyle(AppTheme.textPrimary)
                                        .submitLabel(.next)
                                        .padding(12)
                                        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 10))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10)
                                                .stroke(AppTheme.dynamicAccent.opacity(0.3), lineWidth: 1)
                                        )
                                }

                                // Email
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Email")
                                        .font(AppTheme.bodyFont(size: 12))
                                        .foregroundStyle(AppTheme.textSecondary)
                                        .padding(.leading, 4)
                                    TextField("", text: $email)
                                        .textContentType(.emailAddress)
                                        .keyboardType(.emailAddress)
                                        .autocorrectionDisabled()
                                        .textInputAutocapitalization(.never)
                                        .foregroundStyle(AppTheme.textPrimary)
                                        .submitLabel(.done)
                                        .onSubmit { submitTapped() }
                                        .padding(12)
                                        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 10))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10)
                                                .stroke(AppTheme.dynamicAccent.opacity(0.3), lineWidth: 1)
                                        )
                                }
                            }
                        }
                        .padding(.horizontal)

                        // MARK: Error message
                        let errorText = localError ?? account.errorMessage
                        if let err = errorText {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 14))
                                Text(err)
                                    .font(AppTheme.bodyFont(size: 13))
                                    .multilineTextAlignment(.leading)
                            }
                            .foregroundStyle(AppTheme.error)
                            .padding(.horizontal)
                        }

                        // MARK: Submit Button
                        Button {
                            submitTapped()
                        } label: {
                            ZStack {
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(AppTheme.dynamicAccent)
                                    .frame(height: 50)
                                if isLoading {
                                    ProgressView()
                                        .tint(.white)
                                } else {
                                    Text(isRegistering ? "Create Account" : "Sign In")
                                        .font(.headline)
                                        .foregroundStyle(.white)
                                }
                            }
                        }
                        .disabled(isLoading || username.isEmpty || password.isEmpty)
                        .padding(.horizontal)
                        .opacity((isLoading || username.isEmpty || password.isEmpty) ? 0.6 : 1.0)
        }
    }

    // MARK: - Actions

    private func submitTapped() {
        localError = nil
        account.errorMessage = nil

        let trimmedUsername = username.trimmingCharacters(in: .whitespaces)
        guard !trimmedUsername.isEmpty else {
            localError = "Username is required."
            return
        }
        guard !password.isEmpty else {
            localError = "Password is required."
            return
        }

        if isRegistering {
            guard password == confirmPassword else {
                localError = "Passwords do not match."
                return
            }
            // Eight, matching the server's _validate_password_strength. This
            // said six while the bridge required eight, so a seven-character
            // password passed this gate and was then rejected by the server —
            // the client was promising something the backend would not honour.
            guard password.count >= 8 else {
                localError = "Password must be at least 8 characters."
                return
            }
            // Email is mandatory now. Checked here so the obvious mistakes cost
            // no round trip; the server still has the final say (it also checks
            // the domain can actually receive mail and rejects disposable
            // providers, which this deliberately does not try to replicate).
            if let problem = AccountService.localEmailProblem(email) {
                localError = problem
                return
            }
        }

        isLoading = true
        Task {
            defer { isLoading = false }
            if isRegistering {
                await account.register(
                    username: trimmedUsername,
                    password: password,
                    // Trimmed, not passed raw: a copy-pasted address routinely
                    // carries a trailing space, and that space used to be stored
                    // verbatim — which silently defeated the uniqueness check,
                    // since the trailing form is not equal to the untrailed one.
                    email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                    displayName: displayName.isEmpty ? nil : displayName
                )
            } else {
                await account.login(username: trimmedUsername, password: password)
            }
            await completePostLoginSyncIfNeeded()
        }
    }

    private func discordSignInTapped() {
        localError = nil
        account.errorMessage = nil
        isDiscordLoggingIn = true
        Task {
            defer { isDiscordLoggingIn = false }
            await account.loginWithDiscord(presentationContext: discordPresentationContext)
            await completePostLoginSyncIfNeeded()
        }
    }

    /// Immediately pulls this user's server-side data (library state, gallery
    /// background settings, badges, etc.) instead of waiting for the next app
    /// launch — matters most when switching accounts within the same
    /// session. Shared by every path that can end in `account.isLoggedIn`
    /// flipping true (password sign-in/register, Discord sign-in) so none of
    /// them can forget this step.
    private func completePostLoginSyncIfNeeded() async {
        guard account.isLoggedIn else { return }
        await account.pullSync(library: libraryManager, player: player)
        account.startAutoPushTimer(library: libraryManager)
        await account.loadAvatar(forceRefresh: true)
    }
}
