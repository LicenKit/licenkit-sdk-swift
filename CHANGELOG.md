# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-09-18

### Added
- **Dual-Credential Machine Token Model**:
  - Implemented secure two-tier authentication architecture aligned with LicenKit server.
  - Local disk and Keychain scrub plaintext `licenseKey` upon activation and persist only `machineToken` and `machineId`.
  - Added `sub` claim to `LicenseClaims` with backwards-compatible `licenseKey` alias.
  - Refactored `ApiValidateRequest` and `ApiDeactivateRequest` to use `(account_id, machine_id, machine_token, fingerprint)`.
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
