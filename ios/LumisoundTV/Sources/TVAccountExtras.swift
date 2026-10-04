import SwiftUI

// MARK: - Round 4: Active Sessions + Notifications
//
// Both are plain bridge REST (GET /auth/sessions, GET /user/notifications) —
// see the round-4 scope note in TVBridge.swift for what was deliberately
// left out (push registration, change-password/2FA/delete-account, the
// full friend-request flow, Listen Together).

/// Parses the bridge's ISO-8601 timestamps (with fractional seconds) into a
/// short relative-ish string. Falls back to the raw string if parsing fails
/// rather than showing nothing.
private func tvFormattedTimestamp(_ iso: String?) -> String {
    guard let iso else { return "" }
    let withFraction = ISO8601DateFormatter()
    withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let withoutFraction = ISO8601DateFormatter()
    withoutFraction.formatOptions = [.withInternetDateTime]
    guard let date = withFraction.date(from: iso) ?? withoutFraction.date(from: iso) else { return iso }

    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return formatter.localizedString(for: date, relativeTo: Date())
}

// MARK: - Active Sessions

struct TVSessionsView: View {
    @ObservedObject var client: TVBridgeClient
    @ObservedObject var account: TVAccount
    let token: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                TVScreenTitle(title: "Active Sessions",
                              detail: client.sessions.isEmpty ? nil : "\(client.sessions.count) signed in",
                              eyebrow: "Account")

                if client.isLoadingSessions && client.sessions.isEmpty {
                    TVLoadingState(text: "Loading sessions…")
                } else if client.sessions.isEmpty {
                    TVEmptyState(systemImage: "rectangle.stack.badge.person.crop",
                                 title: "No active sessions")
                } else {
                    VStack(spacing: 14) {
                        ForEach(client.sessions) { session in
                            sessionRow(session)
                        }
                    }
                    .frame(maxWidth: 1300, alignment: .leading)
                    .padding(.horizontal, TVMetrics.margin)
                }
            }
            .padding(.bottom, 80)
        }
        .tvAmbientBackground()
        .task {
            if client.sessions.isEmpty { await client.fetchSessions(token: token) }
        }
    }

    private func sessionRow(_ session: TVSession) -> some View {
        HStack(spacing: 24) {
            Image(systemName: session.isCurrent ? "appletv.fill" : "iphone")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 68, height: 68)
                .background {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(session.isCurrent ? AnyShapeStyle(TVPalette.brand)
                              : AnyShapeStyle(Color.white.opacity(0.1)))
                }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 12) {
                    Text(session.deviceName ?? "Unknown Device")
                        .font(TVType.rowTitle)
                        .lineLimit(1)
                    if session.isCurrent {
                        Text("THIS DEVICE")
                            .font(TVType.eyebrow)
                            .tracking(1.6)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(TVPalette.violet.opacity(0.35)))
                    }
                }
                Text("Signed in \(tvFormattedTimestamp(session.createdAt))")
                    .font(TVType.rowDetail)
                    .foregroundStyle(TVPalette.textTertiary)
            }
            Spacer(minLength: 20)
            Button(role: .destructive) {
                Task {
                    let wasCurrentSession = await client.revokeSession(session.tokenID, token: token)
                    if wasCurrentSession { account.logout() }
                }
            } label: {
                TVPillLabel(title: session.isCurrent ? "Sign Out" : "Revoke",
                            systemImage: "xmark.circle", style: .secondary)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .tvNeonCard(cornerRadius: 24)
    }
}

// MARK: - Notifications

struct TVNotificationsView: View {
    @ObservedObject var client: TVBridgeClient
    let token: String

