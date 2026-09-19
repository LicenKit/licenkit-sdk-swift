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

public struct APIActivateRequest: Codable, Sendable {
    public let accountID: String
    public let productID: String
    public let licenseKey: String
    public let fingerprint: String
    public let devicePlatform: String
    public let name: String?
    public let releaseVersion: String
    public let releasePlatform: String

    enum CodingKeys: String, CodingKey {
        case accountID = "account_id"
        case productID = "product_id"
        case licenseKey = "license_key"
        case fingerprint
        case devicePlatform = "device_platform"
        case name
        case releaseVersion = "release_version"
        case releasePlatform = "release_platform"
    }
}

public struct APICredentialResponse: Codable, Sendable {
    public let activationID: String
    public let machineToken: String
    public let credentialMode: CredentialMode
    public let signedLicenseToken: String?
    public let signedLicenseTokenExpiresAt: FlexibleDate?
    public let signingKeyID: String?
    public let licenseExpiresAt: FlexibleDate?
    public let terms: LicenseTerms

    enum CodingKeys: String, CodingKey {
        case activationID = "activation_id"
        case machineToken = "machine_token"
        case credentialMode = "credential_mode"
        case signedLicenseToken = "signed_license_token"
        case signedLicenseTokenExpiresAt = "signed_license_token_expires_at"
        case signingKeyID = "signing_key_id"
        case licenseExpiresAt = "license_expires_at"
        case terms
    }
}

public struct APIValidateRequest: Codable, Sendable {
    public let accountID: String
    public let productID: String
    public let activationID: String
    public let machineToken: String
    public let fingerprint: String
    public let devicePlatform: String
    public let releaseVersion: String
    public let releasePlatform: String

    enum CodingKeys: String, CodingKey {
        case accountID = "account_id"
        case productID = "product_id"
        case activationID = "activation_id"
        case machineToken = "machine_token"
        case fingerprint
        case devicePlatform = "device_platform"
        case releaseVersion = "release_version"
        case releasePlatform = "release_platform"
    }
}

public struct APIDeactivateRequest: Codable, Sendable {
    public let accountID: String
    public let productID: String
    public let activationID: String
    public let machineToken: String
    public let fingerprint: String

    enum CodingKeys: String, CodingKey {
        case accountID = "account_id"
        case productID = "product_id"
        case activationID = "activation_id"
        case machineToken = "machine_token"
        case fingerprint
    }
}

public struct APIDeactivateResponse: Codable, Sendable {
    public let activationID: String
    public let status: String

    enum CodingKeys: String, CodingKey {
        case activationID = "activation_id"
        case status
    }
}

public struct APITrialClaimRequest: Codable, Sendable {
    public let accountID: String
    public let productID: String
    public let fingerprint: String
    public let devicePlatform: String
    public let releaseVersion: String
    public let releasePlatform: String

    enum CodingKeys: String, CodingKey {
        case accountID = "account_id"
        case productID = "product_id"
        case fingerprint
        case devicePlatform = "device_platform"
        case releaseVersion = "release_version"
        case releasePlatform = "release_platform"
    }
}

public struct APITrialValidateRequest: Codable, Sendable {
    public let accountID: String
    public let productID: String
    public let trialID: String
    public let trialToken: String
    public let fingerprint: String
    public let releaseVersion: String
    public let releasePlatform: String

    enum CodingKeys: String, CodingKey {
        case accountID = "account_id"
        case productID = "product_id"
        case trialID = "trial_id"
        case trialToken = "trial_token"
        case fingerprint
        case releaseVersion = "release_version"
        case releasePlatform = "release_platform"
    }
}

public struct APITrialResponse: Codable, Sendable {
    public let trialID: String
    public let trialToken: String?
    public let status: String
    public let expiresAt: FlexibleDate
    public let features: [String]

    enum CodingKeys: String, CodingKey {
        case trialID = "trial_id"
        case trialToken = "trial_token"
        case status
        case expiresAt = "expires_at"
        case features
    }
}

public struct ActivationResult: Equatable, Sendable {
    public let activationID: String
    public let credentialMode: CredentialMode
    public let status: LicenseStatus
}
