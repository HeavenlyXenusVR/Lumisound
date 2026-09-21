import SwiftUI

// MARK: - Friends tab segments (2026-07-21)
//
// The "Discover", "Requests", and "Activity" segments of the redesigned
// FriendsListView (see FriendsListView.swift for the container, the
// "Friends" segment itself, and shared helpers like `friendsSectionHeader`).
// Split into this second file purely to keep each file a manageable size —
// all three are tightly coupled to the same Friends tab and share the same
// `SocialService` environment object.

// MARK: - DiscoverSegmentView
//
// Add-friend-by-username search plus mutual-friend suggestions — the same
// two capabilities the original single-screen FriendsListView offered under
// "Add Friends" / "People You May Know", now with room of their own instead
// of competing for space at the top of a long flat list.
struct DiscoverSegmentView: View {
    @EnvironmentObject private var social: SocialService

    @State private var searchQuery = ""
    @State private var isSearching = false
    @State private var sendingRequestTo: Set<String> = []
    /// Debounces so every keystroke doesn't fire its own network request —
    /// `SocialService.searchUsers` itself also guards against the resulting
    /// out-of-order completions (see its own doc comment).
    @State private var searchTask: Task<Void, Never>? = nil

    var body: some View {
        List {
            Section {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(AppTheme.textSecondary)
                    TextField("Search by username", text: $searchQuery)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .foregroundStyle(AppTheme.textPrimary)
                        .onChange(of: searchQuery) { newValue in
                            searchTask?.cancel()
                            searchTask = Task {
                                try? await Task.sleep(nanoseconds: 350_000_000)
                                guard !Task.isCancelled else { return }
                                isSearching = true
                                await social.searchUsers(query: newValue)
                                isSearching = false
                            }
                        }
                    if isSearching {
                        ProgressView().tint(AppTheme.dynamicAccent)
                    }
                }

                if !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                    if social.searchResults.isEmpty && !isSearching {
                        Text("No users found.")
                            .font(AppTheme.bodyFont(size: 13))
                            .foregroundStyle(AppTheme.textSecondary)
                    } else {
                        ForEach(social.searchResults) { user in
                            searchResultRow(user)
                        }
                    }
                }
            } header: {
                friendsSectionHeader("Add Friends")
            }
            .listRowBackground(AppTheme.surface)

