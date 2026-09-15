import SwiftUI

// MARK: - TVDesignSystem
//
// Shared visual language for the tvOS port.
//
// This replaces "Aurora", the previous pass. Aurora's premise was a *content-
// agnostic* backdrop — three drifting blurred circles — on the reasoning that
// most screens have no single piece of artwork to draw from. In practice that
// premise is what made the redesign invisible: a backdrop that never varies by
// screen, by track, or by time looks the same everywhere by construction, so
// the app still read as one flat surface no matter how much was layered on it.
//
// The current pass is built on three rules instead:
//
//   1. **The backdrop comes from the music.** `TVAmbientBackground` renders the
//      playing track's artwork, blurred and darkened. Every screen inherits the
//      colour of what's playing and changes when the track does. There IS always
//      a piece of artwork to draw from — it just isn't the screen's own.
//   2. **One scale, named.** `TVMetrics` and `TVType` replace the per-call-site
//      point sizes. Hierarchy you can see requires sizes that actually differ
//      and repeat; ad-hoc numbers produce neither.
//   3. **Different things look different.** Songs are rows (`TVTrackRow`),
//      albums and artists are square cards. A library rendered as one uniform
//      grid of identical tiles has no hierarchy to read, which is exactly how it
//      was reported: everything looks the same.

// MARK: Metrics and type scale
//
// Every size in this port used to be an ad-hoc `.system(size: N)` chosen per
// call site, which is the real reason the app read as undesigned: the same kind
// of thing was 34pt on one screen and 46pt on the next, and margins ranged from
// 60 to 110 with no rule behind them. Naming the steps is what makes a set of
// screens read as one app, so these are the only sizes the port should use.

enum TVMetrics {
    /// Horizontal screen margin. tvOS overscan already eats the outer ~60pt on
    /// some sets, so content starts well inboard of the frame edge.
    static let margin: CGFloat = 80
    /// Gap between major sections down a screen.
    static let section: CGFloat = 52
    /// Gap between sibling rows in a list.
    static let row: CGFloat = 12
    static let cardCorner: CGFloat = 14
    static let panelCorner: CGFloat = 22
}

enum TVType {
    /// Screen titles ("Library", "Discover") — one per screen, nothing else.
    static let display = Font.system(size: 58, weight: .heavy)
    /// Hero/Now Playing track titles.
    static let hero = Font.system(size: 44, weight: .bold)
    /// Section headings inside a screen.
    static let section = Font.system(size: 32, weight: .bold)
    /// The primary line of a list row or card.
    static let rowTitle = Font.system(size: 27, weight: .semibold)
    /// Secondary/supporting text — artists, counts, hints.
    static let rowDetail = Font.system(size: 22, weight: .regular)
    /// Numeric/trailing metadata: durations, indices, "3 of 40".
    static let meta = Font.system(size: 20, weight: .medium).monospacedDigit()
    /// All-caps kicker above a title.
    static let eyebrow = Font.system(size: 17, weight: .bold)
}

// MARK: Ambient background

/// The backdrop behind every screen: the **currently playing artwork**, blown
/// up, heavily blurred and darkened, over a colour floor.
///
/// This replaced three drifting blurred circles. The circles were content-
/// agnostic by design, and that was the mistake — they looked identical on
/// every screen and at every moment, so no matter what you were doing the app
/// looked the same. Deriving the backdrop from what's playing means the whole
/// app takes on the colour of the music, changes when the track changes, and
/// the thing the user is actually doing is visible in the design.
///
/// Performance notes, because this sits behind scrolling content on every
/// screen:
///   - The blurred artwork layer is **not animated**. A large `.blur` is cheap
///     to composite while static and expensive to re-composite every frame;
///     the earlier version animated its layers continuously for no real gain.
///   - `.scaleEffect` past the bounds hides the soft transparent edge a blur
///     leaves behind, which is cheaper than drawing a second bleed layer.
///   - The colour floor is always drawn, so there is never a flat black frame
///     while artwork loads, and screens still look intentional with nothing
///     playing at all.
struct TVAmbientBackground: View {
    var accent: Color = .accentColor
    /// Same adoption pattern as `TVContentView` — this is the app-wide player,
    /// observed so the backdrop follows track changes.
    @StateObject private var player = TVPlayerModel.shared

