import Foundation
import SwiftData

/// Current local user (family member) — mirrors backend `User`.
@Model
final class User {
    @Attribute(.unique) var id: String
    var email: String
    var displayName: String
    var avatarURL: String?
    var timezone: String
    var language: String
    var isActive: Bool
    var createdAt: Date
    var lastLoginAt: Date?

    init(
        id: String = UUID().uuidString,
        email: String,
        displayName: String,
        avatarURL: String? = nil,
        timezone: String = "UTC",
        language: String = "en",
        isActive: Bool = true,
        createdAt: Date = .init(),
        lastLoginAt: Date? = nil
    ) {
        self.id = id
        self.email = email
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.timezone = timezone
        self.language = language
        self.isActive = isActive
        self.createdAt = createdAt
        self.lastLoginAt = lastLoginAt
    }
}
