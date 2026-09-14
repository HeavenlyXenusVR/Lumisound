import MediaPlayer
import SwiftUI

/// Settings redesign, part 2: each section's row background gets a very
/// faint wash of that section's own `sectionHeader` tint (via
/// `Color.mixed(with:amount:)`, the same blend helper Profile
/// customization's decoration/effect overlays use) instead of every section
/// sharing one flat `AppTheme.surface` — carries the "each category is
/// visually its own color" idea from the header badges down into the row
/// itself. The mix amount is deliberately small (6%) so it reads as a
/// subtle color hint, not a colored card — this screen's `.listStyle(.plain)`
/// was chosen specifically so sections stay a continuous surface rather than
/// floating disconnected boxes (see `SettingsView.body`'s doc comment), and
/// a strong per-section tint would fight that.
///
/// A free function (not a `SettingsView` extension method like
/// `sectionHeader` above) — several settings screens (e.g.
/// `NotificationsSettingsView`) are their own separate `View` types, not
/// part of `SettingsView` itself, and still need this same helper.
///
/// Liquid Glass: this returns a *view* rather than the flat `Color` it used
/// to, so every Settings row picks up `adaptiveGlass` and renders as real
/// `.glassEffect()`. Settings was the last major area of the app still painting its
/// rows as opaque fills while the mini-player, toasts, FABs, song cards and
/// the navbar had all moved to glass, so its rows sat as solid slabs over
/// the gallery background that every surface around them let through.
///
/// Doing it here rather than at the call sites is deliberate: all 20 of them
/// across 14 files pass this straight to `.listRowBackground`, which takes
/// any `View`, so one change converts every section of every Settings tab at
/// once and leaves a single place to tune the look.
///
/// The per-section colour is carried by the glass's own `.tint()` (via
/// `adaptiveGlass(sectionTint:)`) rather than by the `fallback:`, which on
/// this app's iOS 26 deployment target would never render — passing it there
/// would have quietly flattened every section to identical untinted glass and
/// thrown away the "each category is its own colour" idea this helper exists
/// for. `settingsRowTintOpacity` keeps it at a hint rather than a coloured card, the same
/// restraint the old 6% surface mix was chosen for; it is the one number to
/// turn if the sections read too strong or too washed out on device.
private let settingsRowTintOpacity: Double = 0.22

@ViewBuilder
func tintedRowBackground(_ tint: Color) -> some View {
    Color.clear
        .adaptiveGlass(
            sectionTint: tint.opacity(settingsRowTintOpacity),
            in: Rectangle(),
            fallback: AppTheme.surface.mixed(with: tint, amount: 0.06)
        )
}

extension SettingsView {

    // MARK: — Helpers

    func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(AppTheme.bodyFont(size: 11))
            .foregroundStyle(AppTheme.textSecondary)
            .kerning(0.8)
    }

    /// Redesigned section header — a small icon in a rounded, tinted badge
    /// next to the label, instead of plain uppercase text alone. Each
    /// section picks its own `tint`/`icon` so Settings' many sections read
    /// as visually distinct categories at a glance instead of one
    /// undifferentiated list — the core idea behind this screen's redesign.
    /// The plain-text `sectionHeader(_:)` above is kept for any call site
    /// that hasn't been moved to this one yet; both render at the same
    /// height so mixing them doesn't cause list-row jitter.
    func sectionHeader(_ text: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 20, height: 20)
                // Glass rather than a flat 16%-tint fill: these badges sit on
                // the header strip where the gallery background shows through
                // most strongly, so a flat fill was the most obviously "pasted
                // on" element left once the rows below became glass. Tinted via
                // `sectionTint:` for the same reason as `tintedRowBackground` —
                // a colour passed as `fallback:` would never render on this
                // deployment target, leaving every category badge identical.
                .adaptiveGlass(
                    sectionTint: tint.opacity(0.25),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous),
                    fallback: tint.opacity(0.16)
                )
            Text(text.uppercased())
                .font(AppTheme.bodyFont(size: 11))
                .foregroundStyle(AppTheme.textSecondary)
                .kerning(0.8)
        }
    }

    var mediaAccessStatusText: String {
        switch MPMediaLibrary.authorizationStatus() {
        case .authorized:    return "Allowed"
        case .denied:        return "Denied"
        case .restricted:    return "Restricted"
        case .notDetermined: return "Not Asked"
        @unknown default:    return "Unknown"
        }
    }

    var mediaAccessStatusColor: Color {
        MPMediaLibrary.authorizationStatus() == .authorized
            ? AppTheme.success
            : AppTheme.warning
    }

    func pitchLabel(_ semitones: Float) -> String {
        if semitones == 0 { return "0 st" }
        let sign = semitones > 0 ? "+" : ""
        return String(format: "%@%.1f st", sign, semitones)
    }
}
