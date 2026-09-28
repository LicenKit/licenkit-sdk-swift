import Foundation

public enum LicenKitResult<Value: Sendable>: Sendable {
    case success(value: Value, metadata: OperationMetadata)
    case notPerformed(reason: NotPerformedReason, cachedValue: Value?, metadata: OperationMetadata)
    case failure(error: LicenKitError, lastKnownValue: Value?, metadata: OperationMetadata)
}

extension LicenKitResult: Equatable where Value: Equatable {}

public enum NotPerformedReason: Equatable, Sendable {
    case minimumInterval(retryAfter: TimeInterval)
    case productInterval(nextEligibleAt: Date)

    public var code: String {
        switch self {
        case .minimumInterval: return "SDK_VALIDATION_MIN_INTERVAL"
        case .productInterval: return "SDK_VALIDATION_PRODUCT_INTERVAL"
        }
    }
}

public enum ValidationTrigger: Equatable, Sendable {
    case silent
    case userInitiated
}

public struct OperationMetadata: Equatable, Sendable {
    public let source: StateSource
    public let requestID: String?
    public let validatedAt: Date?
    public let receivedValidationInterval: TimeInterval?
    public let effectiveValidationInterval: TimeInterval?
    public let offlineGracePeriod: TimeInterval?
    public let lastValidateResponseAt: Date?

    public init(
        source: StateSource,
        requestID: String? = nil,
        validatedAt: Date? = nil,
        receivedValidationInterval: TimeInterval? = nil,
        effectiveValidationInterval: TimeInterval? = nil,
        offlineGracePeriod: TimeInterval? = nil,
        lastValidateResponseAt: Date? = nil
    ) {
        self.source = source
        self.requestID = requestID
        self.validatedAt = validatedAt
        self.receivedValidationInterval = receivedValidationInterval
        self.effectiveValidationInterval = effectiveValidationInterval
        self.offlineGracePeriod = offlineGracePeriod
        self.lastValidateResponseAt = lastValidateResponseAt
    }
}

public enum StateSource: String, Codable, Equatable, Sendable {
    case server
    case cache
    case signedLocal
    case local
}

public enum TrialUnavailableReason: Codable, Equatable, Sendable {
    case notEnabled
    case alreadyClaimed
}

public enum TrialAvailability: Codable, Equatable, Sendable {
    case available(duration: TimeInterval, features: [String])
    case unavailable(reason: TrialUnavailableReason)
    case unknown
}

public enum TrialEntitlement: Codable, Equatable, Sendable {
    case active(expiresAt: Date, features: [String])
    case expired(expiresAt: Date)
    case revoked(reason: String?)
}

public enum LicenseEntitlement: Codable, Equatable, Sendable {
    case active(terms: LicenseTerms, expiresAt: Date?)
    case expired(expiresAt: Date?)
    case suspended(reason: String?)
    case revoked(reason: String?)
    case activationRevoked
    case activationDeactivated
}

public enum EntitlementState: Codable, Equatable, Sendable {
    case activationRequired(trial: TrialAvailability)
    case trial(TrialEntitlement)
    case license(LicenseEntitlement)
    case licenseNotValidForVersion(
        code: String,
        updatesUntil: Date,
        releaseVersion: String,
        releasePlatform: String,
        releaseArch: String,
        releasedAt: Date
    )
    case unknown
}

public enum EntitlementFreshness: Equatable, Sendable {
    case fresh(until: Date)
    case offlineGrace(until: Date)
    case offlineGraceExceeded(since: Date)
    case validationRequired(since: Date?)
    case unknown
}

public struct EntitlementSnapshot: Codable, Equatable, Sendable {
    public let state: EntitlementState
    public let source: StateSource
    public let validatedAt: Date?
    public let receivedValidationInterval: TimeInterval?
    public let effectiveValidationInterval: TimeInterval?
    public let offlineGracePeriod: TimeInterval?
    public let lastValidateResponseAt: Date?
    public let signedCredentialValid: Bool?
    public let businessCode: String?
    public let details: [String: String]

    public init(
        state: EntitlementState,
        source: StateSource,
        validatedAt: Date?,
        receivedValidationInterval: TimeInterval?,
        effectiveValidationInterval: TimeInterval?,
        offlineGracePeriod: TimeInterval? = nil,
        lastValidateResponseAt: Date? = nil,
        signedCredentialValid: Bool? = nil,
        businessCode: String? = nil,
        details: [String: String] = [:]
    ) {
        self.state = state
        self.source = source
        self.validatedAt = validatedAt
        self.receivedValidationInterval = receivedValidationInterval
        self.effectiveValidationInterval = effectiveValidationInterval
        self.offlineGracePeriod = offlineGracePeriod
        self.lastValidateResponseAt = lastValidateResponseAt
        self.signedCredentialValid = signedCredentialValid
        self.businessCode = businessCode
        self.details = details
    }

