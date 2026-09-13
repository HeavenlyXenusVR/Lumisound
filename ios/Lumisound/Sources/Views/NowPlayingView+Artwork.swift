import SwiftUI
import UIKit

extension NowPlayingView {

    // MARK: - Artwork

    var artworkSection: some View {
        VStack(spacing: 14) {
            // ── Artwork display ──────────────────────────────────────────
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
            .gesture(artworkSwipeGesture)

            // ── Style picker (horizontal scroll: built-ins + custom + add/manage) ──
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(visibleBuiltinStyles) { style in
                        styleChip(
                            icon: style.iconName, name: style.displayName,
                            isSelected: artworkStyleSelection == style.rawValue
                        ) {
                            selectStyle(style.rawValue)
                        }
                    }
                    ForEach(customStyleStore.styles) { custom in
                        styleChip(
                            icon: custom.iconName, name: custom.name,
                            isSelected: artworkStyleSelection == custom.id
                        ) {
                            selectStyle(custom.id)
                        }
                        .contextMenu {
                            Button {
                                editingCustomStyle = custom
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                customStyleStore.remove(id: custom.id)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                    addStyleChip
                    manageStylesButton
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .sheet(item: $editingCustomStyle) { style in
            CustomStyleEditorView(style: style, previewSong: player.currentSong) { saved in
                customStyleStore.update(saved)
                selectStyle(saved.id)
            }
            .environmentObject(library)
        }
        .sheet(isPresented: $showStyleManager) {
            StyleManagerView()
                .environmentObject(library)
        }
    }

    func styleChip(icon: String, name: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                Text(name)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(isSelected ? .white : AppTheme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                isSelected ? screenStyle.accentColor : AppTheme.surface,
                in: RoundedRectangle(cornerRadius: screenStyle.elementCornerRadius, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.18), value: isSelected)
    }

    var addStyleChip: some View {
        Button {
            editingCustomStyle = CustomNowPlayingStyle()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .medium))
                Text("New Style")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(screenStyle.accentColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: screenStyle.elementCornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: screenStyle.elementCornerRadius, style: .continuous)
                    .strokeBorder(screenStyle.accentColor.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
        }
        .buttonStyle(.plain)
    }

    var manageStylesButton: some View {
        Button {
            showStyleManager = true
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(AppTheme.textSecondary)
                .frame(width: 32, height: 32)
                .background(AppTheme.surface, in: Circle())
        }
        .buttonStyle(.plain)
    }
}
