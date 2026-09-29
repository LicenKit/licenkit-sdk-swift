import Foundation

public struct LicenKitAPIResponse<T: Decodable & Sendable>: Decodable, Sendable {
    public let success: Bool
    public let data: T?
    public let error: APIErrorDetail?
}

public enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value") }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public var diagnosticString: String {
        switch self {
        case .string(let value): return value
        case .number(let value): return value.rounded() == value ? String(Int64(value)) : String(value)
        case .bool(let value): return String(value)
        case .null: return "null"
        case .object, .array:
            return (try? String(data: JSONEncoder().encode(self), encoding: .utf8)) ?? "[unserializable]"
        }
    }
}

public struct APIErrorDetail: Codable, Equatable, Sendable {
    public let code: String
    public let message: String
    public let requestID: String?
    public let details: [String: JSONValue]

    enum CodingKeys: String, CodingKey {
        case code, message, details
        case requestID = "request_id"
    }

    public init(code: String, message: String, requestID: String? = nil, details: [String: JSONValue] = [:]) {
        self.code = code
        self.message = message
        self.requestID = requestID
        self.details = details
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(String.self, forKey: .code)
        message = try container.decode(String.self, forKey: .message)
        requestID = try container.decodeIfPresent(String.self, forKey: .requestID)
        details = try container.decodeIfPresent([String: JSONValue].self, forKey: .details) ?? [:]
    }
}

public struct FlexibleDate: Codable, Equatable, Sendable {
    public let date: Date?

    public init(_ date: Date?) { self.date = date }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { date = nil; return }
        if let seconds = try? container.decode(Int64.self) {
            date = Date(timeIntervalSince1970: TimeInterval(seconds)); return
        }
        if let seconds = try? container.decode(Double.self) {
            date = Date(timeIntervalSince1970: seconds); return
        }
        if let string = try? container.decode(String.self), let parsed = Self.parseISO8601(string) {
            date = parsed; return
        }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected Unix timestamp, ISO-8601 date, or null")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let date { try container.encode(Int64(date.timeIntervalSince1970)) } else { try container.encodeNil() }
    }

    public static func parseISO8601(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }
}

public enum CredentialMode: String, Codable, Equatable, Sendable {
    case opaque
    case signed
}

public struct LicenseTerms: Codable, Equatable, Sendable {
    public let maxActivations: Int
    public let features: [String]
    public let updatesUntil: FlexibleDate?

    enum CodingKeys: String, CodingKey {
        case maxActivations = "max_activations"
        case features
        case updatesUntil = "updates_until"
    }

    public init(maxActivations: Int, features: [String], updatesUntil: Date?) {
        self.maxActivations = maxActivations
        self.features = features
        self.updatesUntil = updatesUntil.map(FlexibleDate.init)
    }
}

public struct APIResponseMetadata: Codable, Equatable, Sendable {
    public let requestID: String

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requestID = try container.decode(String.self, forKey: .requestID)
        guard !requestID.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .requestID,
                in: container,
                debugDescription: "request_id must not be empty"
            )
        }
    }
}

public struct APIValidationMetadata: Codable, Equatable, Sendable {
    public let validationIntervalSeconds: TimeInterval
    public let offlineGraceSeconds: TimeInterval?
    public let validatedAt: FlexibleDate

    enum CodingKeys: String, CodingKey {
        case validationIntervalSeconds = "validation_interval_seconds"
        case offlineGraceSeconds = "offline_grace_seconds"
        case validatedAt = "validated_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        validationIntervalSeconds = try container.decode(
            TimeInterval.self,
            forKey: .validationIntervalSeconds
        )
        guard validationIntervalSeconds >= 3_600, validationIntervalSeconds <= 86_400 else {
            throw DecodingError.dataCorruptedError(
                forKey: .validationIntervalSeconds,
                in: container,
                debugDescription: "validation_interval_seconds must be between 3600 and 86400"
            )
        }
        guard container.contains(.offlineGraceSeconds) else {
            throw DecodingError.keyNotFound(
                CodingKeys.offlineGraceSeconds,
                .init(
                    codingPath: container.codingPath,
                    debugDescription: "offline_grace_seconds must be present"
                )
            )
        }
        offlineGraceSeconds = try container.decodeIfPresent(
            TimeInterval.self,
            forKey: .offlineGraceSeconds
        )
        if let offlineGraceSeconds, offlineGraceSeconds <= 0 {
            throw DecodingError.dataCorruptedError(
                forKey: .offlineGraceSeconds,
                in: container,
                debugDescription: "offline_grace_seconds must be positive when present"
            )
        }
        validatedAt = try container.decode(FlexibleDate.self, forKey: .validatedAt)
    }
}

