import SwiftUI

// MARK: - TVTrackRow
//
// The library's Songs list used to be a `LazyVGrid` of 280×280 artwork squares
// with a two-line caption under each. That is the right unit for *albums*, and
// the wrong one for *songs*:
//
//   - Six tiles fit on screen at once, so a 160-track library was 27 screens of
//     scrolling, all of it identical-looking. This is the literal cause of the
//     "everything looks the same" reading — every element on the screen was the
//     same size and shape, so there was no hierarchy to see.
//   - A song's identity is its title, not its cover. Blowing the cover up to
//     280pt and shrinking the title to a clipped two-line caption inverts the
//     importance of the two.
//   - Album art repeats heavily within a library, so a grid of covers shows the
//     same picture over and over while the thing that actually distinguishes
//     the rows is the part that got truncated.
//
// A row puts the title first at a readable size, fits roughly seven per screen,
// and has somewhere to put duration and favourite state without covering the
// artwork with badges. Grids are kept for Albums/Artists/Genres, where the
// square art really is the item.
//
// Focus follows the tvOS idiom used elsewhere in this port (`TVChip`,
// `TVNavPillLabel`): read `isFocused` off the environment inside a `.plain`
// button's label rather than having the row manage focus itself, and signal it
// with a fill + scale + elevation rather than colour alone.
struct TVTrackRow: View {
    let artworkURL: URL?
    let token: String?
    let title: String
    let artist: String
    /// Trailing metadata — a duration, a track count, an album name.
    var detail: String? = nil
    var isFavorite: Bool = false
    /// Shown in place of artwork when there is none worth loading.
    var placeholderSymbol: String = "music.note"
    /// Position in an ordered set (album track 1, 2, 3…). When set, the number
    /// takes the artwork's place: inside a single album or genre every row would
    /// otherwise show the *same* cover repeated down the screen, which fills the
    /// most prominent column with the least informative thing on the row.
    var trackNumber: Int? = nil

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        HStack(spacing: 26) {
            if let trackNumber {
                Text("\(trackNumber)")
                    .font(TVType.meta)
                    .foregroundStyle(isFocused ? .black.opacity(0.5) : .secondary)
                    .frame(width: 52, alignment: .trailing)
            } else {
                TVAuthImage(url: artworkURL, token: token) {
                    TVArtPlaceholder(systemImage: placeholderSymbol, iconScale: 0.5)
                }
                .frame(width: 92, height: 92)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                // Only the focused row lifts its artwork. An unfocused row with
                // a drop shadow reads as "also selected", which is what made the
                // old grid so noisy — every tile was elevated at once.
                .shadow(color: .black.opacity(isFocused ? 0.5 : 0), radius: isFocused ? 12 : 0, y: 5)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(TVType.rowTitle)
                    .lineLimit(1)
                Text(artist.isEmpty ? "Unknown Artist" : artist)
                    .font(TVType.rowDetail)
                    .foregroundStyle(isFocused ? .black.opacity(0.62) : .secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 16)

            if isFavorite {
                Image(systemName: "star.fill")
                    .font(.system(size: 21))
                    // Yellow-on-white is illegible on the focused fill, so the
                    // star takes the accent colour there instead of vanishing.
                    .foregroundStyle(isFocused ? Color.accentColor : Color.yellow)
            }
            if let detail {
                Text(detail)
                    .font(TVType.meta)
                    .foregroundStyle(isFocused ? .black.opacity(0.55) : .secondary)
            }
        }
        // Foreground is set once, here, so the title inherits it and only the
        // secondary lines above need to override.
        .foregroundStyle(isFocused ? Color.black : Color.white)
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background {
            RoundedRectangle(cornerRadius: TVMetrics.cardCorner, style: .continuous)
                .fill(isFocused ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.white.opacity(0.06)))
        }
        .scaleEffect(isFocused ? 1.014 : 1)
        .shadow(color: .black.opacity(isFocused ? 0.45 : 0), radius: isFocused ? 22 : 0, y: 10)
        .animation(.spring(response: 0.3, dampingFraction: 0.78), value: isFocused)
    }
}

// MARK: - Duration formatting

extension Double {
    /// "3:07" / "1:02:44" — nil for a missing or zero duration, so callers can
    /// omit the trailing column entirely rather than printing a fake "0:00".
    var tvDurationText: String? {
        guard self >= 1, self.isFinite else { return nil }
        let total = Int(self.rounded())
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
