# Swift SDK V1 API

本文记录当前源码的公共 API。示例与类型可以证明本地源码合同，但不代表这个版本已经发布，也不代表服务端已经部署。

## 配置与入口

```swift
public struct LicenKitConfiguration: Sendable {
    public let serverURL: URL
    public let productID: String
    public let signingPublicKey: String?
    public let environment: LicenKitEnvironment

    public init(
        serverURL: URL,
        productID: String,
        signingPublicKey: String? = nil,
        environment: LicenKitEnvironment = .live
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
    public func restoreLocalEntitlement() async -> LocalEntitlementResult
    public func validate(trigger: ValidationTrigger) async -> LicenKitResult<EntitlementSnapshot>
    @available(*, deprecated) public func validate() async -> LicenKitResult<EntitlementSnapshot>
    public func deactivate() async -> DeactivationResult
    public func hasFeature(_ feature: String) -> Bool
    public func getMachineFingerprint() async throws -> String
}
```

`productID` 是 Admin 产品页展示的全局唯一产品标识，Server 据此解析租户边界，客户端不再传入 `instanceID`。

`signingPublicKey` 是 Admin 产品页交付的 Ed25519 公钥，支持原始 32 字节公钥的 Base64，或 Ed25519 SPKI PEM/Base64。仅使用 `opaque` 凭证时可以省略；`signed` 凭证需要它完成离线验签。当前公共 API 只接受一个公钥，不把服务端下载的数据自动提升为信任根。

`environment` 是宿主 App 构建时确定的运行环境。正式版默认 `.live`，Sandbox 测试版必须显式使用 `.sandbox`。SDK 在激活、在线校验请求中提交该配置，核对响应与本地缓存中的 License 环境，并在 `signed` 模式核对签名令牌的 `env` Claim。两种环境使用不同的 Keychain Service；旧版未标记环境的 Live 凭证继续按 `.live` 读取。服务端会独立检查 License 已固化的环境，HTTP 请求中的环境声明本身不能替代宿主 App 对构建配置的可信管理。

构建身份不再由业务代码传入。SDK 从宿主 App Bundle 的 `CFBundleShortVersionString` 读取版本号，将操作系统标识为 `macos`，并根据主可执行文件架构单独推导 `arm64`、`x86_64` 或 `universal`；无法取得时返回 `.configurationError`。请求使用独立的 `release_version`、`release_platform` 与 `release_arch` 字段。请求超时固定为 SDK 内部的 15 秒，Keychain 使用当前 App 私有命名空间，不暴露 Access Group。

`currentSnapshot` 是进程内最近加载或写入的状态；初始化不会同步读取 Keychain，也不能单独作为冷启动放行依据。App 启动时先等待 `restoreLocalEntitlement()` 的本机结论，再在后台调用 `validate(trigger: .silent)`；进入前台、网络恢复时也可静默复核。用户点击“检查授权”“重试”时调用 `validate(trigger: .userInitiated)`。无参数 `validate()` 暂时按 `.silent` 执行，并已弃用。

### 冷启动本机结论

```swift
public enum LocalEntitlementResult: Equatable, Sendable {
    case usable(snapshot: EntitlementSnapshot)
    case confirmedBlocked(snapshot: EntitlementSnapshot)
    case verificationRequired(reason: LocalEvidenceIssue)
}

public enum LocalEvidenceIssue: Equatable, Sendable {
    case noCredential
    case noMatchingSnapshot
    case expired
    case invalidCredential(LicenKitError)
    case storageFailure(LicenKitError)
    case invalidSnapshot(LicenKitError)
    case deactivationPending(phase: DeactivationAttemptPhase)
}
```

本机调用自身不发网络请求；它与其他 SDK 操作按调用顺序串行，因此冷启动时应先等待本机结论，再启动在线复核。本机结论不代替后续在线复核。`.usable` 只在当前凭据与 SDK 保存的服务端快照绑定、业务期限未到，且 Signed 凭据通过签名、设备、构建身份与快照一致性校验时返回。`.confirmedBlocked` 仅恢复此前保存的服务端业务阻断。无凭据、凭据与快照不匹配、旧版未保存绑定的快照、Keychain 错误、业务期限已到或远端已确认解绑但本机尚未清理，都不能从本机证据放行；原始错误随 `LocalEvidenceIssue` 保留。解绑请求的远端结果未知时，已有可信本机授权仍可恢复，待确认记录继续保存。旧快照会在后续成功在线复核后写入新的绑定记录。

