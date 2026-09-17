# LicenKit Swift SDK

**English** | [简体中文](README_zh.md)

> Modern, lightweight, high-performance native Swift SDK for [LicenKit](https://github.com/LicenKit/licenkit) software licensing, seat activation, and offline cryptographic verification.

---

## 🎯 Overview

**LicenKit Swift SDK** (`licenkit-sdk-swift`) is a native software licensing library built for Apple platforms. Starting with desktop **macOS**, it delivers an ultra-lightweight, zero-external-dependency, and highly secure licensing and trial management solution for commercial apps.

### Key Features

- 🔒 **Zero External Dependencies**: Built 100% on Apple native frameworks (`Foundation`, `CryptoKit`, `Security`, `IOKit`). No third-party pods, binaries, or C-libraries, ensuring instantaneous build times, minimal footprint, and zero supply-chain security risks.
- ⚡ **Swift Concurrency Native**: Modern asynchronous API entirely designed with `async/await`, strongly typed and thread-safe.
- 🛡️ **Dual-Mode Verification**:
  - **Online Heartbeat Validation**: Sub-second synchronization with LicenKit Edge Engines (Cloudflare Workers + D1) for seat activation, lease status, and revocations.
  - **Offline Cryptographic Verification**: Zero-latency mathematical offline signature verification powered by **Ed25519** elliptic curves via CryptoKit.
- 🎁 **Out-of-the-Box Free Trial**: Built-in silent hardware-fingerprint trial claiming (`requestTrial`), anti-abuse protection, offline `LK-TRIAL` token issuance, and seamless migration to commercial licenses upon purchase.
- 💻 **Hardware Fingerprint Anti-Abuse**: Extracts immutable machine characteristics using macOS kernel-level `IOPlatformUUID` with deterministic SHA-256 network fallback to stop license sharing across devices.
- 🔑 **Keychain Security & iCloud Roaming**: Stores offline license tokens and credentials securely in macOS Keychain. Supports seamless iCloud Keychain roaming to restore activations on new devices under the same Apple ID.
- 🎛️ **Feature Entitlements**: In-memory, sub-millisecond feature flag checking to gate premium tiers and modules on demand.

---

## 📦 Installation

### Swift Package Manager (SPM)

In your Xcode project:
1. Navigate to **File** -> **Add Package Dependencies...**
2. Enter the repository URL in the search bar:
   ```text
   https://github.com/LicenKit/licenkit-sdk-swift.git
   ```
3. Set the Dependency Rule (recommended: *Up to Next Major Version* from `0.1.0`), and add `LicenKit` to your macOS App Target.

Or declare it directly in your `Package.swift`:

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MyMacApp",
    platforms: [
        .macOS(.v12)
    ],
    dependencies: [
        .package(url: "https://github.com/LicenKit/licenkit-sdk-swift.git", from: "0.1.0")
    ],
    targets: [
        .target(
            name: "MyMacApp",
            dependencies: [
                .product(name: "LicenKit", package: "licenkit-sdk-swift")
            ]
        )
    ]
)
```

---

## 🚀 Quick Start

### 1. Initialize LicenKit

Configure LicenKit once during app launch (e.g. in your `NSApplicationDelegate` or `@main App` initializer):

```swift
import LicenKit

let config = LicenKitConfiguration(
    serverUrl: "https://licenkit-api.yourdomain.com",
    accountId: "acc_live_9x8a7b6c",
    productId: "prd_macos_pro",
    publicKey: "MCowBQYDK2VwAyEA9F7G4hH..." // 32-byte Ed25519 Public Key (Raw Base64 or SPKI)
)

// Set global shared singleton
LicenKit.configure(with: config)
```

### 2. Verify Local License (Instantaneous Cold Start)

Check the cached credentials offline with 0 network latency:

```swift
Task {
    do {
        // Loads cached token from Keychain (supports both license and trial) and validates via Ed25519
        let status = try await LicenKit.shared.verifyOffline()
        
        switch status {
        case .valid(let claims):
            print("Commercial license valid! Expires at: \(claims.expirationDate)")
            // Unlock all full commercial features
            
        case .trial(let claims):
            print("Free trial active! Expires at: \(claims.expirationDate)")
            // Enable trial features
            
        case .inGracePeriod(let claims, let remainingSeconds):
            print("In offline grace period, \(remainingSeconds) seconds remaining.")
            // Allow app usage, and trigger a background heartbeat
            Task { _ = try? await LicenKit.shared.validate() }
            
        case .expired:
            print("License has expired. Please renew.")
            
        case .trialExpired:
            print("Free trial ended. Prompt user to purchase a license.")
            
        case .untrusted(let reason):
            print("Verification failed: \(reason)")
        }
    } catch LicenKitError.unactivated {
        print("Device is not activated. Prompt user for license key or free trial.")
    }
}
```

### 3. Claim Free Trial (One-Click Silent Claim)

When the user launches the app for the first time and chooses "Start Free Trial":

```swift
Task {
    do {
        let result = try await LicenKit.shared.requestTrial()
        if result.expired {
            print("Trial has already expired for this device.")
        } else {
            print("Trial claimed successfully! Valid until: \(result.expiresAt ?? Date())")
            // Offline token is securely saved to Keychain; next launches verify offline
        }
    } catch {
        print("Failed to request trial: \(error)")
    }
}
```

### 4. Online License Activation

When the user enters a purchased license key (`LIC-XXXX-XXXX-XXXX-XXXX`):

```swift
Task {
    do {
        let result = try await LicenKit.shared.activate(licenseKey: "LIC-ABCD-1234-EFGH-5678")
        print("Activation successful! Seat ID: \(result.machineId)")
        // Keychain is automatically updated with commercial credentials and Ed25519 token
    } catch let error as LicenKitError {
        switch error {
        case .maxMachinesReached:
            print("Activation failed: seat limit reached")
        case .networkError(let message):
            print("Network error: \(message)")
        case .apiError(let code, let msg):
            print("Server rejected [\(code)]: \(msg)")
        default:
            print("Activation error: \(error)")
        }
    }
}
```

### 5. Feature Entitlement Checks

Check access to premium features defined in the policy:

```swift
if LicenKit.shared.hasFeature("pro_export_4k") {
    // Enable 4K export feature
} else {
    // Disable or show upgrade prompt
}
```

### 6. Deactivate Seat

When the user unlinks the device or unregisters their license:

```swift
Task {
    do {
        try await LicenKit.shared.deactivate()
        print("Seat released and local Keychain cleared successfully.")
    } catch {
        print("Deactivation failed: \(error)")
    }
}
```

---

## 📚 Documentation

For deeper architectural details and API references, check the `docs/` folder:

- 🏛️ **[Architecture & Security Model (ARCHITECTURE.md)](./docs/ARCHITECTURE.md)**: Layered architecture, dual-mode verification workflow, hardware fingerprinting mechanism, and multi-platform roadmap.
- 🧩 **[Modules & Features Specification (MODULES_AND_FEATURES.md)](./docs/MODULES_AND_FEATURES.md)**: Technical overview of Core, Crypto, Network, Storage, and Platform components.
- 📖 **[API Reference Manual (API_REFERENCE.md)](./docs/API_REFERENCE.md)**: Complete public classes, protocol definitions, configuration options, and error codes.

---

## 📄 License

This project is licensed under the [Apache-2.0 License](LICENSE).
