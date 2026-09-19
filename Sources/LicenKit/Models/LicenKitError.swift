import Foundation

public enum TransportErrorKind: Equatable, Sendable {
    case network
    case dns
    case tls
    case timeout
    case server(statusCode: Int, code: String?, requestID: String?, details: [String: String])
    case invalidResponse(statusCode: Int?)
}

public enum LicenKitError: Error, LocalizedError, Equatable, Sendable {
    case unactivated
    case trialNotStarted
    case apiError(code: String, message: String, requestID: String?, details: [String: String])
    case transportError(kind: TransportErrorKind, underlyingDescription: String)
    case missingTrustedSigningKey(keyID: String)
    case invalidSignedLicenseToken(reason: String)
    case releaseNotQualified(status: LicenseStatus)
    case credentialStorageError(operation: String, status: Int32)
    case fingerprintError(reason: String)
    case protocolError(reason: String)

    public var errorDescription: String? {
        switch self {
        case .unactivated:
            return "No License activation is stored on this device."
        case .trialNotStarted:
            return "No Product trial is stored on this device."
        case .apiError(let code, let message, let requestID, _):
            return "LicenKit API error [\(code)]\(requestID.map { " request=\($0)" } ?? ""): \(message)"
        case .transportError(_, let description):
            return "LicenKit transport error: \(description)"
        case .missingTrustedSigningKey(let keyID):
            return "No trusted signing key is embedded for key ID '\(keyID)'."
        case .invalidSignedLicenseToken(let reason):
            return "Signed License Token is invalid: \(reason)"
        case .releaseNotQualified(let status):
            return "The current Product Release is not qualified: \(status)"
        case .credentialStorageError(let operation, let status):
            return "Credential storage \(operation) failed with OSStatus \(status)."
        case .fingerprintError(let reason):
            return "Device fingerprint failed: \(reason)"
        case .protocolError(let reason):
            return "LicenKit protocol error: \(reason)"
        }
    }

    public var isRateLimited: Bool {
        if case .apiError(let code, _, _, _) = self {
            return code == "RATE_LIMITED" || code == "TOO_MANY_REQUESTS" || code == "HTTP_429"
        }
        return false
    }

    public var isRecoverable: Bool {
        switch self {
        case .transportError:
            return true
        case .apiError:
            return isRateLimited
        default:
            return false
        }
    }
}
