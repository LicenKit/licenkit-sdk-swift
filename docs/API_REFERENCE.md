# Swift SDK V1 API

本文记录当前源码的公共 API。示例与类型可以证明本地源码合同，但不代表这个版本已经发布，也不代表服务端已经部署。

## 配置与入口

```swift
public struct LicenKitConfiguration: Sendable {
    public let serverURL: URL
    public let productID: String
    public let signingPublicKey: String?

    public init(
        serverURL: URL,
        productID: String,
        signingPublicKey: String? = nil
    )
}

public final class LicenKit: @unchecked Sendable {
    public static let minimumValidationRequestInterval: TimeInterval
    public static func configure(with configuration: LicenKitConfiguration)
    public static var shared: LicenKit { get }

    public init(configuration: LicenKitConfiguration)

    public var currentSnapshot: EntitlementSnapshot? { get }

    public func activate(
        licenseKey: String,
        machineName: String? = nil
    ) async -> LicenKitResult<ActivationData>

    public func startTrial() async -> LicenKitResult<EntitlementSnapshot>
    public func validate() async -> LicenKitResult<EntitlementSnapshot>
    public func deactivate() async -> LicenKitResult<DeactivationData>
    public func hasFeature(_ feature: String) -> Bool
    public func getMachineFingerprint() async throws -> String
}
```

`productID` 是 Admin 产品页展示的全局唯一产品标识，Server 据此解析租户边界，客户端不再传入 `instanceID`。

`signingPublicKey` 是 Admin 产品页交付的 Ed25519 公钥，支持原始 32 字节公钥的 Base64，或 Ed25519 SPKI PEM/Base64。仅使用 `opaque` 凭证时可以省略；`signed` 凭证需要它完成离线验签。当前公共 API 只接受一个公钥，不把服务端下载的数据自动提升为信任根。

构建身份不再由业务代码传入。SDK 从宿主 App Bundle 的 `CFBundleShortVersionString` 读取版本号，将操作系统标识为 `macos`，并根据主可执行文件架构单独推导 `arm64`、`x86_64` 或 `universal`；无法取得时返回 `.configurationError`。请求使用独立的 `release_version`、`release_platform` 与 `release_arch` 字段。请求超时固定为 SDK 内部的 15 秒，Keychain 使用当前 App 私有命名空间，不暴露 Access Group。

`currentSnapshot` 是进程内最近加载或写入的状态；初始化不会同步读取 Keychain。App 启动后应调用 `validate()` 完成恢复与必要的联网校验。

## 操作结果

```swift
public enum LicenKitResult<Value: Sendable>: Sendable {
    case success(value: Value, metadata: OperationMetadata)
    case notPerformed(
        reason: NotPerformedReason,
        cachedValue: Value?,
        metadata: OperationMetadata
    )
    case failure(
        error: LicenKitError,
        lastKnownValue: Value?,
        metadata: OperationMetadata
    )
}

public enum NotPerformedReason: Equatable, Sendable {
    case cooldown
}

public struct OperationMetadata: Equatable, Sendable {
    public let source: StateSource
    public let requestID: String?
    public let validatedAt: Date?
    public let receivedValidationInterval: TimeInterval?
    public let effectiveValidationInterval: TimeInterval?
    public let lastValidateResponseAt: Date?
}
```

- `.success`：操作已完成；仍须读取快照中的业务状态，不能把 HTTP 成功等同于授权可用。
- `.notPerformed(.cooldown, ...)`：`validate()` 命中适用的请求门槛，因此没有发起新请求。这不表示 SDK 安排了稍后的自动请求。
- `.failure`：调用失败；`lastKnownValue` 是诊断和展示上下文，不是本次成功结果。

## 授权状态

```swift
public enum EntitlementState: Codable, Equatable, Sendable {
    case activationRequired(trial: TrialAvailability)
    case trial(TrialEntitlement)
    case license(LicenseEntitlement)
    case licenseNotValidForVersion(
        code: String,
        updatesUntil: Date,
        releaseVersion: String,
        releasePlatform: String,
        releaseArch: String,
        releasedAt: Date
    )
    case unknown
}

public enum TrialAvailability: Codable, Equatable, Sendable {
    case available(duration: TimeInterval, features: [String])
    case unavailable(reason: TrialUnavailableReason)
    case unknown
}

public enum TrialUnavailableReason: Codable, Equatable, Sendable {
    case notEnabled
    case alreadyClaimed
}

public enum TrialEntitlement: Codable, Equatable, Sendable {
    case active(expiresAt: Date, features: [String])
    case expired(expiresAt: Date)
    case revoked(reason: String?)
}

public enum LicenseEntitlement: Codable, Equatable, Sendable {
    case active(terms: LicenseTerms, expiresAt: Date?)
    case expired(expiresAt: Date?)
    case suspended(reason: String?)
    case revoked(reason: String?)
    case activationRevoked
    case activationDeactivated
}

```

`licenseNotValidForVersion` 只表达 Server 已查到对应 Product Release，且它的发布时间晚于永久授权的 `updates_until`。`updatesUntil` 与 `releasedAt` 是服务端得出该结论的必要事实，因此不是可选值；缺失时 SDK 返回协议错误，不构造残缺状态。没有登记 Release 时 Server 按宽容策略继续校验，不产生“未知版本”状态。Product 不存在或已归档仍返回 `.failure` 中的服务端原始错误，而不是扩充 `TrialUnavailableReason`。

## 快照、新鲜度与功能

