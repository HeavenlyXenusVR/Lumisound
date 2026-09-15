import SwiftUI

// MARK: - TVStatsView
//
// Round 3: lifetime stats, a 7-day activity chart, and achievement badges —
// all from GET /user/stats, /user/stats/weekly, /user/achievements (the same
// server-side play-history aggregation iOS's AccountService+Stats.swift and
// AchievementsView.swift already use). Badge catalog ported from
// AchievementsView.swift's `allBadges`; the per-badge "how to unlock" detail
// sheet wasn't ported — title/icon/locked state only, for a first pass.

struct TVStatsView: View {
    @ObservedObject var client: TVBridgeClient
    let token: String

    var body: some View {
        ScrollView {
            if client.isLoadingStats && client.stats == nil {
                ProgressView("Loading your stats…").padding(.top, 100)
            } else {
                VStack(alignment: .leading, spacing: 50) {
                    lifetimeSection.padding(.horizontal, TVMetrics.margin)
                    topArtistsShelf
                    topTracksShelf
                    VStack(alignment: .leading, spacing: 50) {
                        weeklySection
                        badgesSection
                    }
                    .padding(.horizontal, TVMetrics.margin)
                }
                .padding(.vertical, 60)
            }
        }
        .tvAmbientBackground()
        .task {
            if client.stats == nil { await client.fetchStats(token: token) }
        }
    }

    // MARK: Lifetime summary

    private var lifetimeSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            TVSectionHeader(title: "Listening Stats")

