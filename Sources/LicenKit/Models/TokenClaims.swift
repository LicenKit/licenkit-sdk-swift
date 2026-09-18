import Foundation

/// 离线 Token 的头部声明
public struct OfflineTokenHeader: Codable, Equatable, Sendable {
    public let alg: String
    public let typ: String
    public let kid: String?
    
    public init(alg: String = "Ed25519", typ: String = "LK-TOKEN", kid: String? = nil) {
        self.alg = alg
        self.typ = typ
        self.kid = kid
    }
}

/// 离线完整商业许可证 Claims
public struct LicenseClaims: Codable, Equatable, Sendable {
    public let typ: String
    public let licenseId: String
    public let sub: String
    public var licenseKey: String { sub }
    public let accountId: String
    public let productId: String
    public let policyId: String
    public let fingerprint: String
    public let issuedAtTimestamp: Int64
    public let expirationTimestamp: Int64
    public let features: [String]
    
    enum CodingKeys: String, CodingKey {
        case typ
        case licenseId = "lic_id"
        case sub
        case accountId = "acc"
        case productId = "prd"
        case policyId = "pol"
        case fingerprint = "fp"
        case issuedAtTimestamp = "iat"
        case expirationTimestamp = "exp"
        case features = "fea"
    }
    
    public var issuedAt: Date {
        Date(timeIntervalSince1970: TimeInterval(issuedAtTimestamp))
    }
    
    public var expirationDate: Date {
        Date(timeIntervalSince1970: TimeInterval(expirationTimestamp))
    }
    
    public var isExpired: Bool {
        Date() > expirationDate
    }
    
    public init(
        typ: String = "license",
        licenseId: String,
        sub: String,
        accountId: String,
        productId: String,
        policyId: String,
        fingerprint: String,
        issuedAtTimestamp: Int64,
        expirationTimestamp: Int64,
        features: [String] = []
    ) {
        self.typ = typ
        self.licenseId = licenseId
        self.sub = sub
        self.accountId = accountId
        self.productId = productId
        self.policyId = policyId
        self.fingerprint = fingerprint
        self.issuedAtTimestamp = issuedAtTimestamp
        self.expirationTimestamp = expirationTimestamp
        self.features = features
    }

    public init(
        typ: String = "license",
        licenseId: String,
        licenseKey: String,
        accountId: String,
        productId: String,
        policyId: String,
        fingerprint: String,
        issuedAtTimestamp: Int64,
        expirationTimestamp: Int64,
        features: [String] = []
    ) {
        self.init(
            typ: typ,
            licenseId: licenseId,
            sub: licenseKey,
            accountId: accountId,
            productId: productId,
            policyId: policyId,
            fingerprint: fingerprint,
            issuedAtTimestamp: issuedAtTimestamp,
            expirationTimestamp: expirationTimestamp,
            features: features
        )
    }
}

/// 离线试用版 Claims
public struct TrialClaims: Codable, Equatable, Sendable {
    public let typ: String
    public let accountId: String
    public let productId: String
    public let fingerprint: String
    public let issuedAtTimestamp: Int64
    public let expirationTimestamp: Int64
    public let features: [String]
    
    enum CodingKeys: String, CodingKey {
        case typ
        case accountId = "acc"
        case productId = "prd"
        case fingerprint = "fp"
        case issuedAtTimestamp = "iat"
        case expirationTimestamp = "exp"
        case features = "fea"
    }
    
    public var issuedAt: Date {
        Date(timeIntervalSince1970: TimeInterval(issuedAtTimestamp))
    }
    
    public var expirationDate: Date {
        Date(timeIntervalSince1970: TimeInterval(expirationTimestamp))
    }
    
    public var isExpired: Bool {
        Date() > expirationDate
    }
    
    public init(
        typ: String = "trial",
        accountId: String,
        productId: String,
        fingerprint: String,
        issuedAtTimestamp: Int64,
        expirationTimestamp: Int64,
        features: [String] = []
    ) {
        self.typ = typ
        self.accountId = accountId
        self.productId = productId
        self.fingerprint = fingerprint
        self.issuedAtTimestamp = issuedAtTimestamp
        self.expirationTimestamp = expirationTimestamp
        self.features = features
    }
}

/// 聚合离线 Claims 枚举 (正式授权与试用授权)
public enum OfflineClaims: Equatable, Sendable {
    case license(LicenseClaims)
    case trial(TrialClaims)
    
    public var fingerprint: String {
        switch self {
        case .license(let claims):
            return claims.fingerprint
        case .trial(let claims):
            return claims.fingerprint
        }
    }
    
    public var features: [String] {
        switch self {
        case .license(let claims):
            return claims.features
        case .trial(let claims):
            return claims.features
        }
    }
    
    public var expirationDate: Date {
        switch self {
        case .license(let claims):
            return claims.expirationDate
        case .trial(let claims):
            return claims.expirationDate
        }
    }
}
