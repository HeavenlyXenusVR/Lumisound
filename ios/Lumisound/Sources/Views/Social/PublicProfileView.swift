import SwiftUI
import UIKit

// MARK: - PublicProfileView
//
// Read-only view of another user's profile: avatar, bio, their chosen
// main/sub accent colors, pinned favorite tracks, live online/offline +
// now-playing presence, and contextual friend actions (add / accept-decline
// / remove / block) based on the current relationship.
struct PublicProfileView: View {
    let userId: String
    /// Set when this screen is showing the signed-in user's own profile —
    /// either the Profile tab's default view or ProfileView's "View as
    /// Public" preview sheet. Defaults to `false` so every existing call
    /// site (`PublicProfileView(userId:)`) is unaffected. Suppresses the
    /// friend-request/block controls, which would otherwise render
    /// nonsensically self-referential ("Add Friend" pointed at yourself).
    var isSelfPreview: Bool = false
    /// Non-nil when this view IS the Profile tab's primary destination
    /// (rather than the "View as Public" preview sheet reached from inside
    /// the editor): renders an "Edit Profile" button in the header's action
    /// slot instead of the "this is how you look to others" hint, and is
    /// called when that button is tapped so the caller can push the editor.
    /// Only meaningful when `isSelfPreview` is true.
    var onEditProfile: (() -> Void)? = nil

    @EnvironmentObject private var social: SocialService
    @EnvironmentObject private var account: AccountService
    @EnvironmentObject private var player: AudioPlayerManager
    @StateObject private var presenceService = PresenceService.shared

    @State private var profile: PublicSocialProfile? = nil
    @State private var presence: SocialPresence? = nil
    @State private var bannerImage: UIImage? = nil
    @State private var isLoading = true
    @State private var isActing = false
    @State private var showBlockConfirm = false
    @State private var showRemoveConfirm = false
    @State private var comments: [ProfileComment] = []
    @State private var draftComment = ""
    @State private var isPostingComment = false
    @State private var compatibility: MusicCompatibility? = nil
    /// What this library actually sounds like. Friends-only, same as
    /// compatibility — see SonicFingerprintView for why it is treated that way.
    @State private var fingerprint: SonicFingerprint? = nil
    @State private var showBlendMix = false
    // MARK: Feature: profile-customization-3
    @State private var recentlyPlayedTogether: [SharedRecentTrack] = []

    private var mainAccentColor: Color { SocialAccentPalette.color(for: profile?.mainAccentHex) ?? AppTheme.dynamicAccent }
    private var subAccentColor: Color { SocialAccentPalette.color(for: profile?.subAccentHex) ?? AppTheme.accentSoft }

    /// For the self-preview case, "online" is answered locally (are you
    /// logged in and is the app actually in the foreground right now?)
    /// rather than by round-tripping through the same `/api/social/presence`
    /// GET a genuine visitor's client uses. That GET fires the instant this
    /// view appears, racing the heartbeat POST that reports you online in
    /// the first place (PresenceService.startHeartbeat, owned separately by
    /// ContentView) — on a fresh app-open -> Profile tab tap, or after any
    /// single transient network hiccup, the fetch can land before the
    /// server has a fresh row and this screen would show YOU as offline
    /// despite the app being open right in front of you. There's no such
    /// race for the local answer: it's already known without asking anyone.
    private var isOnline: Bool {
        if isSelfPreview {
            return account.isLoggedIn && UIApplication.shared.applicationState == .active
        }
        return presence?.online ?? false
    }

