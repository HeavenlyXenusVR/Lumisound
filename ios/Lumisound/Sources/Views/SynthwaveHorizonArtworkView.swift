import SwiftUI

// MARK: - SynthwaveHorizonArtworkView — "Synthwave Horizon"
//
// A retro-futuristic sunset: a striped sun sinking behind a perspective grid
// floor that scrolls toward the viewer, the cover floating above it all in a
// neon-outlined frame.
struct SynthwaveHorizonArtworkView: View {
    let song: Song?
    let isPlaying: Bool

    @EnvironmentObject private var library: LibraryManager

    private let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
    private let horizonY: CGFloat = 168

    var body: some View {
        TimelineView(.animation(paused: !isPlaying)) { timeline in
            // Grid keeps scrolling regardless of play state (ambient background
            // motion, same treatment as other styles' drifting elements) — only
            // the sun/frame glow reacts to isPlaying via its own opacity below.
            let scroll = ArtworkClock.loop(timeline.date, cycleDuration: 2.2) * 10
            let glow = ArtworkClock.pingPong(timeline.date, legDuration: 2.0)

            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.09, green: 0.03, blue: 0.22),
                        Color(red: 0.42, green: 0.08, blue: 0.38),
                        Color(red: 0.95, green: 0.42, blue: 0.24),
                    ],
                    startPoint: .top, endPoint: .bottom
                )

                // Striped sun, half-hidden behind the horizon line.
                Circle()
                    .fill(
                        LinearGradient(colors: [.yellow, .orange, .pink], startPoint: .top, endPoint: .bottom)
                    )
                    .frame(width: 150, height: 150)
                    .mask(sunStripeMask)
                    .position(x: 150, y: horizonY - 20)
                    .opacity(0.75 + 0.25 * glow)
                    .blur(radius: 0.5)

                // Perspective grid floor: horizontal lines with increasing spacing
                // toward the viewer, scrolling downward for a "moving forward" feel.
                Canvas { context, size in
                    let vanishY = horizonY
                    for i in 0..<10 {
                        let t = (CGFloat(i) + scroll).truncatingRemainder(dividingBy: 10) / 10
                        // Ease the spacing so lines bunch up near the horizon.
                        let y = vanishY + t * t * (size.height - vanishY)
                        let widthAtY = 40 + t * (size.width - 40)
                        let x0 = (size.width - widthAtY) / 2
                        var path = Path()
                        path.move(to: CGPoint(x: x0, y: y))
                        path.addLine(to: CGPoint(x: x0 + widthAtY, y: y))
                        context.stroke(path, with: .color(.cyan.opacity(0.25 + 0.35 * t)), lineWidth: 1)
                    }
                    // Converging verticals from the vanishing point.
                    for dx in stride(from: -5, through: 5, by: 1) {
                        var path = Path()
                        path.move(to: CGPoint(x: size.width / 2, y: vanishY))
                        path.addLine(to: CGPoint(x: size.width / 2 + CGFloat(dx) * 60, y: size.height))
                        context.stroke(path, with: .color(.cyan.opacity(0.18)), lineWidth: 1)
                    }
                }
                .frame(width: 300, height: 300)

                StyleCover(song: song, size: 170, cornerRadius: 18)
                    .clipShape(shape)
                    .overlay(
                        shape.stroke(
                            LinearGradient(colors: [.cyan, .pink], startPoint: .topLeading, endPoint: .bottomTrailing),
                            lineWidth: 2.5
                        )
                    )
                    .shadow(color: .cyan.opacity(0.4 + 0.3 * glow), radius: 14 + 12 * glow)
                    .shadow(color: .pink.opacity(0.4), radius: 20)
                    .offset(y: -18)
            }
            .frame(width: 300, height: 300)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(.white.opacity(0.12), lineWidth: 1)
            )
            .drawingGroup()
        }
        .modifier(FloatModifier(isPlaying: isPlaying, amount: 5, speed: 3.2))
    }

    /// Horizontal stripes cut out of the sun disc, widening toward the
    /// bottom. `.mask` reads the ALPHA of this content, so the gaps must be
    /// `Color.clear` (fully transparent) — an opaque black rectangle would
    /// still count as "visible" and mask nothing.
    private var sunStripeMask: some View {
        VStack(spacing: 5) {
            ForEach(0..<7, id: \.self) { i in
                Rectangle().fill(.white).frame(height: 6 + CGFloat(i))
                if i < 6 { Color.clear.frame(height: 4) }
            }
        }
    }
}
