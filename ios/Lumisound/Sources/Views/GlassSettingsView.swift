import SwiftUI

// MARK: - GlassSettingsView
//
// Customizes the app-wide Liquid Glass look (see GlassSettings / adaptiveGlass)
// — tint tone, tint strength, and (pre-iOS 26) translucency — with a live
// preview card that updates as the sliders move. Other glass surfaces across
// the app pick up the changes on their next redraw.

struct GlassSettingsView: View {
    @ObservedObject private var glass = GlassSettings.shared

    var body: some View {
        List {
            // Live preview
            Section {
                previewCard
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)
            } header: {
                sectionHeader("Preview")
            }

            Section {
                Toggle(isOn: $glass.useAccentTint) {
                    Label("Use App Accent Color", systemImage: "paintpalette")
                        .foregroundStyle(AppTheme.textPrimary)
                }
                .tint(AppTheme.dynamicAccent)

                if !glass.useAccentTint {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Label("Tone", systemImage: "drop.halffull")
                                .foregroundStyle(AppTheme.textSecondary)
                                .font(AppTheme.bodyFont(size: 14))
                            Spacer()
                            Circle()
                                .fill(Color(hue: glass.tintHue, saturation: 0.55, brightness: 0.92))
                                .frame(width: 18, height: 18)
                                .overlay(Circle().stroke(.white.opacity(0.3), lineWidth: 1))
                        }
                        // Hue gradient track behind the slider so the user sees
                        // exactly which tone each position maps to.
                        Slider(value: $glass.tintHue, in: 0...1)
                            .tint(AppTheme.dynamicAccent)
                            .background(
                                LinearGradient(
                                    colors: stride(from: 0.0, through: 1.0, by: 0.1).map {
                                        Color(hue: $0, saturation: 0.55, brightness: 0.92)
                                    },
                                    startPoint: .leading, endPoint: .trailing
                                )
                                .frame(height: 4)
                                .clipShape(Capsule())
                                .padding(.horizontal, 2)
                            )
                    }
                }

                sliderRow(
                    title: "Tint Strength", icon: "circle.lefthalf.filled",
                    value: $glass.tintStrength, label: "\(Int(glass.tintStrength * 100))%"
                )

                sliderRow(
                    title: "Translucency", icon: "square.on.square.dashed",
                    value: $glass.translucency, label: "\(Int(glass.translucency * 100))%"
                )
            } header: {
                sectionHeader("Liquid Glass")
            } footer: {
                Text("Adjusts the tint and translucency of glass surfaces throughout the app — song cards, the mini-player, toasts and floating buttons. Translucency applies on iOS versions before the system Liquid Glass material.")
                    .font(AppTheme.bodyFont(size: 12))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .listRowBackground(tintedRowBackground(.purple))

            Section {
                Button(role: .destructive) {
                    glass.resetToDefaults()
                } label: {
                    Label("Reset to Defaults", systemImage: "arrow.counterclockwise")
                }
            }
            .listRowBackground(tintedRowBackground(.purple))
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(GalleryBackgroundView().ignoresSafeArea())
        .navigationTitle("Liquid Glass")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var previewCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "music.note")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(AppTheme.dynamicAccent)
            Text("Glass Preview")
                .font(AppTheme.bodyFont(size: 15).weight(.semibold))
                .foregroundStyle(AppTheme.textPrimary)
            Text("This card uses your Liquid Glass settings.")
                .font(AppTheme.bodyFont(size: 12))
                .foregroundStyle(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(22)
        .frame(maxWidth: .infinity)
        // Re-evaluated whenever the observed GlassSettings change, so the
        // preview reflects slider moves immediately.
        .background(
            previewBackground,
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(glass.tintColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.white.opacity(0.15), lineWidth: 1)
        )
        .padding(.horizontal, 8)
    }

    private var previewBackground: some ShapeStyle {
        AppTheme.elevatedSurface.opacity(0.4 + glass.translucency * 0.4)
    }

    private func sliderRow(title: String, icon: String, value: Binding<Double>, label: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(title, systemImage: icon)
                    .foregroundStyle(AppTheme.textPrimary)
                    .font(AppTheme.bodyFont(size: 14))
                Spacer()
                Text(label)
                    .font(AppTheme.monoFont(size: 14))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            Slider(value: value, in: 0...1)
                .tint(AppTheme.dynamicAccent)
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(AppTheme.bodyFont(size: 11))
            .foregroundStyle(AppTheme.textSecondary)
            .kerning(0.8)
    }
}
