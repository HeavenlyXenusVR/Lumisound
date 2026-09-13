import SwiftUI

// MARK: - RadarSweepArtworkView — "Radar Sweep"
//
// The cover as the "blip" at the center of a radar scope: concentric range
// rings, a few scattered contacts, and a bright sweep wedge rotating
// continuously around them.
struct RadarSweepArtworkView: View {
    let song: Song?
    let isPlaying: Bool

    @EnvironmentObject private var library: LibraryManager

    private let shape = RoundedRectangle(cornerRadius: 90, style: .continuous)

    /// Fixed contact positions (angle in degrees, radius fraction of 140),
    /// deterministic so the scope layout is stable across redraws.
    private let contacts: [(angle: Double, radius: CGFloat)] = [
        (angle: 40, radius: 0.55), (angle: 130, radius: 0.8),
        (angle: 210, radius: 0.4), (angle: 300, radius: 0.68),
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isPlaying)) { timeline in
            let sweepAngle = ArtworkClock.loop(timeline.date, cycleDuration: 3.2) * 360
            let blipPulse = 0.3 + 0.65 * ArtworkClock.pingPong(timeline.date, legDuration: 1.4)

            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [Color(red: 0.02, green: 0.1, blue: 0.05), .black],
                                          center: .center, startRadius: 10, endRadius: 160))

                ForEach(1..<5, id: \.self) { i in
                    Circle()
                        .stroke(.green.opacity(0.28), lineWidth: 1)
                        .frame(width: CGFloat(i) * 70, height: CGFloat(i) * 70)
                }

                // Sweep wedge: an explicit pie-slice Path (center → arc → back to
                // center), filled with a gradient that fades from bright at the
                // leading edge to transparent at the trailing edge.
                SweepWedge(spanDegrees: 45)
                    .fill(
                        AngularGradient(
                            colors: [.green.opacity(0), .green.opacity(0.6)],
                            center: .center,
                            startAngle: .degrees(-45), endAngle: .degrees(0)
                        )
                    )
                    .frame(width: 280, height: 280)
                    .rotationEffect(.degrees(sweepAngle))

                ForEach(Array(contacts.enumerated()), id: \.offset) { _, contact in
                    Circle()
                        .fill(.green)
                        .frame(width: 6, height: 6)
                        .shadow(color: .green, radius: 5)
                        .opacity(blipPulse)
                        .offset(
                            x: cos(contact.angle * .pi / 180) * contact.radius * 140,
                            y: sin(contact.angle * .pi / 180) * contact.radius * 140
                        )
                }

                StyleCover(song: song, size: 150, cornerRadius: 75)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(.green.opacity(0.6), lineWidth: 2))
                    .shadow(color: .green.opacity(0.5), radius: 20)
            }
            .frame(width: 300, height: 300)
            .clipShape(Circle())
            .overlay(Circle().stroke(.green.opacity(0.3), lineWidth: 1))
            .drawingGroup()
        }
        .modifier(FloatModifier(isPlaying: isPlaying, amount: 4, speed: 4.0))
    }
}

/// An explicit pie-slice shape spanning `spanDegrees`, from the shape's own
/// 0° (3 o'clock) back to `-spanDegrees` — center point, out along one edge,
/// arc across, back to center. Simple and unambiguous, unlike trying to fake
/// a wedge out of a trimmed/thick-stroked circle.
private struct SweepWedge: Shape {
    let spanDegrees: Double

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        var path = Path()
        path.move(to: center)
        path.addArc(center: center, radius: radius,
                    startAngle: .degrees(-spanDegrees), endAngle: .degrees(0),
                    clockwise: false)
        path.closeSubpath()
        return path
    }
}
