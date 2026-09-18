import Foundation
import Security

/// 基于 Apple 系统级 Keychain Services 的安全凭据存储器
public struct KeychainStore: CredentialStore, Sendable {
    
    public let service: String
    public let accessGroup: String?
    public let isSynchronizable: Bool
    
    private let roamingAccount = "roaming_license_key"
    
    public init(
        productId: String,
        accessGroup: String? = nil,
        isSynchronizable: Bool = false
    ) {
        self.service = "com.licenkit.client.\(productId)"
        self.accessGroup = accessGroup
        self.isSynchronizable = isSynchronizable
    }
    
    // MARK: - Fingerprint-Scoped Credentials
    
    public func loadCredentials(for fingerprint: String) throws -> StoredCredentials? {
        let account = accountKey(for: fingerprint)
        guard let data = try readData(for: account) else {
            return nil
        }
        
        do {
            return try JSONDecoder().decode(StoredCredentials.self, from: data)
        } catch {
            throw LicenKitError.keychainError(status: errSecDecode, message: "Failed to decode credentials stored in Keychain: \(error.localizedDescription)")
        }
    }
    
    public func saveCredentials(_ credentials: StoredCredentials, for fingerprint: String) throws {
        let account = accountKey(for: fingerprint)
        let data = try JSONEncoder().encode(credentials)
        try writeData(data, for: account)
    }
    
    public func clearCredentials(for fingerprint: String) throws {
        let account = accountKey(for: fingerprint)
        try deleteData(for: account)
    }
    
    // MARK: - Roaming License Key (iCloud Sync)
    
    public func loadRoamingLicenseKey() throws -> String? {
        guard let data = try readData(for: roamingAccount) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
    
    public func saveRoamingLicenseKey(_ key: String) throws {
        guard let data = key.data(using: .utf8) else { return }
        try writeData(data, for: roamingAccount)
    }
    
    public func clearRoamingLicenseKey() throws {
        try deleteData(for: roamingAccount)
    }
    
    // MARK: - Private Helpers
    
    private func accountKey(for fingerprint: String) -> String {
        let cleanFp = fingerprint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "fp_\(cleanFp)"
    }
    
    private func baseQuery(for account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if isSynchronizable {
            query[kSecAttrSynchronizable as String] = kCFBooleanTrue as Any
        } else {
            query[kSecAttrSynchronizable as String] = kCFBooleanFalse as Any
        }
        if let accessGroup = accessGroup, !accessGroup.isEmpty {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
    
    private func readData(for account: String) throws -> Data? {
        var query = baseQuery(for: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        if status == errSecItemNotFound {
            return nil
        }
        
        guard status == errSecSuccess, let data = result as? Data else {
            throw LicenKitError.keychainError(status: status, message: "Failed to read item '\(account)' from Keychain")
        }
        
        return data
    }
    
    private func writeData(_ data: Data, for account: String) throws {
        let query = baseQuery(for: account)
        
        let updateAttributes: [String: Any] = [
            kSecValueData as String: data
        ]
        
        var status = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)
        
        if status == errSecItemNotFound {
            var newItem = query
            newItem[kSecValueData as String] = data
            newItem[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(newItem as CFDictionary, nil)
            
            // 降级兜底：若因宿主 App 缺少 iCloud Keychain 权限导致 -34018 或 -50，自动回退到本地无同步重试
            if status != errSecSuccess && isSynchronizable {
                var fallbackItem = newItem
                fallbackItem[kSecAttrSynchronizable as String] = kCFBooleanFalse as Any
                status = SecItemAdd(fallbackItem as CFDictionary, nil)
            }
        } else if status != errSecSuccess && isSynchronizable {
            // Update 同样提供非同步降级
            var fallbackQuery = query
            fallbackQuery[kSecAttrSynchronizable as String] = kCFBooleanFalse as Any
            status = SecItemUpdate(fallbackQuery as CFDictionary, updateAttributes as CFDictionary)
        }
        
        guard status == errSecSuccess else {
            throw LicenKitError.keychainError(status: status, message: "Failed to persist item '\(account)' in Keychain")
        }
    }
    
    private func deleteData(for account: String) throws {
        let query = baseQuery(for: account)
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw LicenKitError.keychainError(status: status, message: "Failed to delete item '\(account)' from Keychain")
        }
    }
}
