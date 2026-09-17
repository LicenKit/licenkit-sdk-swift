import Foundation

/// LicenKit 标准 API 包装结构
public struct LicenKitApiResponse<T: Decodable & Sendable>: Decodable, Sendable {
    public let success: Bool
    public let data: T?
    public let error: ApiErrorDetail?
}

public struct ApiErrorDetail: Codable, Sendable {
    public let code: String
    public let message: String
}

// MARK: - Activate

public struct ApiActivateRequest: Codable, Sendable {
    public let accountId: String
    public let licenseKey: String
    public let fingerprint: String
    public let platform: String?
    public let name: String?
    
    enum CodingKeys: String, CodingKey {
        case accountId = "account_id"
        case licenseKey = "license_key"
        case fingerprint
        case platform
        case name
    }
}

public struct ApiPolicyInfo: Codable, Sendable {
    public let name: String
    public let maxMachines: Int
    public let offlineGracePeriod: Int
    public let features: [String]
    
    enum CodingKeys: String, CodingKey {
        case name
        case maxMachines = "max_machines"
        case offlineGracePeriod = "offline_grace_period"
        case features
    }
}

// MARK: - Flexible Date Decoder

/// 弹性时间戳解码结构：优先解码秒级整数时间戳 (方案 A)，亦兼容浮点秒数及带/不带毫秒的 ISO 8601 字符串
public struct FlexibleDate: Codable, Sendable, Equatable {
    public let date: Date?
    
    public init(_ date: Date?) {
        self.date = date
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self.date = nil
            return
        }
        
        // 1. 优先解析秒级数字时间戳 (方案 A 标准)
        if let timestamp = try? container.decode(Int64.self) {
            self.date = Date(timeIntervalSince1970: TimeInterval(timestamp))
            return
        }
        if let timestamp = try? container.decode(Double.self) {
            self.date = Date(timeIntervalSince1970: timestamp)
            return
        }
        
        // 2. 兼容解析 ISO 8601 字符串
        if let dateString = try? container.decode(String.self) {
            self.date = FlexibleDate.parseISO8601(dateString)
            return
        }
        
        self.date = nil
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let date = date {
            try container.encode(Int64(date.timeIntervalSince1970))
        } else {
            try container.encodeNil()
        }
    }
    
    public static func parseISO8601(_ string: String) -> Date? {
        let formatterWithMillis = ISO8601DateFormatter()
        formatterWithMillis.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = formatterWithMillis.date(from: string) {
            return d
        }
        let standardFormatter = ISO8601DateFormatter()
        standardFormatter.formatOptions = [.withInternetDateTime]
        return standardFormatter.date(from: string)
    }
}

public struct ApiActivateResponse: Codable, Sendable {
    public let activated: Bool
    public let reused: Bool
    public let machineId: String
    public let scheme: String
    public let token: String?
    public let tokenExpiresAt: FlexibleDate?
    public let licenseExpiresAt: FlexibleDate?
    public let tokenExpiresAtIso: String?
    public let licenseExpiresAtIso: String?
    public let policy: ApiPolicyInfo
    
    enum CodingKeys: String, CodingKey {
        case activated
        case reused
        case machineId = "machine_id"
        case scheme
        case token
        case tokenExpiresAt = "token_expires_at"
        case licenseExpiresAt = "license_expires_at"
        case tokenExpiresAtIso = "token_expires_at_iso"
        case licenseExpiresAtIso = "license_expires_at_iso"
        case policy
    }
}

// MARK: - Validate (Heartbeat)

public struct ApiValidateRequest: Codable, Sendable {
    public let accountId: String
    public let licenseKey: String
    public let fingerprint: String
    
    enum CodingKeys: String, CodingKey {
        case accountId = "account_id"
        case licenseKey = "license_key"
        case fingerprint
    }
}

public struct ApiValidateResponse: Codable, Sendable {
    public let valid: Bool
    public let scheme: String?
    public let token: String?
    public let tokenExpiresAt: FlexibleDate?
    public let licenseExpiresAt: FlexibleDate?
    public let tokenExpiresAtIso: String?
    public let licenseExpiresAtIso: String?
    public let lastHeartbeatAt: FlexibleDate?
    public let lastHeartbeatAtIso: String?
    public let reason: String?
    
