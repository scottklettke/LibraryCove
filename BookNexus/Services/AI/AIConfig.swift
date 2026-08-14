import Foundation
import Security

/// Persisted AI configuration. A stateless enum namespace over
/// `UserDefaults` (engine + base URL) and the Keychain (API key). The API key
/// never touches `UserDefaults`; it lives in the app's own keychain entry,
/// which needs no extra entitlement.
enum AIConfig {

    /// The endpoint is unset until the user provides one (an OpenAI-compatible
    /// server is required — e.g. a local Ollama/LM Studio instance, a
    /// self-hosted server, or api.openai.com with an API key). An empty value
    /// routes AI features to the Settings onboarding instead of silently
    /// hammering a default host the user never chose.
    static let defaultOpenAIBaseURL = ""

    private enum Keys {
        static let engine = "AI.selectedEngine"
        static let baseURL = "AI.openAIBaseURL"
        static let keychainService = "com.booknexus.app"
        static let keychainAccount = "OpenAIAPIKey"
        static let showTokenRate = "AI.showTokenRate"
        static let maxContextTokens = "AI.maxContextTokens"
    }

    // MARK: Engine

    static var selectedEngine: AIEngine {
        get {
            let raw = UserDefaults.standard.string(forKey: Keys.engine) ?? ""
            return AIEngine(rawValue: raw) ?? .openAI
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Keys.engine)
        }
    }

    // MARK: OpenAI endpoint

    static var openAIBaseURL: String {
        get {
            UserDefaults.standard.string(forKey: Keys.baseURL) ?? defaultOpenAIBaseURL
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(trimmed, forKey: Keys.baseURL)
        }
    }

    // MARK: OpenAI API key

    /// The API key, read/written through the Keychain. Writing an empty value
    /// deletes the stored entry.
    static var openAIAPIKey: String {
        get {
            Keychain.read(service: Keys.keychainService, account: Keys.keychainAccount) ?? ""
        }
        set {
            if newValue.isEmpty {
                Keychain.delete(service: Keys.keychainService, account: Keys.keychainAccount)
            } else {
                Keychain.set(newValue, service: Keys.keychainService, account: Keys.keychainAccount)
            }
        }
    }

    /// True when an OpenAI-compatible request could be attempted. The API key
    /// is optional — local endpoints (Ollama, LM Studio, self-hosted servers)
    /// often need only a base URL, and requests omit the Authorization header
    /// when no key is set.
    static var isOpenAIConfigured: Bool {
        !openAIBaseURL.isEmpty
    }

    // MARK: Chat indicator

    /// Whether the Ask AI chat shows a tokens/second estimate under each reply.
    static var showTokenRate: Bool {
        get {
            UserDefaults.standard.bool(forKey: Keys.showTokenRate)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.showTokenRate)
        }
    }

    // MARK: Context window

    /// The model's context window in tokens, used to size the Ask AI snapshot
    /// and transcript so requests never overflow it. Defaults conservatively to
    /// fit on-device Apple Intelligence / small local models; raise it in
    /// Settings → AI to match a larger model and get more of the library
    /// searchable.
    static let defaultMaxContextTokens = 4096

    static var maxContextTokens: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: Keys.maxContextTokens)
            guard stored >= 1024 else { return defaultMaxContextTokens }
            return min(stored, 262_144)
        }
        set {
            UserDefaults.standard.set(min(max(1024, newValue), 262_144), forKey: Keys.maxContextTokens)
        }
    }

    // MARK: Testing

    /// Clears every persisted value so tests start from a known state.
    static func resetForTesting() {
        UserDefaults.standard.removeObject(forKey: Keys.engine)
        UserDefaults.standard.removeObject(forKey: Keys.baseURL)
        UserDefaults.standard.removeObject(forKey: Keys.showTokenRate)
        UserDefaults.standard.removeObject(forKey: Keys.maxContextTokens)
        AILogStore.clear()
        Keychain.delete(service: Keys.keychainService, account: Keys.keychainAccount)
    }
}

/// Minimal Keychain wrapper for a single generic-password value. Operations
/// return whether they succeeded so failures surface instead of silently
/// swallowing the key.
enum Keychain {
    @discardableResult
    static func set(_ value: String, service: String, account: String) -> Bool {
        // Upsert: drop any existing item first so SecItemAdd never hits
        // errSecDuplicateItem.
        _ = delete(service: service, account: account)
        guard !value.isEmpty else { return true }

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            // Readable after first unlock so foreground + background paths
            // (e.g. sync tasks) can use it.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    static func read(service: String, account: String) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func delete(service: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        // Deleting a missing item is a success for our purposes.
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
