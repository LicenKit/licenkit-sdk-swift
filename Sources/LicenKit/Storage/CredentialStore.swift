import Foundation

public struct StoredCredentials: Codable, Equatable, Sendable {
    public let activationID: String
    public let machineToken: String
    public let credentialMode: CredentialMode
    public let signedLicenseToken: String?
    public let signingKeyID: String?
    public let lastValidatedAt: Date
    public let cachedTerms: LicenseTerms

    public init(
        activationID: String,
        machineToken: String,
        credentialMode: CredentialMode,
        signedLicenseToken: String?,
        signingKeyID: String?,
        lastValidatedAt: Date,
        cachedTerms: LicenseTerms
    ) {
        self.activationID = activationID
        self.machineToken = machineToken
        self.credentialMode = credentialMode
        self.signedLicenseToken = signedLicenseToken
        self.signingKeyID = signingKeyID
        self.lastValidatedAt = lastValidatedAt
        self.cachedTerms = cachedTerms
    }
}

public struct StoredTrialCredentials: Codable, Equatable, Sendable {
    public let trialID: String
    public let trialToken: String
    public let expiresAt: Date
    public let features: [String]
    public let lastValidatedAt: Date

    public init(trialID: String, trialToken: String, expiresAt: Date, features: [String], lastValidatedAt: Date) {
        self.trialID = trialID
        self.trialToken = trialToken
        self.expiresAt = expiresAt
        self.features = features
        self.lastValidatedAt = lastValidatedAt
    }
}

public protocol CredentialStore: Sendable {
    func loadCredentials(for fingerprint: String) throws -> StoredCredentials?
    func saveCredentials(_ credentials: StoredCredentials, for fingerprint: String) throws
    func clearCredentials(for fingerprint: String) throws
    func loadTrialCredentials(for fingerprint: String) throws -> StoredTrialCredentials?
    func saveTrialCredentials(_ credentials: StoredTrialCredentials, for fingerprint: String) throws
    func clearTrialCredentials(for fingerprint: String) throws
}
