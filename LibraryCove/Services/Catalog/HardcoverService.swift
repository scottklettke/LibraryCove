import Foundation
import AuthenticationServices
import CryptoKit

/// A metadata record assembled from Hardcover's public catalog: exactly the
/// fields LibraryCove can merge into an imported/importing book. Deliberately
/// excludes ratings, reviews, reading stats, and anything user-owned.
struct HardcoverBookMetadata: Equatable, Sendable {
    /// Hardcover's internal book id (stable, useful for support/debug).
    let bookID: Int?
    let genres: [String]
    /// Community tags across categories (genre, mood, format…), already
    /// flattened and spoiler-filtered.
    let tags: [String]
    /// Series name, e.g. "The Stormlight Archive", with its position if the
    /// book is numbered ("3").
    let seriesName: String?
    let seriesPosition: String?
    let description: String?
    let pageCount: Int?
    /// ISO-2 language code, e.g. "en".
    let language: String?
    let coverImageURL: String?

    var hasEnrichment: Bool {
        !genres.isEmpty || !tags.isEmpty || seriesName != nil
            || description != nil || pageCount != nil || language != nil
            || coverImageURL != nil
    }
}

/// Client for Hardcover's GraphQL API (https://docs.hardcover.app). Reads
/// ONLY public catalog data — every query stays inside the `read:catalog`
/// scope (editions/books/series/tags/images); no ratings, reviews, or
/// user-library fields are ever requested.
///
/// Auth: each user supplies their own Personal Access Token from
/// https://hardcover.app/account/api — the API has no anonymous or
/// app-shared token mode ("Token is not associated with a user" otherwise),
/// and Hardcover explicitly asks that PATs never be shared. The token lives
/// in the Keychain via `HardcoverConfig`; when absent the service is inert
/// and every lookup returns nil, so callers need no existence checks.
///
/// Rate limits (free plan): 5,000/day, 60/min, burst 10 — generous for a
/// personal scanner; requests are additionally serialized to stay polite.
/// The API is in beta and may change; every failure degrades to nil so the
/// app keeps working without it.
final class HardcoverService: Sendable {
    static let apiURL = URL(string: "https://api.hardcover.app/v1/graphql")!

    private let session: URLSession

    init(session: URLSession = URLSession(configuration: {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 25
        config.httpAdditionalHeaders = [
            "User-Agent": "LibraryCove/0.5 (https://github.com/scottklettke/LibraryCove; librarycove@fastmail.com)"
        ]
        return config
    }())) {
        self.session = session
    }

    // MARK: - Queries

    /// One GraphQL request: find the edition by ISBN-13/10 and pull the
    /// book's enrichment in the same round-trip. Single top-level operation
    /// (the API caps requests at 5).
    private static func enrichmentQuery(isbn13: String?, isbn10: String?) -> String {
        let isbnFilter: String
        if let isbn13, let isbn10, isbn13 != isbn10 {
            isbnFilter = "_or: [{isbn_13: {_eq: \"\(isbn13)\"}}, {isbn_10: {_eq: \"\(isbn10)\"}}]"
        } else if let isbn13 {
            isbnFilter = "isbn_13: {_eq: \"\(isbn13)\"}"
        } else if let isbn10 {
            isbnFilter = "isbn_10: {_eq: \"\(isbn10)\"}"
        } else {
            isbnFilter = "id: {_eq: -1}" // never matches; keeps the query valid
        }
        return """
        query EnrichByISBN {
          editions(where: { \(isbnFilter) }, limit: 1) {
            id
            pages
            language { code2 }
            image { url }
            book {
              id
              description
              cached_tags
              book_series(limit: 1, order_by: { position: asc }) {
                position
                series { name }
              }
            }
          }
        }
        """
    }

    // MARK: - Public API

    /// Look up enrichment for an ISBN (either form). nil = not found,
    /// disabled, or any error — callers treat all three identically.
    func metadata(isbn: String) async -> HardcoverBookMetadata? {
        // OAuth access tokens expire; renew from the refresh token before
        // the request rather than failing it.
        if HardcoverConfig.oauthAccessTokenNeedsRefresh {
            await HardcoverOAuth.refreshTokensIfNeeded()
        }
        guard HardcoverConfig.token != nil else { return nil }
        let cleaned = Book.normalizedISBN(isbn)
        guard let cleaned else { return nil }
        let isbn13: String?, isbn10: String?
        if cleaned.count == 13 {
            isbn13 = cleaned
            isbn10 = nil
        } else {
            isbn13 = nil
            isbn10 = cleaned
        }
        return await query(isbn13: isbn13, isbn10: isbn10)
    }

