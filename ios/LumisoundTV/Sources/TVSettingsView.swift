import SwiftUI

// MARK: - TVSettingsView
//
// Playback and display preferences, reached from the Account screen.
//
// Aria Lumi has no row here. That is deliberate and stated on the screen rather
// than left as a silent omission — a missing switch reads as an oversight, and
// someone looking for it should find the answer instead of wondering. The only
// Aria-related control is whether her spoken handover line is DISPLAYED, which
// is a presentation choice and does not turn her off.
struct TVSettingsView: View {
    @ObservedObject private var settings = TVAudioSettings.shared
    @ObservedObject private var aria = TVAria.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TVMetrics.section) {
                TVScreenTitle(title: "Settings")
                    .padding(.top, 20)

                section("Playback") {
                    toggleRow(
                        title: "Skip Silent Intros",
                        detail: "Starts a track at its first real sound, skipping a silent or fading-in lead-in.",
                        systemImage: "scissors",
                        isOn: $settings.skipSilentIntros
                    )
                    toggleRow(
                        title: "Crossfade",
                        detail: "Overlaps the end of one track with the start of the next.",
                        systemImage: "arrow.triangle.merge",
                        isOn: $settings.crossfadeEnabled
                    )
                    if settings.crossfadeEnabled {
                        toggleRow(
                            title: "Auto Crossfade",
                            detail: "Sets the overlap per track instead of a fixed six seconds — tighter when a track ends abruptly, longer when it fades out, and snapped to the beat where the tempo is known.",
                            systemImage: "waveform.path.ecg",
                            isOn: $settings.autoCrossfade
                        )
                    }
                }

                section("Audio") {
                    toggleRow(
                        title: "Spatial Audio",
                        detail: "Lets the system widen stereo music into a surround field. Off by default — it smears the stereo image, and is the most likely reason music sounds less direct here than on iPhone.",
                        systemImage: "airpodspro",
                        isOn: $settings.allowSpatialization
                    )
                }

                section("Aria Lumi") {
                    ariaNotice
                    toggleRow(
                        title: "Show Aria's Track Intros",
                        detail: "Displays her one-line handover as a new track begins. Aria keeps running either way — this only controls whether the line is shown.",
                        systemImage: "text.bubble",
                        isOn: $settings.djTransitions
                    )
                }

                section("Library") {
                    columnsRow
                }
            }
            .padding(.bottom, 80)
        }
        .tvAmbientBackground()
    }

    // MARK: Pieces

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: TVMetrics.row) {
            TVSectionHeader(title: title)
                .padding(.horizontal, TVMetrics.margin)
            content()
        }
    }

    /// Says plainly why there is no on/off switch, rather than leaving a gap.
    private var ariaNotice: some View {
        HStack(alignment: .top, spacing: 16) {
            TVAriaMark(isAnimating: true, diameter: 30)
            VStack(alignment: .leading, spacing: 6) {
                Text("Aria is always on")
                    .font(.system(size: 25, weight: .semibold))
                Text("She picks a track for you each day and introduces what's coming up. There's no switch for her.")
                    .font(TVType.rowDetail)
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .tvNeonCard(cornerRadius: 18, tint: TVPalette.neonAlt)
        .padding(.horizontal, TVMetrics.margin)
    }

    private func toggleRow(title: String, detail: String, systemImage: String,
                           isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
            TVRemoteLogger.log(category: "settings", event: "setting_toggled",
                               detail: ["setting": title, "value": isOn.wrappedValue])
        } label: {
            TVSettingRowLabel(title: title, detail: detail,
                              systemImage: systemImage, isOn: isOn.wrappedValue)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .padding(.horizontal, TVMetrics.margin)
    }

    /// Column count as a chip row rather than a stepper — three fixed choices
    /// are faster to hit directly than to step through, and the current one is
    /// visible without being selected.
    private var columnsRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Cards per row")
                .font(.system(size: 25, weight: .semibold))
            Text("Applies to albums, artists, genres and search results. Fewer columns means larger artwork.")
                .font(TVType.rowDetail)
                .foregroundStyle(.white.opacity(0.5))
            HStack(spacing: 16) {
                ForEach([2, 3, 4], id: \.self) { count in
                    Button {
                        settings.gridColumns = count
                        TVRemoteLogger.log(category: "settings", event: "grid_columns_changed",
                                           detail: ["columns": count])
                    } label: {
                        TVChip(title: "\(count)", isSelected: settings.gridColumns == count)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                }
            }
            .padding(.top, 6)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .tvNeonCard(cornerRadius: 18)
        .padding(.horizontal, TVMetrics.margin)
    }
}

/// A settings row's appearance, split out so `@Environment(\.isFocused)` is read
/// inside the button's label — the pattern every custom control in this port
/// uses.
private struct TVSettingRowLabel: View {
    let title: String
    let detail: String
    let systemImage: String
    let isOn: Bool

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            Image(systemName: systemImage)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(isOn ? TVPalette.neon : .white.opacity(0.4))
                .frame(width: 44)

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 25, weight: .semibold))
                Text(detail)
                    .font(TVType.rowDetail)
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)

            // A drawn switch rather than SwiftUI's `Toggle`: on tvOS a Toggle
            // inside a custom row brings its own focus behaviour and system
            // highlight, which is what put a white slab behind every control
            // elsewhere in this port.
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? AnyShapeStyle(LinearGradient(
                            colors: [TVPalette.neon, TVPalette.neonAlt],
                            startPoint: .leading, endPoint: .trailing))
                        : AnyShapeStyle(Color.white.opacity(0.14)))
                    .frame(width: 76, height: 42)
                Circle()
                    .fill(.white)
                    .frame(width: 34, height: 34)
                    .padding(4)
                    .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
            }
            .frame(width: 76, height: 42)
            .animation(.spring(response: 0.28, dampingFraction: 0.75), value: isOn)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .tvNeonCard(cornerRadius: 18, isFocused: isFocused)
    }
}
