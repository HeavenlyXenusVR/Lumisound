import Foundation
import Combine

// MARK: - Smart Playlist model
//
// A dynamic, rules-based playlist. Unlike a normal playlist (a fixed list of
// song IDs), a smart playlist stores a set of rules that are evaluated live
// against `LibraryManager.allSongs` every time it's opened — so "Favorites
// added recently", "120-135 BPM workout", "downloaded from YouTube", etc. stay
// up to date on their own. Stored locally (UserDefaults); no server dependency.

enum SmartField: String, Codable, CaseIterable, Identifiable {
    case title, artist, album, genre, year, duration, bpm, favorite, source
    case playCount, daysSincePlayed, daysSinceAdded

    var id: String { rawValue }

    var label: String {
        switch self {
        case .title: return "Title"
        case .artist: return "Artist"
        case .album: return "Album"
        case .genre: return "Genre"
        case .year: return "Year"
        case .duration: return "Duration (sec)"
        case .bpm: return "BPM"
        case .favorite: return "Favorite"
        case .source: return "Source"
        case .playCount: return "Play Count"
        case .daysSincePlayed: return "Days Since Played"
        case .daysSinceAdded: return "Days Since Added"
        }
    }

    var kind: SmartFieldKind {
        switch self {
        case .title, .artist, .album, .genre: return .text
        case .year, .duration, .bpm, .playCount, .daysSincePlayed, .daysSinceAdded: return .number
        case .favorite: return .boolean
        case .source: return .source
        }
    }
}

enum SmartFieldKind { case text, number, boolean, source }

enum SmartOp: String, Codable, CaseIterable, Identifiable {
    case contains, notContains, equals, greaterThan, lessThan, between, isTrue, isFalse

    var id: String { rawValue }

    var label: String {
        switch self {
        case .contains: return "contains"
        case .notContains: return "does not contain"
        case .equals: return "is"
        case .greaterThan: return "greater than"
        case .lessThan: return "less than"
        case .between: return "between"
        case .isTrue: return "is yes"
        case .isFalse: return "is no"
        }
    }

    /// The operators that make sense for a given field kind.
    static func available(for kind: SmartFieldKind) -> [SmartOp] {
        switch kind {
        case .text:    return [.contains, .notContains, .equals]
        case .number:  return [.equals, .greaterThan, .lessThan, .between]
        case .boolean: return [.isTrue, .isFalse]
        case .source:  return [.equals]
        }
    }
}

/// Possible values for the `.source` field.
enum SmartSource: String, Codable, CaseIterable, Identifiable {
    case youtube, soundcloud, local
    var id: String { rawValue }
    var label: String {
        switch self {
        case .youtube: return "YouTube"
        case .soundcloud: return "SoundCloud"
        case .local: return "On-device / Imported"
        }
    }
}

struct SmartRule: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var field: SmartField = .title
    var op: SmartOp = .contains
    var text: String = ""
    var number: Double = 0
    var number2: Double = 0   // upper bound for `.between`
    var source: SmartSource = .youtube
}

enum SmartMatch: String, Codable, CaseIterable, Identifiable {
    case all, any
    var id: String { rawValue }
    var label: String { self == .all ? "Match ALL rules" : "Match ANY rule" }
}

enum SmartSort: String, Codable, CaseIterable, Identifiable {
    case titleAsc, artistAsc, yearDesc, bpmAsc, durationAsc, random
    case playCountDesc, recentlyPlayedDesc, recentlyAddedDesc
    var id: String { rawValue }
    var label: String {
        switch self {
        case .titleAsc: return "Title (A–Z)"
        case .artistAsc: return "Artist (A–Z)"
        case .yearDesc: return "Year (newest)"
        case .bpmAsc: return "BPM (low→high)"
        case .durationAsc: return "Duration (short→long)"
        case .random: return "Random"
        case .playCountDesc: return "Most Played"
        case .recentlyPlayedDesc: return "Recently Played"
        case .recentlyAddedDesc: return "Recently Added"
        }
    }
}

