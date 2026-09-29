import Foundation

extension Sequence where Element == Song {
    /// A–Z by `displayName`, the same order as
    /// `sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }`
    /// but computing each song's `displayName` once instead of on every
    /// comparison. `displayName` isn't a stored property — it trims, builds
    /// a lowercased title|artist key and checks `AmbiguousTitleIndex` under
    /// a lock — and a comparison sort calls it about 2·n·log₂n times: ~70,000
    /// calls for a 3,000-song library, versus 3,000 here.
    func sortedByDisplayName() -> [Song] {
        map { (name: $0.displayName, song: $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map(\.song)
    }
}
