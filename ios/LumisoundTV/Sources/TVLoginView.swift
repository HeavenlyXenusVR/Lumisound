import SwiftUI

// MARK: - TVLoginView

// Two halves: the brand on the left — the icon's gradient as a field of light
// with the mark and wordmark — and the form on the right. The previous screen
// stacked a generic TV glyph, the name, two fields and a button down the
// centre, which is the default shape of every sign-in screen and said nothing
// about which app you were signing in to.
struct TVLoginView: View {
    @ObservedObject var account: TVAccount

    @State private var username = ""
    @State private var password = ""
    @State private var glow = false

    var body: some View {
        ZStack {
            TVAmbientBackground()

            HStack(spacing: 0) {
                brandSide
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                formSide
                    .frame(width: 760)
                    .frame(maxHeight: .infinity)
                    .focusSection()
            }
        }
    }

    private var brandSide: some View {
        ZStack {
            // The icon's gradient as light rather than as a flat panel.
            RadialGradient(colors: [TVPalette.violet.opacity(glow ? 0.65 : 0.45), .clear],
                           center: .init(x: 0.35, y: 0.3), startRadius: 0, endRadius: 800)
            RadialGradient(colors: [TVPalette.blue.opacity(glow ? 0.5 : 0.35), .clear],
                           center: .init(x: 0.6, y: 0.85), startRadius: 0, endRadius: 700)

            VStack(alignment: .leading, spacing: 30) {
                TVBrandMark(height: 96)
                VStack(alignment: .leading, spacing: 12) {
                    Text("Lumisound")
                        .font(.system(size: 92, weight: .heavy, design: .rounded))
                    Text("Your music, on the big screen.")
                        .font(.system(size: 32, weight: .medium, design: .rounded))
                        .foregroundStyle(TVPalette.textSecondary)
                }
                HStack(spacing: 14) {
                    feature("square.stack.fill", "Your cloud library")
                    feature("music.note.list", "Synced playlists")
                    feature("quote.bubble.fill", "Live lyrics")
                }
                .padding(.top, 10)
            }
            .padding(.leading, 120)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .animation(.easeInOut(duration: 3).repeatForever(autoreverses: true), value: glow)
        .onAppear { glow = true }
    }

    private func feature(_ systemImage: String, _ text: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 20, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.08), in: Capsule())
    }

    private var formSide: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 8) {
                Text("SIGN IN")
                    .font(TVType.eyebrow)
                    .tracking(2.6)
                    .foregroundStyle(TVPalette.neonAlt)
                Text("Welcome back")
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                Text("Use the same account as the Lumisound iPhone app.")
                    .font(TVType.rowDetail)
                    .foregroundStyle(TVPalette.textSecondary)
            }

            VStack(spacing: 18) {
                TextField("Username", text: $username)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
                    .textContentType(.password)
            }

            if let err = account.errorText {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(TVType.rowDetail)
                    .foregroundStyle(Color(red: 1.0, green: 0.45, blue: 0.5))
            }

            Button {
                Task { await account.login(username: username, password: password) }
            } label: {
                TVPillLabel(title: "Sign In", systemImage: "arrow.right",
                            width: 540, isLoading: account.isLoggingIn)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .disabled(account.isLoggingIn || username.isEmpty || password.isEmpty)
            .opacity(username.isEmpty || password.isEmpty ? 0.6 : 1)
            .padding(.top, 6)
        }
        .padding(56)
        .tvGlassPanel(cornerRadius: 40)
        .padding(.trailing, 100)
    }
}
