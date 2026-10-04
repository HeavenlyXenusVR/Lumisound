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
// Prism pass: a resting row has no card at all — just artwork and text on the
// backdrop — and the focused row lifts onto a lit surface with a gradient play
// affordance. Thirty outlined boxes down a screen made the outlines the most
// visible thing in the list. Focus does NOT invert the row to a white
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
    /// takes the artwork's place: inside a single album every row would
    /// otherwise show the *same* cover repeated down the screen.
    var trackNumber: Int? = nil
    /// Greys the row out and replaces the play affordance with a note — for
    /// playlist entries that only exist on another device.
    var unavailableReason: String? = nil

    @Environment(\.isFocused) private var isFocused

    private var isAvailable: Bool { unavailableReason == nil }

    var body: some View {
        HStack(spacing: 24) {
            leading

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(TVType.rowTitle)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(artist.isEmpty ? "Unknown Artist" : artist)
                    .font(TVType.rowDetail)
                    .foregroundStyle(isFocused ? TVPalette.textSecondary : TVPalette.textTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 16)

            if isFavorite {
                Image(systemName: "star.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(TVPalette.brand)
            }
            if let unavailableReason {
                Text(unavailableReason)
                    .font(TVType.meta)
                    .foregroundStyle(TVPalette.textTertiary)
            } else if let detail {
                Text(detail)
                    .font(TVType.meta)
                    .foregroundStyle(isFocused ? TVPalette.textSecondary : TVPalette.textTertiary)
                    .frame(minWidth: 64, alignment: .trailing)
            }

            // Not a separate button — a second focusable element per row would
            // double the presses needed to get down a list. This only shows
            // WHERE select will take you, and only on the row that has focus,
            // so a resting list is titles and nothing else.
            Image(systemName: isAvailable ? "play.fill" : "iphone.slash")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background {
                    Circle().fill(isAvailable ? AnyShapeStyle(TVPalette.brand)
                                  : AnyShapeStyle(Color.white.opacity(0.12)))
                }
                .opacity(isFocused ? 1 : 0)
                .scaleEffect(isFocused ? 1 : 0.6)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .opacity(isAvailable || isFocused ? 1 : 0.5)
        .tvNeonCard(cornerRadius: 20, isFocused: isFocused, isProminent: false)
    }

    @ViewBuilder
    private var leading: some View {
        if let trackNumber {
            Text("\(trackNumber)")
                .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(isFocused ? Color.white : TVPalette.textTertiary)
                .frame(width: 50, alignment: .center)
        } else {
            TVAuthImage(url: artworkURL, token: token) {
                TVArtPlaceholder(systemImage: placeholderSymbol, iconScale: 0.5)
            }
            .frame(width: 66, height: 66)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.4), radius: isFocused ? 12 : 4, y: 4)
        }
    }
}

/// A full-width list of rows sits inside this so every list screen has the
/// same inset and spacing.
struct TVTrackList<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        LazyVStack(spacing: TVMetrics.row) {
            content()
        }
        .padding(.horizontal, TVMetrics.margin - 20)
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
