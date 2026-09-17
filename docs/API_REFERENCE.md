# LicenKit Swift SDK API Reference Manual

**English** | [简体中文](zh-CN/API_REFERENCE.md)

This document provides detailed signatures and descriptions for all public classes, structs, enums, and asynchronous APIs in the **LicenKit Swift SDK**.

---

## 1. Core Facade: `LicenKit`

`LicenKit` is the main entry point for host applications, designed around modern Swift concurrency and thread safety.

```swift
public final class LicenKit: @unchecked Sendable
```

### 1.1 Configuration & Shared Singleton

#### `configure(with configuration: LicenKitConfiguration)`
Initializes the global shared LicenKit instance.

```swift
public static func configure(with configuration: LicenKitConfiguration)
```
- **Parameters**:
  - `configuration`: Initialization configuration object.
- **Description**: Typically called once during application startup or app delegate initialization. Calling this multiple times will overwrite the shared instance with the new configuration.

#### `shared`
Retrieves the initialized global shared instance.

```swift
public static var shared: LicenKit { get }
```
- **Exceptions**: Accessing this before calling `configure(with:)` triggers a `fatalError`.

---

### 1.2 Core Operations

#### `verifyOffline() async throws -> LicenseStatus`
Executes pure local, offline Ed25519 cryptographic signature verification and hardware fingerprint checking with 0 network latency. Automatically supports both commercial license tokens and free trial tokens.

```swift
public func verifyOffline() async throws -> LicenseStatus
```
- **Returns**: Current license status enum `LicenseStatus` (e.g. `.valid`, `.trial`, `.inGracePeriod`, etc.).
- **Potential Errors**:
  - `LicenKitError.unactivated`: No credentials found in local Keychain.
  - `LicenKitError.invalidToken(reason)`: Malformed token format or deserialization failure.
  - `LicenKitError.cryptoError(reason)`: Ed25519 signature verification failed (tampered token or incorrect public key).

---

#### `requestTrial() async throws -> TrialResult`
Requests a silent, hardware-bound free trial from the LicenKit server, automatically verifies the `LK-TRIAL` offline token, and securely persists it into the Keychain.

```swift
public func requestTrial() async throws -> TrialResult
```
- **Returns**: `TrialResult`, containing trial claim status, whether previously claimed, expiration date, and enabled features.
- **Potential Errors**:
  - `LicenKitError.apiError(code, message)`: Free trial is disabled for this product (`TRIAL_NOT_AVAILABLE`) or server error.
  - `LicenKitError.networkError(message)`: Network connection failure.

---

#### `activate(licenseKey: String, machineName: String? = nil) async throws -> ActivationResult`
Activates the current machine seat online against the LicenKit edge engine and persists updated credentials into Keychain.

```swift
public func activate(licenseKey: String, machineName: String? = nil) async throws -> ActivationResult
```
- **Parameters**:
  - `licenseKey`: The customer's license key string (`LIC-XXXX-XXXX-XXXX-XXXX`).
  - `machineName`: Optional custom machine alias (defaults to host name).
- **Returns**: `ActivationResult`, containing machine seat ID, signed token, and policy details.
- **Potential Errors**:
  - `LicenKitError.apiError(code, message)`: Invalid, expired, or disabled license key.
  - `LicenKitError.maxMachinesReached`: All allowed seats for this license are occupied.
  - `LicenKitError.networkError(message)`: Network connection failure.

---

#### `validate() async throws -> ValidationResult`
Sends an online heartbeat probe to the server, synchronizes latest status, and renews the local token if updated.

```swift
public func validate() async throws -> ValidationResult
```
- **Returns**: `ValidationResult`, containing probe validation status, refreshed token, and expiration dates.
- **Description**: Best executed silently in the background (e.g. during grace periods or daily network access). If network times out, credentials remain valid within the offline grace period.

---

#### `deactivate() async throws`
Releases the current machine seat on the server and clears credentials from the local Keychain.

```swift
public func deactivate() async throws
```
- **Description**: Typically invoked when the user unlinks the device or logs out. After deactivation, subsequent `verifyOffline()` calls will throw `.unactivated`.

---

#### `hasFeature(_ featureKey: String) -> Bool`
In-memory fast lookup to check if a specific feature entitlement is granted under the active license or trial.

```swift
public func hasFeature(_ featureKey: String) -> Bool
```
- **Parameters**:
  - `featureKey`: Feature identifier string (e.g. `"pro_export_4k"`, `"unlimited_tracks"`).
- **Returns**: `true` if authorized; `false` otherwise.

---

#### `getMachineFingerprint() async throws -> String`
Extracts the immutable hardware fingerprint of the current machine.

