import SwiftUI

// MARK: - InterfaceEdition

/// Which generation of the app's interface is on screen.
///
/// `.lumen` is the full redesign: its own shell (`LumenRootView`), its own
/// Home / Search / Library / Now Playing / You screens, and a palette that
/// `AppTheme` hands to every other screen in the app. `.classic` is the
/// interface exactly as it shipped before the redesign — `ClassicContentView`
/// and every screen under it are untouched, and `AppTheme` returns the
/// original values for it, so switching back restores the old look in full.
///
/// Users switch between them from Settings (either edition) or from the
/// one-time welcome card Lumen shows on first launch.
enum InterfaceEdition: String, CaseIterable, Identifiable {
    case lumen
    case classic

    static let storageKey = "interface_edition"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .lumen:   return "Lumen"
        case .classic: return "Classic"
        }
    }

    var tagline: String {
        switch self {
        case .lumen:   return "The redesigned Lumisound — lit by whatever you're playing."
        case .classic: return "The original Lumisound interface, exactly as it was."
        }
    }

    var systemImage: String {
        switch self {
        case .lumen:   return "sparkles"
        case .classic: return "clock.arrow.circlepath"
        }
    }

    /// The edition currently selected. Read through UserDefaults (not an
    /// `@AppStorage`) so non-view code such as `AppTheme`'s static colors can
    /// use it. Screenshot runs stay on Classic unless the launch arguments
    /// pick an edition explicitly, because the UI tests drive Classic's tab
    /// bar by accessibility identifier.
    static var current: InterfaceEdition {
        if let raw = UserDefaults.standard.string(forKey: storageKey),
           let edition = InterfaceEdition(rawValue: raw) {
            return edition
        }
        return ScreenshotMode.isActive ? .classic : .lumen
    }

    static var isLumen: Bool { current == .lumen }

    static func select(_ edition: InterfaceEdition) {
        UserDefaults.standard.set(edition.rawValue, forKey: storageKey)
    }
}