    /// Verify the configured token works: cheapest possible read-catalog
    /// request. Returns an error string on failure, nil on success.
    func testConnection() async -> String? {
        if HardcoverConfig.oauthAccessTokenNeedsRefresh {
            await HardcoverOAuth.refreshTokensIfNeeded()
        }
        guard let token = HardcoverConfig.token else { return "No API key set." }
        let request = Self.request(query: #"query Ping { books(limit: 1) { id } }"#, token: token)
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return "Unexpected response." }
            switch http.statusCode {
            case 200:
                // Hasura answers 200 with GraphQL errors in the body; check.
                if let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   body["errors"] != nil {
                    return "Key rejected by Hardcover."
                }
                return nil
            case 401: return "Invalid or expired key."
            case 429: return "Rate limited — try again in a minute."
            default: return "Hardcover returned HTTP \(http.statusCode)."
            }
        } catch {
            return "Network error: \(error.localizedDescription)"
        }
    }

    // MARK: - Plumbing

    private static func request(query: String, token: String) -> URLRequest {
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["query": query])
        return request
    }

    private func query(isbn13: String?, isbn10: String?) async -> HardcoverBookMetadata? {
        guard let token = HardcoverConfig.token else { return nil }
        let request = Self.request(query: Self.enrichmentQuery(isbn13: isbn13, isbn10: isbn10), token: token)
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  body["errors"] == nil,
                  let result = body["data"] as? [String: Any],
                  let editions = result["editions"] as? [[String: Any]],
                  let edition = editions.first else {
                return nil
            }
            return Self.parse(edition: edition)
        } catch {
            return nil
        }
    }

    // MARK: - Parsing

    /// `cached_tags` arrives as {"Genre": ["Fantasy", …], "Mood": ["Dark"], …}
    /// (observed in the wild; it's a jsonb column so the shape is loosely
    /// typed). Flatten all categories into one tag list; drop spoiler-marked
    /// entries when the platform sends objects.
    static func parse(edition: [String: Any]) -> HardcoverBookMetadata {
        let book = edition["book"] as? [String: Any] ?? [:]

        var tags: [String] = []
        var genres: [String] = []
        if let cached = book["cached_tags"] {
            flattenTags(cached, into: &tags, genres: &genres)
        }

        var seriesName: String?
        var seriesPosition: String?
        if let seriesList = book["book_series"] as? [[String: Any]],
           let entry = seriesList.first {
            if let series = entry["series"] as? [String: Any] {
                seriesName = series["name"] as? String
            }
            if let position = entry["position"] {
                seriesPosition = "\(position)"
            }
        }

        var language: String?
        if let lang = edition["language"] as? [String: Any] {
            language = lang["code2"] as? String
        }
        var coverImageURL: String?
        if let image = edition["image"] as? [String: Any] {
            coverImageURL = image["url"] as? String
        }

        return HardcoverBookMetadata(
            bookID: book["id"] as? Int,
            genres: genres,
            tags: tags,
            seriesName: seriesName,
            seriesPosition: seriesPosition,
            description: book["description"] as? String,
            pageCount: edition["pages"] as? Int,
            language: language,
            coverImageURL: coverImageURL
        )
    }

    /// Recursively flattens the jsonb `cached_tags` payload. Handles both
    /// observed shapes: {category: [tag, …]} dicts and [{tag, tagSlug,
    /// category, spoiler}, …] object lists. Genre-category tags double as
    /// genres; everything lands in `tags`.
    private static func flattenTags(_ payload: Any, into tags: inout [String], genres: inout [String]) {
        var seen = Set<String>()
        func add(_ raw: String, category: String?) {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, seen.insert(value).inserted else { return }
            tags.append(value)
            if let category, category.lowercased().contains("genre") {
                genres.append(value)
            }
        }
        switch payload {
        case let dict as [String: Any]:
            for (category, value) in dict {
                if let list = value as? [Any] {
                    for item in list { add(String(describing: item), category: category) }
                } else if let s = value as? String {
                    add(s, category: category)
                }
            }
        case let list as [Any]:
            for item in list {
                guard let obj = item as? [String: Any] else { continue }
                if let spoiler = obj["spoiler"] as? Bool, spoiler { continue }
                if let tag = obj["tag"] as? String {
                    add(tag, category: obj["category"] as? String)
                }
            }
        default:
            break
        }
    }
}