    private var track: TVPlayable? { player.current }

    var body: some View {
        ZStack {
            colorFloor

            if let track {
                TVAuthImage(url: track.artworkURL, token: track.authToken) {
                    Color.clear
                }
                // Overscale to push the blur's feathered edges off-screen.
                .scaleEffect(1.4)
                .blur(radius: 110, opaque: false)
                .saturation(1.3)
                // Without this the backdrop competes with the foreground and
                // nothing on top of it is legible. It is a wash, not an image.
                .overlay(Color.black.opacity(0.66))
                .id(track.id)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.8), value: track.id)
            }

            // Bottom scrim so the mini-player bar and any bottom-aligned text
            // always have something solid to sit against.
            LinearGradient(
                colors: [.clear, .black.opacity(0.75)],
                startPoint: .center, endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }

    /// Drawn under the artwork and alone when nothing is playing. Two offset
    /// radial fields rather than a flat fill, so the empty state still has
    /// some depth to it.
    private var colorFloor: some View {
        ZStack {
            Color.black
            RadialGradient(
                colors: [accent.opacity(0.42), .clear],
                center: .init(x: 0.12, y: 0.05), startRadius: 0, endRadius: 1150
            )
            RadialGradient(
                colors: [Color.purple.opacity(0.34), .clear],
                center: .init(x: 0.92, y: 0.88), startRadius: 0, endRadius: 1000
            )
        }
    }
}

extension View {
    /// Drops `TVAmbientBackground` behind this view — apply once, near the
    /// root of a screen's `body` (e.g. wrapping a `ScrollView`), not per row/
    /// card.
    func tvAmbientBackground(accent: Color = .accentColor) -> some View {
        background(TVAmbientBackground(accent: accent))
    }
}

// MARK: Screen title

/// The one large title at the top of a screen, with an optional count/summary
/// beside it. Gives every tab the same anchor so moving between them feels
/// like one app rather than six unrelated views.
struct TVScreenTitle: View {
    let title: String
    var detail: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 20) {
            Text(title).font(TVType.display)
            if let detail {
                Text(detail)
                    .font(TVType.rowDetail)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, TVMetrics.margin)
    }
}

// MARK: Art placeholder

/// Replaces the flat `Color.gray.opacity(0.3)` box every grid card used to
/// fall back to with a subtle accent-tinted gradient — still clearly a
/// placeholder (never mistaken for real artwork), but one that belongs to
/// this app's palette instead of a generic gray tile.
struct TVArtPlaceholder: View {
    let systemImage: String
    var iconScale: CGFloat = 1.0

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.accentColor.opacity(0.5), Color.black.opacity(0.75)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            Image(systemName: systemImage)
                .font(.system(size: 44 * iconScale, weight: .light))
                .foregroundStyle(.white.opacity(0.8))
        }
    }
}

// MARK: Section header

/// Shared header for the horizontally-scrolling sections on Discover (and
/// anywhere else that wants the same treatment) — a short accent-colored
/// rule next to the title is a small, cheap way to make section starts
/// visually distinct from the plain bold-text headers used before.
struct TVSectionHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 34)
                Text(title).font(TVType.section)
            }
            if let subtitle {
                // Deliberately well below the title (.title3 renders ~29pt on
                // tvOS, close enough to the 34pt title that shelf subtitles
                // competed with their own headings and made every screen read
                // as a wall of text). tvOS guidance is to minimise on-screen
                // text; the subtitle is a hint, not a second heading.
                Text(subtitle)
                    .font(TVType.rowDetail)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 20)
            }
        }
    }
}

// MARK: Glass panel

