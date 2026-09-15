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
// Focus follows the tvOS idiom used elsewhere in this port (`TVChip`, the side
// rail's items): read `isFocused` off the environment inside a `.plain` button's
// label rather than having the row manage focus itself.
//
// The row is a neon card (see `TVNeonCard`) whose rim lights on focus, with a
// play affordance on the trailing edge. Focus does NOT invert the row to a white
// fill, which is what it did when rows were introduced: at 10 feet a white bar
// across the screen is a flashbulb, it flattens the depth the rest of the layout
// has, and it forced every piece of text on the row to carry a second colour for
// the inverted case. A rim that lights is legible from a sofa and needs none of
// that.
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
        HStack(spacing: 24) {
            if let trackNumber {
                Text("\(trackNumber)")
                    .font(TVType.meta)
                    .foregroundStyle(isFocused ? Color.white : Color.white.opacity(0.45))
                    .frame(width: 46, alignment: .trailing)
            } else {
                TVAuthImage(url: artworkURL, token: token) {
                    TVArtPlaceholder(systemImage: placeholderSymbol, iconScale: 0.5)
                }
                .frame(width: 86, height: 86)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.45), radius: isFocused ? 14 : 6, y: 4)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(TVType.rowTitle)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(artist.isEmpty ? "Unknown Artist" : artist)
                    .font(TVType.rowDetail)
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }

            Spacer(minLength: 16)

            if isFavorite {
                Image(systemName: "star.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(TVPalette.neonAlt)
                    .shadow(color: TVPalette.neonAlt.opacity(0.8), radius: 8)
            }
            if let detail {
                Text(detail)
                    .font(TVType.meta)
                    .foregroundStyle(.white.opacity(0.45))
            }

            // Not a separate button — a second focusable element per row would
            // double the presses needed to get down a list, and the row already
            // plays on select. This shows WHERE select will take you.
            Image(systemName: "play.fill")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(isFocused ? Color.black : Color.white.opacity(0.8))
                .frame(width: 50, height: 50)
                .background {
                    Circle().fill(
                        isFocused
                            ? AnyShapeStyle(LinearGradient(
                                colors: [TVPalette.neon, TVPalette.neonAlt],
                                startPoint: .topLeading, endPoint: .bottomTrailing))
                            : AnyShapeStyle(Color.white.opacity(0.10))
                    )
                }
                .shadow(color: TVPalette.neon.opacity(isFocused ? 0.75 : 0), radius: 14)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .tvNeonCard(isFocused: isFocused)
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
