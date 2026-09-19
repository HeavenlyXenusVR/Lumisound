import Foundation

// MARK: - Announcements
//
// A short in-app toast, broadcast from the bridge to a time-boxed audience —
// typically spoken in Aria's voice, since a message the user did not ask for
// lands better coming from her than from anonymous app chrome.
//
// Deliberately NOT the notification inbox (`AccountService+Notifications`).
// That path is per-user rows mirrored to a real device notification, so it
// needs OS authorization, respects per-topic user preferences, and leaves an
// inbox entry behind — all correct for "an artist you follow uploaded a track",
// and all wrong for "here is one sentence about the app you are holding right
// now". This surface needs no permission and leaves nothing to clean up.
//
// Eligibility is entirely the server's decision (see /user/announcements): who
// is in the audience, how long the window lasts, and who is excluded from it.
// The client's only jobs are to ask, to show what comes back, and to say when
// it has been shown.

/// One announcement from `GET /user/announcements`.
struct AppAnnouncement: Decodable, Identifiable, Equatable {
    let id: String
    let message: String
    /// Whether to present this as Aria speaking rather than as a system toast.
    let from_aria: Bool
    /// Maps to `ToastCategory`; unknown values fall back to `.info` rather than
    /// failing to decode, so the server can add a category without this build
    /// silently dropping every announcement that uses it.
    let category: String

    var isFromAria: Bool { from_aria }

    var toastCategory: ToastCategory {
        switch category.lowercased() {
        case "success":  return .success
        case "error":    return .error
        case "warning":  return .warning
        case "download": return .download
        default:         return .info
        }
    }

    /// `sparkles` is already Aria's mark in this app's toasts (see
    /// NowPlayingView+Helpers' lyrics toast), so an announcement from her reads
    /// as the same voice the user has heard before rather than a new one.
    var toastIcon: String? { isFromAria ? "sparkles" : nil }
}

extension AccountService {

    /// Fetches and shows any announcements this account is currently eligible
    /// for, then tells the server they were shown.
    ///
    /// Silent on every failure. An announcement is never worth interrupting a
    /// launch over, and the window means a missed fetch simply gets picked up by
    /// the next foreground instead.
    func showPendingAnnouncements() async {
        guard isLoggedIn else { return }
        let announcements: [AppAnnouncement]
        do {
            let data = try await makeRequest("/user/announcements")
            announcements = try JSONDecoder().decode([AppAnnouncement].self, from: data)
        } catch {
            // Deliberately does NOT set `errorMessage`: unlike the other calls
            // in this service, nothing here was user-initiated, so surfacing a
            // failure would put an error in front of someone who never asked
            // for anything.
            return
        }
        guard !announcements.isEmpty else { return }

        for announcement in announcements {
            ToastCenter.shared.show(
                announcement.message,
                category: announcement.toastCategory,
                icon: announcement.toastIcon,
                // Long enough to read a sentence the user has not seen before,
                // and to notice it at all if they were looking at the artwork
                // rather than the top of the screen.
                duration: 6.0
            )
            // Acknowledged only once the toast is actually enqueued for display,
            // never merely on fetch — otherwise an app killed between the fetch
            // and the toast would burn the announcement without ever showing it.
            await acknowledgeAnnouncement(id: announcement.id)
        }
    }

    private func acknowledgeAnnouncement(id: String) async {
        do {
            _ = try await makeRequest("/user/announcements/\(id)/seen", method: "POST")
        } catch {
            // Best-effort. Failing here means the announcement stays pending and
            // is shown once more on a later launch — a repeat is a much better
            // failure than never showing it at all, which is what acknowledging
            // before display would have risked.
        }
    }
}