/// Persisted Hardcover settings: enabled flag in UserDefaults; the OAuth
/// token pair in the Keychain (never UserDefaults). `token` transparently
/// returns the current access token regardless of whether the user
/// connected via OAuth or pasted a legacy PAT — callers needn't care.
enum HardcoverConfig {
    private enum Keys {
        static let enabled = "Hardcover.enabled"
        static let keychainService = "com.librarycove.app"
        static let keychainAccount = "HardcoverAPIToken"
        static let oauthAccount = "HardcoverOAuthAccessToken"
        static let refreshAccount = "HardcoverOAuthRefreshToken"
        static let expiryKey = "HardcoverOAuthAccessTokenExpiry"
    }

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.enabled) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.enabled) }
    }

    /// The PAT, read/written through the Keychain. Writing nil/empty deletes.
    static var token: String? {
        get {
            let value = Keychain.read(service: Keys.keychainService, account: Keys.keychainAccount) ?? ""
            return value.isEmpty ? nil : value
        }
        set {
            if let newValue, !newValue.isEmpty {
                Keychain.set(newValue, service: Keys.keychainService, account: Keys.keychainAccount)
            } else {
                Keychain.delete(service: Keys.keychainService, account: Keys.keychainAccount)
            }
        }
    }

    static var isConfigured: Bool { isEnabled && token != nil }

    // MARK: - OAuth token storage

    /// The OAuth access token, stored separately from a pasted PAT so the
    /// refresh flow only ever touches its own credential.
    static var oauthAccessToken: String? {
        get {
            let value = Keychain.read(service: Keys.keychainService, account: Keys.oauthAccount) ?? ""
            return value.isEmpty ? nil : value
        }
        set {
            if let newValue, !newValue.isEmpty {
                Keychain.set(newValue, service: Keys.keychainService, account: Keys.oauthAccount)
            } else {
                Keychain.delete(service: Keys.keychainService, account: Keys.oauthAccount)
            }
        }
    }

    static var oauthRefreshToken: String? {
        get {
            let value = Keychain.read(service: Keys.keychainService, account: Keys.refreshAccount) ?? ""
            return value.isEmpty ? nil : value
        }
        set {
            if let newValue, !newValue.isEmpty {
                Keychain.set(newValue, service: Keys.keychainService, account: Keys.refreshAccount)
            } else {
                Keychain.delete(service: Keys.keychainService, account: Keys.refreshAccount)
            }
        }
    }

    /// Absolute epoch when the cached access token expires.
    static var oauthAccessTokenExpiry: Date? {
        get {
            let t = UserDefaults.standard.double(forKey: Keys.expiryKey)
            return t > 0 ? Date(timeIntervalSince1970: t) : nil
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.timeIntervalSince1970, forKey: Keys.expiryKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.expiryKey)
            }
        }
    }

    /// True when the cached access token is already expired (with a 60s
    /// safety margin so in-flight requests don't race expiry).
    static var oauthAccessTokenNeedsRefresh: Bool {
        guard oauthAccessToken != nil else { return false }
        guard let expiry = oauthAccessTokenExpiry else { return false }
        return Date().addingTimeInterval(60) >= expiry
    }

    /// Clears every credential — Disconnect, and refresh-failure recovery.
    static func clearAllTokens() {
        oauthAccessToken = nil
        oauthRefreshToken = nil
        oauthAccessTokenExpiry = nil
        token = nil
    }

    /// Adopts OAuth credentials as the active token (plus remembers the
    /// refresh token for renewal).
    static func adoptOAuthTokens(access: String, refresh: String?, expiresInSeconds: Int?) {
        oauthAccessToken = access
        oauthRefreshToken = refresh
        if let expiresInSeconds {
            oauthAccessTokenExpiry = Date().addingTimeInterval(TimeInterval(expiresInSeconds))
        }
        token = access
        isEnabled = true
    }
}

/// OAuth client for Hardcover (public mobile client, PKCE — no secret).
/// Standard authorization-code flow via ASWebAuthenticationSession with a
/// custom-scheme callback, plus the RFC 8628 device grant as a fallback.
/// Endpoints per docs.hardcover.app/api/oauth (also published at the
/// discovery document).
///
/// Registration: ONE developer app ("LibraryCove") at
/// hardcover.app/account/developer-apps yields the embedded client_id —
/// public by design, safe to ship in the binary. Each user just approves a
/// consent screen; their tokens live in their own Keychain and rate bucket.
@MainActor
final class HardcoverOAuth: NSObject {
    static let shared = HardcoverOAuth()