`opaque` License 和 Trial 的本机证据依赖 SDK 曾写入 Keychain 的服务端快照与凭据一致性；它们没有可独立验签的权益载荷。远端解绑已确认且没有剩余 Trial 时，本机恢复可返回 `.confirmedBlocked`，但快照仍标记 `source=.local`：它表示依据远端解绑事实构造的“需要激活”，不宣称 Server 已确认 Trial 资格。宿主应把该结果映射到自己的访问决策，随后消费 `validate(trigger:)` 的结果；`notPerformed.cachedValue` 和 `failure.lastKnownValue` 只提供上下文，不能替代本机证据判定。

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
    case minimumInterval(retryAfter: TimeInterval)
    case productInterval(nextEligibleAt: Date)
    public var code: String { get }
}

public enum ValidationTrigger: Equatable, Sendable {
    case silent
    case userInitiated
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
- `.notPerformed(.minimumInterval(retryAfter:), ...)`：距上次真正发出的 `/validate` 请求尚未满 30 秒，`code` 为 `SDK_VALIDATION_MIN_INTERVAL`。用户主动操作时可提示稍后重试。
- `.notPerformed(.productInterval(nextEligibleAt:), ...)`：静默调用距上次明确服务端响应尚未达到 Product 间隔，`code` 为 `SDK_VALIDATION_PRODUCT_INTERVAL`。用户主动调用不会得到此结果。这两种结果都没有发起新请求，也没有 Request ID；服务端 HTTP 429 仍按原始错误返回 `.failure`。
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
    case offlineGrace(until: Date)
    case offlineGraceExceeded(since: Date)
    case validationRequired(since: Date?)
    case unknown
}

public struct EntitlementSnapshot: Codable, Equatable, Sendable {
    public let state: EntitlementState
    public let source: StateSource
    public let validatedAt: Date?
    public let receivedValidationInterval: TimeInterval?
    public let effectiveValidationInterval: TimeInterval?
    public let offlineGracePeriod: TimeInterval?
    public let lastValidateResponseAt: Date?
    public let signedCredentialValid: Bool?
    public let businessCode: String?
    public let details: [String: String]

    public func freshness(at now: Date = Date()) -> EntitlementFreshness
    public func isUsable(at now: Date = Date()) -> Bool
    public func hasFeature(_ feature: String, at now: Date = Date()) -> Bool
}
```

在线校验间隔由服务端必填，范围为 3600 至 86400 秒。间隔内为 `fresh`；间隔后、License 离线宽限期前为 `offlineGrace`；超过宽限期为 `offlineGraceExceeded`。新鲜度不决定可用性：活动状态在业务未到期且 Signed 凭据未被判定无效时，`isUsable` 仍返回 `true`；`hasFeature` 还要求功能名存在于 Trial features 或 License terms 中。

请求门槛与业务新鲜度分开保存。固定 30 秒从持久化的最近一次实际 `/validate` 请求发出时间计算；请求即使超时、断网或收到非法正文，也会启动这条门槛。升级前没有请求记录的旧快照暂用 `lastValidateResponseAt` 保留其尚未结束的 30 秒窗口。Product 间隔只在静默调用时，从 `lastValidateResponseAt` 计算；合法业务成功与明确 HTTP 失败推进该时间，无 HTTP 响应与非法 2xx 正文不推进。HTTP 失败不推进 `validatedAt`。

用户主动调用始终豁免 Product 间隔。静默调用在缓存的 active Trial/License 首次跨过已知业务截止时间、宿主 Release 版本/平台/架构变化后首次复核，或 Signed Token 本地失效时也豁免。已缓存的 active Signed License 因时间流逝跨过签名 Claims 中相同的业务截止时间时，先停止本机放行，再进入在线复核；真正的签名、字段或快照不一致仍保留原始错误。到期和构建身份变化的豁免只各触发一次请求尝试；收到服务端到期终态或一次失败后，不因同一个事实持续静默请求。旧快照缺少构建身份时允许一次提前复核；该迁移不会自行改变缓存授权的可用性。缺少或无效的内置签名公钥属于配置错误，保留原始诊断，不靠在线重试修复。`activate()`、`startTrial()`、`deactivate()` 不受这些门槛约束，也不启动冷却。

自定义 `CredentialStore` 实现需要读写 `StoredValidationAttempt` 与 `StoredDeactivationAttempt`。前者按 Product 与设备指纹保存请求发出时间及当前 Release 身份，不包含 License Key 或 Token；后者在 Keychain 中保存解绑恢复所需的 Activation ID、Machine Token、阶段与可用的 Request ID。`StoredEntitlementSnapshot.validatedBuild`、`credentialBinding` 与 `confirmedRemoteDeactivation` 均为可选字段，以便解码升级前的快照；缺少凭据绑定时不会立即提供本机可用结论。

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

public enum DeactivationResult: Equatable, Sendable {
    case success(value: DeactivationData, metadata: OperationMetadata)
    case remoteConfirmedLocalRepairRequired(
        stage: DeactivationRepairStage,
        error: LicenKitError,
        metadata: OperationMetadata
    )
    case failure(
        error: LicenKitError,
        remoteOutcome: DeactivationRemoteOutcome,
        lastKnownSnapshot: EntitlementSnapshot?,
        metadata: OperationMetadata,
        localRecoveryError: LicenKitError?
    )
}
```

