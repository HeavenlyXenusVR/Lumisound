import SwiftUI

// MARK: - You

/// Everything about the listener in one place: profile, social, listening
/// insights, and the way into Settings.
struct LumenYouView: View {
    @EnvironmentObject private var account: AccountService
    @EnvironmentObject private var library: LibraryManager
    @EnvironmentObject private var social: SocialService

    @AppStorage("carModeEnabled") private var carModeEnabled: Bool = false
    @State private var showLogin = false

    private var displayName: String {
        guard let user = account.currentUser else { return "Listener" }
        return user.displayName?.isEmpty == false ? user.displayName! : user.username
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                LumenScreenHeader(eyebrow: "Your space", title: "You") {
                    NavigationLink(value: LumenRoute.settings) {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(LumenPalette.textPrimary)
                            .frame(width: 38, height: 38)
                            .background(Circle().fill(LumenPalette.fill))
                            .overlay(Circle().strokeBorder(LumenPalette.hairline, lineWidth: 1))
                    }
                    .accessibilityLabel("Settings")
                }

                profileCard

                if account.isLoggedIn { socialCard }

                insights

                VStack(spacing: 0) {
                    NavigationLink(value: LumenRoute.settings) {
                        LumenNavRow(title: "Settings", systemImage: "gearshape.fill", tint: LumenPalette.textTertiary)
                    }
                    .buttonStyle(.plain)
                    if account.isLoggedIn {
                        Divider().overlay(LumenPalette.hairline).padding(.leading, 48)
                        NavigationLink(value: LumenRoute.account) {
                            LumenNavRow(title: "Account & Security", systemImage: "lock.shield.fill", tint: LumenPalette.azure)
                        }
                        .buttonStyle(.plain)
                    }
                    Divider().overlay(LumenPalette.hairline).padding(.leading, 48)
                    NavigationLink(value: LumenRoute.libraryHealth) {
                        LumenNavRow(title: "Library Health", systemImage: "stethoscope", tint: LumenPalette.success)
                    }
                    .buttonStyle(.plain)
                    if carModeEnabled {
                        Divider().overlay(LumenPalette.hairline).padding(.leading, 48)
                        Button {
                            NotificationCenter.default.post(name: .lumenShowCarMode, object: nil)
                        } label: {
                            LumenNavRow(title: "Car Mode", systemImage: "car.fill", tint: LumenPalette.warning)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .lumenCard()
                .padding(.horizontal, LumenMetrics.gutter)

                VStack(alignment: .leading, spacing: 12) {
                    Text("INTERFACE")
                        .font(LumenType.eyebrow())
                        .tracking(1.6)
                        .foregroundStyle(LumenPalette.textTertiary)
                    InterfaceEditionPicker()
                }
                .padding(.horizontal, LumenMetrics.gutter)
            }
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showLogin) {
            LoginView().environmentObject(account)
        }
        .task {
            if account.isLoggedIn && account.stats == nil { await account.fetchStats() }
        }
    }

    // MARK: Profile

    @ViewBuilder
    private var profileCard: some View {
        if account.isLoggedIn {
            VStack(spacing: 18) {
                HStack(spacing: 16) {
                    avatar
                    VStack(alignment: .leading, spacing: 3) {
                        Text(displayName)
                            .font(LumenType.title(22))
                            .foregroundStyle(LumenPalette.textPrimary)
                            .lineLimit(1)
                        if let username = account.currentUser?.username {
                            Text("@\(username)")
                                .font(LumenType.caption(13))
                                .foregroundStyle(LumenPalette.textSecondary)
                        }
                        NavigationLink(value: LumenRoute.profile) {
                            HStack(spacing: 4) {
                                Text("View profile")
                                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                            }
                            .font(LumenType.headline(13))
                            .foregroundStyle(LumenPalette.accent)
                        }
                        .padding(.top, 2)
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 8) {
                    LumenStat(value: "\(library.allSongs.count)", label: "Songs")
                    LumenStat(value: "\(library.playlists.count)", label: "Playlists")
                    if let stats = account.stats {
                        LumenStat(value: "\(stats.totalPlays)", label: "Plays")
                        LumenStat(value: "\(stats.totalListenSeconds / 3600)h", label: "Listened")
                    } else {
                        LumenStat(value: "\(library.favoriteSongIDs.count)", label: "Favorites")
                    }
                }
            }
            .lumenCard(padding: 18)
            .padding(.horizontal, LumenMetrics.gutter)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    avatar
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Sign in to Lumisound")
                            .font(LumenType.title(19))
                            .foregroundStyle(LumenPalette.textPrimary)
                        Text("Sync your library, see your stats, and listen with friends.")
                            .font(LumenType.caption(13))
                            .foregroundStyle(LumenPalette.textSecondary)
                    }
                }
                LumenPrimaryButton(title: "Sign In", systemImage: "person.fill", expands: true) { showLogin = true }
            }
            .lumenCard(padding: 18)
            .padding(.horizontal, LumenMetrics.gutter)
        }
    }

    private var avatar: some View {
        ZStack {
            Circle().fill(LumenPalette.glow).frame(width: 72, height: 72).blur(radius: 10).opacity(0.6)
            Group {
                if let image = account.avatarImage {
                    if (image.images?.count ?? 0) > 1 {
                        AnimatedImageView(image: image, contentMode: .scaleAspectFill)
                    } else {
                        Image(uiImage: image).resizable().scaledToFill()
                    }
                } else {
                    LumenGeneratedArt(seed: displayName, showsMonogram: true)
                }
            }
            .frame(width: 68, height: 68)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(LumenPalette.glow, lineWidth: 2))
        }
    }

    // MARK: Social

    private var socialCard: some View {
        HStack(spacing: 12) {
            socialTile("Friends", icon: "person.2.fill", route: .friends,
                       badge: social.incomingRequests.count, colors: [LumenPalette.iris, LumenPalette.azure])
            socialTile("Rooms", icon: "dot.radiowaves.left.and.right", route: .listenRooms,
                       badge: 0, colors: [LumenPalette.ember, Color(red: 0.85, green: 0.25, blue: 0.55)])
            socialTile("Inbox", icon: "bell.fill", route: .notifications,
                       badge: account.unreadNotificationCount, colors: [LumenPalette.success, Color(red: 0.1, green: 0.55, blue: 0.6)])
        }
        .padding(.horizontal, LumenMetrics.gutter)
    }

    private func socialTile(_ title: String, icon: String, route: LumenRoute, badge: Int, colors: [Color]) -> some View {
        NavigationLink(value: route) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                    Spacer()
                    if badge > 0 {
                        Text("\(min(badge, 99))")
                            .font(LumenType.eyebrow(11))
                            .foregroundStyle(colors[0])
                            .padding(.horizontal, 6)
                            .frame(minWidth: 20, minHeight: 20)
                            .background(Color.white, in: Capsule())
                    }
                }
                Text(title)
                    .font(LumenType.headline(15))
                    .foregroundStyle(.white)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(LumenPressStyle())
        .accessibilityLabel(badge > 0 ? "\(title), \(badge) new" : title)
    }

    // MARK: Insights

    private struct Insight: Identifiable {
        let id: String
        let title: String
        let icon: String
        let tint: Color
        let route: LumenRoute
    }

    private var insightItems: [Insight] {
        [
            Insight(id: "rewind", title: "Rewind", icon: "chart.bar.xaxis", tint: LumenPalette.iris, route: .rewind),
            Insight(id: "stats", title: "Stats", icon: "chart.pie.fill", tint: LumenPalette.azure, route: .stats),
            Insight(id: "achievements", title: "Achievements", icon: "trophy.fill", tint: LumenPalette.warning, route: .achievements),
            Insight(id: "heatmap", title: "Heatmap", icon: "calendar", tint: LumenPalette.success, route: .heatmap),
            Insight(id: "goal", title: "Goal", icon: "target", tint: LumenPalette.ember, route: .goal),
            Insight(id: "capsules", title: "Time Capsules", icon: "shippingbox.fill", tint: Color(red: 0.6, green: 0.45, blue: 0.95), route: .timeCapsules),
            Insight(id: "constellation", title: "Constellation", icon: "sparkles", tint: Color(red: 0.4, green: 0.7, blue: 1), route: .constellation),
            Insight(id: "onthisday", title: "On This Day", icon: "clock.arrow.circlepath", tint: Color(red: 0.95, green: 0.55, blue: 0.75), route: .onThisDay),
            Insight(id: "mix", title: "Discover Mix", icon: "wand.and.stars", tint: LumenPalette.iris, route: .discoverMix),
            Insight(id: "needle", title: "Needle Drop", icon: "questionmark.circle.fill", tint: LumenPalette.azure, route: .needleDrop),
            Insight(id: "podcasts", title: "Podcasts", icon: "mic.fill", tint: Color(red: 0.6, green: 0.35, blue: 0.95), route: .podcasts),
            Insight(id: "discover", title: "Discover", icon: "safari.fill", tint: LumenPalette.success, route: .discover),
        ]
    }

    private var insights: some View {
        VStack(alignment: .leading, spacing: 12) {
            LumenSectionHeader(title: "Your Listening", subtitle: "Insights, games and mixes")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                      spacing: 10) {
                ForEach(insightItems) { item in
                    NavigationLink(value: item.route) {
                        VStack(spacing: 10) {
                            Image(systemName: item.icon)
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(item.tint)
                                .frame(width: 44, height: 44)
                                .background(item.tint.opacity(0.16), in: Circle())
                            Text(item.title)
                                .font(LumenType.caption(12))
                                .foregroundStyle(LumenPalette.textPrimary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(LumenPalette.surface.opacity(0.75), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(LumenPalette.hairline, lineWidth: 1))
                    }
                    .buttonStyle(LumenPressStyle())
                }
            }
            .padding(.horizontal, LumenMetrics.gutter)
        }
    }
}