    /// What to show in the "Listening To" card, if anything. Was driven by
    /// `presence` unconditionally, which meant this NEVER showed in
    /// self-preview: the presence-polling `.task` below is deliberately
    /// skipped for self-preview (same reasoning as `isOnline` above — no
    /// need to round-trip through a remote GET, racy against your own
    /// heartbeat, to learn what YOUR OWN device is currently playing), so
    /// `presence` just stayed `nil` forever there and this card silently
    /// never appeared — on the Profile tab itself, or on the "View as
    /// Public" preview, even with "Share Now Playing" turned on. Local
    /// player state for self-preview (same source `ProfileView`'s own
    /// "Listening To" section already uses, unconditionally — matching that
    /// precedent rather than re-deriving the share-now-playing check here,
    /// since this is your own screen showing your own state, not a
    /// broadcast to someone else); server-provided, privacy-gated presence
    /// for an actual visitor.
    private var displayedNowPlaying: (title: String, artist: String?, song: Song?, artworkURL: URL?)? {
        if isSelfPreview {
            guard let song = player.currentSong, player.isPlaying else { return nil }
            return (song.title, song.artist.isEmpty ? nil : song.artist, song, nil)
        }
        guard presence?.online == true, presence?.isPlaying == true,
              let title = presence?.nowPlayingTitle else { return nil }
        // No `song` for a visitor's view (only this device's own local
        // player state has one) — but the presence payload does carry a
        // best-effort artwork URL now (see SocialPresence.nowPlayingArtworkURL),
        // so NowPlayingActivityRow still shows real artwork via AsyncImage
        // instead of always falling back to the placeholder icon.
        let artworkURL = presence?.nowPlayingArtworkURL.flatMap(URL.init(string:))
        return (title, presence?.nowPlayingArtist, nil, artworkURL)
    }

