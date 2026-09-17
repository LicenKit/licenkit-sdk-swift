import Foundation

/// LicenKit Swift 客户端门面，提供统一的授权管理、在线激活、心跳探活与脱网离线验签能力
public final class LicenKit: @unchecked Sendable {
    
    // MARK: - Singleton
    
    private static let lock = NSLock()
    private static var _shared: LicenKit?
    
    /// 初始化全局共享实例
    public static func configure(with configuration: LicenKitConfiguration) {
        lock.lock()
        defer { lock.unlock() }
        _shared = LicenKit(configuration: configuration)
    }
    
    /// 获取全局共享实例
    public static var shared: LicenKit {
        lock.lock()
        defer { lock.unlock() }
        guard let instance = _shared else {
            fatalError("LicenKit has not been initialized. Please call LicenKit.configure(with:) before accessing LicenKit.shared.")
        }
        return instance
    }
    
    // MARK: - Properties
    
    public let configuration: LicenKitConfiguration
    private let credentialStore: CredentialStore
    private let fingerprintProvider: DeviceFingerprintProvider
    private let ed25519Verifier: Ed25519Verifier
    private let claimsEvaluator: ClaimsEvaluator
    private let apiClient: LicenKitAPIClient
    
    private let stateLock = NSLock()
    private var _cachedStatus: LicenseStatus?
    
