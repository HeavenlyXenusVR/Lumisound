import MediaPlayer
import SwiftUI

extension SettingsView {

    // MARK: — Appearance Section

    var appearanceSection: some View {
        Section {
            NavigationLink(destination: InterfaceEditionView()) {
                HStack {
                    Label("Interface", systemImage: "sparkles.rectangle.stack")
                        .foregroundStyle(AppTheme.textPrimary)
                    Spacer()
                    Text(InterfaceEdition.current.displayName)
                        .font(AppTheme.bodyFont(size: 13))
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }
            NavigationLink(destination: AppearanceView()) {
                HStack {
                    Label("Appearance", systemImage: "paintbrush")
                        .foregroundStyle(AppTheme.textPrimary)
                    Spacer()
                    // Current accent preview swatch
                    Circle()
                        .fill(AppTheme.dynamicAccent)
                        .frame(width: 22, height: 22)
                        .shadow(color: AppTheme.dynamicAccent.opacity(0.4), radius: 4, x: 0, y: 2)
                }
            }
            NavigationLink(destination: BackgroundSettingsView()) {
                Label("Gallery Background", systemImage: "photo.on.rectangle")
                    .foregroundStyle(AppTheme.textPrimary)
            }
            NavigationLink(destination: GlassSettingsView()) {
                Label("Liquid Glass", systemImage: "circle.hexagongrid.fill")
                    .foregroundStyle(AppTheme.textPrimary)
            }
            NavigationLink(destination: LuaThemePresetsView()) {
                HStack {
                    Label("Lua Theme Presets", systemImage: "scroll.fill")
                        .foregroundStyle(AppTheme.textPrimary)
                    Spacer()
                    if let activeID = LuaThemeEngine.shared.activePresetID,
                       let preset = LuaPreset(rawValue: activeID) {
                        Text(preset.displayName)
                            .font(AppTheme.bodyFont(size: 13))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                }
            }

            // Navbar mode — same setting Now Playing's own toggle controls
            // (see NowPlayingView's "Navbar Mode" row), sharing one
            // @AppStorage key so either surface always reflects the other's
            // current choice.
            VStack(alignment: .leading, spacing: 8) {
                Label("Navbar Mode", systemImage: "rectangle.bottomthird.inset.filled")
                    .foregroundStyle(AppTheme.textPrimary)
                Picker("Navbar Mode", selection: $navbarDisplayMode) {
                    ForEach(NavbarDisplayMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                Text("Mini Player replaces the tab bar with artwork, a seeker, and transport controls whenever a song is loaded — the bar's size never changes, only what's inside it.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .padding(.vertical, 4)

            // Tab-bar-mode customization — only meaningful while Navbar Mode
            // (above) is set to Tabs, but left always-visible/editable
            // rather than hidden behind that choice, so switching back to
            // Tabs mode later doesn't require re-discovering these.
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: $navbarShowTabLabels) {
                    Label("Show Tab Labels", systemImage: "textformat")
                        .foregroundStyle(AppTheme.textPrimary)
                }
                .tint(.purple)

                Label("Selection Style", systemImage: "circle.dashed")
                    .foregroundStyle(AppTheme.textPrimary)
                Picker("Selection Style", selection: $navbarSelectionStyle) {
                    ForEach(NavbarSelectionStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .pickerStyle(.segmented)
            }
            .padding(.vertical, 4)

            hiddenTabsSection
        } header: {
            sectionHeader("Appearance", icon: "paintbrush.fill", tint: .purple)
        }
        .listRowBackground(tintedRowBackground(.purple))
    }

    /// "Allow users to hide different tabs" — mirrors `CustomTabBar.specs`'s
    /// tag numbering exactly (0 Library, 1 Playing, 2 Queue, 3 Cloud
    /// Services, 4 Friends, 5 Profile, 6 Settings) but deliberately omits a
    /// row for Settings (6) — that's the one screen these toggles live on,
    /// so hiding it would strand a user with no way back to un-hide
    /// anything. `CustomTabBar`/`ContentView` both additionally refuse to
    /// treat 6 as hidden even if it somehow ended up in the stored value,
    /// as a second layer of the same guard.
    private var hideableTabs: [(tag: Int, title: String, icon: String)] {
        [
            (0, "Library", "music.note.list"),
            (1, "Playing", "play.circle"),
            (2, "Queue", "list.number"),
            (3, "Cloud Services", "icloud.and.arrow.down"),
            (4, "Friends", "person.2.fill"),
            (5, "Profile", "person.crop.circle"),
        ]
    }

    private var hiddenTabSet: Set<Int> {
        Set(navbarHiddenTabsRaw.split(separator: ",").compactMap { Int($0) })
    }

    private func setTab(_ tag: Int, hidden: Bool) {
        var set = hiddenTabSet
        if hidden { set.insert(tag) } else { set.remove(tag) }
        navbarHiddenTabsRaw = set.sorted().map(String.init).joined(separator: ",")
    }

    private var hiddenTabsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Hidden Tabs", systemImage: "eye.slash")
                .foregroundStyle(AppTheme.textPrimary)
            ForEach(hideableTabs, id: \.tag) { tab in
                Toggle(isOn: Binding(
                    get: { !hiddenTabSet.contains(tab.tag) },
                    set: { setTab(tab.tag, hidden: !$0) }
                )) {
                    Label(tab.title, systemImage: tab.icon)
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.textPrimary)
                }
                .tint(.purple)
            }
            Text("Hidden tabs are still reachable from wherever you'd normally navigate to them in-app — this only controls what shows in the navbar itself. Settings can't be hidden, so you can always get back here.")
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
        }
        .padding(.vertical, 4)
    }
}
