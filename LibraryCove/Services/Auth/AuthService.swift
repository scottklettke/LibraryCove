import Foundation

/// Authentication result for a family member.
struct AuthResult: Sendable {
    let userID: String
    let token: String?
    let displayName: String
}

/// Protocol for auth providers (iCloud identity, self-hosted JWT).
protocol AuthService: AnyObject, Sendable {
    func login(email: String, password: String) async throws -> AuthResult
    func register(email: String, displayName: String, password: String) async throws -> AuthResult
    func logout() async throws
}

/// Self-hosted JWT auth against the FastAPI backend.
final class JWTAuthService: AuthService {
    private let baseURL: URL

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    func login(email: String, password: String) async throws -> AuthResult {
        // TODO: POST /api/auth/login
        return AuthResult(userID: UUID().uuidString, token: nil, displayName: email)
    }

    func register(email: String, displayName: String, password: String) async throws -> AuthResult {
        // TODO: POST /api/auth/register
        return AuthResult(userID: UUID().uuidString, token: nil, displayName: displayName)
    }

    func logout() async throws {
        // TODO: POST /api/auth/logout
    }
}

/// iCloud identity auth (placeholder until entitlement configured).
final class ICloudAuthService: AuthService {
    func login(email: String, password: String) async throws -> AuthResult {
        // TODO: CKAccountStatus / CloudKit user record
        return AuthResult(userID: UUID().uuidString, token: nil, displayName: email)
    }

    func register(email: String, displayName: String, password: String) async throws -> AuthResult {
        return AuthResult(userID: UUID().uuidString, token: nil, displayName: displayName)
    }

    func logout() async throws {
        // TODO
    }
}
