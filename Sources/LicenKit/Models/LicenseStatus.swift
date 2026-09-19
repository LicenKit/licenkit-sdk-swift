import Foundation

public enum LicenseStatus: Equatable, Sendable {
    case unactivated
    case validOnline(terms: LicenseTerms)
    case trialValidOnline(expiresAt: Date, features: [String])
    case validLocally(claims: LicenseClaims)
    case temporarilyUnverified(lastValidatedAt: Date, cachedTerms: LicenseTerms?)
    case onlineValidationRequired
    case suspended(reason: String?)
    case expired(expiresAt: Date?)
    case productReleaseUnknown(version: String, platform: String)
    case updateEntitlementRequired(updatesUntil: Date, releaseVersion: String, releasedAt: Date)
    case revoked(reason: String?)
    case activationRevoked
    case trialExpired(expiresAt: Date)
    case trialRevoked(reason: String?)
    case untrusted(reason: String)

    public var isUsable: Bool {
        switch self {
        case .validOnline, .trialValidOnline, .validLocally:
            return true
        default:
            return false
        }
    }

    public var features: [String] {
        switch self {
        case .validOnline(let terms):
            return terms.features
        case .trialValidOnline(_, let features):
            return features
        case .validLocally(let claims):
            return claims.features
        case .temporarilyUnverified(_, let terms):
            return terms?.features ?? []
        default:
            return []
        }
    }

    public func hasFeature(_ feature: String) -> Bool {
        isUsable && features.contains(feature)
    }
}

public enum DeactivationResult: Equatable, Sendable {
    case completed
    case remoteFailed(localCredentialsPreserved: Bool, underlying: LicenKitError)
}
