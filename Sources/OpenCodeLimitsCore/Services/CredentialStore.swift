import Foundation
import Security

/// Resolves the OpenCode Go API key from a database, the environment or the
/// macOS Keychain. The key itself is never logged, persisted in UserDefaults
/// or exposed by any description property.
public final class CredentialStore: @unchecked Sendable {
    private static let keychainService = "dev.alex.opencodelimits"
    private static let keychainAccount = "go-api-key"
    private static let environmentVariable = "OPENCODE_GO_KEY"
    private static let databaseEnvironmentVariable = "OPENCODE_DB_PATH"

    private let lock = NSLock()
    private let storedDatabasePath: String
    private var currentPreferredSource: KeySource

    public init(dbPath: String? = nil) {
        self.storedDatabasePath = dbPath
            ?? ProcessInfo.processInfo.environment[CredentialStore.databaseEnvironmentVariable]
            ?? AppConfig.defaultDatabasePath
        if let raw = UserDefaults.standard.string(forKey: AppDefaultsKey.keySource),
           let saved = KeySource(rawValue: raw) {
            self.currentPreferredSource = saved
        } else {
            self.currentPreferredSource = .database
        }
    }

    /// Source tried first; other sources are still used as fallbacks.
    public var preferredSource: KeySource {
        get {
            lock.lock()
            defer { lock.unlock() }
            return currentPreferredSource
        }
        set {
            lock.lock()
            currentPreferredSource = newValue
            lock.unlock()
            UserDefaults.standard.set(newValue.rawValue, forKey: AppDefaultsKey.keySource)
        }
    }

    public var databasePath: String { storedDatabasePath }

    private var keychainQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: CredentialStore.keychainService,
            kSecAttrAccount as String: CredentialStore.keychainAccount,
        ]
    }

    private func resolutionOrder() -> [KeySource] {
        let preferred = preferredSource
        return [preferred] + KeySource.allCases.filter { $0 != preferred }
    }

    /// - Throws: `UsageError.missingKey` when no source contains a usable key.
    public func goAPIKey() throws -> String {
        for source in resolutionOrder() {
            if let key = try? readKey(from: source), !key.isEmpty { return key }
        }
        throw UsageError.missingKey
    }

    /// Source that would actually be used right now (no secret included).
    public var activeSource: KeySource? {
        for source in resolutionOrder() {
            if let key = try? readKey(from: source), !key.isEmpty { return source }
        }
        return nil
    }

    /// Human-readable, secret-free description of the active key source.
    public var activeSourceDescription: String {
        activeSource?.title ?? "Ключ не найден"
    }

    public var hasManualKey: Bool { readKeychainKey() != nil }

    // MARK: - Individual sources

    private func readKey(from source: KeySource) throws -> String {
        switch source {
        case .environment:
            let raw = ProcessInfo.processInfo.environment[CredentialStore.environmentVariable] ?? ""
            let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { throw UsageError.missingKey }
            return key
        case .keychain:
            guard let key = readKeychainKey() else { throw UsageError.missingKey }
            return key
        case .database:
            return try readDatabaseKey()
        }
    }

    private func readDatabaseKey() throws -> String {
        guard FileManager.default.fileExists(atPath: storedDatabasePath) else {
            throw UsageError.missingKey
        }
        let database = try SQLiteDatabase(path: storedDatabasePath)
        defer { database.close() }
        let statement = try database.prepare(
            "SELECT json_extract(value, '$.key') FROM credential "
                + "WHERE integration_id = 'opencode-go' AND active = 1 LIMIT 1"
        )
        defer { statement.finalize() }
        guard try statement.step() else { throw UsageError.missingKey }
        let key = statement.string(at: 0)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty else { throw UsageError.missingKey }
        return key
    }

    private func readKeychainKey() -> String? {
        var query = keychainQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        let key = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return key.isEmpty ? nil : key
    }

    // MARK: - Manual key management

    public func saveManualKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw UsageError.missingKey }
        let data = Data(trimmed.utf8)
        var addQuery = keychainQuery
        addQuery[kSecValueData as String] = data
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            break
        case errSecDuplicateItem:
            let updateStatus = SecItemUpdate(
                keychainQuery as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw UsageError.database("Не удалось обновить ключ в Keychain (код \(updateStatus)).")
            }
        default:
            throw UsageError.database("Не удалось сохранить ключ в Keychain (код \(status)).")
        }
        preferredSource = .keychain
    }

    public func clearManualKey() {
        _ = SecItemDelete(keychainQuery as CFDictionary)
    }
}