public struct APITrialAvailability: Codable, Equatable, Sendable {
    public let status: String
    public let durationSeconds: TimeInterval?
    public let features: [String]?
    public let reason: String?
    public let code: String?

    enum CodingKeys: String, CodingKey {
        case status
        case durationSeconds = "duration_seconds"
        case features, reason, code
    }
}

public struct APIEntitlementState: Codable, Equatable, Sendable {
    public let kind: String
    public let status: String?
    public let code: String?
    public let expiresAt: FlexibleDate?
    public let terms: LicenseTerms?
    public let features: [String]?
    public let reason: String?
    public let trial: APITrialAvailability?
    public let releaseVersion: String?
    public let releasePlatform: String?
    public let releaseArch: String?
    public let updatesUntil: FlexibleDate?
    public let releasedAt: FlexibleDate?
    public let details: [String: JSONValue]

    enum CodingKeys: String, CodingKey {
        case kind, status, code, terms, features, reason, trial, details
        case expiresAt = "expires_at"
        case releaseVersion = "release_version"
        case releasePlatform = "release_platform"
        case releaseArch = "release_arch"
        case updatesUntil = "updates_until"
        case releasedAt = "released_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(String.self, forKey: .kind)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        code = try container.decodeIfPresent(String.self, forKey: .code)
        expiresAt = try container.decodeIfPresent(FlexibleDate.self, forKey: .expiresAt)
        terms = try container.decodeIfPresent(LicenseTerms.self, forKey: .terms)
        features = try container.decodeIfPresent([String].self, forKey: .features)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        trial = try container.decodeIfPresent(APITrialAvailability.self, forKey: .trial)
        releaseVersion = try container.decodeIfPresent(String.self, forKey: .releaseVersion)
        releasePlatform = try container.decodeIfPresent(String.self, forKey: .releasePlatform)
        releaseArch = try container.decodeIfPresent(String.self, forKey: .releaseArch)
        updatesUntil = try container.decodeIfPresent(FlexibleDate.self, forKey: .updatesUntil)
        releasedAt = try container.decodeIfPresent(FlexibleDate.self, forKey: .releasedAt)
        details = try container.decodeIfPresent([String: JSONValue].self, forKey: .details) ?? [:]
    }
}

public struct APIActivateRequest: Codable, Sendable {
    public let productID: String
    public let licenseKey: String
    public let machineToken: String
    public let fingerprint: String
    public let devicePlatform: String
    public let name: String?
    public let releaseVersion: String
    public let releasePlatform: String
    public let releaseArch: String
    public let billingEnvironment: LicenKitEnvironment

    enum CodingKeys: String, CodingKey {
        case productID = "product_id"
        case licenseKey = "license_key"
        case machineToken = "machine_token"
        case fingerprint
        case devicePlatform = "device_platform"
        case name
        case releaseVersion = "release_version"
        case releasePlatform = "release_platform"
        case releaseArch = "release_arch"
        case billingEnvironment = "billing_environment"
    }
}

public struct APICredentialResponse: Codable, Sendable {
    public let activationID: String
    public let machineToken: String
    public let billingEnvironment: LicenKitEnvironment?
    public let credentialMode: CredentialMode
    public let signedLicenseToken: String?
    public let signingKeyID: String?
    public let licenseExpiresAt: FlexibleDate?
    public let terms: LicenseTerms
    public let state: APIEntitlementState
    public let validation: APIValidationMetadata
    public let meta: APIResponseMetadata

    enum CodingKeys: String, CodingKey {
        case activationID = "activation_id"
        case machineToken = "machine_token"
        case billingEnvironment = "billing_environment"
        case credentialMode = "credential_mode"
        case signedLicenseToken = "signed_license_token"
        case signingKeyID = "signing_key_id"
        case licenseExpiresAt = "license_expires_at"
        case terms, state, validation, meta
    }
}

