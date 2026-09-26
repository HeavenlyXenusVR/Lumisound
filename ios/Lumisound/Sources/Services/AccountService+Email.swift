import Foundation
import SwiftUI

extension AccountService {

    // MARK: - Email

    /// Whether the signed-in account still has no address on file.
    ///
    /// Registration made email optional for most of the app's life, and
    /// sign-in-with-Discord auto-created accounts with no email column at all,
    /// so a large share of existing accounts have nothing here. The server now
    /// requires a valid address at registration, which closes the hole going
    /// forward but does nothing for accounts already created — this drives the
    /// in-app prompt that closes it for them, deliberately WITHOUT blocking any
    /// functionality. Locking those users out of an app they already use would
    /// cost more than the missing address is worth.
    var needsEmail: Bool {
        guard isLoggedIn, let user = currentUser else { return false }
        return (user.email ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Client-side sanity check, mirroring the shape the server enforces.
    ///
    /// Intentionally a *cheap* check, not a reimplementation of the server's
    /// rules: the bridge is the authority (it also resolves the domain's MX
    /// records and rejects disposable providers, neither of which is worth doing
    /// on-device). The point here is to catch the obvious mistakes — empty,
    /// spaces, no @ — without a network round trip, and to let the real error
    /// text come from the server for everything else.
    static func localEmailProblem(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Email is required." }
        // Checked on the trimmed value, so a leading/trailing space the user
        // cannot see is forgiven, while a space in the middle is not.
        if trimmed.contains(where: { $0.isWhitespace }) {
            return "Email must not contain spaces."
        }
        let parts = trimmed.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            return "Enter a valid email address."
        }
        // A domain with no dot cannot be a real public mailbox.
        guard parts[1].contains("."), !parts[1].hasPrefix("."), !parts[1].hasSuffix(".") else {
            return "Enter a valid email address."
        }
        return nil
    }

    /// Sets (or changes) the account's email address via `PUT /auth/me`.
    ///
    /// Returns `true` on success so a caller can dismiss its prompt only when
    /// the address was actually accepted — the server may still reject it for a
    /// reason this client deliberately does not check (undeliverable domain,
    /// disposable provider, already tied to another account).
    @discardableResult
    func setEmail(_ email: String) async -> Bool {
        guard isLoggedIn else { return false }
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = Self.localEmailProblem(trimmed) {
            errorMessage = problem
            return false
        }
        appLog("setEmail: updating account email", category: "account")
        errorMessage = nil
        struct Body: Encodable { let email: String }
        do {
            let data = try await makeRequest("/auth/me", method: "PUT", body: Body(email: trimmed))
            // The endpoint returns the refreshed user, so the local copy picks up
            // the *normalised* address the server stored rather than whatever was
            // typed — otherwise `needsEmail` and the Account screen would keep
            // showing the pre-normalisation spelling until the next full refresh.
            if let user = try? JSONDecoder().decode(AppUser.self, from: data) {
                currentUser = user
                saveUserLocally(user)
                hasDateOfBirth = user.dateOfBirth != nil
            }
            appLog("setEmail: success", category: "account")
            return true
        } catch let err as AccountError {
            appError("setEmail failed [\(err.statusCode)]: \(err.message)", category: "account")
            errorMessage = err.message
            return false
        } catch {
            appError("setEmail error: \(error.localizedDescription)", category: "account")
            errorMessage = error.localizedDescription
            return false
        }
    }
}