```swift
public enum StateSource: String, Codable, Equatable, Sendable {
    case server
    case cache
    case signedLocal
    case local
}

public enum EntitlementFreshness: Equatable, Sendable {
    case fresh(until: Date)
    case validationRequired(since: Date?)
    case unknown
}

public struct EntitlementSnapshot: Codable, Equatable, Sendable {
    public let state: EntitlementState
    public let source: StateSource
    public let validatedAt: Date?
    public let receivedValidationInterval: TimeInterval?
    public let effectiveValidationInterval: TimeInterval?
    public let signedLicenseTokenExpiresAt: Date?
    public let lastValidateResponseAt: Date?
    public let signedCredentialValid: Bool?
    public let businessCode: String?
    public let details: [String: String]

    public func freshness(at now: Date = Date()) -> EntitlementFreshness
    public func isUsable(at now: Date = Date()) -> Bool
    public func hasFeature(_ feature: String, at now: Date = Date()) -> Bool
}
```

收到的在线校验间隔为 `nil` 时采用 3600 秒，并限制到 3600 至 86400 秒。活动授权的 `fresh(until:)` 不晚于业务到期、业务状态校验窗口或 Signed Token 到期中的任一时间。只有活动状态且仍 fresh 时，`isUsable` 才返回 `true`；`hasFeature` 还要求功能名存在于 Trial features 或 License terms 中。

请求冷却与业务新鲜度分开保存。`lastValidateResponseAt` 是两个门槛的共同起点；`signedCredentialValid` 为 `true/false` 时表示本地 Signed 凭据本轮验证成功/失败，非 Signed 或尚无结论时可以为空。`validate()` 的普通路径必须同时越过 Server 建议间隔和公开常量 `minimumValidationRequestInterval`（当前为 30 秒）；Signed Token 过期或本地验证失败时只绕过建议间隔。合法业务成功和明确 HTTP 失败会推进最近响应时间；无 HTTP 响应的传输失败与 2xx 非法业务数据不会推进。HTTP 失败不推进 `validatedAt`。`activate()`、`startTrial()`、`deactivate()` 不受这些门槛约束，也不启动冷却。

`businessCode` 与 `details` 保存业务终态的原始诊断信息；其中敏感字段按字段递归脱敏。

## 写操作返回值

```swift
public struct ActivationData: Equatable, Sendable {
    public let activationID: String
    public let credentialMode: CredentialMode
    public let snapshot: EntitlementSnapshot
}

public struct DeactivationData: Equatable, Sendable {
    public let wasDeactivated: Bool
    public let snapshot: EntitlementSnapshot
}
```

本地没有 License 凭据时，`deactivate()` 返回成功的 `wasDeactivated=false` 和 `source=.local` 快照；它不会声称发生过远端解绑。远端失败时返回 `.failure` 并保留凭据。

## License Terms

```swift
public enum CredentialMode: String, Codable, Equatable, Sendable {
    case opaque
    case signed
}

public struct LicenseTerms: Codable, Equatable, Sendable {
    public let maxActivations: Int
    public let features: [String]
    public let updatesUntil: FlexibleDate?
}
```

`LicenseEntitlement.active.expiresAt` 是服务端计算的最终有效期；对支付型订阅已包含支付宽限期，客户端不得再次叠加。

## 错误

```swift
public enum LicenKitError: Error, LocalizedError, Equatable, Sendable {
    case unactivated
    case trialNotStarted
    case apiError(
        statusCode: Int,
        code: String,
        message: String,
        requestID: String?,
        details: [String: String]
    )
    case transportError(
        kind: TransportErrorKind,
        underlyingDescription: String
    )
    case configurationError(reason: String)
    case missingSigningPublicKey(keyID: String)
    case invalidSignedLicenseToken(reason: String)
    case credentialStorageError(operation: String, status: Int32)
    case fingerprintError(reason: String)
    case protocolError(reason: String)
}

public enum TransportErrorKind: Equatable, Sendable {
    case network
    case dns
    case tls
    case timeout
    case server(
        statusCode: Int,
        code: String?,
        requestID: String?,
        details: [String: String]
    )
    case invalidResponse(statusCode: Int?, requestID: String?)
}
```

HTTP 5xx 归为传输错误，但保留响应中的安全 `code/requestID/details`；4xx 业务拒绝使用 `.apiError`。服务端已经确认的 License/Trial/Release 终态位于 `.success` 的快照，不再通过错误分支表达。

## Signed License Token

Token 是紧凑 JWS：

- Header 固定要求 `alg=EdDSA`、`typ=licenkit-license+jwt` 与已知 `kid`；
- Claims 要求 `lic`、`act`、`ins`、`prd`、`ver`、`plt`、`arc`、`fp`、`iat`、`exp`、`lexp`、`upd`、`fea`；
- `prd/act/fp/ver/plt/arc` 必须与当前 Product、Activation、设备和 SDK 自动读取的构建身份一致；`ins` 由 Server 签发并保留为服务端租户信息，不要求宿主 App 再配置一份；
- 响应外层 Signed Token 到期时间必须与签名内绝对 `exp` 相同；
- Active License 的 features、`updates_until` 和最终到期时间必须与签名 Claims 相同；
- `lexp` 可为空表示永久 License；`upd` 可为空表示不限制未来版本；
- Token 不携带 Product Release ID 或 `released_at`；更新权益是否覆盖当前版本由 Server 在线校验，SDK 不用 `upd` 在本地重复推导发布时间规则；
- Claims 不包含 Registration Key。

Plan 的 `signed_token_ttl_seconds` 只用于 Server 计算绝对 `exp`：它取“签发时间 + License 快照 TTL”与 License 最终有效截止时间（如有）中的较早值；billing 模式的最终截止时间已包含支付宽限。原始 TTL 不进入 Token，也不要求覆盖 3600 秒建议间隔。Token 先到期时，后续 `validate()` 绕过建议间隔但仍受 30 秒门槛。SDK 不从 Token 自报算法选择验证器，也不把运行时下载的公钥自动提升为信任根。