public enum APIValidationCredential: Encodable, Equatable, Sendable {
    case license(activationID: String, machineToken: String)
    case trial(trialID: String, trialToken: String)
    case none

    private enum CodingKeys: String, CodingKey {
        case kind
        case activationID = "activation_id"
        case machineToken = "machine_token"
        case trialID = "trial_id"
        case trialToken = "trial_token"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .license(let activationID, let machineToken):
            try container.encode("license", forKey: .kind)
            try container.encode(activationID, forKey: .activationID)
            try container.encode(machineToken, forKey: .machineToken)
        case .trial(let trialID, let trialToken):
            try container.encode("trial", forKey: .kind)
            try container.encode(trialID, forKey: .trialID)
            try container.encode(trialToken, forKey: .trialToken)
        case .none:
            try container.encode("none", forKey: .kind)
        }
    }
}

public struct APIValidateRequest: Encodable, Sendable {
    public let productID: String
    public let fingerprint: String
    public let releaseVersion: String
    public let releasePlatform: String
    public let releaseArch: String
    public let billingEnvironment: LicenKitEnvironment
    public let credential: APIValidationCredential

    enum CodingKeys: String, CodingKey {
        case productID = "product_id"
        case fingerprint
        case releaseVersion = "release_version"
        case releasePlatform = "release_platform"
        case releaseArch = "release_arch"
        case billingEnvironment = "billing_environment"
        case credential
    }
}

public struct APICredentialUpdate: Codable, Sendable {
    public let credentialMode: CredentialMode
    public let signedLicenseToken: String?
    public let signingKeyID: String?
    public let billingEnvironment: LicenKitEnvironment?

    enum CodingKeys: String, CodingKey {
        case credentialMode = "credential_mode"
        case signedLicenseToken = "signed_license_token"
        case signingKeyID = "signing_key_id"
        case billingEnvironment = "billing_environment"
    }
}

public struct APIValidateResponse: Codable, Sendable {
    public let state: APIEntitlementState
    public let credentialUpdate: APICredentialUpdate?
    public let billingEnvironment: LicenKitEnvironment?
    public let validation: APIValidationMetadata
    public let meta: APIResponseMetadata

    enum CodingKeys: String, CodingKey {
        case state, validation, meta
        case credentialUpdate = "credential_update"
        case billingEnvironment = "billing_environment"
    }
}

public struct APIDeactivateRequest: Codable, Sendable {
    public let productID: String
    public let activationID: String
    public let machineToken: String
    public let fingerprint: String

    enum CodingKeys: String, CodingKey {
        case productID = "product_id"
        case activationID = "activation_id"
        case machineToken = "machine_token"
        case fingerprint
    }
}

public struct APIDeactivateResponse: Codable, Sendable {
    public let activationID: String
    public let status: String
    public let meta: APIResponseMetadata

    enum CodingKeys: String, CodingKey {
        case activationID = "activation_id"
        case status, meta
    }
}

public struct APITrialClaimRequest: Codable, Sendable {
    public let productID: String
    public let fingerprint: String
    public let trialToken: String
    public let devicePlatform: String
    public let releaseVersion: String
    public let releasePlatform: String
    public let releaseArch: String

    enum CodingKeys: String, CodingKey {
        case productID = "product_id"
        case fingerprint
        case trialToken = "trial_token"
        case devicePlatform = "device_platform"
        case releaseVersion = "release_version"
        case releasePlatform = "release_platform"
        case releaseArch = "release_arch"
    }
}

public struct APITrialClaimResponse: Codable, Sendable {
    public let trialID: String
    public let trialToken: String
    public let status: String
    public let expiresAt: FlexibleDate
    public let features: [String]
    public let state: APIEntitlementState
    public let validation: APIValidationMetadata
    public let meta: APIResponseMetadata

    enum CodingKeys: String, CodingKey {
        case trialID = "trial_id"
        case trialToken = "trial_token"
        case status
        case expiresAt = "expires_at"
        case features, state, validation, meta
    }
}
