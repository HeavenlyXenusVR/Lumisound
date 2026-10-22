import SwiftUI
import UIKit

// MARK: - EffectsView

struct EffectsView: View {
    @EnvironmentObject private var player: AudioPlayerManager
    @State private var showLuaEffects = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 5)
    private let selectHaptic = UISelectionFeedbackGenerator()
    private let successHaptic = UINotificationFeedbackGenerator()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Active indicator row
            HStack(spacing: 6) {
                Text("Active:")
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
                let activeName = AudioEffectsService.effect(id: player.audioSettings.activeEffectID)?.name ?? "None"
                Text(activeName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.dynamicAccent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Effect grid
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(AudioEffectsService.allEffects) { effect in
                    EffectCell(
                        effect: effect,
                        isActive: player.audioSettings.activeEffectID == effect.id
                    ) {
                        selectHaptic.selectionChanged()
                        player.applyEffect(effect)
                        successHaptic.notificationOccurred(.success)
                    }
                }
            }

            Button {
                showLuaEffects = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "scroll")
                    Text("Scripted Effects (Lua)")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(AppTheme.dynamicAccent)
            }
            .padding(.top, 4)
        }
        .onAppear {
            selectHaptic.prepare()
            successHaptic.prepare()
        }
        .sheet(isPresented: $showLuaEffects) {
            NavigationStack {
                LuaEffectScriptsView()
                    .environmentObject(player)
            }
        }
    }
}

// MARK: - EffectCell

private struct EffectCell: View {
    let effect: AudioEffect
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: effect.icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(isActive ? .white : AppTheme.textSecondary)
                    .frame(height: 22)

                Text(effect.name)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(isActive ? .white : AppTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity)
            .background(
                isActive
                    ? AnyShapeStyle(AppTheme.dynamicAccent)
                    : AnyShapeStyle(AppTheme.elevatedSurface),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.18), value: isActive)
    }
}