    /// 当前内存中缓存的许可证状态
    public var cachedStatus: LicenseStatus? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _cachedStatus
    }
    
    // MARK: - Initialization
    
    public init(
        configuration: LicenKitConfiguration,
        credentialStore: CredentialStore? = nil,
        fingerprintProvider: DeviceFingerprintProvider? = nil
    ) {
        self.configuration = configuration
        self.credentialStore = credentialStore ?? KeychainStore(
            productId: configuration.productId,
            accessGroup: configuration.accessGroup
        )
        
        #if os(macOS)
        self.fingerprintProvider = fingerprintProvider ?? MacOSFingerprintProvider()
        #else
        self.fingerprintProvider = fingerprintProvider ?? UnsupportedPlatformFingerprintProvider()
        #endif
        
        self.ed25519Verifier = Ed25519Verifier()
        self.claimsEvaluator = ClaimsEvaluator()
        self.apiClient = LicenKitAPIClient(
            serverUrl: configuration.serverUrl,
            timeoutInterval: configuration.timeoutInterval
        )
    }
    
    // MARK: - Public APIs
    
    /// 纯脱网离线执行 Ed25519 密码学签名核验与硬件指纹校验 (0 网络耗时)
    @discardableResult
    public func verifyOffline() async throws -> LicenseStatus {
        let fingerprint = try await fingerprintProvider.getFingerprint()
        
        guard let creds = try credentialStore.loadCredentials(for: fingerprint) else {
            setCachedStatus(.expired(claims: nil))
            throw LicenKitError.unactivated
        }
        
        // 执行 Ed25519 签名验证与反序列化
        let (_, claims): (OfflineTokenHeader, LicenseClaims) = try ed25519Verifier.verifyAndDecodeToken(
            token: creds.token,
            publicKeyInput: configuration.publicKey
        )
        
        // 评估当前运行态约束
        let status = claimsEvaluator.evaluate(
            claims: claims,
            currentFingerprint: fingerprint,
            lastValidatedAt: creds.lastValidatedAt,
            offlineGracePeriodSeconds: Double(creds.offlineGracePeriod)
        )
        
        setCachedStatus(status)
        return status
    }
    
    /// 在线激活当前设备席位，并持久化新凭据至 Keychain
    @discardableResult
    public func activate(licenseKey: String, machineName: String? = nil) async throws -> ActivationResult {
        let fingerprint = try await fingerprintProvider.getFingerprint()
        
        let platformName: String
        #if os(macOS)
        platformName = "macOS"
        #elseif os(iOS)
        platformName = "iOS"
        #else
        platformName = "Apple"
        #endif
        
        let hostName: String = {
            if let customName = machineName, !customName.isEmpty {
                return customName
            }
            #if os(macOS)
            return Host.current().localizedName ?? ProcessInfo.processInfo.hostName
            #else
            return ProcessInfo.processInfo.hostName
            #endif
        }()
        
        let request = ApiActivateRequest(
            accountId: configuration.accountId,
            licenseKey: licenseKey,
            fingerprint: fingerprint,
            platform: platformName,
            name: hostName
        )
        
        let response = try await apiClient.activate(request: request)
        
        guard let token = response.token, !token.isEmpty else {
            throw LicenKitError.invalidToken("Server did not return an offline verification token")
        }
        
        // 首次脱网验签自检，确保证书在本地立即可用
        let (_, claims): (OfflineTokenHeader, LicenseClaims) = try ed25519Verifier.verifyAndDecodeToken(
            token: token,
            publicKeyInput: configuration.publicKey
        )
        
        // 持久化到 Keychain (按当前机器指纹隔离保存，防止多设备 iCloud 同步冲突)
        let creds = StoredCredentials(
            licenseKey: licenseKey,
            token: token,
            lastValidatedAt: Date(),
            offlineGracePeriod: response.policy.offlineGracePeriod,
            policyFeatures: response.policy.features,
            machineId: response.machineId
        )
        try credentialStore.saveCredentials(creds, for: fingerprint)
        
        // 同步漫游激活码至 iCloud Keychain，供同一 Apple ID 下的新设备无感恢复
        try? credentialStore.saveRoamingLicenseKey(licenseKey)
        
        let status = claimsEvaluator.evaluate(
            claims: claims,
            currentFingerprint: fingerprint,
            lastValidatedAt: creds.lastValidatedAt,
            offlineGracePeriodSeconds: Double(creds.offlineGracePeriod)
        )
        setCachedStatus(status)
        
        let tokenExpiresAt = response.tokenExpiresAt?.date ?? claims.expirationDate
        let licenseExpiresAt = response.licenseExpiresAt?.date
        
        return ActivationResult(
            activated: response.activated,
            reused: response.reused,
            machineId: response.machineId,
            token: token,
            tokenExpiresAt: tokenExpiresAt,
            licenseExpiresAt: licenseExpiresAt,
            policy: response.policy
        )
    }
    
    /// 在线发送心跳探活，刷新许可证状态并在必要时续签本地 Token
    @discardableResult
    public func validate() async throws -> ValidationResult {
        let fingerprint = try await fingerprintProvider.getFingerprint()
        
        guard let creds = try credentialStore.loadCredentials(for: fingerprint) else {
            throw LicenKitError.unactivated
        }
        
        let request = ApiValidateRequest(
            accountId: configuration.accountId,
            licenseKey: creds.licenseKey,
            fingerprint: fingerprint
        )
        
        let response = try await apiClient.validate(request: request)
        let tokenExpiresAt = response.tokenExpiresAt?.date
        let licenseExpiresAt = response.licenseExpiresAt?.date
        
        // 若服务端判定无效（已吊销/已过期/未激活机器等），直接置为 untrusted，严防刷新本地宽限期
        if !response.valid {
            setCachedStatus(.untrusted(reason: response.reason ?? "License invalid or revoked by server"))
            return ValidationResult(
                valid: false,
                token: response.token,
                tokenExpiresAt: tokenExpiresAt,
                licenseExpiresAt: licenseExpiresAt,
                reason: response.reason
            )
        }
        
        var updatedToken = creds.token
        // 若服务端下发了最新 Token，则更新 Keychain
        if let newToken = response.token, !newToken.isEmpty {
            updatedToken = newToken
        }
        
        let updatedCreds = StoredCredentials(
            licenseKey: creds.licenseKey,
            token: updatedToken,
            lastValidatedAt: Date(),
            offlineGracePeriod: creds.offlineGracePeriod,
            policyFeatures: creds.policyFeatures,
            machineId: creds.machineId
        )
        try credentialStore.saveCredentials(updatedCreds, for: fingerprint)
        
        // 重新离线核验
        _ = try? await verifyOffline()
        
        return ValidationResult(
            valid: response.valid,
            token: response.token,
            tokenExpiresAt: tokenExpiresAt,
            licenseExpiresAt: licenseExpiresAt,
            reason: response.reason
        )
    }
    
    /// 释放当前机器席位并清空本地 Keychain 凭据
    /// - Parameter clearRoamingKey: 是否连同 iCloud 漫游激活码一同清空（默认 false，仅解绑本机席位）
    public func deactivate(clearRoamingKey: Bool = false) async throws {
        let fingerprint = try? await fingerprintProvider.getFingerprint()
        let savedCreds: StoredCredentials? = try? {
            if let fp = fingerprint {
                return try credentialStore.loadCredentials(for: fp)
            }
            return nil
        }()
        
        // 无论网络端结果如何，本地必须保证清空当前指纹的 Keychain 凭据
        defer {
            if let fp = fingerprint {
                try? credentialStore.clearCredentials(for: fp)
            }
            if clearRoamingKey {
                try? credentialStore.clearRoamingLicenseKey()
            }
            setCachedStatus(.untrusted(reason: "Deactivated"))
        }
        
        if let creds = savedCreds, let fp = fingerprint {
            let request = ApiDeactivateRequest(
                accountId: configuration.accountId,
                licenseKey: creds.licenseKey,
                fingerprint: fp
            )
            _ = try? await apiClient.deactivate(request: request)
        }
    }
    
    /// 获取通过 iCloud Keychain 漫游同步的激活码 (若有)
    public func getRoamingLicenseKey() throws -> String? {
        try credentialStore.loadRoamingLicenseKey()
    }
    
    /// 若检测到 iCloud 漫游激活码，自动发起新设备静默激活（无需用户重复输入激活码）
    @discardableResult
    public func restoreAndActivateFromRoamingKey(machineName: String? = nil) async throws -> ActivationResult {
        guard let roamingKey = try credentialStore.loadRoamingLicenseKey(), !roamingKey.isEmpty else {
            throw LicenKitError.unactivated
        }
        return try await activate(licenseKey: roamingKey, machineName: machineName)
    }
    
    /// 内存级快速查询当前是否具备指定高级特性权限
    public func hasFeature(_ featureKey: String) -> Bool {
        guard let status = cachedStatus else { return false }
        return status.hasFeature(featureKey)
    }
    
    /// 获取当前设备的硬件指纹
    public func getMachineFingerprint() async throws -> String {
        return try await fingerprintProvider.getFingerprint()
    }
    
    // MARK: - Private
    
    private func setCachedStatus(_ status: LicenseStatus) {
        stateLock.lock()
        defer { stateLock.unlock() }
        self._cachedStatus = status
    }
}
