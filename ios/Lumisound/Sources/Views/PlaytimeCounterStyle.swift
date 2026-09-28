import SwiftUI

/// Presets for how the elapsed/remaining playtime is displayed below the
/// seeker in Now Playing. Independent of `SeekerStyle` (which controls the
/// scrubber itself) — this controls the summary text row beneath it.
enum PlaytimeCounterStyle: String, CaseIterable, Identifiable {
    case elapsedRemaining
    case elapsedOnly
    case remainingOnly
    case totalDuration
    case percentage
    case fraction
    /// No separate counter — every seeker style already draws its own
    /// elapsed/remaining labels, so a second readout under it just repeats
    /// them. The default since the 2026-09 Now Playing restructure.
    case hidden

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .elapsedRemaining: return "Elapsed / Remaining"
        case .elapsedOnly:      return "Elapsed"
        case .remainingOnly:    return "Remaining"
        case .totalDuration:    return "Total Length"
        case .percentage:       return "Percentage"
        case .fraction:         return "Position / Total"
        case .hidden:           return "Off"
        }
    }

    var iconName: String {
        switch self {
        case .elapsedRemaining: return "arrow.left.and.right"
        case .elapsedOnly:      return "hourglass.bottomhalf.filled"
        case .remainingOnly:    return "hourglass.tophalf.fill"
        case .totalDuration:    return "clock"
        case .percentage:       return "percent"
        case .fraction:         return "number"
        case .hidden:           return "eye.slash"
        }
    }

    /// Returns the text to display for the given playback position/duration.
    func text(position: TimeInterval, duration: TimeInterval) -> String {
        let remaining = max(0, duration - position)
        switch self {
        case .elapsedRemaining:
            return "\(Self.formatTime(position)) · -\(Self.formatTime(remaining))"
        case .elapsedOnly:
            return Self.formatTime(position)
        case .remainingOnly:
            return "-\(Self.formatTime(remaining))"
        case .totalDuration:
            return Self.formatTime(duration)
        case .percentage:
            guard duration > 0 else { return "0%" }
            return "\(Int((position / duration * 100).rounded()))%"
        case .fraction:
            return "\(Self.formatTime(position)) / \(Self.formatTime(duration))"
        case .hidden:
            return ""
        }
    }

    private static func formatTime(_ t: TimeInterval) -> String {
        t.formattedWithHours
    }
}
