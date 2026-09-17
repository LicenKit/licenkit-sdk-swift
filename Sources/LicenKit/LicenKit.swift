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
    public let retryCoordinator: LicenKitRetryCoordinator
    
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
        fingerprintProvider: DeviceFingerprintProvider? = nil,
        retryCoordinator: LicenKitRetryCoordinator? = nil,
        apiClient: LicenKitAPIClient? = nil
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
        self.apiClient = apiClient ?? LicenKitAPIClient(
            serverUrl: configuration.serverUrl,
            timeoutInterval: configuration.timeoutInterval
        )
        self.retryCoordinator = retryCoordinator ?? LicenKitRetryCoordinator.shared
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
        
        // 执行自适应 Ed25519 签名验证与反序列化 (支持正式版 License 与免密 Trial)
        let (_, claims) = try ed25519Verifier.verifyAndDecodeAnyToken(
            token: creds.token,
            publicKeyInput: configuration.publicKey
        )
        
        let status: LicenseStatus
        switch claims {
        case .license(let licenseClaims):
            status = claimsEvaluator.evaluate(
                claims: licenseClaims,
                currentFingerprint: fingerprint,
                lastValidatedAt: creds.lastValidatedAt,
                offlineGracePeriodSeconds: Double(creds.offlineGracePeriod)
            )
        case .trial(let trialClaims):
            status = claimsEvaluator.evaluateTrial(
                claims: trialClaims,
                currentFingerprint: fingerprint
            )
        }
        
        setCachedStatus(status)
        return status
    }
    
    /// 向服务端发起设备免费试用认领，并持久化试用凭据至 Keychain
    @discardableResult
    public func requestTrial() async throws -> TrialResult {
        let fingerprint = try await fingerprintProvider.getFingerprint()
        
        let request = ApiTrialRequest(
            accountId: configuration.accountId,
            productId: configuration.productId,
            fingerprint: fingerprint
        )
        
        let response = try await retryCoordinator.execute(scenario: .foregroundActivation) {
            try await self.apiClient.requestTrial(request: request)
        }
        
        let claimedAt = response.claimedAt?.date
        let expiresAt = response.expiresAt?.date
        
        // 若服务端判定已过期或未下发 Token
        guard let token = response.token, !token.isEmpty, !response.expired else {
            let expiredResult = TrialResult(
                trialClaimed: response.trialClaimed,
                alreadyClaimed: response.alreadyClaimed,
                expired: true,
                token: response.token,
                claimedAt: claimedAt,
                expiresAt: expiresAt,
                features: response.features
            )
            setCachedStatus(.trialExpired(claims: nil))
            return expiredResult
        }
        
        // 首次脱网验签自检，确保证书本地立即可用
        let (_, trialClaims): (OfflineTokenHeader, TrialClaims) = try ed25519Verifier.verifyAndDecodeToken(
            token: token,
            publicKeyInput: configuration.publicKey
        )
        
        // 保存试用凭据至 Keychain (免密钥标记 isTrial = true)
        let creds = StoredCredentials(
            licenseKey: "",
            token: token,
            lastValidatedAt: Date(),
            offlineGracePeriod: 0,
            policyFeatures: response.features,
            machineId: "",
            isTrial: true
        )
        try credentialStore.saveCredentials(creds, for: fingerprint)
        
        let status = claimsEvaluator.evaluateTrial(
            claims: trialClaims,
            currentFingerprint: fingerprint
        )
        setCachedStatus(status)
        
        return TrialResult(
            trialClaimed: response.trialClaimed,
            alreadyClaimed: response.alreadyClaimed,
            expired: response.expired,
            token: token,
            claimedAt: claimedAt ?? trialClaims.issuedAt,
            expiresAt: expiresAt ?? trialClaims.expirationDate,
            features: response.features
        )
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
        
        let response = try await retryCoordinator.execute(scenario: .foregroundActivation) {
            try await self.apiClient.activate(request: request)
        }
        
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
    /// 遵循 Fail-Silent 原则：
    /// - 若当前本地主状态可用，遇网络超时、服务端 5xx、429 或 Session 熔断，一律静默保底，维持本地主状态可用，零弹窗零干扰；
    /// - 若当前本地主状态已不可用（已过期/试用结束），保持原判并抛出异常，绝不伪造放行。
    @discardableResult
    public func validate() async throws -> ValidationResult {
        return try await executeValidation(scenario: .backgroundSync)
    }
    
    /// 前台主动刷新授权（供用户在界面点击【刷新授权】或【检查续费】时调用）
    /// 遵循前台交互语义：
    /// - 重置当前 Session 熔断，采用前台重试策略 (foregroundActivation)；
    /// - 成功获取新 Token 后更新本地凭据并恢复主状态；
    /// - 若网络不可用或服务端故障，直接抛出异常供 UI 弹窗或 Toast 提示，主状态继续维持不变。
    @discardableResult
    public func refresh() async throws -> ValidationResult {
        retryCoordinator.resetSessionBlock()
        return try await executeValidation(scenario: .foregroundActivation)
    }
    
    private func executeValidation(scenario: RequestScenario) async throws -> ValidationResult {
        let fingerprint = try await fingerprintProvider.getFingerprint()
        
        guard let creds = try credentialStore.loadCredentials(for: fingerprint) else {
            throw LicenKitError.unactivated
        }
        
        // 读取当前本地离线客观主状态
        let currentStatus = (try? await verifyOffline()) ?? .expired(claims: nil)
        if case .untrusted(let reason) = currentStatus {
            throw LicenKitError.cryptoError(reason)
        }
        
        do {
            if creds.isTrial {
                // 统一通过调度器执行 Trial 探活
                let trialResponse = try await retryCoordinator.execute(scenario: scenario) {
                    let request = ApiTrialRequest(
                        accountId: self.configuration.accountId,
                        productId: self.configuration.productId,
                        fingerprint: fingerprint
                    )
                    return try await self.apiClient.requestTrial(request: request)
                }
                
                let isValid = !trialResponse.expired && trialResponse.token != nil
                if !isValid {
                    if trialResponse.expired {
                        setCachedStatus(.trialExpired(claims: currentStatus.trialClaims))
                    } else {
                        _ = try? await verifyOffline()
                    }
                    return ValidationResult(
                        valid: false,
                        token: trialResponse.token,
                        tokenExpiresAt: trialResponse.expiresAt?.date,
                        licenseExpiresAt: trialResponse.expiresAt?.date,
                        reason: "Trial expired"
                    )
                }
                
                let updatedToken = trialResponse.token ?? creds.token
                let updatedCreds = StoredCredentials(
                    licenseKey: creds.licenseKey,
                    token: updatedToken,
                    lastValidatedAt: Date(),
                    offlineGracePeriod: creds.offlineGracePeriod,
                    policyFeatures: creds.policyFeatures,
                    machineId: creds.machineId,
                    isTrial: true
                )
                try credentialStore.saveCredentials(updatedCreds, for: fingerprint)
                _ = try? await verifyOffline()
                
                return ValidationResult(
                    valid: true,
                    token: updatedToken,
                    tokenExpiresAt: trialResponse.expiresAt?.date,
                    licenseExpiresAt: trialResponse.expiresAt?.date
                )
            } else {
                let request = ApiValidateRequest(
                    accountId: configuration.accountId,
                    licenseKey: creds.licenseKey,
                    fingerprint: fingerprint
                )
                
                let response = try await retryCoordinator.execute(scenario: scenario) {
                    try await self.apiClient.validate(request: request)
                }
                
                let tokenExpiresAt = response.tokenExpiresAt?.date
                let licenseExpiresAt = response.licenseExpiresAt?.date
                
                // 若服务端明确业务拒绝 (valid == false) -> 严厉封锁置为 untrusted
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
                if let newToken = response.token, !newToken.isEmpty {
                    updatedToken = newToken
                }
                
                let updatedCreds = StoredCredentials(
                    licenseKey: creds.licenseKey,
                    token: updatedToken,
                    lastValidatedAt: Date(),
                    offlineGracePeriod: creds.offlineGracePeriod,
                    policyFeatures: creds.policyFeatures,
                    machineId: creds.machineId,
                    isTrial: false
                )
                try credentialStore.saveCredentials(updatedCreds, for: fingerprint)
                _ = try? await verifyOffline()
                
                return ValidationResult(
                    valid: true,
                    token: updatedToken,
                    tokenExpiresAt: tokenExpiresAt,
                    licenseExpiresAt: licenseExpiresAt,
                    reason: response.reason
                )
            }
        } catch let error as LicenKitError {
            // 1. 业务级显式失效 (如 LICENSE_NOT_FOUND, MACHINE_REVOKED) -> 坚决封锁，不走降级
            if error.isExplicitBusinessRejection {
                setCachedStatus(.untrusted(reason: "License no longer valid on server"))
                throw error
            }
            
            // 2. 基础设施/网络/5xx/限流/Session 熔断
            if scenario == .backgroundSync {
                // 后台探活：Fail-Silent 保底
                if currentStatus.isValid {
                    return ValidationResult(
                        valid: true,
                        token: creds.token,
                        tokenExpiresAt: currentStatus.expirationDate,
                        licenseExpiresAt: currentStatus.expirationDate,
                        reason: "Fail-silent: server unavailable, retaining valid offline status"
                    )
                } else {
                    // 本地已明确过期：维持不可用，绝不伪造放行
                    throw error
                }
            } else {
                // 前台主动刷新：抛出网络异常供 UI 明确处理
                throw error
            }
        } catch {
            if scenario == .backgroundSync && currentStatus.isValid {
                return ValidationResult(
                    valid: true,
                    token: creds.token,
                    tokenExpiresAt: currentStatus.expirationDate,
                    licenseExpiresAt: currentStatus.expirationDate,
                    reason: "Fail-silent: server unavailable, retaining valid offline status"
                )
            }
            throw error
        }
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
        
        if let creds = savedCreds, let fp = fingerprint, !creds.isTrial, !creds.licenseKey.isEmpty {
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