struct SmartPlaylist: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var name: String = "New Smart Playlist"
    var icon: String = "sparkles"
    var match: SmartMatch = .all
    var rules: [SmartRule] = []
    var limit: Int = 0        // 0 = unlimited
    var sort: SmartSort = .titleAsc
    /// Optional Lua predicate applied ON TOP OF `rules` (an additional AND
    /// condition), for logic the fixed field/operator grid above can't
    /// express — arbitrary boolean/string/math logic across every field at
    /// once. `nil`/empty for the overwhelming majority of playlists that
    /// don't need it; optional (rather than a non-optional default) so
    /// playlists persisted before this field existed still decode fine (see
    /// `queueSource` on `Song` for the identical reasoning). The script must
    /// define `function matches(song) ... end` — see
    /// `LuaSmartPlaylistEngine` for the exact fields `song` carries.
    var luaScript: String? = nil

    // MARK: Evaluation

    /// Returns the songs from `songs` that satisfy this playlist's rules
    /// (and, if set, its Lua predicate), sorted and limited. `favorites` is
    /// `LibraryManager.favoriteSongIDs`.
    @MainActor
    func evaluate(over songs: [Song], favorites: Set<String>) -> [Song] {
        var filtered = songs.filter { matches($0, favorites: favorites) }
        if let luaScript, !luaScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // A script that fails to run (bad syntax, threw, …) leaves the
            // native-rules-only result alone rather than silently emptying
            // the playlist — `nil` specifically means "couldn't evaluate",
            // as opposed to a real empty match set (`[]`).
            if let allowedIDs = LuaSmartPlaylistEngine.filterSongIDs(script: luaScript, songs: filtered, favorites: favorites) {
                filtered = filtered.filter { allowedIDs.contains($0.id) }
            }
        }
        let sorted = sortSongs(filtered)
        if limit > 0 { return Array(sorted.prefix(limit)) }
        return sorted
    }

    @MainActor
    func matches(_ song: Song, favorites: Set<String>) -> Bool {
        guard !rules.isEmpty else { return true }
        let results = rules.map { evaluate(rule: $0, song: song, favorites: favorites) }
        return match == .all ? results.allSatisfy { $0 } : results.contains(true)
    }

    @MainActor
    private func evaluate(rule: SmartRule, song: Song, favorites: Set<String>) -> Bool {
        switch rule.field.kind {
        case .text:
            let value = textValue(of: rule.field, in: song)
            switch rule.op {
            case .contains:    return value.localizedCaseInsensitiveContains(rule.text)
            case .notContains: return !value.localizedCaseInsensitiveContains(rule.text)
            case .equals:      return value.compare(rule.text, options: .caseInsensitive) == .orderedSame
            default:           return false
            }
        case .number:
            guard let value = numberValue(of: rule.field, in: song) else { return false }
            switch rule.op {
            case .equals:      return abs(value - rule.number) < 0.5
            case .greaterThan: return value > rule.number
            case .lessThan:    return value < rule.number
            case .between:
                let lo = min(rule.number, rule.number2)
                let hi = max(rule.number, rule.number2)
                return value >= lo && value <= hi
            default:           return false
            }
        case .boolean:
            let isFav = favorites.contains(song.id)
            return rule.op == .isTrue ? isFav : !isFav
        case .source:
            return Self.sourceValue(of: song) == rule.source
        }
    }

    private func textValue(of field: SmartField, in song: Song) -> String {
        switch field {
        case .title:  return song.title
        case .artist: return song.artist
        case .album:  return song.album
        case .genre:  return song.genre
        default:      return ""
        }
    }

    @MainActor
    private func numberValue(of field: SmartField, in song: Song) -> Double? {
        switch field {
        case .year:     return Double(song.year.trimmingCharacters(in: .whitespaces))
        case .duration: return song.duration > 0 ? song.duration : nil
        case .bpm:      return song.bpm
        case .playCount:
            return Double(PlayHistoryStore.shared.playCount(for: song.id))
        case .daysSincePlayed:
            guard let lastPlayed = PlayHistoryStore.shared.lastPlayedAt(for: song.id) else {
                return .greatestFiniteMagnitude // never played — treat as "longest ago"
            }
            return Date().timeIntervalSince(lastPlayed) / 86400
        case .daysSinceAdded:
            guard let dateAdded = song.dateAdded else { return nil }
            return Date().timeIntervalSince(dateAdded) / 86400
        default:        return nil
        }
    }

    /// Also used by `LuaSmartPlaylistEngine` to fill in a song's `source`
    /// fact for scripts — `static` since it depends only on `song`, not any
    /// playlist state.
    static func sourceValue(of song: Song) -> SmartSource {
        guard let s = song.sourceTrackID?.lowercased() else { return .local }
        if s.hasPrefix("youtube") { return .youtube }
        if s.hasPrefix("soundcloud") { return .soundcloud }
        return .local
    }

    @MainActor
    private func sortSongs(_ songs: [Song]) -> [Song] {
        switch sort {
        case .titleAsc:    return songs.sortedByDisplayName()
        case .artistAsc:   return songs.sorted { $0.artist.localizedCaseInsensitiveCompare($1.artist) == .orderedAscending }
        case .yearDesc:    return songs.sorted { (Int($0.year) ?? 0) > (Int($1.year) ?? 0) }
        case .bpmAsc:      return songs.sorted { ($0.bpm ?? 0) < ($1.bpm ?? 0) }
        case .durationAsc: return songs.sorted { $0.duration < $1.duration }
        case .random:      return songs.shuffled()
        case .playCountDesc:
            return songs.sorted { PlayHistoryStore.shared.playCount(for: $0.id) > PlayHistoryStore.shared.playCount(for: $1.id) }
        case .recentlyPlayedDesc:
            return songs.sorted {
                (PlayHistoryStore.shared.lastPlayedAt(for: $0.id) ?? .distantPast)
                    > (PlayHistoryStore.shared.lastPlayedAt(for: $1.id) ?? .distantPast)
            }
        case .recentlyAddedDesc:
            return songs.sorted { ($0.dateAdded ?? .distantPast) > ($1.dateAdded ?? .distantPast) }
        }
    }
}

