import SwiftUI

// MARK: - TVDesignSystem
//
// Shared visual language for the tvOS port — "Aurora": a slowly drifting,
// softly colored ambient backdrop behind every screen (echoing the Now
// Playing screen's artwork-glow concept, but content-agnostic since most
// screens don't have a single piece of artwork to draw from), a consistent
// gradient placeholder for art that hasn't loaded (or never had any) instead
// of a flat gray box, and a shared section-header style with an accent
// glyph. One place to define the look so every screen reads as part of the
// same app instead of a loose collection of plain system-styled lists.

// MARK: Ambient background

/// Three soft, oversized blurred color fields drifting on independent slow
/// loops behind the content — subtle enough to stay out of the way of text
/// and focus outlines, present enough that the app doesn't read as flat
/// black everywhere. Intentionally cheap: three blurred circles, no images,
/// no per-frame work — this runs behind scrolling content on every screen.
struct TVAmbientBackground: View {
    var accent: Color = .accentColor
    @State private var drift = false

    var body: some View {
        ZStack {
            Color.black
            Circle()
                .fill(accent.opacity(0.35))
                .frame(width: 900, height: 900)
                .blur(radius: 220)
                .offset(x: drift ? -260 : -340, y: drift ? -260 : -180)
            Circle()
                .fill(Color.purple.opacity(0.28))
                .frame(width: 760, height: 760)
                .blur(radius: 200)
                .offset(x: drift ? 380 : 300, y: drift ? 120 : 220)
            Circle()
                .fill(Color.blue.opacity(0.22))
                .frame(width: 640, height: 640)
                .blur(radius: 180)
                .offset(x: drift ? -120 : -40, y: drift ? 340 : 420)
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeInOut(duration: 18).repeatForever(autoreverses: true)) {
                drift = true
            }
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
                Text(title).font(.system(size: 34, weight: .bold))
            }
            if let subtitle {
                // Deliberately well below the title (.title3 renders ~29pt on
                // tvOS, close enough to the 34pt title that shelf subtitles
                // competed with their own headings and made every screen read
                // as a wall of text). tvOS guidance is to minimise on-screen
                // text; the subtitle is a hint, not a second heading.
                Text(subtitle)
                    .font(.system(size: 21))
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
            .font(.system(size: 26, weight: isSelected || isFocused ? .bold : .semibold))
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
        .padding(.horizontal, 70)
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
        .font(.system(size: 22, weight: isSelected || isFocused ? .bold : .medium))
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
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                    .tracking(2)
                Text(title)
                    .font(.system(size: 56, weight: .heavy))
                    .lineLimit(2)
                Text(subtitle)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                playButton()
                    .padding(.top, 8)
            }
            .padding(.horizontal, 70)
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
            .padding(.horizontal, 70)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 32) { content() }
                    .padding(.horizontal, 70)
            }
        }
    }
}
