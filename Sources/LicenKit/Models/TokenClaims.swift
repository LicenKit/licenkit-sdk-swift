import Foundation

public struct SignedLicenseTokenHeader: Codable, Equatable, Sendable {
    public let alg: String
    public let typ: String
    public let kid: String

    public init(alg: String = "EdDSA", typ: String = "licenkit-license+jwt", kid: String) {
        self.alg = alg
        self.typ = typ
        self.kid = kid
    }
}

public struct LicenseClaims: Codable, Equatable, Sendable {
    public let licenseID: String
    public let activationID: String
    public let instanceID: String
    public let productID: String
    public let releaseID: String
    public let releaseVersion: String
    public let releasePlatform: String
    public let releasedAtTimestamp: Int64
    public let fingerprint: String
    public let issuedAtTimestamp: Int64
    public let tokenExpiresAtTimestamp: Int64
    public let licenseExpiresAtTimestamp: Int64?
    public let updatesUntilTimestamp: Int64?
    public let features: [String]

    enum CodingKeys: String, CodingKey {
        case licenseID = "lic"
        case activationID = "act"
        case instanceID = "ins"
        case productID = "prd"
        case releaseID = "rel"
        case releaseVersion = "ver"
        case releasePlatform = "plt"
        case releasedAtTimestamp = "rat"
        case fingerprint = "fp"
        case issuedAtTimestamp = "iat"
        case tokenExpiresAtTimestamp = "exp"
        case licenseExpiresAtTimestamp = "lexp"
        case updatesUntilTimestamp = "upd"
        case features = "fea"
    }

    public var issuedAt: Date { Date(timeIntervalSince1970: TimeInterval(issuedAtTimestamp)) }
    public var tokenExpiresAt: Date { Date(timeIntervalSince1970: TimeInterval(tokenExpiresAtTimestamp)) }
    public var licenseExpiresAt: Date? { licenseExpiresAtTimestamp.map { Date(timeIntervalSince1970: TimeInterval($0)) } }
    public var updatesUntil: Date? { updatesUntilTimestamp.map { Date(timeIntervalSince1970: TimeInterval($0)) } }
    public var releasedAt: Date { Date(timeIntervalSince1970: TimeInterval(releasedAtTimestamp)) }

    public init(
        licenseID: String,
        activationID: String,
        instanceID: String,
        productID: String,
        releaseID: String,
        releaseVersion: String,
        releasePlatform: String,
        releasedAtTimestamp: Int64,
        fingerprint: String,
        issuedAtTimestamp: Int64,
        tokenExpiresAtTimestamp: Int64,
        licenseExpiresAtTimestamp: Int64?,
        updatesUntilTimestamp: Int64?,
        features: [String]
    ) {
        self.licenseID = licenseID
        self.activationID = activationID
        self.instanceID = instanceID
        self.productID = productID
        self.releaseID = releaseID
        self.releaseVersion = releaseVersion
        self.releasePlatform = releasePlatform
        self.releasedAtTimestamp = releasedAtTimestamp
        self.fingerprint = fingerprint
        self.issuedAtTimestamp = issuedAtTimestamp
        self.tokenExpiresAtTimestamp = tokenExpiresAtTimestamp
        self.licenseExpiresAtTimestamp = licenseExpiresAtTimestamp
        self.updatesUntilTimestamp = updatesUntilTimestamp
        self.features = features
    }
}
