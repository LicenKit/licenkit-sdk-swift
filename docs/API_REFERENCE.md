# Swift SDK V1 API

## 配置

```swift
public struct LicenKitConfiguration: Sendable {
    public let serverURL: URL
    public let accountID: String
    public let productID: String
    public let releaseVersion: String
    public let releasePlatform: String
    public let trustedSigningKeys: [String: String]
    public let timeoutInterval: TimeInterval
    public let accessGroup: String?
}
```

Release 版本与工件平台属于构建身份，不接收客户端自报发布时间。`trustedSigningKeys` 是随 App 受信发布链交付的 key ID 到 Ed25519 公钥映射。

## Facade

```swift
public func activate(licenseKey: String, machineName: String? = nil) async throws -> ActivationResult
public func validate() async throws -> LicenseStatus
public func checkLocalStatus() async throws -> LicenseStatus
public func startTrial() async throws -> LicenseStatus
public func validateTrial() async throws -> LicenseStatus
public func deactivate() async throws -> DeactivationResult
public func clearLocalTrial() async throws
public func hasFeature(_ feature: String) -> Bool
```

`activate` 不长期保存注册码。`validate` 不把网络失败转换成有效、过期或吊销状态。`deactivate` 仅在服务端确认解绑后清除本地凭据。

## 状态

```swift
public enum LicenseStatus: Equatable, Sendable {
    case unactivated
    case validOnline(terms: LicenseTerms)
    case trialValidOnline(expiresAt: Date, features: [String])
    case validLocally(claims: LicenseClaims)
    case temporarilyUnverified(lastValidatedAt: Date, cachedTerms: LicenseTerms?)
    case onlineValidationRequired
    case suspended(reason: String?)
    case expired(expiresAt: Date?)
    case productReleaseUnknown(version: String, platform: String)
    case updateEntitlementRequired(updatesUntil: Date, releaseVersion: String, releasedAt: Date)
    case revoked(reason: String?)
    case activationRevoked
    case trialExpired(expiresAt: Date)
    case trialRevoked(reason: String?)
    case untrusted(reason: String)
}
```

只有 `validOnline`、`trialValidOnline` 和 `validLocally` 的 `isUsable` 为 `true`。宿主 App 可以自行处理 `.temporarilyUnverified`，但 SDK 不默认把它视为有效授权。

## Signed License Token

Token 是紧凑 JWS：

- Header 固定要求 `alg=EdDSA`、`typ=licenkit-license+jwt` 与已知 `kid`；
- Claims 要求 `lic`、`act`、`acc`、`prd`、`rel`、`ver`、`plt`、`rat`、`fp`、`iat`、`exp`、`lexp`、`upd`、`fea`；
- `lexp` 可为空表示永久 License；`upd` 可为空表示不限制未来版本；
- SDK 验证 `ver` 与 `plt` 等于当前构建，并要求 `rat <= upd`；
- Claims 不包含注册码。

## 错误

```swift
public enum LicenKitError: Error, Equatable, Sendable {
    case apiError(code: String, message: String, requestID: String?, details: [String: String])
    case transportError(kind: TransportErrorKind, underlyingDescription: String)
    case missingTrustedSigningKey(keyID: String)
    case invalidSignedLicenseToken(reason: String)
    case releaseNotQualified(status: LicenseStatus)
    case credentialStorageError(operation: String, status: Int32)
    // 另含未激活、试用未开始、指纹与协议错误。
}
```

HTTP 5xx 属于 `.transportError(.server(...))`，其中仍保存安全可记录的服务端 code、request ID 和 details；4xx 业务拒绝通过 `.apiError` 原样到达宿主 App。`LICENSE_CHECKOUT_VERIFICATION_ONLY` 不会被归一化为过期或无效注册码。

## Trial

Product/设备 Trial Claim 使用独立 `trialID + trialToken` Keychain 记录和 `/trials/claim`、`/trials/validate` 在线接口。Trial 没有 `.validLocally`。Paddle 免费订阅试用得到普通 License Key，应调用 `activate()`，不调用 Trial Claim API。
