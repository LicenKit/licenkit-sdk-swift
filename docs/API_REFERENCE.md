# LicenKit Swift SDK API 规范与参考手册

本文档提供 **LicenKit Swift SDK** 的所有公开类、结构体、枚举与异步接口的详细签名与调用说明。

---

## 1. 核心门面：`LicenKit`

`LicenKit` 是宿主应用接入 SDK 的主入口，采用现代 Swift 并发与线程安全设计。

```swift
public final class LicenKit: @unchecked Sendable
```

### 1.1 静态配置与共享实例

#### `configure(with configuration: LicenKitConfiguration)`
初始化全局共享的 LicenKit 实例。

```swift
public static func configure(with configuration: LicenKitConfiguration)
```
- **参数**：
  - `configuration`: 初始化配置对象。
- **说明**：通常在应用入口或启动委托中调用一次。重复调用将使用新配置覆盖全局实例。

#### `shared`
获取已初始化的全局共享实例。

```swift
public static var shared: LicenKit { get }
```
- **异常**：若在调用 `configure(with:)` 之前访问，将抛出断言或致命错误（`fatalError`）。

---

### 1.2 核心操作接口

#### `verifyOffline() async throws -> LicenseStatus`
纯本地、脱网执行 Ed25519 签名核验与硬件指纹比对，0 网络延迟。自动兼容正式版商业许可证与免费试用版 Token。

```swift
public func verifyOffline() async throws -> LicenseStatus
```
- **返回值**：当前许可证状态枚举 `LicenseStatus`（如 `.valid`、`.trial`、`.inGracePeriod` 等）。
- **可能抛出的错误**：
  - `LicenKitError.unactivated`: 本地 Keychain 中无任何凭据。
  - `LicenKitError.invalidToken(reason)`: 凭据格式损坏或反序列化失败。
  - `LicenKitError.cryptoError(reason)`: Ed25519 验签失败（公钥不匹配或内容被篡改）。

---

#### `requestTrial() async throws -> TrialResult`
向服务端申请单机免密免费试用，自动验签 `LK-TRIAL` 离线 Token 并安全保存至本地 Keychain。

```swift
public func requestTrial() async throws -> TrialResult
```
- **返回值**：`TrialResult`，包含试用认领结果、是否已认领过、过期时间及可用特性清单。
- **可能抛出的错误**：
  - `LicenKitError.apiError(code, message)`: 产品未开启试用（如 `TRIAL_NOT_AVAILABLE`）或服务异常。
  - `LicenKitError.networkError(message)`: 网络连接失败。

---

#### `activate(licenseKey: String, machineName: String? = nil) async throws -> ActivationResult`
向 LicenKit 边缘引擎在线激活当前设备席位，并持久化新凭据至 Keychain。

```swift
public func activate(licenseKey: String, machineName: String? = nil) async throws -> ActivationResult
```
- **参数**：
  - `licenseKey`: 用户输入的许可证密钥（格式：`LIC-XXXX-XXXX-XXXX-XXXX`）。
  - `machineName`: 可选，自定义设备别名（默认读取系统设备名）。
- **返回值**：`ActivationResult`，包含席位 ID、签名 Token、策略信息。
- **可能抛出的错误**：
  - `LicenKitError.apiError(code, message)`: 许可证无效、过期或已被禁用。
  - `LicenKitError.maxMachinesReached`: 授权席位已满。
  - `LicenKitError.networkError(message)`: 网络连接失败。

---

#### `validate() async throws -> ValidationResult`
在线向服务端发送探活心跳，同步最新许可证状态并自动续期本地 Token。

```swift
public func validate() async throws -> ValidationResult
```
- **返回值**：`ValidationResult`，包含探活结论、最新 Token 与过期时间。
- **说明**：建议在后台静默发起（例如在宽限期内或每日首次联网时）。若网络超时失败，SDK 不会自动使凭据失效，应用可根据 `verifyOffline()` 宽限期策略决定是否继续放行。

---

#### `deactivate() async throws`
向服务端释放当前设备绑定的席位，并原子清空本地 Keychain 中的授权凭据。

```swift
public func deactivate() async throws
```
- **说明**：通常在用户主动退出授权、换机迁移或注销账号时调用。执行完成后，再次调用 `verifyOffline()` 将返回 `unactivated`。

---

#### `hasFeature(_ featureKey: String) -> Bool`
内存级极速判断当前许可证是否被授予指定的高级特性（Feature Entitlement）。

```swift
public func hasFeature(_ featureKey: String) -> Bool
```
- **参数**：
  - `featureKey`: 特性标识字符串（例如 `"pro_export_4k"`, `"unlimited_tracks"`）。
- **返回值**：`true` 表示具备该特性授权；`false` 表示无权使用或许可证无效。

---

#### `getMachineFingerprint() async throws -> String`
直接获取当前设备的硬件指纹识别码。

```swift
public func getMachineFingerprint() async throws -> String
```
- **返回值**：设备硬件指纹字符串（macOS 环境下为 `IOPlatformUUID` 或安全回退哈希）。

---

## 2. 配置结构：`LicenKitConfiguration`

