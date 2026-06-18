import Foundation
import AuthenticationServices
import CryptoKit
import UIKit

/// Google OAuth 2.0 for an installed iOS app: the custom-URI-scheme + PKCE flow
/// (no client secret), run through `ASWebAuthenticationSession`. Access/refresh
/// tokens live in the Keychain; access tokens refresh transparently when expired.
/// Scope is read-only Gmail — enough to triage, summarize, and open in Gmail.
///
/// The OAuth client ID is a PUBLIC identifier (iOS clients have no secret), so it
/// lives in code; only the resulting tokens are sensitive and they go to the
/// Keychain. No Info.plist URL type is needed — `ASWebAuthenticationSession`
/// intercepts the callback scheme itself.
@MainActor
final class GoogleAuth: NSObject, ObservableObject {
    static let shared = GoogleAuth()

    /// The iOS OAuth client ID issued in Google Cloud Console.
    private static let clientID =
        "299688744667-f4obpikdc7o82eunl431gbp7ee11iu2m.apps.googleusercontent.com"
    /// Reverse-DNS of the client ID — the custom URL scheme Google redirects to.
    private static let reversedClientID =
        "com.googleusercontent.apps.299688744667-f4obpikdc7o82eunl431gbp7ee11iu2m"
    private static var redirectURI: String { "\(reversedClientID):/oauth2redirect" }
    private static let scope = "https://www.googleapis.com/auth/gmail.readonly"

    private static let authEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    private static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!

    @Published private(set) var isSignedIn: Bool

    /// Retained for the duration of an in-flight web auth session.
    private var session: ASWebAuthenticationSession?

    private var tokens: GoogleTokens? {
        didSet { isSignedIn = (tokens != nil) }
    }

    private override init() {
        let loaded = GoogleTokens.load()
        tokens = loaded
        isSignedIn = (loaded != nil)
        super.init()
    }

    // MARK: - Sign in / out

    /// Run the interactive OAuth flow and persist the resulting tokens. Throws on
    /// user cancellation or any auth failure (the caller surfaces a message).
    func signIn() async throws {
        let verifier = Self.randomURLSafe(64)
        let challenge = Self.codeChallenge(for: verifier)
        let state = Self.randomURLSafe(32)

        var comps = URLComponents(url: Self.authEndpoint, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        guard let authURL = comps.url else {
            throw GoogleAuthError("Couldn't build the sign-in URL.")
        }

        let callback = try await authorize(url: authURL, scheme: Self.reversedClientID)
        guard let code = callback.queryValue("code"),
              callback.queryValue("state") == state else {
            throw GoogleAuthError("Sign-in returned an invalid response. Please try again.")
        }

        let new = try await exchangeCode(code, verifier: verifier)
        new.save()
        tokens = new
    }

    func signOut() {
        GoogleTokens.clear()
        tokens = nil
    }

    // MARK: - Access token

    /// A valid access token, transparently refreshing with the stored refresh
    /// token when the current one has expired.
    func validAccessToken() async throws -> String {
        guard let tokens else { throw GoogleAuthError("Not connected to Gmail.") }
        guard tokens.isExpired else { return tokens.accessToken }

        let refreshed = try await refresh(tokens)
        refreshed.save()
        self.tokens = refreshed
        return refreshed.accessToken
    }

    // MARK: - Web auth session

    private func authorize(url: URL, scheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { callbackURL, error in
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(throwing: GoogleAuthError("Sign-in was cancelled."))
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() {
                continuation.resume(throwing: GoogleAuthError("Couldn't start the sign-in session."))
            }
        }
    }

    // MARK: - Token endpoint

    private func exchangeCode(_ code: String, verifier: String) async throws -> GoogleTokens {
        try await tokenRequest([
            "client_id": Self.clientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": Self.redirectURI,
        ], existingRefresh: nil)
    }

    private func refresh(_ tokens: GoogleTokens) async throws -> GoogleTokens {
        try await tokenRequest([
            "client_id": Self.clientID,
            "grant_type": "refresh_token",
            "refresh_token": tokens.refreshToken,
        ], existingRefresh: tokens.refreshToken)
    }

    /// POST the token endpoint (form-encoded) and parse the token response. A
    /// refresh response omits `refresh_token`, so we carry the existing one
    /// forward.
    private func tokenRequest(_ body: [String: String], existingRefresh: String?) async throws -> GoogleTokens {
        var request = URLRequest(url: Self.tokenEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
            .map { "\(Self.formEncode($0.key))=\(Self.formEncode($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = object["access_token"] as? String,
              let expiresIn = object["expires_in"] as? Double else {
            throw GoogleAuthError("Gmail authorization failed. Please reconnect.")
        }
        let refreshToken = (object["refresh_token"] as? String) ?? existingRefresh ?? ""
        // Refresh a minute early to avoid races at the boundary.
        let expiry = Date().addingTimeInterval(expiresIn - 60)
        return GoogleTokens(accessToken: access, refreshToken: refreshToken, expiry: expiry)
    }

    // MARK: - PKCE / helpers

    private static func randomURLSafe(_ byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    private static func codeChallenge(for verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return Data(hash).base64URLEncodedString()
    }

    /// Percent-encode a form value (unreserved set only) for the token POST body.
    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

// MARK: - Presentation anchor

extension GoogleAuth: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
        return windows.first { $0.isKeyWindow } ?? windows.first ?? ASPresentationAnchor()
    }
}

// MARK: - Tokens

/// The persisted OAuth token set. Stored as JSON in the Keychain.
struct GoogleTokens: Codable {
    let accessToken: String
    let refreshToken: String
    let expiry: Date

    var isExpired: Bool { Date() >= expiry }

    func save() {
        guard let data = try? JSONEncoder().encode(self),
              let json = String(data: data, encoding: .utf8) else { return }
        KeychainHelper.save(json, secret: .googleTokens)
    }

    static func load() -> GoogleTokens? {
        guard let json = KeychainHelper.load(secret: .googleTokens),
              let data = json.data(using: .utf8),
              let tokens = try? JSONDecoder().decode(GoogleTokens.self, from: data),
              !tokens.refreshToken.isEmpty else { return nil }
        return tokens
    }

    static func clear() {
        KeychainHelper.delete(secret: .googleTokens)
    }
}

// MARK: - Error & URL helper

struct GoogleAuthError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private extension URL {
    func queryValue(_ name: String) -> String? {
        URLComponents(url: self, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == name }?.value
    }
}

private extension Data {
    /// Base64URL without padding (RFC 7636 / PKCE + JOSE convention).
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
