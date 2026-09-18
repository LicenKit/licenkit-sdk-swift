import Foundation

/// 客户端本地持久化凭据模型
public struct StoredCredentials: Codable, Sendable {
    public let licenseKey: String
    public let machineToken: String
    public let token: String
    public let lastValidatedAt: Date
    public let offlineGracePeriod: Int
    public let policyFeatures: [String]
    public let machineId: String
    public let isTrial: Bool
    
    public init(
        licenseKey: String = "",
        machineToken: String = "",
        token: String,
        lastValidatedAt: Date,
        offlineGracePeriod: Int,
        policyFeatures: [String],
        machineId: String,
        isTrial: Bool = false
    ) {
        self.licenseKey = licenseKey
        self.machineToken = machineToken
        self.token = token
        self.lastValidatedAt = lastValidatedAt
        self.offlineGracePeriod = offlineGracePeriod
        self.policyFeatures = policyFeatures
        self.machineId = machineId
        self.isTrial = isTrial
    }
    
    enum CodingKeys: String, CodingKey {
        case licenseKey
        case machineToken
        case token
        case lastValidatedAt
        case offlineGracePeriod
        case policyFeatures
        case machineId
        case isTrial
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.licenseKey = try container.decodeIfPresent(String.self, forKey: .licenseKey) ?? ""
        self.machineToken = try container.decodeIfPresent(String.self, forKey: .machineToken) ?? ""
        self.token = try container.decode(String.self, forKey: .token)
        self.lastValidatedAt = try container.decode(Date.self, forKey: .lastValidatedAt)
        self.offlineGracePeriod = try container.decodeIfPresent(Int.self, forKey: .offlineGracePeriod) ?? 0
        self.policyFeatures = try container.decodeIfPresent([String].self, forKey: .policyFeatures) ?? []
        self.machineId = try container.decodeIfPresent(String.self, forKey: .machineId) ?? ""
        self.isTrial = try container.decodeIfPresent(Bool.self, forKey: .isTrial) ?? false
    }
}

/// 本地安全存储抽象接口
public protocol CredentialStore: Sendable {
    /// 读取指定机器指纹的本地授权凭据
    func loadCredentials(for fingerprint: String) throws -> StoredCredentials?
    
    /// 保存或更新指定机器指纹的授权凭据
    func saveCredentials(_ credentials: StoredCredentials, for fingerprint: String) throws
    
    /// 清除指定机器指纹的本地授权凭据 (解绑本机席位)
    func clearCredentials(for fingerprint: String) throws
    
    /// 读取通过 iCloud 同步的漫游激活码 (用于新设备首次启动时无感恢复)
    func loadRoamingLicenseKey() throws -> String?
    
    /// 保存漫游激活码至 iCloud Keychain
    func saveRoamingLicenseKey(_ key: String) throws
    
    /// 清空漫游激活码 (彻底注销授权)
    func clearRoamingLicenseKey() throws
    
    /// 读取缺省凭据 (向后兼容)
    func loadCredentials() throws -> StoredCredentials?
    
    /// 保存缺省凭据 (向后兼容)
    func saveCredentials(_ credentials: StoredCredentials) throws
    
    /// 清空缺省凭据 (向后兼容)
    func clearCredentials() throws
}

public extension CredentialStore {
    func loadCredentials() throws -> StoredCredentials? {
        try loadCredentials(for: "default")
    }
    
    func saveCredentials(_ credentials: StoredCredentials) throws {
        try saveCredentials(credentials, for: "default")
    }
    
    func clearCredentials() throws {
        try clearCredentials(for: "default")
    }
    
    func loadRoamingLicenseKey() throws -> String? {
        return nil
    }
    
    func saveRoamingLicenseKey(_ key: String) throws {}
    
    func clearRoamingLicenseKey() throws {}
}
