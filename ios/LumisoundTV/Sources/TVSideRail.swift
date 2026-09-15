import SwiftUI

// MARK: - TVSideRail
//
// The app's primary navigation, as a narrow vertical icon rail down the left
// edge, replacing the horizontal pill row that ran across the top.
//
// Why the change is structural and not just cosmetic:
//
//   - A top bar spends a full band of the screen's *height* on navigation, and
//     height is the scarce axis on a 16:9 display showing a list. The rail costs
//     width instead, which there is plenty of, so more content fits on screen.
//   - It moves navigation off the path between the content and the Now Playing
//     panel. With a top bar, moving "up" out of a list hit navigation; the rail
//     puts the three regions side by side, so left/right moves between regions
//     and up/down stays within one.
//   - Six destinations as icons in a column are readable at a glance from a
//     sofa in a way six text pills competing for one line are not.
//
// The rail's width is FIXED and its labels are an overlay on the focused item
// only. An earlier draft expanded the whole rail while focus was inside it,
// which needed a container-level "is focus anywhere in this subtree" probe —
// there is no supported API for that, and the workaround (an invisible
// `.focusable(false).focused($state)` wrapper) is the same class of focus-engine
// abuse that made v1.7.0 relaunch in a loop. A label that floats beside the
// focused item needs no such probe: it is driven entirely by that item's own
// `@Environment(\.isFocused)`, changes no layout, and cannot reorder focus.
struct TVSideRail: View {
    @Binding var selection: TVDestination
    var accountName: String
    var accountBadge: Int = 0
    /// Drawn in place of the account glyph — the rail showed a generic person
    /// icon while the account screen behind it showed the real picture, so the
    /// one place the avatar is permanently visible was the one place it wasn't.
    var user: TVUser? = nil
    var baseURL: String = ""

    static let width: CGFloat = 112

    var body: some View {
        VStack(spacing: 14) {
            mark
                .padding(.bottom, 26)

            ForEach(TVDestination.allCases) { dest in
                Button {
                    selection = dest
                } label: {
                    TVRailItemLabel(
                        title: dest.title(accountName: accountName),
                        systemImage: dest.systemImage,
                        isSelected: selection == dest,
                        badge: dest == .account ? accountBadge : 0,
                        avatar: dest == .account
                            ? TVAvatarView(user: user, baseURL: baseURL,
                                           diameter: 40, showsRing: false)
                            : nil
                    )
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
            }

            Spacer(minLength: 0)
        }
        // maxHeight as well as width: the VStack otherwise sizes to its content,
        // so the background gradient below stopped where the last icon did and
        // painted a hard-edged block partway down the screen instead of a full
        // column. `ignoresSafeArea` extends a view past the safe area; it does
        // not make one fill its parent.
        .padding(.vertical, 44)
        .frame(width: Self.width)
        // Fill the window's height so the background below covers a full
        // column. The VStack otherwise sizes to its content, so the gradient
        // stopped where the last icon did and painted a hard-edged block partway
        // down the screen. `ignoresSafeArea` extends a view past the safe area;
        // it does not make one fill its parent, which is what was needed.
        // Applied AFTER the padding — padding an already-infinite frame grows it
        // past the window rather than insetting the content within it.
        .frame(maxHeight: .infinity)
        .background {
            // Reads as a lit edge rather than a panel with a border on it.
            LinearGradient(
                colors: [TVPalette.surface.opacity(0.9), TVPalette.ground.opacity(0.25)],
                startPoint: .leading, endPoint: .trailing
            )
            .overlay(alignment: .trailing) {
                LinearGradient(
                    colors: [TVPalette.neon.opacity(0.55), TVPalette.neonAlt.opacity(0.35)],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(width: 1.5)
            }
        }
        // `.leading` as well as `.vertical`: with only the vertical edges
        // ignored, tvOS's horizontal safe-area inset left a strip of backdrop
        // between the rail and the screen edge — the rail floated slightly
        // inboard instead of being anchored to the side of the picture.
        .ignoresSafeArea(edges: [.vertical, .leading])
        .focusSection()
    }

    /// The Lumisound mark: a stack of bars — the app's own shape rather than a
    /// borrowed glyph — lit with the same neon as the rail edge.
    private var mark: some View {
        HStack(alignment: .center, spacing: 4) {
            ForEach(Array([16, 34, 24, 44, 20].enumerated()), id: \.offset) { _, h in
                Capsule()
                    .fill(
                        LinearGradient(colors: [TVPalette.neon, TVPalette.neonAlt],
                                       startPoint: .top, endPoint: .bottom)
                    )
                    .frame(width: 5, height: CGFloat(h))
            }
        }
        .frame(height: 48)
        .shadow(color: TVPalette.neon.opacity(0.7), radius: 14)
    }
}

/// One destination in the rail. Focus is read off the environment inside a
/// `.plain` button's label — the same pattern as `TVChip` and the old nav pill,
/// so focus styling stays consistent across every custom control in the port.
private struct TVRailItemLabel: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    var badge: Int = 0
    /// Replaces the glyph entirely when set (the account row).
    var avatar: TVAvatarView? = nil

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        ZStack {
            if let avatar {
                avatar
                    // Dimmed to match the other icons when this tab is neither
                    // focused nor current, so one row does not sit permanently
                    // brighter than the rest of the rail.
                    .opacity(isFocused || isSelected ? 1 : 0.55)
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(isFocused || isSelected ? Color.white : Color.white.opacity(0.45))
            }
            if badge > 0 {
                Text("\(badge)")
                    .font(.system(size: 15, weight: .bold))
                    .padding(5)
                    .background(TVPalette.neonAlt, in: Circle())
                    .offset(x: 19, y: -16)
            }
        }
        .frame(width: 60, height: 54)
        .background {
            // The selected destination keeps a quiet marker; the focused one
            // gets the lit surface. Both states must be distinguishable at once,
            // since focus moves through items that are not the current tab.
            ZStack(alignment: .leading) {
                if isFocused {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(TVPalette.surface)
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(TVPalette.neon.opacity(0.9), lineWidth: 1.5)
                        }
                        .shadow(color: TVPalette.neon.opacity(0.5), radius: 18)
                }
                if isSelected {
                    Capsule()
                        .fill(LinearGradient(colors: [TVPalette.neon, TVPalette.neonAlt],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: 4, height: 30)
                        .shadow(color: TVPalette.neon, radius: 8)
                        .offset(x: -14)
                }
            }
        }
        // Floating name for the focused item. `.overlay` with a fixed-size
        // frame and `allowsHitTesting(false)` so it paints outside the rail
        // without widening it or becoming a focus target of its own.
        .overlay(alignment: .leading) {
            if isFocused {
                Text(title)
                    .font(.system(size: 23, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background {
                        Capsule().fill(TVPalette.surface)
                        Capsule().strokeBorder(TVPalette.neon.opacity(0.7), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.6), radius: 16, y: 4)
                    .offset(x: 86)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .scaleEffect(isFocused ? 1.06 : 1)
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: isFocused)
    }
}
