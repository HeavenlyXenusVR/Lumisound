import SwiftUI

// MARK: - MoltenGlassDripArtworkView — "Molten Glass Drip"
//
// The cover set in glowing molten glass — warm streaks slowly lengthen down
// its edges like syrup, over a deep ember-orange base.
struct MoltenGlassDripArtworkView: View {
    let song: Song?
    let isPlaying: Bool

    @EnvironmentObject private var library: LibraryManager

    private let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)

    /// Fixed drip origin x-positions (as a fraction of width) and base/target
    /// lengths — deterministic, only `drip` (0...1) animates the length.
    private let drips: [(x: CGFloat, baseLength: CGFloat, maxLength: CGFloat, width: CGFloat)] = [
        (0.15, 14, 46, 10), (0.32, 10, 30, 7), (0.55, 16, 52, 12),
        (0.72, 8, 26, 6), (0.88, 12, 38, 9),
    ]

    var body: some View {
        TimelineView(.animation(paused: !isPlaying)) { timeline in
            let drip = 0.2 + 0.8 * ArtworkClock.pingPong(timeline.date, legDuration: 3.6)

            ZStack {
                RadialGradient(
                    colors: [Color(red: 0.32, green: 0.08, blue: 0.02), Color(red: 0.08, green: 0.01, blue: 0.02)],
                    center: .center, startRadius: 20, endRadius: 210
                )

                StyleCover(song: song, size: 210, cornerRadius: 20)
                    .clipShape(shape)
                    .overlay(shape.stroke(.orange.opacity(0.5), lineWidth: 2))
                    .shadow(color: .orange.opacity(0.5), radius: 24)
                    .shadow(color: .red.opacity(0.3), radius: 34)

                // Drips hang from the cover's bottom edge (y ≈ 105 from center,
                // for a 210pt cover), lengthening/shortening together via `drip`.
                ForEach(Array(drips.enumerated()), id: \.offset) { _, d in
                    let length = d.baseLength + (d.maxLength - d.baseLength) * drip
                    Capsule()
                        .fill(
                            LinearGradient(colors: [.yellow, .orange, .red.opacity(0.7)],
                                           startPoint: .top, endPoint: .bottom)
                        )
                        .frame(width: d.width, height: length)
                        .offset(x: (d.x - 0.5) * 210, y: 105 + length / 2)
                        .blur(radius: 0.6)
                }
            }
            .frame(width: 300, height: 300)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .drawingGroup()
        }
        .modifier(FloatModifier(isPlaying: isPlaying, amount: 4, speed: 4.0))
    }
}