    public func freshness(at now: Date = Date()) -> EntitlementFreshness {
        guard let validatedAt, let effectiveValidationInterval else { return .unknown }
        guard now >= validatedAt else { return .validationRequired(since: nil) }

        var freshUntil = validatedAt.addingTimeInterval(effectiveValidationInterval)
        if let businessExpiry { freshUntil = min(freshUntil, businessExpiry) }
        if now < freshUntil { return .fresh(until: freshUntil) }
        if let businessExpiry, now >= businessExpiry {
            return .validationRequired(since: businessExpiry)
        }
        guard let offlineGracePeriod else {
            return .validationRequired(since: freshUntil)
        }
        let graceUntil = validatedAt.addingTimeInterval(offlineGracePeriod)
        if now < graceUntil { return .offlineGrace(until: graceUntil) }
        return .offlineGraceExceeded(since: graceUntil)
    }

    public func isUsable(at now: Date = Date()) -> Bool {
        guard isActiveState else { return false }
        if let businessExpiry, now >= businessExpiry { return false }
        if signedCredentialValid == false { return false }
        return true
    }

    public func hasFeature(_ feature: String, at now: Date = Date()) -> Bool {
        guard isUsable(at: now) else { return false }
        switch state {
        case .trial(.active(_, let features)):
            return features.contains(feature)
        case .license(.active(let terms, _)):
            return terms.features.contains(feature)
        default:
            return false
        }
    }

    var metadata: OperationMetadata {
        OperationMetadata(
            source: source,
            validatedAt: validatedAt,
            receivedValidationInterval: receivedValidationInterval,
            effectiveValidationInterval: effectiveValidationInterval,
            offlineGracePeriod: offlineGracePeriod,
            lastValidateResponseAt: lastValidateResponseAt
        )
    }

    func withSource(_ source: StateSource) -> EntitlementSnapshot {
        EntitlementSnapshot(
            state: state,
            source: source,
            validatedAt: validatedAt,
            receivedValidationInterval: receivedValidationInterval,
            effectiveValidationInterval: effectiveValidationInterval,
            offlineGracePeriod: offlineGracePeriod,
            lastValidateResponseAt: lastValidateResponseAt,
            signedCredentialValid: signedCredentialValid,
            businessCode: businessCode,
            details: details
        )
    }

    func withValidationReceipt(
        _ receivedAt: Date,
        signedCredentialValid: Bool? = nil
    ) -> EntitlementSnapshot {
        EntitlementSnapshot(
            state: state,
            source: source,
            validatedAt: validatedAt,
            receivedValidationInterval: receivedValidationInterval,
            effectiveValidationInterval: effectiveValidationInterval,
            offlineGracePeriod: offlineGracePeriod,
            lastValidateResponseAt: receivedAt,
            signedCredentialValid: signedCredentialValid ?? self.signedCredentialValid,
            businessCode: businessCode,
            details: details
        )
    }

    func withSignedCredentialValidity(
        _ isValid: Bool,
        source: StateSource
    ) -> EntitlementSnapshot {
        EntitlementSnapshot(
            state: state,
            source: source,
            validatedAt: validatedAt,
            receivedValidationInterval: receivedValidationInterval,
            effectiveValidationInterval: effectiveValidationInterval,
            offlineGracePeriod: offlineGracePeriod,
            lastValidateResponseAt: lastValidateResponseAt,
            signedCredentialValid: isValid,
            businessCode: businessCode,
            details: details
        )
    }

    private var isActiveState: Bool {
        switch state {
        case .trial(.active), .license(.active): return true
        default: return false
        }
    }

    private var businessExpiry: Date? {
        switch state {
        case .trial(.active(let expiresAt, _)): return expiresAt
        case .license(.active(_, let expiresAt)): return expiresAt
        default: return nil
        }
    }
}

public struct ActivationData: Equatable, Sendable {
    public let activationID: String
    public let credentialMode: CredentialMode
    public let snapshot: EntitlementSnapshot

    public init(activationID: String, credentialMode: CredentialMode, snapshot: EntitlementSnapshot) {
        self.activationID = activationID
        self.credentialMode = credentialMode
        self.snapshot = snapshot
    }
}

public struct DeactivationData: Equatable, Sendable {
    public let wasDeactivated: Bool
    public let snapshot: EntitlementSnapshot

    public init(wasDeactivated: Bool, snapshot: EntitlementSnapshot) {
        self.wasDeactivated = wasDeactivated
        self.snapshot = snapshot
    }
}