    private var unreadCount: Int { client.notifications.filter(\.isUnread).count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                HStack(alignment: .bottom) {
                    TVScreenTitle(title: "Notifications",
                                  detail: unreadCount > 0 ? "\(unreadCount) unread" : nil,
                                  eyebrow: "Account")
                    if unreadCount > 0 {
                        Button {
                            Task { await client.markAllNotificationsRead(token: token) }
                        } label: {
                            TVPillLabel(title: "Mark All Read", systemImage: "checkmark", style: .secondary)
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .padding(.trailing, TVMetrics.margin)
                    }
                }

                if client.isLoadingNotifications && client.notifications.isEmpty {
                    TVLoadingState(text: "Loading notifications…")
                } else if client.notifications.isEmpty {
                    TVEmptyState(systemImage: "bell.slash",
                                 title: "You're all caught up",
                                 message: "Notifications from Lumisound and your friends show up here.")
                } else {
                    VStack(spacing: TVMetrics.row) {
                        ForEach(client.notifications) { note in
                            Button {
                                guard note.isUnread else { return }
                                Task { await client.markNotificationRead(note.id, token: token) }
                            } label: {
                                TVNotificationRowLabel(note: note)
                            }
                            .buttonStyle(.plain)
                            .focusEffectDisabled()
                        }
                    }
                    .frame(maxWidth: 1300, alignment: .leading)
                    .padding(.horizontal, TVMetrics.margin - 20)
                }
            }
            .padding(.bottom, 80)
        }
        .tvAmbientBackground()
        .task {
            if client.notifications.isEmpty { await client.fetchNotifications(token: token) }
        }
    }
}

private struct TVNotificationRowLabel: View {
    let note: TVNotification
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        HStack(alignment: .top, spacing: 22) {
            Image(systemName: note.isUnread ? "bell.badge.fill" : "bell")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(note.isUnread ? Color.white : TVPalette.textTertiary)
                .frame(width: 54, height: 54)
                .background {
                    Circle().fill(note.isUnread ? AnyShapeStyle(TVPalette.brand)
                                  : AnyShapeStyle(Color.white.opacity(0.08)))
                }
            VStack(alignment: .leading, spacing: 5) {
                Text(note.title ?? "Notification")
                    .font(TVType.rowTitle)
                    .foregroundStyle(note.isUnread ? Color.white : TVPalette.textSecondary)
                if let body = note.body, !body.isEmpty {
                    Text(body)
                        .font(TVType.rowDetail)
                        .foregroundStyle(TVPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(tvFormattedTimestamp(note.createdAt))
                    .font(TVType.meta)
                    .foregroundStyle(TVPalette.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .tvNeonCard(cornerRadius: 22, isFocused: isFocused, isProminent: note.isUnread)
    }
}

// MARK: - Friends Listening Now
//
// Deliberately minimal — a passive "who's playing something right now" strip,
// not a full friends/social tab. A shared living-room screen showing a whole
// social graph is a worse fit than on a personal phone; this only ever renders
// when it has something to show (see TVBridgeClient.fetchFriendsListening).

struct TVFriendsListeningCard: View {
    let friendsListening: [TVFriendListening]

    var body: some View {
        if !friendsListening.isEmpty {
            VStack(spacing: 12) {
                ForEach(friendsListening) { entry in
                    HStack(spacing: 20) {
                        TVGeneratedArt(seed: entry.friend.name, systemImage: "person.fill")
                            .frame(width: 60, height: 60)
                            .clipShape(Circle())
                            .overlay {
                                Text(String(entry.friend.name.prefix(1)).uppercased())
                                    .font(.system(size: 26, weight: .heavy, design: .rounded))
                            }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.friend.name)
                                .font(TVType.rowTitle)
                                .lineLimit(1)
                            if let title = entry.presence.nowPlayingTitle, !title.isEmpty {
                                Text("\(title)\(entry.presence.nowPlayingArtist.map { " — \($0)" } ?? "")")
                                    .font(TVType.rowDetail)
                                    .foregroundStyle(TVPalette.textSecondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 12)
                        TVPlayingMeter(isAnimating: entry.presence.isPlaying)
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 14)
                    .tvNeonCard(cornerRadius: 22)
                }
            }
        }
    }
}
