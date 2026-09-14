import Foundation

// MARK: - AmbiguousTitleIndex
//
// The set of `Song.ambiguityKey`s (title+artist, lowercased) shared by more
// than one track in the library — i.e. titles that are present but identify
// nothing. `Song.displayName` consults it to fall back to the filename for
// exactly those tracks; see its doc comment for why ambiguity, and not
// filename word order, is the signal worth trusting.
//
// Storage lives here rather than as a static on `LibraryManager` for an
// isolation reason: `LibraryManager` is `@MainActor`, so a static on it is
// MainActor-isolated, while `displayName` is a nonisolated computed property
// on a struct and can be evaluated from anywhere (background metadata passes,
// export, sorting). A lock-guarded box is reachable from both without either
// side having to pretend about isolation.
//
// Writes happen once per library scan; reads happen per rendered row, so this
// is deliberately read-cheap: an `NSLock` around a plain `Set` rather than an
// actor (which would force every call site to be async) or a concurrent queue.
enum AmbiguousTitleIndex {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var storage: Set<String> = []

    /// Replaces the whole set — the library is always recomputed wholesale, so
    /// there's no partial-update path to get wrong.
    static func replace(with keys: Set<String>) {
        lock.lock()
        storage = keys
        lock.unlock()
    }

    static func contains(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage.contains(key)
    }
}
