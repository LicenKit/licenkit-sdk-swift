# LicenKit Swift SDK

**English** | [简体中文](./README.zh-CN.md)

Add license activation, device trials, and license checks to your macOS app with [LicenKit](https://github.com/LicenKit/licenkit).

- Activate a license key or start a device trial.
- Restore saved license access at launch, then check with your server.
- Verify signed licenses offline using an Ed25519 public key bundled with your app.
- Store credentials in macOS Keychain, with separate storage for live and sandbox environments.
- Use Swift concurrency (`async`/`await`) with no third-party dependencies.

## Requirements

- macOS 12 or later.
- Swift 5.9 or later.
- A LicenKit server and a product configured in its admin console.

## Installation

In Xcode, add a package dependency using this repository URL:

```text
https://github.com/LicenKit/licenkit-sdk-swift.git
```

Add the **LicenKit** library product to your app target, then import it:

```swift
import LicenKit
```

## Quick start

### 1. Configure the SDK

Configure once before using `LicenKit.shared`:

```swift
import Foundation
import LicenKit

let configuration = LicenKitConfiguration(
    serverURL: URL(string: "https://licenses.example.com")!,
    productID: "YOUR_PRODUCT_ID",
    signingPublicKey: "YOUR_PRODUCT_SIGNING_PUBLIC_KEY"
)

LicenKit.configure(with: configuration)
```

Replace the example values with your server address and the values shown on the product page in the admin console.

| Setting | What to provide |
| --- | --- |
| `serverURL` | Your LicenKit server's base URL, without `/api/v1/client`. |
| `productID` | The product's globally unique ID from the admin console. |
| `signingPublicKey` | The product's Ed25519 public key, bundled with your app. Required for `signed` licenses; omit it for `opaque` licenses. |
| `environment` | Defaults to `.live`. Pass `.sandbox` explicitly in a sandbox build. |

The SDK reads your app version from `CFBundleShortVersionString` and detects its executable architecture (`arm64`, `x86_64`, or `universal`). Ensure this version is set in your app bundle; missing build information produces a configuration error.

### 2. Restore access at launch

Run the following snippets in your app's asynchronous startup flow. First, restore the saved license or trial. This call does not make a network request.

```swift
let local = await LicenKit.shared.restoreLocalEntitlement()
var canUseProtectedFeatures: Bool

switch local {
case .usable:
    canUseProtectedFeatures = true
case .confirmedBlocked, .verificationRequired:
    canUseProtectedFeatures = false
}

// Apply canUseProtectedFeatures to your app's UI and protected features now.
```

`.usable` means the saved evidence permits access. `.confirmedBlocked` restores a previously confirmed state such as an expired or revoked license. `.verificationRequired` means the app needs a new check before granting access, for example on first launch or when saved credentials cannot be verified.

### 3. Check with the server

After applying the local decision, check in the background and update access when a new state is received:

```swift
switch await LicenKit.shared.validate(trigger: .silent) {
case .success(let snapshot, _):
    canUseProtectedFeatures = snapshot.isUsable()
    // Update your UI and protected features using this result.

case .notPerformed:
    // No request was sent because a validation interval has not elapsed.
    break

case .failure(_, _, let metadata):
    // A failed check does not by itself mean the license was revoked.
    print("License check failed. Request ID:", metadata.requestID ?? "unavailable")
}
```

Keep respecting license and trial expiry while your app is running. A network failure does not extend that expiry, and the SDK does not schedule checks or update your app's UI automatically.

## Common operations

Activate the license key entered by the user:

```swift
let activation = await LicenKit.shared.activate(licenseKey: "LICENSE_KEY_FROM_USER")
```

Start a device trial:

```swift
let trial = await LicenKit.shared.startTrial()
```

Check again when the user clicks “Check license” or “Retry”:

```swift
let validation = await LicenKit.shared.validate(trigger: .userInitiated)
```

Deactivate this device to release its license seat:

```swift
let deactivation = await LicenKit.shared.deactivate()
```

Activation, trial, and validation calls return `LicenKitResult` with `.success`, `.notPerformed`, or `.failure`. A successful call means a state was obtained; check `snapshot.isUsable()` to decide whether access is allowed. For activation, the snapshot is available as `activationData.snapshot` in the success value.

Deactivation returns `DeactivationResult`. If it returns `.remoteConfirmedLocalRepairRequired`, the server has deactivated the device but local cleanup needs another attempt. Stop using the old license and retry `deactivate()` to finish cleanup. See the [API reference](./docs/API_REFERENCE.md) for all result types.

A device trial is separate from a payment provider's subscription trial. If the customer received a license key through a subscription trial, use `activate(licenseKey:)`.

## License modes

The product's license configuration determines the credential mode:

| Mode | Local verification |
| --- | --- |
| `opaque` | Restores a saved server response matched to the device's credentials. No independently signed license payload is available. |
| `signed` | Also verifies a signed license token using the Ed25519 public key bundled with your app. |

Both modes use an activation ID and device fingerprint for online license checks. Device trials use a trial ID and the device fingerprint. The SDK stores license and trial credentials in Keychain.

## Integration notes

- **Restore before checking.** Await `restoreLocalEntitlement()` before starting online validation at launch. `currentSnapshot`, a failure's `lastKnownValue`, or `.notPerformed`'s cached value cannot replace this initial verification.
- **Choose the right trigger.** Use `.silent` for background checks, such as at launch, on returning to the foreground, or when connectivity returns. Use `.userInitiated` for an explicit user action. Both have a 30-second minimum between new validation requests, including attempts that fail. The product's configured check interval applies only to silent calls; the SDK can check earlier after expiry, a build change, or an invalid signed token.
- **Handle skipped checks quietly.** `.notPerformed` sends no request. For `.minimumInterval`, a user-initiated check can show the remaining wait time. `.productInterval` usually needs no message. The SDK does not automatically retry when either interval ends. Activation, trial claims, and deactivation are not subject to these validation intervals.
- **Separate connection problems from license status.** Expiry, suspension, and revocation are license states. A failed request is a check that could not be completed. Exceeding the offline grace period produces an `offlineGraceExceeded` freshness value; it does not by itself disable an otherwise valid license.
- **Keep diagnostics free of secrets.** Use `businessCode`, sanitized `details`, and `OperationMetadata.requestID` for troubleshooting. Do not log license keys or signed license tokens.

## Documentation

The detailed guides below are currently in Simplified Chinese:

- [API reference](./docs/API_REFERENCE.md)
- [Architecture and security](./docs/ARCHITECTURE.md)
- [Server integration guide](https://github.com/LicenKit/licenkit/blob/main/docs/zh-CN/unified-client-validation-guide.md)

See the [changelog](./CHANGELOG.md) for version history and [LICENSE](./LICENSE) for license terms.