    enum OAuthError: LocalizedError {
        case noClientID
        case cancelled
        case callback(String)
        case tokenExchange(String)

        var errorDescription: String? {
            switch self {
            case .noClientID: return "Hardcover OAuth client is not registered yet."
            case .cancelled: return "Sign-in was cancelled."
            case .callback(let detail): return "Sign-in failed: \(detail)"
            case .tokenExchange(let detail): return "Token exchange failed: \(detail)"
            }
        }
    }

    // Endpoints per the OAuth docs (also published at
    // /.well-known/oauth-authorization-server).
    static let authorizeURL = URL(string: "https://hardcover.app/oauth2/authorize")!
    static let tokenURL = URL(string: "https://api.hardcover.app/oauth2/token")!
    static let revokeURL = URL(string: "https://api.hardcover.app/oauth2/revoke")!
    /// Custom scheme registered in project.yml's CFBundleURLTypes; the
    /// registered redirect URI must match scheme+path (loopback-style match).
    static let redirectURI = "librarycove:oauth2hardcover"
    /// Public catalog reads only — the app never touches the user's library,
    /// journal, lists, or account.
    static let scope = "read:catalog"

    /// Registered client id. Embedded in the binary by design (public
    /// client); empty until the developer app is registered.
    static var clientID: String {
        get { UserDefaults.standard.string(forKey: "HardcoverOAuthClientID") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "HardcoverOAuthClientID") }
    }

    private var authSession: ASWebAuthenticationSession?
    private var pendingDeviceCode: String?

    // MARK: - Standard flow (browser + custom-scheme callback)

    /// Runs the authorization-code flow with PKCE. Throws on cancel,
    /// mismatch, or exchange failure; adopts tokens on success.
    func authorize(presentationAnchor: ASWebAuthenticationPresentationContextProviding) async throws {
        guard !Self.clientID.isEmpty else { throw OAuthError.noClientID }

        let verifier = Self.randomURLSafeBase64(byteCount: 32)
        let challenge = Self.base64URLSHA256(verifier)
        let state = Self.randomURLSafeBase64(byteCount: 24)

        var components = URLComponents(url: Self.authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "scope", value: Self.scope),
        ]

        let callbackURL = try await startAuthSession(url: components.url!, scheme: Self.redirectScheme, anchor: presentationAnchor)
        guard let comps = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            throw OAuthError.callback("Malformed callback.")
        }
        let query = comps.queryItems ?? []
        // RFC 9207: Hardcover names its issuer in every callback; checking
        // it prevents mix-up attacks if another provider is ever added.
        if let iss = query.first(where: { $0.name == "iss" })?.value, iss != "https://api.hardcover.app" {
            throw OAuthError.callback("Response came from the wrong issuer.")
        }
        guard let code = query.first(where: { $0.name == "code" })?.value else {
            let error = query.first(where: { $0.name == "error" })?.value ?? "no code in callback"
            throw OAuthError.callback(error)
        }
        guard query.first(where: { $0.name == "state" })?.value == state else {
            throw OAuthError.callback("State mismatch — restart sign-in.")
        }
        try await Self.exchangeCode(code: code, verifier: verifier)
    }

    private static var redirectScheme: String {
        String(redirectURI.split(separator: ":").first ?? "librarycove")
    }

    // MARK: - Device grant fallback (RFC 8628)

    struct DeviceFlowStart {
        let verificationURL: URL
        let userCode: String
        let interval: TimeInterval
        let expiresAt: Date
    }

    /// Starts the device flow: returns what to show the user.
    func startDeviceFlow() async throws -> DeviceFlowStart {
        guard !Self.clientID.isEmpty else { throw OAuthError.noClientID }
        var request = URLRequest(url: URL(string: "https://api.hardcover.app/oauth2/device")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "client_id=\(Self.clientID)&scope=\(Self.scope)".data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let deviceCode = body["device_code"] as? String,
              let userCode = body["user_code"] as? String,
              let verificationString = body["verification_uri"] as? String,
              let verificationURL = URL(string: verificationString) else {
            let detail = (response as? HTTPURLResponse).map { "HTTP \($0.statusCode)" } ?? "malformed response"
            throw OAuthError.tokenExchange(detail)
        }
        let interval = TimeInterval(body["interval"] as? Int ?? 5)
        let expiresAt = Date().addingTimeInterval(TimeInterval(body["expires_in"] as? Int ?? 900))
        pendingDeviceCode = deviceCode
        return DeviceFlowStart(verificationURL: verificationURL,
                               userCode: userCode,
                               interval: interval,
                               expiresAt: expiresAt)
    }

    /// One poll of the device token endpoint. Returns true when tokens
    /// landed, false while still pending (bumping `interval` on slow_down);
    /// throws on denial/expiry/error.
    func pollDeviceFlow(interval: inout TimeInterval) async throws -> Bool {
        guard let deviceCode = pendingDeviceCode else { throw OAuthError.tokenExchange("No device flow started.") }
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "grant_type=urn:ietf:params:oauth:grant-type:device_code&device_code=\(deviceCode)&client_id=\(Self.clientID)".data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OAuthError.tokenExchange("No response.") }
        let body = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if http.statusCode == 200, let access = body["access_token"] as? String {
            pendingDeviceCode = nil
            HardcoverConfig.adoptOAuthTokens(
                access: access,
                refresh: body["refresh_token"] as? String,
                expiresInSeconds: body["expires_in"] as? Int)
            return true
        }
        switch body["error"] as? String {
        case "authorization_pending":
            return false
        case "slow_down":
            interval += 5
            return false
        case let other?:
            pendingDeviceCode = nil
            throw OAuthError.tokenExchange(other)
        default:
            throw OAuthError.tokenExchange("HTTP \(http.statusCode)")
        }
    }

    // MARK: - Token plumbing

    private static func exchangeCode(code: String, verifier: String) async throws {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "grant_type=authorization_code&code=\(code)&redirect_uri=\(redirectURI)&code_verifier=\(verifier)&client_id=\(clientID)"
        request.httpBody = body.data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let tokenBody = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = tokenBody["access_token"] as? String else {
            let detail = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:])["error_description"] as? String
                ?? ((response as? HTTPURLResponse).map { "HTTP \($0.statusCode)" } ?? "unknown error")
            throw OAuthError.tokenExchange(detail)
        }
        HardcoverConfig.adoptOAuthTokens(
            access: access,
            refresh: tokenBody["refresh_token"] as? String,
            expiresInSeconds: tokenBody["expires_in"] as? Int)
    }

    /// Exchanges the refresh token for a fresh access token. Returns
    /// silently when there's nothing to refresh; clears credentials when
    /// refresh fails (caller should reconnect). Injectable session so tests
    /// can stub the endpoint.
    static func refreshTokensIfNeeded(session: URLSession = .shared) async {
        guard HardcoverConfig.oauthAccessTokenNeedsRefresh,
              let refresh = HardcoverConfig.oauthRefreshToken else { return }
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "grant_type=refresh_token&refresh_token=\(refresh)&client_id=\(clientID)".data(using: .utf8)
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let access = body["access_token"] as? String else {
                HardcoverConfig.clearAllTokens()
                return
            }
            HardcoverConfig.adoptOAuthTokens(
                access: access,
                refresh: (body["refresh_token"] as? String) ?? refresh,
                expiresInSeconds: body["expires_in"] as? Int)
        } catch {
            // Network error: keep the current tokens; next request retries.
        }
    }

    /// Revokes both tokens server-side (the session disappears from the
    /// user's Authorized Apps page), then clears local storage.
    static func disconnect() async {
        if let refresh = HardcoverConfig.oauthRefreshToken {
            var request = URLRequest(url: revokeURL)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = "token=\(refresh)&token_type_hint=refresh_token&client_id=\(clientID)".data(using: .utf8)
            _ = try? await URLSession.shared.data(for: request)
        }
        HardcoverConfig.clearAllTokens()
    }

    // MARK: - ASWebAuthenticationSession plumbing

    private func startAuthSession(url: URL, scheme: String, anchor: ASWebAuthenticationPresentationContextProviding) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { callbackURL, error in
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                    continuation.resume(throwing: OAuthError.cancelled)
                } else {
                    continuation.resume(throwing: OAuthError.callback(error?.localizedDescription ?? "unknown"))
                }
            }
            session.presentationContextProvider = anchor
            session.prefersEphemeralWebBrowserSession = true
            self.authSession = session
            session.start()
        }
    }

    // MARK: - PKCE helpers (nonisolated: pure crypto, no UI or state)

    nonisolated static func randomURLSafeBase64(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    nonisolated static func base64URLSHA256(_ verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
    }
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
