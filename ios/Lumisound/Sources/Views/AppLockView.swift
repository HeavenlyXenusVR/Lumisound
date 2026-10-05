import SwiftUI

/// Full-screen cover shown over the whole app while `AppLockService.isUnlocked`
/// is false. Deliberately minimal (no library stats, no account greeting like
/// `LaunchView`) — this can appear every time the app returns from background,
/// so it needs to get out of the way fast once authenticated, not perform an
/// entrance animation each time.
struct AppLockView: View {
    @EnvironmentObject private var appLock: AppLockService

    var body: some View {
        Group {
            if InterfaceEdition.isLumen {
                lumenBody
            } else {
                classicBody
            }
        }
        .task {
            // Prompt immediately on first appearance (app launch with locking
            // on, or returning from background) rather than making the user
            // tap "Unlock" every single time.
            await appLock.authenticate()
        }
    }

    /// Lumen: the lit ground, the breathing app mark, and a glow button.
    private var lumenBody: some View {
        ZStack {
            LumenBackdrop(intensity: 1.4)
            VStack(spacing: 18) {
                Spacer()
                LumenLaunchMark(animate: appLock.isAuthenticating)
                VStack(spacing: 6) {
                    Text("LOCKED")
                        .font(LumenType.eyebrow())
                        .tracking(2)
                        .foregroundStyle(LumenPalette.accent)
                    Text("Lumisound")
                        .font(LumenType.display(32))
                        .foregroundStyle(LumenPalette.textPrimary)
                    Text("Unlock with \(appLock.biometryTypeName) to continue")
                        .font(LumenType.body(15))
                        .foregroundStyle(LumenPalette.textSecondary)
                }
                Spacer()
                LumenPrimaryButton(
                    title: appLock.isAuthenticating ? "Unlocking\u{2026}" : "Unlock",
                    systemImage: biometryIcon,
                    expands: true
                ) {
                    Task { await appLock.authenticate() }
                }
                .disabled(appLock.isAuthenticating)
                .padding(.horizontal, 32)
                .padding(.bottom, 48)
            }
        }
    }

    private var classicBody: some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()

            VStack(spacing: 20) {
                Spacer()

                Image("AppIconDisplay")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 84, height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(.white.opacity(0.18), lineWidth: 1)
                    )
                    .shadow(color: AppTheme.dynamicAccent.opacity(0.4), radius: 20, x: 0, y: 6)

                VStack(spacing: 6) {
                    Text("Lumisound Locked")
                        .font(.title2.bold())
                        .foregroundStyle(AppTheme.textPrimary)
                    Text("Unlock with \(appLock.biometryTypeName) to continue")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.textSecondary)
                }

                Spacer()

                Button {
                    Task { await appLock.authenticate() }
                } label: {
                    Label(
                        appLock.isAuthenticating ? "Unlocking\u{2026}" : "Unlock",
                        systemImage: biometryIcon
                    )
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(AppTheme.dynamicAccent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(appLock.isAuthenticating)
                .padding(.horizontal, 32)
                .padding(.bottom, 48)
            }
        }
    }

    private var biometryIcon: String {
        switch appLock.biometryTypeName {
        case "Face ID": return "faceid"
        case "Touch ID": return "touchid"
        case "Optic ID": return "opticid"
        default: return "lock.fill"
        }
    }
}
