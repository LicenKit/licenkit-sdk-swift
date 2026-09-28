import Foundation

public struct StoredCredentials: Codable, Equatable, Sendable {
    public let activationID: String
    public let machineToken: String
    public let credentialMode: CredentialMode
    public let signedLicenseToken: String?
    public let signingKeyID: String?

    public init(
        activationID: String,
        machineToken: String,
        credentialMode: CredentialMode,
        signedLicenseToken: String?,
        signingKeyID: String?
    ) {
        self.activationID = activationID
        self.machineToken = machineToken
        self.credentialMode = credentialMode
        self.signedLicenseToken = signedLicenseToken
        self.signingKeyID = signingKeyID
    }
}

public struct StoredActivationVerification: Codable, Equatable, Sendable {
    public let machineToken: String

    public init(machineToken: String) {
        self.machineToken = machineToken
    }
}

public struct StoredTrialVerification: Codable, Equatable, Sendable {
    public let trialToken: String

    public init(trialToken: String) {
        self.trialToken = trialToken
    }
}

public struct StoredTrialCredentials: Codable, Equatable, Sendable {
    public let trialID: String
    public let trialToken: String

    public init(trialID: String, trialToken: String) {
        self.trialID = trialID
        self.trialToken = trialToken
    }
}

public enum StoredCredentialSubject: String, Codable, Equatable, Sendable {
    case license
    case trial
    case none
}

public struct ValidationBuildIdentity: Codable, Equatable, Sendable {
    public let version: String
    public let platform: String
    public let arch: String

    public init(version: String, platform: String, arch: String) {
        self.version = version
        self.platform = platform
        self.arch = arch
    }
}

public struct StoredValidationAttempt: Codable, Equatable, Sendable {
    public let startedAt: Date
    public let build: ValidationBuildIdentity

    public init(startedAt: Date, build: ValidationBuildIdentity) {
        self.startedAt = startedAt
        self.build = build
    }
}

public struct StoredEntitlementSnapshot: Codable, Equatable, Sendable {
    public let subject: StoredCredentialSubject
    public let snapshot: EntitlementSnapshot
    public let validatedBuild: ValidationBuildIdentity?

    public init(subject: StoredCredentialSubject, snapshot: EntitlementSnapshot, validatedBuild: ValidationBuildIdentity? = nil) {
        self.subject = subject
        self.snapshot = snapshot
        self.validatedBuild = validatedBuild
    }
}

public protocol CredentialStore: Sendable {
    func loadValidationAttempt(for fingerprint: String) throws -> StoredValidationAttempt?
    func saveValidationAttempt(_ attempt: StoredValidationAttempt, for fingerprint: String) throws
    func loadActivationVerification(for fingerprint: String) throws -> StoredActivationVerification?
    func saveActivationVerification(_ verification: StoredActivationVerification, for fingerprint: String) throws
    func clearActivationVerification(for fingerprint: String) throws
    func loadCredentials(for fingerprint: String) throws -> StoredCredentials?
    func saveCredentials(_ credentials: StoredCredentials, for fingerprint: String) throws
    func clearCredentials(for fingerprint: String) throws
    func loadTrialCredentials(for fingerprint: String) throws -> StoredTrialCredentials?
    func saveTrialCredentials(_ credentials: StoredTrialCredentials, for fingerprint: String) throws
    func clearTrialCredentials(for fingerprint: String) throws
    func loadTrialVerification(for fingerprint: String) throws -> StoredTrialVerification?
    func saveTrialVerification(_ verification: StoredTrialVerification, for fingerprint: String) throws
    func clearTrialVerification(for fingerprint: String) throws
    func loadSnapshot(for fingerprint: String) throws -> StoredEntitlementSnapshot?
    func saveSnapshot(_ snapshot: StoredEntitlementSnapshot, for fingerprint: String) throws
}