// MARK: - Settings index

struct LumenSettingsView: View {
    @EnvironmentObject private var account: AccountService
    @EnvironmentObject private var updater: UpdateService

    private let pages: [(page: SettingsView.SettingsTab, icon: String, tint: Color)] = [
        (.general, "person.crop.circle.fill", LumenPalette.azure),
        (.audio, "waveform", Color(red: 0.2, green: 0.8, blue: 0.75)),
        (.library, "music.note.list", Color(red: 0.95, green: 0.45, blue: 0.75)),
        (.ytdlp, "arrow.down.circle.fill", LumenPalette.warning),
        (.app, "info.circle.fill", LumenPalette.success),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if updater.updateAvailable {
                    NavigationLink(value: LumenRoute.settingsPage(.app)) {
                        HStack(spacing: 12) {
                            Image(systemName: "arrow.down.app.fill")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(.white)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Update available").font(LumenType.headline(15)).foregroundStyle(.white)
                                Text("Tap to see what's new").font(LumenType.caption(12)).foregroundStyle(.white.opacity(0.8))
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.white.opacity(0.8))
                        }
                        .padding(16)
                        .background(LumenPalette.glow, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    .buttonStyle(LumenPressStyle())
                    .padding(.horizontal, LumenMetrics.gutter)
                }

                VStack(spacing: 0) {
                    ForEach(pages, id: \.page) { item in
                        NavigationLink(value: LumenRoute.settingsPage(item.page)) {
                            HStack(spacing: 14) {
                                Image(systemName: item.icon)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 38, height: 38)
                                    .background(
                                        LinearGradient(colors: [item.tint, item.tint.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing),
                                        in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    )
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.page.lumenTitle)
                                        .font(LumenType.headline(16))
                                        .foregroundStyle(LumenPalette.textPrimary)
                                    Text(item.page.lumenSubtitle)
                                        .font(LumenType.caption(12))
                                        .foregroundStyle(LumenPalette.textSecondary)
                                        .lineLimit(2)
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(LumenPalette.textTertiary)
                            }
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if item.page != pages.last?.page {
                            Divider().overlay(LumenPalette.hairline).padding(.leading, 52)
                        }
                    }
                }
                .lumenCard()
                .padding(.horizontal, LumenMetrics.gutter)

                VStack(alignment: .leading, spacing: 0) {
                    Text("LOOK & FEEL")
                        .font(LumenType.eyebrow())
                        .tracking(1.6)
                        .foregroundStyle(LumenPalette.textTertiary)
                        .padding(.bottom, 8)
                    NavigationLink(destination: AppearanceView()) {
                        LumenNavRow(title: "Colors & Type", systemImage: "paintpalette.fill", tint: LumenPalette.accent)
                    }
                    .buttonStyle(.plain)
                    Divider().overlay(LumenPalette.hairline).padding(.leading, 48)
                    NavigationLink(destination: BackgroundSettingsView()) {
                        LumenNavRow(title: "Background", systemImage: "photo.on.rectangle", tint: LumenPalette.azure)
                    }
                    .buttonStyle(.plain)
                    Divider().overlay(LumenPalette.hairline).padding(.leading, 48)
                    NavigationLink(destination: GlassSettingsView()) {
                        LumenNavRow(title: "Liquid Glass", systemImage: "circle.hexagongrid.fill", tint: Color(red: 0.4, green: 0.75, blue: 1))
                    }
                    .buttonStyle(.plain)
                }
                .lumenCard()
                .padding(.horizontal, LumenMetrics.gutter)

                VStack(alignment: .leading, spacing: 12) {
                    Text("INTERFACE")
                        .font(LumenType.eyebrow())
                        .tracking(1.6)
                        .foregroundStyle(LumenPalette.textTertiary)
                    InterfaceEditionPicker()
                }
                .padding(.horizontal, LumenMetrics.gutter)
            }
            .padding(.vertical, 12)
        }
        .scrollIndicators(.hidden)
        .lumenScreen(title: "Settings")
    }
}