本地没有 License 凭据且没有待恢复记录时，`deactivate()` 返回成功的 `wasDeactivated=false`；已有的无凭据服务端阻断或远端解绑确认记录会保留，否则返回 `source=.local` 的新快照。它不会声称本次发生了远端解绑。请求前无法保存恢复记录时返回 `remoteOutcome=.notRequested`，且不发请求。收到明确的 4xx 拒绝时返回 `.rejected`，尝试清除恢复记录并保留原凭据；若清理记录也失败，`localRecoveryError` 单独保留该错误。请求已发出但没有可靠确认时返回 `.unknown`，恢复记录在重启后仍可用于重试 `deactivate()`，使用原 Machine Token 确认远端结果；已有可信本机授权可以继续使用，并可调用 `validate(trigger:)` 更新授权状态。

远端确认后如清凭据、读取剩余 Trial 或保存快照失败，返回 `.remoteConfirmedLocalRepairRequired`，其中的 `stage`、原始 `error` 和 `metadata.requestID` 分别表达失败步骤、本地错误和远端请求。失败分支的 `lastKnownSnapshot` 仅用于诊断，不携带可能被误解为本次结果的 `wasDeactivated=false`。重试 `deactivate()` 会完成本机清理；服务端已确认的重复解绑是可重试的。远端已确认而恢复记录未清除前，`restoreLocalEntitlement()` 返回 `.deactivationPending`；待确认或已确认的恢复记录会阻止新的激活与 Trial 领取，以便先完成解绑恢复。

如果写入“远端已确认”阶段本身失败，当前进程仍返回带原始错误与 Request ID 的 `.remoteConfirmedLocalRepairRequired(stage: .recordConfirmation)`，并立即撤销进程内旧授权。重启后持久化记录只剩“请求已发出”，无法从本机判断服务端是否已完成解绑；按待确认策略，旧的可信本机授权可能暂时恢复。此时重试 `deactivate()` 会用原 Machine Token 再次确认服务端结果。若本机存储一直不可写，SDK 无法跨进程可靠保存远端确认事实。

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
- Claims 要求 `lic`、`act`、`ins`、`prd`、`ver`、`plt`、`arc`、`fp`、`iat`、`lexp`、`upd`、`fea`；未知 Claim（包括旧 `exp`）按协议错误拒绝；
- `prd/act/fp/ver/plt/arc` 必须与当前 Product、Activation、设备和 SDK 自动读取的构建身份一致；`ins` 由 Server 签发并保留为服务端租户信息，不要求宿主 App 再配置一份；
- Active License 的 features、`updates_until` 和最终到期时间必须与签名 Claims 相同；
- `lexp` 可为空表示永久 License；`upd` 可为空表示不限制未来版本；
- Token 不携带 Product Release ID 或 `released_at`；更新权益是否覆盖当前版本由 Server 在线校验，SDK 不用 `upd` 在本地重复推导发布时间规则；
- Claims 不包含 Registration Key。

Product 的 `validation_interval_seconds` 控制在线复核尝试频率；Plan 的 `offline_grace_seconds` 在签发时固化到 License，超过后只产生 `offlineGraceExceeded` 强提示。两者都不是 Signed Token 独有规则，也都不会单独使授权不可用。SDK 不从 Token 自报算法选择验证器，也不把运行时下载的公钥自动提升为信任根。