            // Placed ABOVE "People You May Know" because it is the section that
            // can actually answer for a new account. Mutual-friend suggestions
            // need an existing friend to work from and are therefore empty for
            // exactly the people who most need somewhere to start.
            Section {
                if social.isLoadingRecommendedPeople && social.recommendedPeople.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView().tint(AppTheme.dynamicAccent)
                        Text("Finding people who listen like you…")
                            .font(AppTheme.bodyFont(size: 13))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                } else if social.recommendedPeople.isEmpty {
                    // Says WHICH kind of empty this is. "Play a few more tracks"
                    // and "no one matches yet" call for different things from the
                    // reader, and a blank section asks for nothing.
                    Text(social.recommendedPeopleEmptyReason?.message
                         ?? "No recommendations right now.")
                        .font(AppTheme.bodyFont(size: 13))
                        .foregroundStyle(AppTheme.textSecondary)
                } else {
                    ForEach(social.recommendedPeople) { person in
                        recommendedPersonRow(person)
                    }
                }
            } header: {
                friendsSectionHeader("Recommended For You")
            }
            .listRowBackground(AppTheme.surface)

            if !social.suggestions.isEmpty {
                Section {
                    ForEach(social.suggestions) { suggestion in
                        suggestionRow(suggestion)
                    }
                } header: {
                    friendsSectionHeader("People You May Know")
                }
                .listRowBackground(AppTheme.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .task {
            await social.fetchSuggestions()
            await social.fetchRecommendedPeople()
        }
        .refreshable {
            await social.fetchSuggestions()
            await social.fetchRecommendedPeople()
        }
    }

    private func searchResultRow(_ user: SocialUserRef) -> some View {
        HStack(spacing: 12) {
            NavigationLink(destination: PublicProfileView(userId: user.userId)) {
                HStack(spacing: 12) {
                    SocialAvatarView(userId: user.userId, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(user.displayName ?? user.username)
                            .foregroundStyle(AppTheme.textPrimary)
                        Text("@\(user.username)")
                            .font(AppTheme.bodyFont(size: 12))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                }
            }
            .buttonStyle(.plain)
            Spacer()
            if sendingRequestTo.contains(user.userId) {
                ProgressView().tint(AppTheme.dynamicAccent)
            } else if isAlreadyFriend(user.userId) {
                Text("Friends").font(AppTheme.bodyFont(size: 12)).foregroundStyle(AppTheme.textSecondary)
            } else if isPendingOutgoing(user.userId) {
                Text("Requested").font(AppTheme.bodyFont(size: 12)).foregroundStyle(AppTheme.textSecondary)
            } else {
                Button {
                    sendRequest(to: user.userId)
                } label: {
                    Image(systemName: "person.badge.plus")
                        .foregroundStyle(AppTheme.dynamicAccent)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func suggestionRow(_ suggestion: SocialFriendSuggestion) -> some View {
        HStack(spacing: 12) {
            NavigationLink(destination: PublicProfileView(userId: suggestion.userId)) {
                HStack(spacing: 12) {
                    SocialAvatarView(userId: suggestion.userId, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(suggestion.displayName ?? suggestion.username)
                            .foregroundStyle(AppTheme.textPrimary)
                        Text("\(suggestion.mutualFriendCount) mutual friend\(suggestion.mutualFriendCount == 1 ? "" : "s")")
                            .font(AppTheme.bodyFont(size: 12))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                }
            }
            .buttonStyle(.plain)
            Spacer()
            if sendingRequestTo.contains(suggestion.userId) {
                ProgressView().tint(AppTheme.dynamicAccent)
            } else {
                Button {
                    sendRequest(to: suggestion.userId)
                } label: {
                    Image(systemName: "person.badge.plus")
                        .foregroundStyle(AppTheme.dynamicAccent)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// A recommendation row: who they are, how strong the match is, and why.
    ///
    /// The whole row is a link into `PublicProfileView`, the same full profile
    /// reached from search or from a friend — deciding whether to add someone
    /// means looking at them properly, not at a score in a list.
    private func recommendedPersonRow(_ person: RecommendedPerson) -> some View {
        HStack(alignment: .top, spacing: 12) {
            NavigationLink(destination: PublicProfileView(userId: person.userId)) {
                HStack(alignment: .top, spacing: 12) {
                    SocialAvatarView(userId: person.userId, size: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(person.displayName ?? person.username)
                            .foregroundStyle(AppTheme.textPrimary)
                        Text("@\(person.username)")
                            .font(AppTheme.bodyFont(size: 11))
                            .foregroundStyle(AppTheme.textSecondary)

                        matchLine(person)

                        // The reasons carry the actual meaning. A percentage on
                        // its own is not something anyone can agree or disagree
                        // with; "2 artists in common" is.
                        ForEach(person.reasons.prefix(2), id: \.self) { reason in
                            Label {
                                Text(reason)
                                    .font(AppTheme.bodyFont(size: 11))
                                    .foregroundStyle(AppTheme.textSecondary)
                            } icon: {
                                Image(systemName: "sparkle")
                                    .font(.system(size: 8))
                                    .foregroundStyle(AppTheme.dynamicAccent)
                            }
                        }
                    }
                }
            }
            .buttonStyle(.plain)

            Spacer(minLength: 4)

            if sendingRequestTo.contains(person.userId) {
                ProgressView().tint(AppTheme.dynamicAccent)
            } else if isPendingOutgoing(person.userId) {
                Text("Sent")
                    .font(AppTheme.bodyFont(size: 12))
                    .foregroundStyle(AppTheme.textSecondary)
            } else {
                Button {
                    sendRequest(to: person.userId)
                } label: {
                    Image(systemName: "person.badge.plus")
                        .foregroundStyle(AppTheme.dynamicAccent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 2)
    }

    /// The match strength, stated in a way that does not overclaim.
    ///
    /// A low score has two very different meanings — "your tastes differ" and
    /// "we barely know either of you yet" — and a bare percentage cannot tell
    /// them apart. When the server reports low confidence the number is dropped
    /// entirely rather than shown as a discouraging single digit, because at that
    /// point it is not measuring the people, it is measuring how little has been
    /// listened to so far.
    @ViewBuilder
    private func matchLine(_ person: RecommendedPerson) -> some View {
        if person.isLowConfidence {
            Text("Still learning your taste")
                .font(AppTheme.bodyFont(size: 11))
                .foregroundStyle(AppTheme.textSecondary.opacity(0.85))
        } else {
            HStack(spacing: 6) {
                Text("\(person.score)% match")
                    .font(AppTheme.bodyFont(size: 12).weight(.semibold))
                    .foregroundStyle(AppTheme.dynamicAccent)
                if let sonic = person.sonicScore, person.sharedArtists.isEmpty {
                    // Worth distinguishing: a score resting on the two libraries
                    // sounding alike is weaker evidence than a shared artist, and
                    // saying so is more honest than letting both read the same.
                    Text("· \(sonic)% alike by sound")
                        .font(AppTheme.bodyFont(size: 11))
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }
        }
    }

    private func isAlreadyFriend(_ userId: String) -> Bool {
        social.friends.contains { $0.userId == userId }
    }

    private func isPendingOutgoing(_ userId: String) -> Bool {
        social.outgoingRequests.contains { $0.userId == userId }
    }

    private func sendRequest(to userId: String) {
        guard !sendingRequestTo.contains(userId) else { return }
        sendingRequestTo.insert(userId)
        Task {
            defer { sendingRequestTo.remove(userId) }
            _ = await social.sendFriendRequest(toUserId: userId)
        }
    }
}

// MARK: - RequestsSegmentView
//
// Incoming (accept/decline) and outgoing (cancel) pending friend requests,
// inline in the redesigned tab. `FriendRequestsView.swift`'s original
// full-screen version is kept intact and still reachable via "Manage All
// Requests" below, rather than being folded into (and losing its own
// identity as) this segment.
struct RequestsSegmentView: View {
    @EnvironmentObject private var social: SocialService
    @State private var actingOn: Set<String> = []

    var body: some View {
        List {
            Section {
                NavigationLink(destination: FriendRequestsView()) {
                    Label("Manage All Requests", systemImage: "list.bullet.rectangle")
                        .foregroundStyle(AppTheme.dynamicAccent)
                }
            }
            .listRowBackground(AppTheme.surface)

            Section {
                if social.incomingRequests.isEmpty {
                    Text("No incoming requests.")
                        .font(AppTheme.bodyFont(size: 13))
                        .foregroundStyle(AppTheme.textSecondary)
                } else {
                    ForEach(social.incomingRequests) { request in
                        requestRow(request, isIncoming: true)
                    }
                }
            } header: {
                friendsSectionHeader("Incoming")
            }
            .listRowBackground(AppTheme.surface)

            Section {
                if social.outgoingRequests.isEmpty {
                    Text("No outgoing requests.")
                        .font(AppTheme.bodyFont(size: 13))
                        .foregroundStyle(AppTheme.textSecondary)
                } else {
                    ForEach(social.outgoingRequests) { request in
                        requestRow(request, isIncoming: false)
                    }
                }
            } header: {
                friendsSectionHeader("Outgoing")
            }
            .listRowBackground(AppTheme.surface)
        }
        .scrollContentBackground(.hidden)
        .task { await social.fetchFriendRequests() }
        .refreshable { await social.fetchFriendRequests() }
    }

    private func requestRow(_ request: SocialFriendRequest, isIncoming: Bool) -> some View {
        HStack(spacing: 12) {
            NavigationLink(destination: PublicProfileView(userId: request.userId)) {
                HStack(spacing: 12) {
                    SocialAvatarView(userId: request.userId, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(request.displayName ?? request.username)
                            .foregroundStyle(AppTheme.textPrimary)
                        Text("@\(request.username)")
                            .font(AppTheme.bodyFont(size: 12))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                }
            }
            .buttonStyle(.plain)
            Spacer()
            if actingOn.contains(request.id) {
                ProgressView().tint(AppTheme.dynamicAccent)
            } else if isIncoming {
                Button {
                    act(request.id) { await social.acceptRequest(request.id) }
                } label: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(AppTheme.success)
                }
                .buttonStyle(.plain)

                Button {
                    act(request.id) { await social.declineRequest(request.id) }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(AppTheme.error)
                }
                .buttonStyle(.plain)
            } else {
                Button("Cancel") {
                    act(request.id) { await social.cancelRequest(request.id) }
                }
                .font(AppTheme.bodyFont(size: 13))
                .foregroundStyle(AppTheme.textSecondary)
            }
        }
    }

    private func act(_ id: String, _ operation: @escaping () async -> Void) {
        guard !actingOn.contains(id) else { return }
        actingOn.insert(id)
        Task {
            defer { actingOn.remove(id) }
            await operation()
        }
    }
}

// MARK: - ActivitySegmentView
//
// New feature: a "Most Active This Week" leaderboard card (ranked by play
// count) up top, then the existing friends-only activity feed inline (with
// a link through to the full-screen `FriendsActivityFeedView` for the
// complete history).
struct ActivitySegmentView: View {
    @EnvironmentObject private var social: SocialService

    var body: some View {
        List {
            Section {
                leaderboardCard
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            Section {
                NavigationLink(destination: FriendsActivityFeedView()) {
                    Label("View Full Activity Feed", systemImage: "waveform.path.ecg")
                        .foregroundStyle(AppTheme.dynamicAccent)
                }
            }
            .listRowBackground(AppTheme.surface)

            Section {
                if social.friendsActivity.isEmpty {
                    Text("No recent activity from friends yet.")
                        .font(AppTheme.bodyFont(size: 13))
                        .foregroundStyle(AppTheme.textSecondary)
                } else {
                    ForEach(social.friendsActivity.prefix(15)) { entry in
                        activityRow(entry)
                    }
                }
            } header: {
                friendsSectionHeader("Recent Activity")
            }
            .listRowBackground(AppTheme.surface)
        }
        .scrollContentBackground(.hidden)
        .task {
            await social.fetchFriendsActivity()
            await social.fetchLeaderboard()
        }
        .refreshable {
            await social.fetchFriendsActivity()
            await social.fetchLeaderboard()
        }
    }

    // MARK: New feature: weekly activity leaderboard

    @ViewBuilder
    private var leaderboardCard: some View {
        if !social.leaderboard.isEmpty {
            ProfileInfoCard(title: "Most Active This Week", icon: "trophy.fill", tint: AppTheme.dynamicAccent) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(social.leaderboard.prefix(5).enumerated()), id: \.element.id) { index, entry in
                        NavigationLink(destination: PublicProfileView(userId: entry.userId)) {
                            HStack(spacing: 10) {
                                Text(medal(for: index))
                                    .font(AppTheme.bodyFont(size: 14).weight(.semibold))
                                    .frame(width: 22, alignment: .leading)
                                SocialAvatarView(userId: entry.userId, size: 28)
                                Text(entry.displayName ?? entry.username)
                                    .font(AppTheme.bodyFont(size: 13))
                                    .foregroundStyle(AppTheme.textPrimary)
                                    .lineLimit(1)
                                Spacer()
                                Text("\(entry.playCount) play\(entry.playCount == 1 ? "" : "s")")
                                    .font(AppTheme.bodyFont(size: 12))
                                    .foregroundStyle(AppTheme.textSecondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func medal(for index: Int) -> String {
        switch index {
        case 0: return "🥇"
        case 1: return "🥈"
        case 2: return "🥉"
        default: return "\(index + 1)."
        }
    }

    private func activityRow(_ entry: SocialActivityEntry) -> some View {
        HStack(spacing: 12) {
            SocialAvatarView(userId: entry.userId, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(entry.displayName ?? entry.username)
                        .fontWeight(.medium)
                        .foregroundStyle(AppTheme.textPrimary)
                    Image(systemName: entry.isPlayed ? "play.fill" : "heart.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(entry.isPlayed ? AppTheme.dynamicAccent : AppTheme.error)
                }
                Text([entry.title, entry.artist].compactMap { $0 }.joined(separator: " — "))
                    .font(AppTheme.bodyFont(size: 13))
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(1)
            }
        }
    }
}