    /// An incoming pending request FROM this user, if any.
    private var incomingRequest: SocialFriendRequest? {
        social.incomingRequests.first { $0.userId == userId }
    }
    /// An outgoing pending request TO this user, if any.
    private var outgoingRequest: SocialFriendRequest? {
        social.outgoingRequests.first { $0.userId == userId }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear.ignoresSafeArea()
            if profile != nil {
                ProfileAccentBackgroundGlow(
                    mainAccent: mainAccentColor, subAccent: subAccentColor,
                    intensity: ProfileGlowIntensity.from(profile?.accentGlowIntensity)
                )
            }

            if isLoading {
                ProgressView().tint(AppTheme.dynamicAccent)
            } else if let profile {
                ScrollView {
                    VStack(spacing: 16) {
                        if isSelfPreview, onEditProfile == nil {
                            Label("This is how your profile looks to others", systemImage: "eye")
                                .font(AppTheme.bodyFont(size: 12))
                                .foregroundStyle(AppTheme.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        ProfileHeaderCard(
                            mainAccent: mainAccentColor,
                            subAccent: subAccentColor,
                            displayName: profile.displayName ?? profile.username,
                            username: profile.username,
                            isOnline: isOnline,
                            bannerImage: bannerImage,
                            avatarFrame: profile.avatarFrame,
                            avatarDecoration: profile.avatarDecoration,
                            profileEffect: profile.profileEffect,
                            pronouns: profile.pronouns,
                            statusEmoji: profile.statusEmoji,
                            statusText: profile.statusText,
                            discordVerified: profile.discordVerified,
                            discordUsername: profile.discordUsername
                        ) {
                            SocialAvatarView(userId: userId, size: 84, fallbackFill: .clear)
                        } action: {
                            if !isSelfPreview {
                                friendActionControl
                            } else if let onEditProfile {
                                Button(action: onEditProfile) {
                                    Label("Edit Profile", systemImage: "pencil")
                                        .foregroundStyle(mainAccentColor)
                                }
                            }
                        }

                        if let nowPlaying = displayedNowPlaying {
                            ProfileInfoCard(title: "Listening To", icon: "waveform", tint: mainAccentColor) {
                                NowPlayingActivityRow(title: nowPlaying.title, artist: nowPlaying.artist, tint: mainAccentColor, song: nowPlaying.song, artworkURL: nowPlaying.artworkURL)
                            }
                        }

                        if let bio = profile.bio, !bio.isEmpty {
                            ProfileInfoCard(title: "Bio / Status", icon: "text.quote", tint: mainAccentColor) {
                                bioText(bio)
                                    .font(AppTheme.bodyFont(size: 14))
                                    .foregroundStyle(AppTheme.textPrimary)
                            }
                        }

                        ProfileInfoCard(title: "Member Since", icon: "calendar", tint: subAccentColor) {
                            MemberSinceRow(memberSince: profile.memberSince)
                        }

                        // MARK: Badges — no privacy toggle, always shown
                        // once earned (public flair, like a Discord badge).
                        if !profile.badges.isEmpty {
                            ProfileInfoCard(title: "Badges", icon: "rosette", tint: mainAccentColor) {
                                ProfileBadgeRow(badges: profile.badges)
                            }
                        }

                        if !profile.pinnedTracks.isEmpty {
                            ProfileInfoCard(title: "Pinned Favorite Tracks", icon: "pin.fill", tint: subAccentColor) {
                                VStack(spacing: 10) {
                                    ForEach(Array(profile.pinnedTracks.enumerated()), id: \.offset) { index, track in
                                        PinnedTrackRow(title: track.title, artist: track.artist, tint: subAccentColor)
                                        if index < profile.pinnedTracks.count - 1 {
                                            Divider().background(AppTheme.textSecondary.opacity(0.15))
                                        }
                                    }
                                }
                            }
                        }

                        // MARK: Featured Playlist — an owner-chosen
                        // spotlight; shown whenever set, same visibility as
                        // pinned tracks above (no separate privacy toggle —
                        // featuring a playlist is itself an intentional
                        // public action).
                        if let featuredPlaylist = profile.featuredPlaylist {
                            ProfileInfoCard(title: "Featured Playlist", icon: "music.note.list", tint: subAccentColor) {
                                FeaturedPlaylistRow(playlist: featuredPlaylist, tint: subAccentColor)
                            }
                        }

                        // MARK: Listening Streak — only present when the
                        // owner opted in via show_listening_stats.
                        if let streak = profile.listeningStreak {
                            ProfileInfoCard(title: "Listening Streak", icon: "flame.fill", tint: mainAccentColor) {
                                ListeningStreakRow(streak: streak, tint: mainAccentColor)
                            }
                        }

                        // MARK: Profile Visitors — only present when the
                        // owner opted in via show_visitor_stats; the
                        // recent-visitor avatar stack inside further
                        // requires the viewer to actually be a friend (see
                        // the bridge's _profile_visitor_stats).
                        if let visitorCount = profile.visitorCount {
                            ProfileInfoCard(title: "Profile Visitors", icon: "eye.fill", tint: mainAccentColor) {
                                ProfileVisitorStatsRow(visitorCount: visitorCount, recentVisitors: profile.recentVisitors, tint: mainAccentColor)
                            }
                        }

                        if let compatibility, profile.isFriend, !isSelfPreview {
                            ProfileInfoCard(title: "Music Match", icon: "waveform.path.ecg", tint: mainAccentColor) {
                                VStack(alignment: .leading, spacing: 12) {
                                    MusicCompatibilityRow(compatibility: compatibility, tint: mainAccentColor)
                                    // Why the score is what it is. A bare
                                    // percentage cannot be agreed or disagreed
                                    // with; these can.
                                    MusicMatchReasons(compatibility: compatibility)
                                    Button {
                                        showBlendMix = true
                                    } label: {
                                        Label("Play Blend Mix", systemImage: "play.fill")
                                            .font(.subheadline.weight(.semibold))
                                            .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(mainAccentColor)
                                }
                            }
                        }

                        // MARK: Listening Fingerprint
                        //
                        // Deliberately placed with the other music cards rather
                        // than in the showcase area at the top: unlike a pinned
                        // track or a featured playlist, this one cannot be
                        // curated. It is measured from what the library actually
                        // contains, so it belongs with the factual sections, not
                        // the presented ones.
                        if let fingerprint, fingerprint.available {
                            ProfileInfoCard(title: "Listening Fingerprint",
                                            icon: "waveform.badge.magnifyingglass",
                                            tint: subAccentColor) {
                                SonicFingerprintView(fingerprint: fingerprint)
                            }
                        }

                        // MARK: Recently Played Together — extra feature #5,
                        // friends-only (the fetch itself is skipped for
                        // self-preview/non-friends — see the .task below).
                        if !recentlyPlayedTogether.isEmpty, profile.isFriend, !isSelfPreview {
                            ProfileInfoCard(title: "Recently Played Together", icon: "person.2.wave.2.fill", tint: subAccentColor) {
                                SharedRecentTracksRow(tracks: recentlyPlayedTogether, tint: subAccentColor)
                            }
                        }

                        if !profile.topGenres.isEmpty || !profile.topArtists.isEmpty {
                            ProfileInfoCard(title: "Top Music", icon: "chart.bar.fill", tint: mainAccentColor) {
                                TopMusicShowcaseRow(topGenres: profile.topGenres, topArtists: profile.topArtists, tint: mainAccentColor)
                            }
                        }

                        if profile.showGuestbook || isSelfPreview {
                            ProfileInfoCard(title: "Guestbook", icon: "bubble.left.and.bubble.right.fill", tint: subAccentColor) {
                                guestbookContent
                            }
                        }

                        if profile.isFriend, !isSelfPreview {
                            ProfileInfoCard(tint: AppTheme.error) {
                                Button(role: .destructive) { showBlockConfirm = true } label: {
                                    Label("Block User", systemImage: "hand.raised.fill")
                                        .frame(maxWidth: .infinity)
                                }
                            }
                        }
                    }
                    .padding(.top, 4)
                    .padding(.bottom, 40)
                }
            } else {
                Text("This profile isn't available.")
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
        .navigationTitle(profile?.displayName ?? profile?.username ?? "Profile")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadProfile()
            // Friend-request state only feeds `friendActionControl`, which is
            // never rendered in self-preview (see its `!isSelfPreview` guard
            // above) — fetching it there is a pure wasted round trip on the
            // single most-hit screen in the app (the Profile tab).
            if !isSelfPreview {
                await social.fetchFriendRequests()
            }
        }
        // Lightweight self-cancelling poll for this one profile's presence —
        // stops automatically when the view disappears, unlike the standing
        // friends-list timer in PresenceService (which only runs while
        // FriendsListView itself is on screen). Skipped for self-preview:
        // `isOnline` above answers itself locally and never reads `presence`.
        .task {
            guard !isSelfPreview else { return }
            while !Task.isCancelled {
                presence = await presenceService.fetchPresence(userId: userId, account: account)
                try? await Task.sleep(nanoseconds: UInt64(PresenceService.friendsPollInterval * 1_000_000_000))
            }
        }
        // Guestbook comments are readable regardless of relationship (the
        // bridge only blocks a blocked-either-direction pair, matching
        // profile visibility generally) — fetched unconditionally, unlike
        // compatibility below which the bridge hard-requires friendship for.
        .task { comments = await social.fetchProfileComments(userId: userId) }
        .task {
            guard !isSelfPreview else { return }
            compatibility = await social.fetchCompatibility(userId: userId)
        }
        .task {
            // Fetched for a self-preview too: seeing your own fingerprint is
            // the whole point of having one, and the endpoint allows it.
            fingerprint = await social.fetchSonicFingerprint(userId: userId)
        }
        // Extra feature #5 — same friends-only/self-preview-skip reasoning
        // as compatibility just above (the endpoint itself 400s on a
        // self-lookup and 403s on a non-friend, so there's no point firing
        // it in either case).
        .task {
            guard !isSelfPreview else { return }
            recentlyPlayedTogether = await social.fetchRecentlyPlayedTogether(userId: userId)
        }
        .confirmationDialog("Block this user?", isPresented: $showBlockConfirm, titleVisibility: .visible) {
            Button("Block", role: .destructive) {
                Task {
                    await social.blockUser(userId)
                    await loadProfile()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll no longer see each other's profiles, and any friendship or pending request will be removed.")
        }
        .confirmationDialog("Remove this friend?", isPresented: $showRemoveConfirm, titleVisibility: .visible) {
            Button("Remove Friend", role: .destructive) {
                Task {
                    await social.removeFriend(userId)
                    await loadProfile()
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showBlendMix) {
            NavigationStack {
                BlendMixView(friendUserID: userId, friendName: profile?.displayName ?? profile?.username ?? "your friend")
            }
        }
    }

    @ViewBuilder
    private var friendActionControl: some View {
        if isActing {
            HStack { Spacer(); ProgressView().tint(AppTheme.dynamicAccent); Spacer() }
        } else if let profile, profile.isFriend {
            Button(role: .destructive) { showRemoveConfirm = true } label: {
                Label("Remove Friend", systemImage: "person.fill.badge.minus")
            }
        } else if let incoming = incomingRequest {
            HStack {
                Button {
                    act { await social.acceptRequest(incoming.id) }
                } label: {
                    Label("Accept Request", systemImage: "person.fill.checkmark")
                        .foregroundStyle(AppTheme.success)
                }
                Spacer()
                Button {
                    act { await social.declineRequest(incoming.id) }
                } label: {
                    Label("Decline", systemImage: "xmark")
                        .foregroundStyle(AppTheme.error)
                }
            }
        } else if let outgoing = outgoingRequest {
            Button {
                act { await social.cancelRequest(outgoing.id) }
            } label: {
                Label("Cancel Request", systemImage: "clock.arrow.circlepath")
                    .foregroundStyle(AppTheme.textSecondary)
            }
        } else {
            Button {
                act { _ = await social.sendFriendRequest(toUserId: userId) }
            } label: {
                Label("Add Friend", systemImage: "person.badge.plus")
                    .foregroundStyle(AppTheme.dynamicAccent)
            }
        }
    }

    /// Guestbook contents: the message list (if any), a compose box for
    /// friends (posting is friends-only server-side — a non-friend visitor
    /// or self-preview just sees the read-only list), and an empty-state
    /// hint otherwise.
    @ViewBuilder
    private var guestbookContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if comments.isEmpty {
                Text(isSelfPreview ? "No messages yet — friends can leave one here." : "No messages yet.")
                    .font(AppTheme.bodyFont(size: 13))
                    .foregroundStyle(AppTheme.textSecondary)
            } else {
                VStack(spacing: 10) {
                    ForEach(Array(comments.enumerated()), id: \.element.id) { index, comment in
                        ProfileCommentRow(
                            comment: comment,
                            tint: subAccentColor,
                            canDelete: isSelfPreview || comment.authorUserId == account.currentUser?.id
                        ) {
                            Task { await deleteComment(comment.id) }
                        }
                        if index < comments.count - 1 {
                            Divider().background(AppTheme.textSecondary.opacity(0.15))
                        }
                    }
                }
            }

            if let profile, profile.isFriend, !isSelfPreview {
                HStack(spacing: 8) {
                    TextField("Leave a message...", text: $draftComment, axis: .vertical)
                        .font(AppTheme.bodyFont(size: 13))
                        .lineLimit(1...3)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(AppTheme.textSecondary.opacity(0.1)))
                    Button {
                        Task { await postComment() }
                    } label: {
                        if isPostingComment {
                            ProgressView().tint(subAccentColor)
                        } else {
                            Image(systemName: "paperplane.fill")
                                .foregroundStyle(subAccentColor)
                        }
                    }
                    .disabled(isPostingComment || draftComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    /// "Open up ALOT more customization to the profiles" — light Markdown
    /// (bold/italic/links only, no headers/lists/block quotes — those would
    /// look out of place in a short bio) instead of always-plain text.
    /// `AttributedString(markdown:)` (not `Text(LocalizedStringKey:)`, which
    /// would treat arbitrary user text as a LOCALIZATION KEY — format
    /// specifiers like a literal "%" in someone's bio could then be
    /// misinterpreted) falls back to the raw string on a parse failure
    /// rather than showing nothing.
    private func bioText(_ bio: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: bio,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attributed)
        }
        return Text(bio)
    }

    private func postComment() async {
        let text = draftComment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isPostingComment else { return }
        isPostingComment = true
        defer { isPostingComment = false }
        if let posted = await social.postProfileComment(userId: userId, body: text) {
            comments.insert(posted, at: 0)
            draftComment = ""
        }
    }

    private func deleteComment(_ commentId: String) async {
        comments.removeAll { $0.id == commentId }
        await social.deleteProfileComment(commentId)
    }

    private func act(_ operation: @escaping () async -> Void) {
        guard !isActing else { return }
        isActing = true
        Task {
            defer { isActing = false }
            await operation()
        }
    }

    private func loadProfile() async {
        isLoading = true
        // Both are independent GETs — fire them concurrently instead of back
        // to back. Gate the screen only on the profile fetch (the essential
        // data); the banner is decorative and pops in via `bannerImage`'s
        // own `@State` update whenever it lands, same as any other async
        // image in this app.
        async let bannerTask = SocialService.loadBanner(userId: userId)
        profile = await social.fetchPublicProfile(userId: userId)
        isLoading = false
        bannerImage = await bannerTask
    }
}
