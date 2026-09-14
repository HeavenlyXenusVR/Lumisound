import SwiftUI

/// All-time on-device listening stats — top songs, top artists, total plays,
/// estimated listening time — computed entirely from `PlayHistoryStore`
/// (itself fed by `AudioPlayerManager` once a track has played ~5s, so
/// instant skips don't count). No server involved; nothing here leaves the
/// device. Doesn't break down by week/month since only a running total +
/// last-played date is tracked per song, not a full per-play log.
struct ListeningStatsView: View {
    @EnvironmentObject private var library: LibraryManager

    @State private var totalPlays = 0
    @State private var estimatedSeconds: TimeInterval = 0
    @State private var topSongs: [(song: Song, plays: Int)] = []
    @State private var topArtists: [(artist: String, plays: Int)] = []

    var body: some View {
        List {
            summarySection
            topSongsSection
            topArtistsSection
        }
        .scrollContentBackground(.hidden)
        .background(AppTheme.background.ignoresSafeArea())
        .navigationTitle("Listening Stats")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: recompute)
    }

    @ViewBuilder
    private var summarySection: some View {
        Section {
            HStack {
                statTile(value: "\(totalPlays)", label: "Total Plays")
                Divider().frame(height: 36)
                statTile(value: estimatedTimeText, label: "Est. Listening Time")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        } footer: {
            Text("Counts a play once a track has been playing for at least 5 seconds, so instant skips don't inflate the numbers. Listening time is estimated from play count × track length, not actual seconds heard.")
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
        }
        .listRowBackground(tintedRowBackground(.pink))
    }

    private var estimatedTimeText: String {
        let hours = Int(estimatedSeconds) / 3600
        let minutes = (Int(estimatedSeconds) % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    private func statTile(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title2.bold())
                .foregroundStyle(AppTheme.textPrimary)
            Text(label)
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var topSongsSection: some View {
        if !topSongs.isEmpty {
            Section {
                ForEach(Array(topSongs.enumerated()), id: \.offset) { index, entry in
                    HStack(spacing: 12) {
                        Text("\(index + 1)")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(AppTheme.textSecondary)
                            .frame(width: 20)
                        SongRow(song: entry.song, isCurrent: false)
                        Text("\(entry.plays)×")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(AppTheme.dynamicAccent)
                    }
                }
            } header: {
                sectionHeader("Top Songs")
            }
            .listRowBackground(tintedRowBackground(.pink))
        }
    }

    @ViewBuilder
    private var topArtistsSection: some View {
        if !topArtists.isEmpty {
            Section {
                ForEach(Array(topArtists.enumerated()), id: \.offset) { index, entry in
                    HStack(spacing: 12) {
                        Text("\(index + 1)")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(AppTheme.textSecondary)
                            .frame(width: 20)
                        Text(entry.artist)
                            .foregroundStyle(AppTheme.textPrimary)
                        Spacer()
                        Text("\(entry.plays) plays")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(AppTheme.dynamicAccent)
                    }
                }
            } header: {
                sectionHeader("Top Artists")
            }
            .listRowBackground(tintedRowBackground(.pink))
        } else if topSongs.isEmpty {
            Section {
                EmptyStateView(
                    icon: "chart.bar",
                    title: "No listening history yet",
                    message: "Play a few tracks and your stats will show up here."
                )
            }
            .listRowBackground(Color.clear)
        }
    }

    private func recompute() {
        let history = PlayHistoryStore.shared
        let songs = library.allSongs

        var plays = 0
        var seconds: TimeInterval = 0
        var artistPlays: [String: Int] = [:]
        var songPlays: [(song: Song, plays: Int)] = []

        for song in songs {
            let count = history.playCount(for: song.id)
            guard count > 0 else { continue }
            plays += count
            seconds += song.duration * Double(count)
            artistPlays[song.artistName, default: 0] += count
            songPlays.append((song: song, plays: count))
        }

        totalPlays = plays
        estimatedSeconds = seconds
        topSongs = Array(songPlays.sorted { $0.plays > $1.plays }.prefix(15))
        topArtists = Array(
            artistPlays.map { (artist: $0.key, plays: $0.value) }
                .sorted { $0.plays > $1.plays }
                .prefix(10)
        )
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(AppTheme.bodyFont(size: 11))
            .foregroundStyle(AppTheme.textSecondary)
            .kerning(0.8)
    }
}
