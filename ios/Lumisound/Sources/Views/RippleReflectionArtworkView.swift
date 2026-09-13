import SwiftUI

// MARK: - RippleReflectionArtworkView — "Ripple Reflection"
//
// The cover sits above a faint, flipped reflection of itself on a dark
// "water" surface, with pale ripple rings expanding outward across the
// reflection as if something just broke the surface.
struct RippleReflectionArtworkView: View {
    let song: Song?
    let isPlaying: Bool

    @EnvironmentObject private var library: LibraryManager

    private let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
    private let coverSize: CGFloat = 180

    var body: some View {
        TimelineView(.animation(paused: !isPlaying)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate

            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.03, green: 0.05, blue: 0.09), Color(red: 0.01, green: 0.02, blue: 0.04)],
                    startPoint: .top, endPoint: .bottom
                )

                VStack(spacing: 4) {
                    StyleCover(song: song, size: coverSize, cornerRadius: 16)
                        .clipShape(shape)
                        .overlay(shape.stroke(.white.opacity(0.25), lineWidth: 1))
                        .shadow(color: .black.opacity(0.5), radius: 18, y: 10)

                    ZStack {
                        StyleCover(song: song, size: coverSize, cornerRadius: 16)
                            .clipShape(shape)
                            .scaleEffect(x: 1, y: -1)
                            .opacity(0.35)
                            .blur(radius: 1.5)
                            .mask(
                                LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .bottom)
                            )

                        rippleRings(t: t)
                    }
                    .frame(width: coverSize, height: coverSize * 0.62, alignment: .top)
                    .clipped()
                }
            }
            .frame(width: 300, height: 300)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .drawingGroup()
        }
        .modifier(FloatModifier(isPlaying: isPlaying, amount: 5, speed: 3.4))
    }

    /// A few expanding ring outlines drawn across the reflection, each
    /// looping outward from the top-center and fading as it grows — like
    /// concentric ripples spreading across still water.
    private func rippleRings(t: Double) -> some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: 0)
            for i in 0..<3 {
                let phase = (t / 2.4 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                let radius = phase * size.width * 0.85
                let opacity = 0.5 * (1 - phase)
                let rect = CGRect(x: center.x - radius, y: center.y - radius * 0.4, width: radius * 2, height: radius * 0.8)
                context.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(opacity)), lineWidth: 1.5)
            }
        }
    }
}
