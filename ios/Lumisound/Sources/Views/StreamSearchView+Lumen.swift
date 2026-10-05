import SwiftUI

// MARK: - Lumen frame
//
// Lumen's Cloud tab. Search, sources, results and every download/stream
// action are the classic implementation (`configuredBody` and friends);
// Lumen supplies the frame — its title, lit backdrop, and a row of tool
// chips in place of the overflow menu — while the result rows and cards pick up Lumen surfaces from
// `adaptiveGlass` and `LumenUIKitSkin`.

extension StreamSearchView {
    var lumenBody: some View {
        NavigationStack {
            Group {
                if streaming.isConfigured {
                    VStack(spacing: 0) {
                        lumenToolsRow
                            .padding(.top, 4)
                            .padding(.bottom, 6)
                        configuredBody
                    }
                } else {
                    notConfiguredView
                }
            }
            .navigationTitle("Cloud")
            .navigationBarTitleDisplayMode(.large)
            .background(LumenBackdrop())
            .scrollContentBackground(.hidden)
        }
    }

    private var lumenToolsRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                lumenTool("Subscriptions", icon: "person.crop.circle.badge.checkmark") { SubscriptionsView() }
                lumenTool("Discover", icon: "sparkles") { DiscoverView() }
                lumenTool("Discover Mix", icon: "wand.and.stars") { DiscoverMixView() }
                if account.isLoggedIn {
                    lumenTool("Shared With Me", icon: "person.2.fill") { SharedPlaylistsView() }
                    lumenTool("Pending Imports", icon: "tray.and.arrow.down") { PendingImportsView() }
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden)
    }

    private func lumenTool<Destination: View>(_ title: String, icon: String,
                                              @ViewBuilder destination: @escaping () -> Destination) -> some View {
        NavigationLink {
            destination()
                .background(LumenBackdrop())
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 12, weight: .bold))
                Text(title).font(LumenType.caption(13))
            }
            .foregroundStyle(LumenPalette.textPrimary)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(LumenPalette.fill, in: Capsule())
            .overlay(Capsule().strokeBorder(LumenPalette.hairline, lineWidth: 1))
        }
        .buttonStyle(LumenPressStyle())
    }
}