/// A translucent, blurred panel background — used for stat tiles, form
/// panels, and other content that needs to sit legibly on top of
/// `TVAmbientBackground` without a hard-edged solid fill.
struct TVGlassPanel: ViewModifier {
    var cornerRadius: CGFloat = 20
    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            )
    }
}

extension View {
    func tvGlassPanel(cornerRadius: CGFloat = 20) -> some View {
        modifier(TVGlassPanel(cornerRadius: cornerRadius))
    }
}

// MARK: - Top-level destinations
//
// The root shell used to be a stock `TabView` — tvOS renders that as its own
// fixed top tab bar chrome, which can't be restyled and reads as a completely
// generic "any tvOS app" shell. `TVTopNavBar` below replaces it with a custom
// row we fully control, driven by this selection enum instead of `.tabItem`.

enum TVDestination: String, CaseIterable, Identifiable {
    case home, library, playlists, discover, search, account
    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .home:      return "house.fill"
        case .library:   return "music.note.house.fill"
        case .playlists: return "music.note.list"
        case .discover:  return "sparkles"
        case .search:    return "magnifyingglass"
        case .account:   return "person.crop.circle.fill"
        }
    }

    func title(accountName: String) -> String {
        switch self {
        case .home:      return "Home"
        case .library:   return "Library"
        case .playlists: return "Playlists"
        case .discover:  return "Discover"
        case .search:    return "Search"
        case .account:   return accountName
        }
    }
}

/// One pill in `TVTopNavBar` — reads focus off its own environment (tvOS
/// populates `@Environment(\.isFocused)` on a `Button` label's subtree while
/// that button is the focused element) rather than the button carrying any
/// focus styling itself, same pattern as `TVPlayerView`'s transport buttons.
private struct TVNavPillLabel: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 25, weight: isSelected || isFocused ? .bold : .semibold))
            .foregroundStyle(
                isFocused ? Color.black
                : isSelected ? Color.white
                : Color.white.opacity(0.55)
            )
            .padding(.horizontal, 30)
            .padding(.vertical, 16)
            .background(
                Capsule().fill(
                    isFocused ? Color.white
                    : isSelected ? Color.white.opacity(0.16)
                    : Color.clear
                )
            )
            .scaleEffect(isFocused ? 1.08 : 1.0)
            .shadow(color: isFocused ? .black.opacity(0.35) : .clear, radius: isFocused ? 16 : 0, y: 8)
            .animation(.spring(response: 0.32, dampingFraction: 0.75), value: isFocused)
    }
}

/// Custom persistent top navigation replacing the stock `TabView` tab bar —
/// a translucent pill row that floats over `TVAmbientBackground` instead of
/// tvOS's own opaque system chrome.
struct TVTopNavBar: View {
    @Binding var selection: TVDestination
    var accountName: String
    var accountBadge: Int = 0

