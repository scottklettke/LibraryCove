import Foundation
import SwiftData

/// Current local user (family member) — mirrors backend `User`.
@Model
final class User {
    var id: String = UUID().uuidString
    var email: String = ""
    var displayName: String = ""
    var avatarURL: String?
    var timezone: String = "UTC"
    var language: String = "en"
    var isActive: Bool = true
    var createdAt: Date = Date(timeIntervalSinceReferenceDate: 0)
    var lastLoginAt: Date?

    init(
        id: String = UUID().uuidString,
        email: String,
        displayName: String,
        avatarURL: String? = nil,
        timezone: String = "UTC",
        language: String = "en",
        isActive: Bool = true,
        createdAt: Date = Date(timeIntervalSinceReferenceDate: 0),
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
