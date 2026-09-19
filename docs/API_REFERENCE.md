# Swift SDK 目标 API 合同

> 以下接口是 V1 目标设计，当前源码尚未全部对齐。

## 1. 配置

```swift
public struct LicenKitConfiguration: Sendable {
    public let serverURL: URL
    public let accountID: String
    public let productID: String
    public let trustedSigningKeys: [String: String]
    public let timeoutInterval: TimeInterval
    public let accessGroup: String?

    public init(
        serverURL: URL,
        accountID: String,
        productID: String,
        trustedSigningKeys: [String: String] = [:],
        timeoutInterval: TimeInterval = 15,
        accessGroup: String? = nil
    )
}
```

## 2. Facade

```swift
public final class LicenKit: Sendable {
    public static func configure(with configuration: LicenKitConfiguration)
    public static var shared: LicenKit { get }

    public func activate(licenseKey: String, machineName: String? = nil) async throws -> ActivationResult
    public func checkLocalStatus() async throws -> LicenseStatus
    public func validate() async throws -> LicenseStatus
    public func deactivate() async throws -> DeactivationResult
    public func hasFeature(_ feature: String) async throws -> Bool
}
```

## 3. 激活结果

```swift
public struct ActivationResult: Sendable, Equatable {
    public let activationID: String
    public let verificationMode: VerificationMode
    public let status: LicenseStatus
}

public enum VerificationMode: String, Codable, Sendable {
    case online
    case signedOffline = "signed_offline"
}
```

## 4. License 状态

```swift
public enum LicenseStatus: Sendable, Equatable {
    case unactivated
    case validOnline(terms: LicenseTerms)
    case validOffline(claims: LicenseClaims)
    case temporarilyUnverified(lastValidatedAt: Date, cachedTerms: LicenseTerms?)
    case onlineValidationRequired
    case suspended(reason: String?)
    case expired(expiresAt: Date?)
    case revoked(reason: String?)
    case activationRevoked
    case untrusted(reason: String)
}
```

`validOffline` 只在 Ed25519 验签成功后出现。

## 5. 授权条款

```swift
public struct LicenseTerms: Codable, Sendable, Equatable {
    public let maxActivations: Int
    public let features: [String]
    public let licenseExpiresAt: Date?
    public let offlineTokenExpiresAt: Date?
}
```

SDK 不暴露或修改 License Plan。这里只表示当前 License 已固化并由服务端返回的条款。

## 6. Offline Token Claims

```swift
public struct LicenseClaims: Codable, Sendable, Equatable {
    public let licenseID: String
    public let activationID: String
    public let accountID: String
    public let productID: String
    public let fingerprint: String
    public let issuedAt: Date
    public let tokenExpiresAt: Date
    public let licenseExpiresAt: Date?
    public let features: [String]
    public let signingKeyID: String
}
```

Claims 不包含注册码。

## 7. 解绑结果

```swift
public enum DeactivationResult: Sendable, Equatable {
    case completed
    case remoteFailed(localCredentialsPreserved: Bool, error: LicenKitError)
}
```

如果 Swift 的递归 Equatable 或 Error 设计导致实现不合理，可以移除 Equatable，但不能移除远端失败与本地状态的区分。

## 8. 错误

```swift
public enum LicenKitError: Error, Sendable {
    case notConfigured
    case invalidConfiguration(String)
    case missingTrustedSigningKey(keyID: String)
    case invalidOfflineToken(reason: String)
    case apiError(
        code: String,
        message: String,
        requestID: String?,
        details: [String: String]
    )
    case transportError(kind: TransportErrorKind, description: String)
    case credentialStorageError(operation: String, status: Int32)
    case decodingError(description: String)
}
```

服务端新增错误码时，SDK 应通过 `apiError` 保留原值，不得因为本地枚举未更新而降级成没有来源的 unknown error。

## 9. 兼容边界

V1 是不承诺源码兼容的主版本重构。以下旧接口可以直接调整：

- `publicKey: String` 必填改为 `trustedSigningKeys` 可空；
- `verifyOffline()` 改为 `checkLocalStatus()`；
- ActivationResult 和 LicenseStatus 重新表达两种模式；
- 停止保存 roaming license key；
- `deactivate()` 不再静默吞掉远端错误。
