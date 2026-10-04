import SwiftUI

// MARK: - TVSideRail
//
// Prism pass: the rail is a floating glass column inset from the screen edge,
// with the brand tile at the top, the five content destinations grouped in the
// middle and the account avatar anchored at the bottom — the same place every
// Apple TV app puts the profile. The current tab is a brand-gradient tile; the
// focused one is white (the strongest focus signal, on a small control) with
// its name floating beside it.
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
    /// Drawn in place of the account glyph — the one place the avatar is
    /// permanently visible should show the real picture.
    var user: TVUser? = nil
    var baseURL: String = ""

    static let width: CGFloat = 124

    private var contentDestinations: [TVDestination] {
        TVDestination.allCases.filter { $0 != .account }
    }

    var body: some View {
        VStack(spacing: 0) {
            TVBrandMark(height: 30)
                .padding(.bottom, 34)

            VStack(spacing: 14) {
                ForEach(contentDestinations) { dest in
                    item(dest)
                }
            }
            .padding(.vertical, 18)
            .padding(.horizontal, 12)
            .background {
                Capsule(style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay { Capsule(style: .continuous).fill(TVPalette.surface.opacity(0.5)) }
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(
                                LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.03)],
                                               startPoint: .top, endPoint: .bottom),
                                lineWidth: 1
                            )
                    }
                    .shadow(color: .black.opacity(0.4), radius: 24, y: 10)
            }

            Spacer(minLength: 24)

            item(.account)
        }
        .padding(.top, 50)
        .padding(.bottom, 50)
        .frame(width: Self.width)
        // Fill the window's height so the account item anchors to the bottom.
        // Applied AFTER the padding — padding an already-infinite frame grows
        // it past the window rather than insetting the content within it.
        .frame(maxHeight: .infinity)
        .ignoresSafeArea(edges: [.vertical, .leading])
        .focusSection()
    }

    private func item(_ dest: TVDestination) -> some View {
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
                                   diameter: 58, showsRing: false)
                    : nil
            )
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }
}

/// One destination in the rail. Focus is read off the environment inside a
/// `.plain` button's label — the same pattern as every custom control here.
private struct TVRailItemLabel: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    var badge: Int = 0
    /// Replaces the glyph entirely when set (the account item).
    var avatar: TVAvatarView? = nil

    @Environment(\.isFocused) private var isFocused

    private let size: CGFloat = 66

    var body: some View {
        ZStack {
            if let avatar {
                avatar
                    .overlay {
                        Circle()
                            .strokeBorder(isFocused ? AnyShapeStyle(Color.white)
                                          : isSelected ? AnyShapeStyle(TVPalette.brand)
                                          : AnyShapeStyle(Color.white.opacity(0.15)),
                                          lineWidth: isFocused || isSelected ? 3 : 1)
                    }
                    .opacity(isFocused || isSelected ? 1 : 0.7)
                    .frame(width: size, height: size)
            } else {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(isFocused ? AnyShapeStyle(Color.white)
                          : isSelected ? AnyShapeStyle(TVPalette.brand)
                          : AnyShapeStyle(Color.clear))
                    .frame(width: size, height: size)
                    .shadow(color: isSelected && !isFocused ? TVPalette.violet.opacity(0.55) : .clear,
                            radius: 14, y: 6)
                Image(systemName: systemImage)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(isFocused ? Color.black
                                     : isSelected ? Color.white
                                     : Color.white.opacity(0.5))
            }
            if badge > 0 {
                Text("\(badge)")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(minWidth: 26, minHeight: 26)
                    .background(Circle().fill(Color(red: 0.96, green: 0.33, blue: 0.47)))
                    .offset(x: 24, y: -24)
            }
        }
        .frame(width: size, height: size)
        // Floating name for the focused item: an overlay with
        // `allowsHitTesting(false)`, so it paints outside the rail without
        // widening it or becoming a focus target of its own.
        .overlay(alignment: .leading) {
            if isFocused {
                Text(title)
                    .font(.system(size: 23, weight: .semibold, design: .rounded))
                    .foregroundStyle(.black)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 20)
                    .padding(.vertical, 11)
                    .background(Capsule().fill(Color.white))
                    .shadow(color: .black.opacity(0.45), radius: 16, y: 6)
                    .offset(x: size + 22)
                    .allowsHitTesting(false)
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
        .scaleEffect(isFocused ? 1.1 : 1)
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: isFocused)
    }
}