    var body: some View {
        HStack(spacing: 22) {
            ForEach(TVDestination.allCases) { dest in
                Button {
                    selection = dest
                } label: {
                    TVNavPillLabel(
                        title: dest.title(accountName: accountName),
                        systemImage: dest.systemImage,
                        isSelected: selection == dest
                    )
                }
                .buttonStyle(.plain)
                .overlay(alignment: .topTrailing) {
                    if dest == .account, accountBadge > 0 {
                        Text("\(accountBadge)")
                            .font(.caption2.weight(.bold))
                            .padding(6)
                            .background(Color.red, in: Circle())
                            .offset(x: 8, y: -8)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, TVMetrics.margin)
        .padding(.top, 54)
        .padding(.bottom, 26)
    }
}

// MARK: - Chip (filter pills — Library's Songs/Albums/Artists/… selector,
// Search's suggestion row, anywhere a stock `Picker`/segmented control would
// otherwise be the only focus-driven option on tvOS)

struct TVChip: View {
    let title: String
    let isSelected: Bool
    var systemImage: String? = nil
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        Group {
            if let systemImage {
                Label(title, systemImage: systemImage)
            } else {
                Text(title)
            }
        }
        .font(.system(size: 21, weight: isSelected || isFocused ? .bold : .medium))
        .foregroundStyle(
            isFocused ? Color.black
            : isSelected ? Color.white
            : Color.white.opacity(0.6)
        )
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(
            Capsule().fill(
                isFocused ? Color.white
                : isSelected ? Color.accentColor.opacity(0.35)
                : Color.white.opacity(0.08)
            )
        )
        .overlay(
            Capsule().strokeBorder(
                isSelected && !isFocused ? Color.accentColor.opacity(0.7) : .clear,
                lineWidth: 2
            )
        )
        .scaleEffect(isFocused ? 1.08 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isFocused)
    }
}

// MARK: - Hero banner

/// The big featured treatment at the top of the Home hub — a blown-up piece
/// of artwork with a gradient scrim, title/subtitle, and a Play button.
/// Content-agnostic: callers decide what's "featured" (most-recently-added,
/// a Discover Mix pick, etc.) and just hand this the pieces to render.
struct TVHeroBanner<Art: View, PlayButton: View>: View {
    let eyebrow: String
    let title: String
    let subtitle: String
    let art: () -> Art
    /// The actual focusable/navigable control — a caller-supplied
    /// `NavigationLink` (or `Button`), NOT a plain action closure. The hero
    /// itself carries no button of its own: nesting a `Button` inside this
    /// view while ALSO wrapping the whole banner in a `NavigationLink` (as an
    /// earlier draft did) creates two overlapping focusable elements, which
    /// tvOS's focus engine can't cleanly resolve. This is the one and only
    /// focusable/interactive element in the banner.
    let playButton: () -> PlayButton

    init(
        eyebrow: String,
        title: String,
        subtitle: String,
        @ViewBuilder art: @escaping () -> Art,
        @ViewBuilder playButton: @escaping () -> PlayButton
    ) {
        self.eyebrow = eyebrow
        self.title = title
        self.subtitle = subtitle
        self.art = art
        self.playButton = playButton
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            art()
                .frame(height: 620)
                .frame(maxWidth: .infinity)
                .clipped()

            LinearGradient(
                colors: [.clear, .black.opacity(0.55), .black.opacity(0.92)],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: 620)

            VStack(alignment: .leading, spacing: 14) {
                Text(eyebrow.uppercased())
                    .font(TVType.eyebrow)
                    .foregroundStyle(Color.accentColor)
                    .tracking(2)
                Text(title)
                    .font(TVType.display)
                    .lineLimit(2)
                Text(subtitle)
                    .font(TVType.rowDetail)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                playButton()
                    .padding(.top, 8)
            }
            .padding(.horizontal, TVMetrics.margin)
            .padding(.bottom, 56)
        }
        .frame(height: 620)
    }
}

// MARK: - Shelf section (Home hub + Discover share this shape)

/// A titled, horizontally-scrolling row of cards with an optional "See All"
/// destination — the recurring shape every Home/Discover shelf reduces to.
/// The destination is type-erased (`AnyView`) rather than a second generic
/// parameter so the no-"See All" initializer doesn't need a stand-in type.
struct TVShelfSection<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    let content: () -> Content
    var seeAll: (() -> AnyView)? = nil

    init(title: String, subtitle: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content
        self.seeAll = nil
    }

    init<Destination: View>(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder seeAll: @escaping () -> Destination
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content
        self.seeAll = { AnyView(seeAll()) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .lastTextBaseline) {
                TVSectionHeader(title: title, subtitle: subtitle)
                if let seeAll {
                    Spacer()
                    NavigationLink {
                        seeAll()
                    } label: {
                        Label("See All", systemImage: "chevron.right")
                            .labelStyle(.titleAndIcon)
                            .font(.headline)
                    }
                    .buttonStyle(.card)
                }
            }
            .padding(.horizontal, TVMetrics.margin)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 32) { content() }
                    .padding(.horizontal, TVMetrics.margin)
            }
        }
    }
}