```swift
public func getMachineFingerprint() async throws -> String
```
- **Returns**: Device fingerprint string (e.g. `IOPlatformUUID` on macOS or deterministic SHA-256 fallback hash).

---

## 2. Configuration: `LicenKitConfiguration`

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

- `serverUrl`: Base endpoint of your LicenKit deployment (e.g. `https://license.yourcompany.com`).
- `accountId`: Account / Workspace identifier (e.g. `acc_xxx`).
- `productId`: Software product ID (e.g. `prd_mac_editor`).
- `publicKey`: Product's Ed25519 public key (32-byte raw Base64 or standard SPKI PEM format).
- `timeoutInterval`: Network request timeout in seconds (defaults to 15.0s).

---

## 3. Data Models

### 3.1 License Status Enum: `LicenseStatus`

```swift
public enum LicenseStatus: Equatable, Sendable {
    /// Commercial license is fully valid
    case valid(claims: LicenseClaims)
    
    /// Free trial is active and within valid period
    case trial(claims: TrialClaims)
    
    /// Currently in offline grace period (temporary offline buffer)
    case inGracePeriod(claims: LicenseClaims, remainingGraceSeconds: TimeInterval)
    
    /// Commercial license has expired
    case expired(claims: LicenseClaims?)
    
    /// Free trial period has ended
    case trialExpired(claims: TrialClaims?)
    
    /// Credentials untrusted (signature tampered, fingerprint mismatch, or clock rollback)
    case untrusted(reason: String)
}
```

- `isUsable`: Convenience check whether the core app should remain usable (`true` for `.valid`, `.trial`, and `.inGracePeriod`).
- `isTrial`: Whether currently under trial (`.trial` or `.trialExpired`).
- `features`: Array of authorized feature keys `[String]`.

### 3.2 Offline Claims: `LicenseClaims` & `TrialClaims`

#### Commercial License Claims (`LicenseClaims`)
```swift
public struct LicenseClaims: Codable, Equatable, Sendable {
    public let typ: String              // "license"
    public let licenseId: String         // Internal license ID
    public let licenseKey: String        // License key code (sub)
    public let accountId: String         // Account ID (acc)
    public let productId: String         // Product ID (prd)
    public let policyId: String          // Policy ID (pol)
    public let fingerprint: String       // Hardware fingerprint (fp)
    public let issuedAt: Date            // Token issuance date (iat)
    public let expirationDate: Date      // Expiration date (exp)
    public let features: [String]        // Enabled features list (fea)
}
```

#### Free Trial Claims (`TrialClaims`)
```swift
public struct TrialClaims: Codable, Equatable, Sendable {
    public let typ: String              // "trial"
    public let accountId: String         // Account ID (acc)
    public let productId: String         // Product ID (prd)
    public let fingerprint: String       // Hardware fingerprint (fp)
    public let issuedAt: Date            // Trial start date
    public let expirationDate: Date      // Trial expiration date
    public let features: [String]        // Trial features list (fea)
}
```

### 3.3 Operation Results: `ActivationResult` & `TrialResult`

```swift
public struct ActivationResult: Sendable {
    public let activated: Bool
    public let reused: Bool              // Whether existing seat was reused
    public let machineId: String         // Seat identifier
    public let token: String             // Signed offline token
    public let tokenExpiresAt: Date?     // Token expiration date
    public let licenseExpiresAt: Date?   // Commercial license expiration date
    public let policy: ApiPolicyInfo     // Associated policy details
}

public struct TrialResult: Sendable {
    public let trialClaimed: Bool        // Whether trial was claimed successfully
    public let alreadyClaimed: Bool      // Whether previously claimed on this machine
    public let expired: Bool             // Whether trial has already expired
    public let token: String?            // Signed offline trial token
    public let claimedAt: Date?          // Initial claim timestamp
    public let expiresAt: Date?          // Trial expiration timestamp
    public let features: [String]        // Available trial features
}
```

---

## 4. Error Handling: `LicenKitError`

All SDK exceptions conform to the standard `LicenKitError`:

```swift
public enum LicenKitError: Error, LocalizedError, Equatable {
    /// No local credentials stored on this device
    case unactivated
    
    /// License seat limit reached (HTTP 409)
    case maxMachinesReached
    
    /// Cryptographic signature verification failed or public key malformed
    case cryptoError(String)
    
    /// Token payload malformed or deserialization failure
    case invalidToken(String)
    
    /// Hardware fingerprint mismatch (preventing multi-machine copying)
    case fingerprintMismatch(expected: String, actual: String)
    
    /// Network connection failure or timeout
    case networkError(String)
    
    /// Server business rejection
    case apiError(code: String, message: String)
    
    /// System Keychain read/write error
    case keychainError(status: OSStatus, message: String)
}
```
