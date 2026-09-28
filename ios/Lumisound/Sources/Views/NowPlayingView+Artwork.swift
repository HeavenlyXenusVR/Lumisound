import SwiftUI
import UIKit

extension NowPlayingView {

    // MARK: - Artwork
    //
    // 2026-09 restructure: the row of 26+ style chips that sat under the
    // artwork is gone — it was the first thing under the cover and pushed
    // the title and controls well down the screen. Styles are now picked in
    // the Customize sheet (`NowPlayingCustomizeSheet`), opened from the small
    // pill under the artwork that names the current style. Swiping the
    // artwork still skips tracks.

    var artworkSection: some View {
        VStack(spacing: 12) {
            ZStack {
                AmbientArtworkBackground(song: player.currentSong, isPlaying: artworkIsPlaying)
                    .environmentObject(library)

                artworkDisplay
                    .scaleEffect(artworkScale * artworkDragScale)
                    .opacity(artworkOpacity)
                    .offset(x: artworkDragOffset)
                    .animation(.spring(response: 0.4, dampingFraction: 0.65), value: artworkScale)
                    .animation(.easeInOut(duration: 0.2), value: artworkOpacity)
                    .id(artworkAnimationID)
                    .modifier(PulseModifier(isPlaying: player.isPlaying))
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .simultaneousGesture(artworkSwipeGesture)

            currentStylePill
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    /// Name + icon of the selected artwork style (built-in or custom).
    var currentStyleLabel: (name: String, icon: String) {
        if let builtin = selectedBuiltinStyle {
            return (builtin.displayName, builtin.iconName)
        }
        if let custom = selectedCustomStyle {
            return (custom.name, custom.iconName)
        }
        return (NowPlayingArtworkStyle.kaleidoscopeBloom.displayName, NowPlayingArtworkStyle.kaleidoscopeBloom.iconName)
    }

    /// "✦ Kaleidoscope Bloom ⌄" — opens the Customize sheet. Long-press for
    /// a quick menu of every style without leaving the screen.
    var currentStylePill: some View {
        let label = currentStyleLabel
        return Button {
            selectHaptic.selectionChanged()
            showCustomizeSheet = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: label.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(screenStyle.accentColor)
                Text(label.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .adaptiveGlass(in: Capsule(), fallback: AppTheme.surface.opacity(0.6))
        }
        .buttonStyle(PressableButtonStyle())
        .contextMenu {
            Button {
                cycleArtworkStyle()
            } label: {
                Label("Next Style", systemImage: "arrow.right.circle")
            }
            Divider()
            ForEach(visibleBuiltinStyles) { style in
                Button {
                    selectStyle(style.rawValue)
                } label: {
                    Label(style.displayName, systemImage: artworkStyleSelection == style.rawValue ? "checkmark" : style.iconName)
                }
            }
            if !customStyleStore.styles.isEmpty {
                Divider()
                ForEach(customStyleStore.styles) { custom in
                    Button {
                        selectStyle(custom.id)
                    } label: {
                        Label(custom.name, systemImage: artworkStyleSelection == custom.id ? "checkmark" : custom.iconName)
                    }
                }
            }
        }
        .accessibilityLabel("Artwork style: \(label.name)")
        .accessibilityHint("Opens Now Playing customization")
    }

    /// Steps to the next style in the same order the Customize sheet lists
    /// them (visible built-ins, then custom styles), wrapping around.
    func cycleArtworkStyle() {
        let ids = visibleBuiltinStyles.map(\.rawValue) + customStyleStore.styles.map(\.id)
        guard !ids.isEmpty else { return }
        let next = ids.firstIndex(of: artworkStyleSelection).map { ($0 + 1) % ids.count } ?? 0
        skipHaptic.impactOccurred()
        withAnimation(.easeInOut(duration: 0.25)) {
            selectStyle(ids[next])
        }
        ToastCenter.shared.show(currentStyleLabel.name, category: .info, icon: currentStyleLabel.icon)
    }
}
