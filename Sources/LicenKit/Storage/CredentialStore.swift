import Foundation

public struct StoredCredentials: Codable, Equatable, Sendable {
    public let activationID: String
    public let machineToken: String
    public let credentialMode: CredentialMode
    public let signedLicenseToken: String?
    public let signingKeyID: String?
    public let signedLicenseTokenExpiresAt: Date?

    public init(
        activationID: String,
        machineToken: String,
        credentialMode: CredentialMode,
        signedLicenseToken: String?,
        signingKeyID: String?,
        signedLicenseTokenExpiresAt: Date?
    ) {
        self.activationID = activationID
        self.machineToken = machineToken
        self.credentialMode = credentialMode
        self.signedLicenseToken = signedLicenseToken
        self.signingKeyID = signingKeyID
        self.signedLicenseTokenExpiresAt = signedLicenseTokenExpiresAt
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

public struct StoredEntitlementSnapshot: Codable, Equatable, Sendable {
    public let subject: StoredCredentialSubject
    public let snapshot: EntitlementSnapshot

    public init(subject: StoredCredentialSubject, snapshot: EntitlementSnapshot) {
        self.subject = subject
        self.snapshot = snapshot
    }
}

public protocol CredentialStore: Sendable {
    func loadCredentials(for fingerprint: String) throws -> StoredCredentials?
    func saveCredentials(_ credentials: StoredCredentials, for fingerprint: String) throws
    func clearCredentials(for fingerprint: String) throws
    func loadTrialCredentials(for fingerprint: String) throws -> StoredTrialCredentials?
    func saveTrialCredentials(_ credentials: StoredTrialCredentials, for fingerprint: String) throws
    func clearTrialCredentials(for fingerprint: String) throws
    func loadSnapshot(for fingerprint: String) throws -> StoredEntitlementSnapshot?
    func saveSnapshot(_ snapshot: StoredEntitlementSnapshot, for fingerprint: String) throws
}
