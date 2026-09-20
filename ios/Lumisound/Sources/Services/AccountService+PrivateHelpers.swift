import Foundation
import SwiftUI
import UIKit

extension AccountService {

    // MARK: - Private helpers

    struct EmptyBody: Encodable {}

    struct AuthResponse: Decodable {
        let user: AppUser
        let token: String
    }

    /// /auth/login's alternate response shape for a 2FA-enabled account —
    /// see `login()`'s doc comment.
    struct TOTPPendingResponse: Decodable {
        let requires_2fa: Bool
        let pending_token: String
    }

    func saveUserLocally(_ user: AppUser) {
        if let data = try? JSONEncoder().encode(user) {
            UserDefaults.standard.set(data, forKey: Self.userKey)
        }
    }

    func handleUnauthorized() {
        appWarn("JWT expired or invalid — clearing session", category: "account")
        // Snapshot the token before clearing it below — RemoteLogger's send
        // is fire-and-forget and runs on a later run-loop turn, so reading
        // the *live* token from inside it would very likely already see nil
        // and lose this event's user attribution entirely.
        let priorToken = token
        RemoteLogger.logError(category: "auth", event: "session_expired",
                               message: "JWT expired or invalid — clearing local session",
                               authToken: priorToken)
        UserDefaults.standard.removeObject(forKey: Self.tokenKey)
        UserDefaults.standard.removeObject(forKey: Self.userKey)
        token = nil
        currentUser = nil
        isLoggedIn = false
        errorMessage = "Your session expired. Please sign in again."
    }

    func clearSession() {
        // Covers logout, account deletion, and self/other session revocation
        // (see AccountService+PublicAPI.swift / +Sessions.swift /
        // +PasswordAndDeletion.swift, which all call this) — logged once
        // here rather than at each call site so every path that ends a
        // local session is covered without duplicating the event. Snapshot
        // the token first — see handleUnauthorized above for why.
        let priorToken = token
        RemoteLogger.log(category: "auth", event: "local_session_cleared", authToken: priorToken)
        token = nil
        currentUser = nil
        isLoggedIn = false
        hasDateOfBirth = false
        // A stream ticket is bound to the account that asked for it, so it must
        // not survive into the next session's stream URLs. Cleared here rather
        // than in logout() because every path that ends a session comes through
        // this function — account deletion and session revocation included.
        StreamingService.clearStreamTicket()
        avatarImage = nil
        stopAutoPushTimer()
        UserDefaults.standard.removeObject(forKey: Self.userKey)
    }

    func makeRequest<T: Encodable>(_ path: String, method: String = "GET", body: T) async throws -> Data {
        try await _makeRequest(path, method: method, bodyData: try JSONEncoder().encode(body))
    }

    func makeRequest(_ path: String, method: String = "GET") async throws -> Data {
        try await _makeRequest(path, method: method, bodyData: nil)
    }

    func _makeRequest(_ path: String, method: String, bodyData: Data?) async throws -> Data {
        let base = bridgeURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        guard let url = URL(string: base + normalizedPath) else {
            throw AccountError(statusCode: 0, message: "Invalid bridge URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20

        if let tok = token {
            request.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
        }

        if let data = bodyData {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = data
        }

        // Only idempotent GETs are retried — a retried POST/PUT/DELETE could
        // double-apply a mutation if the original request actually reached the
        // server but the response was lost to a transient network blip.
        let attempts = method == "GET" ? 3 : 1

        return try await NetworkRetry.withRetry(maxAttempts: attempts) {
            let (data, response) = try await URLSession.shared.data(for: request)

            if let http = response as? HTTPURLResponse {
                if http.statusCode == 401 {
                    // Only auto-logout on 401 when the user was already logged in.
                    // A 401 on /auth/login means wrong password — not an expired token.
                    if self.isLoggedIn && path != "/auth/login" {
                        self.handleUnauthorized()
                    }
                    throw AccountError(statusCode: 401, message: "Session expired. Please sign in again.")
                }
                if !(200..<300).contains(http.statusCode) {
                    // Try to extract detail from FastAPI error body
                    if let detail = try? JSONDecoder().decode(APIErrorBody.self, from: data) {
                        throw AccountError(statusCode: http.statusCode, message: detail.detail)
                    }
                    throw AccountError(statusCode: http.statusCode, message: "Server error (HTTP \(http.statusCode))")
                }
            }

            return data
        }
    }
}
