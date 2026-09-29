import Foundation

extension AccountService {

    // MARK: - Podcasts

    /// Podcast search-by-name (iTunes Search API, proxied through the bridge
    /// so the app never talks to a third-party host directly) — lets
    /// `AddPodcastSheet` offer a "search" path alongside "paste a feed URL".
    func searchPodcasts(query: String) async -> [PodcastSearchResult] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty,
              var components = URLComponents(string: "/podcasts/search") else { return [] }
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        do {
            let data = try await makeRequest(components.string ?? "/podcasts/search")
            return try JSONDecoder().decode([PodcastSearchResult].self, from: data)
        } catch {
            return []
        }
    }

    /// Trending podcasts (GET /podcasts/trending, Apple's public top-
    /// podcasts chart, filtered server-side to exclude shows already
    /// subscribed) — the first real discovery surface for podcasts, unlike
    /// `searchPodcasts` above which requires already knowing what to look
    /// for. Same `PodcastSearchResult` shape/decode path since the two
    /// endpoints return identical JSON.
    func fetchTrendingPodcasts(limit: Int = 20) async -> [PodcastSearchResult] {
        guard isLoggedIn else { return [] }
        do {
            let data = try await makeRequest("/podcasts/trending?limit=\(limit)")
            return try JSONDecoder().decode([PodcastSearchResult].self, from: data)
        } catch {
            appWarn("fetchTrendingPodcasts: \(error.localizedDescription)", category: "network")
            return []
        }
    }

    /// Subscribes to a podcast RSS feed — the bridge fetches+validates it
    /// once (extracting title/artwork) before persisting the subscription.
    func subscribeToPodcast(feedURL: String) async -> PodcastSubscription? {
        guard isLoggedIn else { return nil }
        struct Body: Encodable { let feed_url: String }
        do {
            let data = try await makeRequest("/user/podcasts/subscriptions", method: "POST", body: Body(feed_url: feedURL))
            return try JSONDecoder().decode(PodcastSubscription.self, from: data)
        } catch let err as AccountError {
            errorMessage = err.message
            return nil
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func fetchPodcastSubscriptions() async -> [PodcastSubscription] {
        guard isLoggedIn else { return [] }
        do {
            let data = try await makeRequest("/user/podcasts/subscriptions")
            return try JSONDecoder().decode([PodcastSubscription].self, from: data)
        } catch {
            errorMessage = (error as? AccountError)?.message ?? error.localizedDescription
            return []
        }
    }

    /// Toggles new-episode push/in-app notifications for one subscription
    /// (the `_poll_due_podcast_subscriptions` background pass respects this).
    @discardableResult
    func setPodcastNotificationsMuted(id: String, muted: Bool) async -> Bool {
        guard isLoggedIn else { return false }
        struct Body: Encodable { let notifications_muted: Bool }
        do {
            _ = try await makeRequest("/user/podcasts/subscriptions/\(id)", method: "PATCH", body: Body(notifications_muted: muted))
            return true
        } catch {
            return false
        }
    }

    /// Fetches an OPML document of every subscription — the standard
    /// cross-app podcast-subscription export format (Apple Podcasts,
    /// Overcast, Pocket Casts, ...).
    func exportPodcastsOPML() async -> String? {
        guard isLoggedIn else { return nil }
        do {
            let data = try await makeRequest("/user/podcasts/export-opml")
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    /// Bulk-subscribes to every feed found in an OPML document (imported
    /// from another podcast app). Returns (added, failed, total) counts.
    func importPodcastsOPML(_ opml: String) async -> (added: Int, failed: Int, total: Int)? {
        guard isLoggedIn else { return nil }
        struct Body: Encodable { let opml: String }
        struct Result: Decodable { let added: Int; let failed: Int; let total: Int }
        do {
            let data = try await makeRequest("/user/podcasts/import-opml", method: "POST", body: Body(opml: opml))
            let result = try JSONDecoder().decode(Result.self, from: data)
            return (result.added, result.failed, result.total)
        } catch let err as AccountError {
            errorMessage = err.message
            return nil
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func unsubscribeFromPodcast(id: String) async {
        guard isLoggedIn else { return }
        do {
            _ = try await makeRequest("/user/podcasts/subscriptions/\(id)", method: "DELETE")
        } catch {
            errorMessage = (error as? AccountError)?.message ?? error.localizedDescription
        }
    }

    /// Fetches the episode list for `feedURL` — live-parsed by the bridge on
    /// every call (no server-side episode cache; see main.py's comment on
    /// ios_podcast_subscriptions).
    func fetchPodcastEpisodes(feedURL: String) async -> [PodcastEpisode] {
        guard isLoggedIn,
              var components = URLComponents(string: "/user/podcasts/episodes") else { return [] }
        components.queryItems = [URLQueryItem(name: "feed_url", value: feedURL)]
        do {
            let data = try await makeRequest(components.string ?? "/user/podcasts/episodes")
            return try JSONDecoder().decode([PodcastEpisode].self, from: data)
        } catch {
            errorMessage = (error as? AccountError)?.message ?? error.localizedDescription
            return []
        }
    }

    /// Every tracked episode position for `feedURL`, keyed by episode guid —
    /// merge with `fetchPodcastEpisodes` results client-side to show
    /// in-progress/completed state per episode.
    func fetchPodcastEpisodeProgress(feedURL: String) async -> [String: PodcastEpisodeProgress] {
        guard isLoggedIn,
              var components = URLComponents(string: "/user/podcasts/episode-progress") else { return [:] }
        components.queryItems = [URLQueryItem(name: "feed_url", value: feedURL)]
        do {
            let data = try await makeRequest(components.string ?? "/user/podcasts/episode-progress")
            let entries = try JSONDecoder().decode([PodcastEpisodeProgress].self, from: data)
            return Dictionary(entries.map { ($0.episodeGuid, $0) }, uniquingKeysWith: { first, _ in first })
        } catch {
            return [:]
        }
    }

    /// Fetches and parses one episode's Podcasting 2.0 chapters file
    /// (`episode.chaptersURL`, when a feed provides one). Not called
    /// automatically per-episode — only when a chapters UI is actually
    /// opened, since most episodes' chapters will never be viewed.
    func fetchPodcastChapters(url: String) async -> [PodcastChapter] {
        guard isLoggedIn,
              var components = URLComponents(string: "/user/podcasts/chapters") else { return [] }
        components.queryItems = [URLQueryItem(name: "chapters_url", value: url)]
        do {
            let data = try await makeRequest(components.string ?? "/user/podcasts/chapters")
            return try JSONDecoder().decode([PodcastChapter].self, from: data)
        } catch {
            return []
        }
    }

    /// Every in-progress (not completed, >5s in) episode across ALL
    /// subscriptions, most recently updated first — the Home hub's
    /// Continue Listening teaser's data source. `title`/`feedURL` come
    /// along on each entry so the teaser doesn't need a second fetch per
    /// feed just to show what it found (see main.py's doc comment on
    /// get_podcast_episode_progress for why `title` is a cached snapshot).
    func fetchRecentPodcastProgress(limit: Int = 10) async -> [PodcastEpisodeProgress] {
        guard isLoggedIn,
              var components = URLComponents(string: "/user/podcasts/episode-progress") else { return [] }
        components.queryItems = [URLQueryItem(name: "limit", value: "\(limit)")]
        do {
            let data = try await makeRequest(components.string ?? "/user/podcasts/episode-progress")
            return try JSONDecoder().decode([PodcastEpisodeProgress].self, from: data)
        } catch {
            return []
        }
    }

    /// Best-effort position save — called periodically by
    /// `AudioPlayerManager.pushPlaybackStateToBridge` while a podcast
    /// episode is playing. Silent on failure, same posture as the main
    /// music playback-state push it piggybacks on.
    func updatePodcastEpisodeProgress(feedURL: String, episodeGuid: String, title: String, position: Double, duration: Double, completed: Bool) async {
        guard isLoggedIn else { return }
        struct Body: Encodable {
            let feed_url: String
            let episode_guid: String
            let title: String
            let position_seconds: Double
            let duration_seconds: Double
            let completed: Bool
        }
        _ = try? await makeRequest(
            "/user/podcasts/episode-progress", method: "PUT",
            body: Body(
                feed_url: feedURL, episode_guid: episodeGuid, title: title,
                position_seconds: position, duration_seconds: duration, completed: completed
            )
        )
    }
}
