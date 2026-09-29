# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.9.1] - 2026-09-29

### Fixed
- 修复含 `env` 的 Signed License Token 被严格字段校验误拒；继续接受旧版无 `env` 的 Live Token，并保留未知字段与环境不匹配检查。

## [0.9.0] - 2026-09-29

### Added
- 新增 `LicenKitEnvironment`（`.live`、`.sandbox`），可在 `LicenKitConfiguration` 中显式指定运行环境（正式版默认 `.live`，Sandbox 测试版指定 `.sandbox`）。
- Keychain 针对 Live 与 Sandbox 环境隔离存储命名空间（Sandbox 环境使用 `.sandbox` 命名后缀）。
- 激活与校验请求提交 `billing_environment`，并在凭据恢复、服务端响应与签名 License Token（`env` Claim）中严格核验环境一致性。

### Changed
- 移除设备端临时验证令牌（`machine_token` 与 `trial_token`），重试激活与试用改由服务端依据设备指纹与激活记录保障幂等。
- 简化凭据存储接口：从 `CredentialStore` 及 `KeychainStore` 中移除 `StoredActivationVerification`、`StoredTrialVerification` 相关方法，`StoredCredentials` 与 `StoredDeactivationAttempt` 不再持久化 `machineToken`。

## [0.8.0] - 2026-09-28

### Added
- 新增只读的 `restoreLocalEntitlement()`，在网络复核前明确交付本机可用、已确认阻断或需要核验的结论；新保存的缓存快照与具体 License/Trial 凭据绑定，旧的未绑定快照需先在线复核。
- 解绑请求前持久化恢复记录；远端已确认而本机清理失败时返回独立结果，进程重启后可重试 `deactivate()` 完成清理。

### Fixed
- 已缓存的 active Signed License 跨过业务到期日后，静默或用户主动复核可以请求服务端；签名与快照真实不一致仍返回原始错误。

## [0.7.0] - 2026-09-28

### Changed
- `validate(trigger:)` 区分用户主动与宿主静默复核；Product 间隔只限制静默调用，固定 30 秒从请求尝试开始计时。
- Trial/License 首次到期、Release 身份变化首次静默复核及 Signed Token 本地失效可跳过 Product 间隔；两种本地跳过原因提供不同代码和可重试时间。
- 缺少或无效的内置签名公钥保留配置错误；旧的无参数 `validate()` 暂按静默模式执行并标记弃用。
- 自定义 `CredentialStore` 实现需新增校验请求尝试的读写方法；旧快照缺少 Release 身份时可正常解码，并在下一次静默调用中提前复核一次。

## [0.6.0] - 2026-09-28

### Added
- **Pending Verification Token Persistence**:
  - Activation and trial claims now persist a client-generated 256-bit CSPRNG verification token (`StoredActivationVerification`, `StoredTrialVerification`) before network requests.
  - When responses are lost or subsequent credential writes fail, retrying `activate()` or `startTrial()` reuses the pending token for idempotency across process restarts without leaking registration keys or hashes.
  - Added verification storage APIs to `CredentialStore` and `KeychainStore`.
- **Offline Grace Period**:
  - Added `offlineGrace(until: Date)` and `offlineGraceExceeded(since: Date)` freshness states to `EntitlementFreshness`.
  - Added `offlineGracePeriod` to `EntitlementSnapshot` and `OperationMetadata`, populated from the server's `offline_grace_seconds`.
  - Offline grace period applies equally to opaque and signed credentials.

### Changed
- **Signed License Token Contract Alignment**:
  - Removed legacy `exp` (token expiry) claim from `LicenseClaims` and signed license tokens; signed credentials no longer maintain an independent token expiry.
  - Usability of active entitlements is now governed solely by business validity/expiry and signed credential validity, with validation intervals and offline grace periods governing freshness and validation scheduling.

## [0.5.0] - 2026-09-28

### Changed
- Replaced `releaseNotEligible(.updateRequired(...))` with the direct `licenseNotValidForVersion(...)` entitlement state so host applications can present the actual License/version mismatch without interpreting an ambiguous update action.
- `licenseNotValidForVersion` now requires both `updatesUntil` and `releasedAt`; malformed Server responses missing either fact fail as protocol errors while preserving operation diagnostics.

## [0.4.0] - 2026-09-27

### Changed
- **Simplified SDK Configuration (`LicenKitConfiguration`)**:
  - Removed client-side `instanceID` requirement; instance resolution is now managed entirely server-side via the globally unique `productID`.
  - Replaced the `trustedSigningKeys: [String: String]` dictionary with a single `signingPublicKey: String?` property.
  - Automatically derives `releaseVersion` from the host application bundle (`CFBundleShortVersionString`) and `releaseArch` (`arm64` / `x86_64`), with `releasePlatform` fixed to `macos`.
  - Fixed internal HTTP request timeout to 15 seconds and encapsulated private Keychain access.
- **V1 Token Claims & Alignment**:
  - Aligned `TokenClaims` with the server specification: added `arc` (system architecture) and omitted client-side `rel` (Release ID) and `rat` (released at timestamp).
  - Updated `ClaimsEvaluator` and `Ed25519Verifier` to verify the single configured signing key, product ID, bundle version, platform, and architecture.
  - Aligned trial entitlement handling: unregistered product releases do not block trial access.

## [0.3.0] - 2026-09-27