    enum CodingKeys: String, CodingKey {
        case valid
        case scheme
        case token
        case tokenExpiresAt = "token_expires_at"
        case licenseExpiresAt = "license_expires_at"
        case tokenExpiresAtIso = "token_expires_at_iso"
        case licenseExpiresAtIso = "license_expires_at_iso"
        case lastHeartbeatAt = "last_heartbeat_at"
        case lastHeartbeatAtIso = "last_heartbeat_at_iso"
        case reason
    }
}

// MARK: - Deactivate

public struct ApiDeactivateRequest: Codable, Sendable {
    public let accountId: String
    public let licenseKey: String
    public let fingerprint: String
    
    enum CodingKeys: String, CodingKey {
        case accountId = "account_id"
        case licenseKey = "license_key"
        case fingerprint
    }
}

public struct ApiDeactivateResponse: Codable, Sendable {
    public let deactivated: Bool
    public let message: String
}

// MARK: - Product Public Key

public struct ApiProductPublicKeyResponse: Codable, Sendable {
    public let productId: String
    public let kid: String
    public let algorithm: String
    public let publicKey: String
}

// MARK: - Public Client Results

public struct ActivationResult: Sendable {
    public let activated: Bool
    public let reused: Bool
    public let machineId: String
    public let token: String
    public let tokenExpiresAt: Date?
    public let licenseExpiresAt: Date?
    public let policy: ApiPolicyInfo
}

public struct ValidationResult: Sendable {
    public let valid: Bool
    public let token: String?
    public let tokenExpiresAt: Date?
    public let licenseExpiresAt: Date?
    public let reason: String?
    
    public init(
        valid: Bool,
        token: String? = nil,
        tokenExpiresAt: Date? = nil,
        licenseExpiresAt: Date? = nil,
        reason: String? = nil
    ) {
        self.valid = valid
        self.token = token
        self.tokenExpiresAt = tokenExpiresAt
        self.licenseExpiresAt = licenseExpiresAt
        self.reason = reason
    }
}

// MARK: - Trial

public struct ApiTrialRequest: Codable, Sendable {
    public let accountId: String
    public let productId: String
    public let fingerprint: String
    
    enum CodingKeys: String, CodingKey {
        case accountId = "account_id"
        case productId = "product_id"
        case fingerprint
    }
    
    public init(accountId: String, productId: String, fingerprint: String) {
        self.accountId = accountId
        self.productId = productId
        self.fingerprint = fingerprint
    }
}

public struct ApiTrialResponse: Codable, Sendable {
    public let trialClaimed: Bool
    public let alreadyClaimed: Bool
    public let expired: Bool
    public let claimedAt: FlexibleDate?
    public let expiresAt: FlexibleDate?
    public let claimedAtIso: String?
    public let expiresAtIso: String?
    public let token: String?
    public let features: [String]
    
    enum CodingKeys: String, CodingKey {
        case trialClaimed = "trial_claimed"
        case alreadyClaimed = "already_claimed"
        case expired
        case claimedAt = "claimed_at"
        case expiresAt = "expires_at"
        case claimedAtIso = "claimed_at_iso"
        case expiresAtIso = "expires_at_iso"
        case token
        case features
    }
}

public struct TrialResult: Sendable {
    public let trialClaimed: Bool
    public let alreadyClaimed: Bool
    public let expired: Bool
    public let token: String?
    public let claimedAt: Date?
    public let expiresAt: Date?
    public let features: [String]
    
    public init(
        trialClaimed: Bool,
        alreadyClaimed: Bool,
        expired: Bool,
        token: String?,
        claimedAt: Date?,
        expiresAt: Date?,
        features: [String]
    ) {
        self.trialClaimed = trialClaimed
        self.alreadyClaimed = alreadyClaimed
        self.expired = expired
        self.token = token
        self.claimedAt = claimedAt
        self.expiresAt = expiresAt
        self.features = features
    }
}
