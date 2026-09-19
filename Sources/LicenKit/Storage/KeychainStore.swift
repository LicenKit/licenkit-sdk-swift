import Foundation
import Security

public struct KeychainStore: CredentialStore, Sendable {
    public let service: String
    public let accessGroup: String?

    public init(productID: String, accessGroup: String? = nil) {
        self.service = "com.licenkit.client.\(productID)"
        self.accessGroup = accessGroup
    }

    public func loadCredentials(for fingerprint: String) throws -> StoredCredentials? {
        try read(StoredCredentials.self, account: accountKey(prefix: "license", fingerprint: fingerprint))
    }

    public func saveCredentials(_ credentials: StoredCredentials, for fingerprint: String) throws {
        try write(credentials, account: accountKey(prefix: "license", fingerprint: fingerprint))
    }

    public func clearCredentials(for fingerprint: String) throws {
        try delete(account: accountKey(prefix: "license", fingerprint: fingerprint))
    }

    public func loadTrialCredentials(for fingerprint: String) throws -> StoredTrialCredentials? {
        try read(StoredTrialCredentials.self, account: accountKey(prefix: "trial", fingerprint: fingerprint))
    }

    public func saveTrialCredentials(_ credentials: StoredTrialCredentials, for fingerprint: String) throws {
        try write(credentials, account: accountKey(prefix: "trial", fingerprint: fingerprint))
    }

    public func clearTrialCredentials(for fingerprint: String) throws {
        try delete(account: accountKey(prefix: "trial", fingerprint: fingerprint))
    }

    private func accountKey(prefix: String, fingerprint: String) -> String {
        "\(prefix)_\(fingerprint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }

    private func baseQuery(account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
        if let accessGroup, !accessGroup.isEmpty { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    private func read<T: Decodable>(_ type: T.Type, account: String) throws -> T? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw LicenKitError.credentialStorageError(operation: "read", status: status)
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw LicenKitError.credentialStorageError(operation: "decode", status: errSecDecode) }
    }

    private func write<T: Encodable>(_ value: T, account: String) throws {
        let data: Data
        do { data = try JSONEncoder().encode(value) }
        catch { throw LicenKitError.credentialStorageError(operation: "encode", status: errSecParam) }
        let query = baseQuery(account: account)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw LicenKitError.credentialStorageError(operation: "write", status: status)
        }
    }

    private func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw LicenKitError.credentialStorageError(operation: "delete", status: status)
        }
    }
}