### Added
- Added `LicenKitResult<Value>` so Facade operations distinguish success, validation cooldown, and failure with the last known value.
- Added `EntitlementSnapshot` and the unified License, Trial, activation-required, and Release-eligibility state model.
- Added server/cache/signed-local/local state provenance, validation freshness, original business codes, safe details, and operation request IDs.

### Changed
- **Breaking Unified Validation Contract**:
  - `activate`, `startTrial`, `validate`, and `deactivate` now return `LicenKitResult` instead of throwing business and transport failures.
  - `validate()` now selects License, Trial, or no credential and uses the single `/api/v1/client/validate` protocol.
  - Concurrent validations share one task; all credential and snapshot mutations are serialized with activation, Trial claiming, and deactivation.
  - `validate()` now applies both the server interval and a hard-coded 30-second gate; an invalid or expired Signed License Token bypasses only the server interval.
  - Only an explicit `/validate` server result advances request cooldown. Valid business data or an HTTP failure advances it; no-response transport failures and malformed 2xx data do not. HTTP failures do not advance `validatedAt`.
  - Activation, Trial claiming, and deactivation do not participate in or initialize validation cooldown, and the SDK does not schedule background requests.
  - Cached usability remains bounded by the effective validation interval, business expiry, and Signed License Token expiry.
  - Deactivation preserves credentials on remote failure and returns an explicit local result when no License credential exists.
- Signed responses now require the outer token expiry to match the signed absolute `exp`, and active state fields to match signed Claims. The configured TTL is not embedded in the token and may be shorter than the validation interval; `exp` is capped by the effective License expiry, which already includes snapshotted payment grace for billing Licenses.
- **Breaking Instance Contract Rename**:
  - Renamed the Swift configuration and request property from `accountID` to `instanceID`.
  - Renamed the public JSON field from `account_id` to `instance_id`.
  - Renamed the Signed License Token claim from `acc` to `ins`.
  - Removed compatibility aliases; callers and tokens using the previous names are rejected.

### Removed
- Removed the separate `validateTrial()` and `checkLocalStatus()` Facade paths; `validate()` and `EntitlementSnapshot` now carry those responsibilities.
- Removed the legacy `LicenseStatus`, `ActivationResult`, and `DeactivationResult` public state model.

## [0.2.0] - 2026-09-18

### Added
- **Dual-Credential Machine Token Model**:
  - Implemented secure two-tier authentication architecture aligned with LicenKit server.
  - Local disk and Keychain scrub plaintext `licenseKey` upon activation and persist only `machineToken` and `machineId`.
  - Added `sub` claim to `LicenseClaims` with backwards-compatible `licenseKey` alias.
  - Refactored `ApiValidateRequest` and `ApiDeactivateRequest` around the then-current tenant ID, machine ID, machine token, and fingerprint contract. The current contract is documented in `[0.3.0]` above.
- **High Availability Disaster Recovery & Resilience**:
  - Implemented `LicenKitRetryCoordinator` featuring dual-track execution:
    - **Track A (Foreground Blocking)**: `activate()` and `refresh()` with jittered exponential backoff (up to 3 retries) and immediate user feedback.
    - **Track B (Background Silent)**: `validate()` adhering strictly to the Fail-Silent principle (one background retry, session-level circuit breaking, and daily 429 rate-limiting block).
  - Added `SystemNetworkMonitor` and `NetworkMonitorProtocol` based on Apple's `NWPathMonitor` for real-time interface monitoring, fail-fast offline short-circuiting, and auto-reset of circuit breakers upon reconnection.
  - Added `refresh() async throws -> ValidationResult` for user-triggered foreground license renewal from UI (e.g. "Check Renewal" buttons).
  - Added blame-aware offline fallback in `LicenKit.validate()`: valid local licenses are never revoked due to transient network outages, proxy/gateway 404/403/502/504 errors, server 5xx errors, or rate limiting.
- **Documentation**:
  - Added comprehensive bilingual disaster recovery and resilience guides (`FAULT_TOLERANCE_AND_DISASTER_RECOVERY.md`).
  - Updated API reference with `refresh()` method documentation.

### Fixed
- **Keychain Compatibility**:
  - Changed default Keychain `isSynchronizable` parameter from `true` to `false`, resolving `-34018` (missing entitlement) and `-50` errors on standard non-iCloud macOS applications.
  - Added automatic fallback retry without `kSecAttrSynchronizable` when encountering Keychain entitlement errors.
- **Client Error Code Alignment**:
  - Mapped server error code `SEAT_LIMIT_EXCEEDED` to `LicenKitError.maxMachinesReached`.
  - Refined `LicenKitError.isExplicitBusinessRejection` to exclude HTTP status codes from proxies and reverse gateways.

---

## [0.1.0] - 2026-09-17

### Added
- **Initial Release of LicenKit Swift SDK**:
  - Native Swift implementation with zero external third-party dependencies.
  - Swift Concurrency native design (`async/await`, Sendable).
  - Offline Ed25519 elliptic curve signature verification via CryptoKit.
  - Online license seat activation, heartbeat validation, and seat deactivation.
  - Free trial claiming (`requestTrial`) and offline trial verification.
  - Hardware fingerprinting using macOS `IOPlatformUUID` with deterministic fallback.
  - Secure credential storage in macOS Keychain with iCloud Keychain roaming support.
  - In-memory feature entitlement checks (`hasFeature`).
  - Multilingual documentation (English and Simplified Chinese).
