import Foundation

enum SignedLicenseEvaluation: Equatable, Sendable {
    case active(claims: LicenseClaims)
    case licenseExpired(claims: LicenseClaims)
}

struct ClaimsEvaluator: Sendable {

    func evaluate(
        claims: LicenseClaims,
        configuration: LicenKitConfiguration,
        activationID: String,
        currentFingerprint: String,
        now: Date = Date()
    ) throws -> SignedLicenseEvaluation {
        guard claims.productID == configuration.productID else {
            throw LicenKitError.invalidSignedLicenseToken(reason: "Signed License Token product does not match SDK configuration")
        }
        guard (claims.environment ?? .live) == configuration.environment else {
            throw LicenKitError.invalidSignedLicenseToken(reason: "Signed License Token environment does not match SDK configuration")
        }
        guard claims.activationID == activationID else {
            throw LicenKitError.invalidSignedLicenseToken(reason: "Signed License Token activation does not match stored credentials")
        }
        guard claims.fingerprint.caseInsensitiveCompare(currentFingerprint) == .orderedSame else {
            throw LicenKitError.invalidSignedLicenseToken(reason: "Signed License Token fingerprint does not match this device")
        }
        guard claims.releaseVersion == configuration.releaseVersion,
              claims.releasePlatform == configuration.releasePlatform,
              claims.releaseArch == configuration.releaseArch else {
            throw LicenKitError.invalidSignedLicenseToken(reason: "Signed License Token release identity does not match this build")
        }
        guard claims.issuedAt <= now.addingTimeInterval(300) else {
            throw LicenKitError.invalidSignedLicenseToken(reason: "Signed License Token was issued in the future")
        }
        if let licenseExpiration = claims.licenseExpiresAt, licenseExpiration <= now {
            return .licenseExpired(claims: claims)
        }
        return .active(claims: claims)
    }
}