```swift
public struct LicenKitConfiguration: Sendable {
    public let serverUrl: String
    public let accountId: String
    public let productId: String
    public let publicKey: String
    public let timeoutInterval: TimeInterval
    
    public init(
        serverUrl: String,
        accountId: String,
        productId: String,
        publicKey: String,
        timeoutInterval: TimeInterval = 15.0
    )
}
```

- `serverUrl`: LicenKit 服务端部署地址（例如 `https://license.yourcompany.com`）。
- `accountId`: 工作区/账户 ID（如 `acc_xxx`）。
- `productId`: 软件产品 ID（如 `prd_mac_editor`）。
- `publicKey`: 产品的 Ed25519 验签公钥（32 字节原始公钥的 Base64 字符串或标准 SPKI 文本）。
- `timeoutInterval`: 网络请求超时时间（默认为 15 秒）。

---

## 3. 核心数据模型

### 3.1 许可证状态枚举：`LicenseStatus`

```swift
public enum LicenseStatus: Equatable, Sendable {
    /// 商业许可证完全有效
    case valid(claims: LicenseClaims)
    
    /// 免费试用期内有效
    case trial(claims: TrialClaims)
    
    /// 脱网宽限期中（当前处于离线，但距上次校验仍在允许的宽限期内）
    case inGracePeriod(claims: LicenseClaims, remainingGraceSeconds: TimeInterval)
    
    /// 许可证已过期
    case expired(claims: LicenseClaims?)
    
    /// 试用期已结束
    case trialExpired(claims: TrialClaims?)
    
    /// 凭据不可信（签名伪造、指纹不匹配等安全异常）
    case untrusted(reason: String)
}
```

- `isUsable`: 判定当前状态是否允许应用核心功能放行运行（在 `.valid`、`.trial`、`.inGracePeriod` 时为 `true`）。
- `isTrial`: 判定当前是否处于试用状态（`.trial` 或 `.trialExpired`）。
- `features`: 统一获取当前授权或试用下发的功能特性数组 `[String]`。

### 3.2 离线荷载声明：`LicenseClaims` 与 `TrialClaims`

#### 商业许可证 Claims (`LicenseClaims`)
```swift
public struct LicenseClaims: Codable, Equatable, Sendable {
    public let typ: String              // "license"
    public let licenseId: String         // 授权内部唯一标识
    public let licenseKey: String        // 授权码 (sub)
    public let accountId: String         // 账户 ID (acc)
    public let productId: String         // 产品 ID (prd)
    public let policyId: String          // 策略 ID (pol)
    public let fingerprint: String       // 绑定的硬件指纹 (fp)
    public let issuedAt: Date            // 签发时间 (iat)
    public let expirationDate: Date      // 过期时间 (exp)
    public let features: [String]        // 允许的功能特性列表 (fea)
}
```

#### 免费试用 Claims (`TrialClaims`)
```swift
public struct TrialClaims: Codable, Equatable, Sendable {
    public let typ: String              // "trial"
    public let accountId: String         // 账户 ID (acc)
    public let productId: String         // 产品 ID (prd)
    public let fingerprint: String       // 绑定的硬件指纹 (fp)
    public let issuedAt: Date            // 试用启动时间
    public let expirationDate: Date      // 试用到期时间
    public let features: [String]        // 试用开放的功能特性列表 (fea)
}
```

### 3.3 操作结果：`ActivationResult` 与 `TrialResult`

```swift
public struct ActivationResult: Sendable {
    public let activated: Bool
    public let reused: Bool              // 是否重用了历史激活席位
    public let machineId: String         // 席位唯一标识
    public let token: String             // 签名的离线 Token
    public let tokenExpiresAt: Date?     // Token 本身有效期
    public let licenseExpiresAt: Date?   // 商业授权到期时间
    public let policy: ApiPolicyInfo     // 关联的策略信息
}

public struct TrialResult: Sendable {
    public let trialClaimed: Bool        // 试用是否认领成功
    public let alreadyClaimed: Bool      // 是否为历史已认领设备
    public let expired: Bool             // 试用是否已过期
    public let token: String?            // 离线试用 Token (已过期为 nil)
    public let claimedAt: Date?          // 首次认领时间
    public let expiresAt: Date?          // 试用到期时间
    public let features: [String]        // 试用特性列表
}
```

---

## 4. 错误处理体系：`LicenKitError`

所有 SDK 抛出的异常均遵循标准 `LicenKitError`：

```swift
public enum LicenKitError: Error, LocalizedError, Equatable {
    /// 本地无任何授权激活凭据
    case unactivated
    
    /// 席位已达到上限 (HTTP 409 / MAX_MACHINES_REACHED)
    case maxMachinesReached
    
    /// 密码学校验失败（数字签名被篡改或公钥错误）
    case cryptoError(String)
    
    /// 凭据格式损坏或 Base64URL 无法反序列化
    case invalidToken(String)
    
    /// 硬件指纹不匹配（尝试将一台机器的凭据拷贝至另一台机器使用）
    case fingerprintMismatch(expected: String, actual: String)
    
    /// 网络传输失败或超时
    case networkError(String)
    
    /// 服务端业务错误返回
    case apiError(code: String, message: String)
    
    /// 本地 Keychain 读写异常
    case keychainError(status: OSStatus, message: String)
}
```
