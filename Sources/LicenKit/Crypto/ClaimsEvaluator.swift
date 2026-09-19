import Foundation

public struct ClaimsEvaluator: Sendable {
    public init() {}

    public func evaluate(
        claims: LicenseClaims,
        configuration: LicenKitConfiguration,
        activationID: String,
        currentFingerprint: String,
        now: Date = Date()
    ) -> LicenseStatus {
        guard claims.accountID == configuration.accountID else {
            return .untrusted(reason: "Signed License Token account does not match SDK configuration")
        }
        guard claims.productID == configuration.productID else {
            return .untrusted(reason: "Signed License Token product does not match SDK configuration")
        }
        guard claims.activationID == activationID else {
            return .untrusted(reason: "Signed License Token activation does not match stored credentials")
        }
        guard claims.fingerprint.caseInsensitiveCompare(currentFingerprint) == .orderedSame else {
            return .untrusted(reason: "Signed License Token fingerprint does not match this device")
        }
        guard claims.releaseVersion == configuration.releaseVersion,
              claims.releasePlatform == configuration.releasePlatform else {
            return .untrusted(reason: "Signed License Token release identity does not match this build")
        }
        guard claims.issuedAt <= now.addingTimeInterval(300) else {
            return .untrusted(reason: "Signed License Token was issued in the future")
        }
        guard claims.tokenExpiresAt > now else {
            return .expired(expiresAt: claims.tokenExpiresAt)
        }
        if let licenseExpiration = claims.licenseExpiresAt, licenseExpiration <= now {
            return .expired(expiresAt: licenseExpiration)
        }
        if let updatesUntil = claims.updatesUntil, claims.releasedAt > updatesUntil {
            return .updateEntitlementRequired(
                updatesUntil: updatesUntil,
                releaseVersion: claims.releaseVersion,
                releasedAt: claims.releasedAt
            )
        }
        return .validLocally(claims: claims)
    }
}