// MARK: - SmartPlaylistStore

/// Local persistence for smart playlists (UserDefaults-backed), mirroring
/// `TrackedPlaylistStore`. No server sync — smart playlists are derived data.
@MainActor
final class SmartPlaylistStore: ObservableObject {
    static let shared = SmartPlaylistStore()

    @Published private(set) var playlists: [SmartPlaylist] = []

    private let key = "smartPlaylists.v1"
    private static let seededDefaultsKey = "smartPlaylists.seededDefaults.v1"

    init() {
        load()
        seedDefaultsIfNeeded()
    }

    /// Adds four starter smart playlists (Recently Added, Most Played,
    /// Forgotten Favorites, Quick Listens) the first time this ever runs on
    /// a device — all built from ordinary rules, so users can edit/delete
    /// them like anything else they'd create themselves. Gated on a flag
    /// rather than "playlists.isEmpty" so deleting all of them later
    /// doesn't bring them back.
    private func seedDefaultsIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.seededDefaultsKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.seededDefaultsKey)
        guard playlists.isEmpty else { return }
        playlists = [
            SmartPlaylist(
                name: "Recently Added", icon: "clock.badge.checkmark", match: .all,
                rules: [SmartRule(field: .daysSinceAdded, op: .lessThan, number: 30)],
                sort: .recentlyAddedDesc
            ),
            SmartPlaylist(
                name: "Most Played", icon: "flame.fill", match: .all,
                rules: [SmartRule(field: .playCount, op: .greaterThan, number: 0)],
                limit: 100, sort: .playCountDesc
            ),
            SmartPlaylist(
                name: "Forgotten Favorites", icon: "heart.slash", match: .all,
                rules: [
                    SmartRule(field: .favorite, op: .isTrue),
                    SmartRule(field: .daysSincePlayed, op: .greaterThan, number: 60),
                ],
                sort: .recentlyPlayedDesc
            ),
            SmartPlaylist(
                name: "Quick Listens", icon: "bolt.fill", match: .all,
                rules: [SmartRule(field: .duration, op: .lessThan, number: 180)],
                sort: .durationAsc
            ),
        ]
        save()
    }

    func add(_ playlist: SmartPlaylist) {
        playlists.append(playlist)
        save()
    }

    func update(_ playlist: SmartPlaylist) {
        guard let idx = playlists.firstIndex(where: { $0.id == playlist.id }) else {
            add(playlist); return
        }
        playlists[idx] = playlist
        save()
    }

    func remove(id: String) {
        playlists.removeAll { $0.id == id }
        save()
    }

    /// Merges smart playlists pulled from the account backup (see
    /// `AccountService.pullSync`) — adds any whose id isn't already present
    /// locally. Never overwrites an existing one, so local edits made since
    /// the last push are never clobbered by a stale server copy. Rules
    /// reference `Song` fields (play count, favorite, duration, …), never
    /// stored song ids, so they're fully portable across devices.
    func mergeFromSync(_ remote: [SmartPlaylist]) {
        let existingIDs = Set(playlists.map { $0.id })
        let toAdd = remote.filter { !existingIDs.contains($0.id) }
        guard !toAdd.isEmpty else { return }
        playlists.append(contentsOf: toAdd)
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key) else { return }
        if let decoded = try? JSONDecoder().decode([SmartPlaylist].self, from: data) {
            playlists = decoded
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(playlists) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
