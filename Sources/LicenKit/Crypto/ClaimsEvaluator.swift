import Foundation

enum SignedLicenseEvaluation: Equatable, Sendable {
    case active(claims: LicenseClaims)
    case licenseExpired(expiresAt: Date)
    case releaseNotEligible(ReleaseEligibilityIssue)
}

struct ClaimsEvaluator: Sendable {

    func evaluate(
        claims: LicenseClaims,
        configuration: LicenKitConfiguration,
        activationID: String,
        currentFingerprint: String,
        now: Date = Date()
    ) throws -> SignedLicenseEvaluation {
        guard claims.instanceID == configuration.instanceID else {
            throw LicenKitError.invalidSignedLicenseToken(reason: "Signed License Token instance does not match SDK configuration")
        }
        guard claims.productID == configuration.productID else {
            throw LicenKitError.invalidSignedLicenseToken(reason: "Signed License Token product does not match SDK configuration")
        }
        guard claims.activationID == activationID else {
            throw LicenKitError.invalidSignedLicenseToken(reason: "Signed License Token activation does not match stored credentials")
        }
        guard claims.fingerprint.caseInsensitiveCompare(currentFingerprint) == .orderedSame else {
            throw LicenKitError.invalidSignedLicenseToken(reason: "Signed License Token fingerprint does not match this device")
        }
        guard claims.releaseVersion == configuration.releaseVersion,
              claims.releasePlatform == configuration.releasePlatform else {
            throw LicenKitError.invalidSignedLicenseToken(reason: "Signed License Token release identity does not match this build")
        }
        guard claims.issuedAt <= now.addingTimeInterval(300) else {
            throw LicenKitError.invalidSignedLicenseToken(reason: "Signed License Token was issued in the future")
        }
        guard claims.tokenExpiresAt > now else {
            throw LicenKitError.invalidSignedLicenseToken(reason: "Signed License Token has expired")
        }
        if let licenseExpiration = claims.licenseExpiresAt, licenseExpiration <= now {
            return .licenseExpired(expiresAt: licenseExpiration)
        }
        if let updatesUntil = claims.updatesUntil, claims.releasedAt > updatesUntil {
            return .releaseNotEligible(
                .updateRequired(
                    code: "UPDATE_ENTITLEMENT_REQUIRED",
                    updatesUntil: updatesUntil,
                    releaseVersion: claims.releaseVersion,
                    releasedAt: claims.releasedAt
                )
            )
        }
        return .active(claims: claims)
    }
}