            HStack(spacing: 40) {
                statTile("Total Plays", value: "\(client.stats?.totalPlays ?? 0)")
                statTile("Listening Time", value: formattedListenTime(client.stats?.totalListenSeconds ?? 0))
                statTile("Current Streak", value: streakLabel(client.achievements?.currentStreakDays ?? 0))
                statTile("Longest Streak", value: streakLabel(client.achievements?.longestStreakDays ?? 0))
            }
        }
    }

    @ViewBuilder
    private var topArtistsShelf: some View {
        if let stats = client.stats, !stats.topArtists.isEmpty {
            TVShelfSection(title: "Top Artists") {
                ForEach(Array(stats.topArtists.enumerated()), id: \.element.id) { index, artist in
                    rankCard(rank: index + 1, primary: artist.artist, secondary: nil, count: artist.playCount)
                }
            }
        }
    }

    @ViewBuilder
    private var topTracksShelf: some View {
        if let stats = client.stats, !stats.topTracks.isEmpty {
            TVShelfSection(title: "Top Tracks") {
                ForEach(Array(stats.topTracks.enumerated()), id: \.element.id) { index, track in
                    rankCard(rank: index + 1, primary: track.title, secondary: track.artist, count: track.playCount)
                }
            }
        }
    }

    private func rankCard(rank: Int, primary: String, secondary: String?, count: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("#\(rank)")
                    .font(.system(size: 30, weight: .heavy).monospacedDigit())
                    .foregroundStyle(Color.accentColor)
                Spacer()
                Text("\(count) plays")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Text(primary).font(.headline).lineLimit(2)
            if let secondary, !secondary.isEmpty {
                Text(secondary).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(20)
        .frame(width: 240, height: 200, alignment: .topLeading)
        .tvGlassPanel()
    }

    private func statTile(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(value)
                .font(.system(size: 30, weight: .bold).monospacedDigit())
                .foregroundStyle(
                    LinearGradient(colors: [.white, Color.accentColor],
                                   startPoint: .leading, endPoint: .trailing)
                )
            Text(label).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .tvGlassPanel()
    }

    // MARK: Weekly activity

    private var weeklySection: some View {
        VStack(alignment: .leading, spacing: 20) {
            TVSectionHeader(title: "This Week")
            if client.weeklyStats.isEmpty {
                Text("No listening activity in the last 7 days yet.")
                    .font(.title3).foregroundStyle(.secondary)
            } else {
                let maxSeconds = max(1, client.weeklyStats.map(\.listenSeconds).max() ?? 1)
                HStack(alignment: .bottom, spacing: 24) {
                    ForEach(client.weeklyStats) { day in
                        VStack(spacing: 10) {
                            Text("\(day.plays)")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.accentColor.opacity(day.listenSeconds > 0 ? 0.85 : 0.15))
                                .frame(width: 44, height: max(6, 140 * CGFloat(day.listenSeconds) / CGFloat(maxSeconds)))
                            Text(weekdayLabel(day.date))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(height: 190, alignment: .bottom)
            }
        }
    }

    private func weekdayLabel(_ isoDate: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        guard let date = formatter.date(from: isoDate) else { return "" }
        let weekday = DateFormatter()
        weekday.dateFormat = "EEE"
        return weekday.string(from: date)
    }

    // MARK: Achievements

    private var badgesSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            TVSectionHeader(title: "Achievements")
            let unlocked = Set(client.achievements?.badges ?? [])
            let columns = [GridItem(.adaptive(minimum: 160), spacing: 24)]
            LazyVGrid(columns: columns, spacing: 24) {
                ForEach(TVBadge.all) { badge in
                    badgeCell(badge, isUnlocked: unlocked.contains(badge.id))
                }
            }
        }
    }

    private func badgeCell(_ badge: TVBadge, isUnlocked: Bool) -> some View {
        VStack(spacing: 10) {
            Image(systemName: badge.icon)
                .font(.system(size: 34))
                .foregroundStyle(isUnlocked ? Color.accentColor : Color.secondary)
                .frame(width: 90, height: 90)
                .background(.white.opacity(isUnlocked ? 0.12 : 0.05), in: Circle())
                .shadow(color: isUnlocked ? Color.accentColor.opacity(0.55) : .clear, radius: isUnlocked ? 16 : 0)
            Text(badge.title)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(isUnlocked ? Color.primary : Color.secondary)
        }
        .opacity(isUnlocked ? 1 : 0.5)
        .frame(width: 160)
    }

    private func streakLabel(_ days: Int) -> String {
        "\(days) \(days == 1 ? "day" : "days")"
    }

    private func formattedListenTime(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}

// MARK: - TVBadge (ported catalog from AchievementsView.swift's `allBadges`)

struct TVBadge: Identifiable {
    let id: String
    let title: String
    let icon: String

    static let all: [TVBadge] = [
        TVBadge(id: "plays_10", title: "10 Plays", icon: "play.circle"),
        TVBadge(id: "plays_50", title: "50 Plays", icon: "play.circle.fill"),
        TVBadge(id: "plays_100", title: "100 Plays", icon: "repeat.circle"),
        TVBadge(id: "plays_500", title: "500 Plays", icon: "repeat.circle.fill"),
        TVBadge(id: "plays_1000", title: "1000 Plays", icon: "star.circle.fill"),
        TVBadge(id: "hours_1", title: "1 Hour Listened", icon: "clock"),
        TVBadge(id: "hours_10", title: "10 Hours Listened", icon: "clock.fill"),
        TVBadge(id: "hours_24", title: "24 Hours Listened", icon: "timer"),
        TVBadge(id: "hours_100", title: "100 Hours Listened", icon: "hourglass"),
        TVBadge(id: "streak_3", title: "3-Day Streak", icon: "flame"),
        TVBadge(id: "streak_7", title: "Week Streak", icon: "flame.fill"),
        TVBadge(id: "streak_30", title: "Month Streak", icon: "calendar"),
        TVBadge(id: "streak_100", title: "100-Day Streak", icon: "calendar.badge.clock"),
        TVBadge(id: "night_owl", title: "Night Owl", icon: "moon.stars.fill"),
        TVBadge(id: "early_bird", title: "Early Bird", icon: "sunrise.fill"),
        TVBadge(id: "marathon", title: "Marathon", icon: "figure.run.circle.fill"),
        TVBadge(id: "crate_digger", title: "Crate Digger", icon: "shippingbox.fill"),
        TVBadge(id: "globe_trotter", title: "Globe Trotter", icon: "globe"),
        TVBadge(id: "completionist", title: "Completionist", icon: "checkmark.seal.fill"),
        TVBadge(id: "shuffle_master", title: "Shuffle Master", icon: "shuffle"),
    ]
}
