import Foundation

public enum TransportErrorKind: Equatable, Sendable {
    case network
    case dns
    case tls
    case timeout
    case server(statusCode: Int, code: String?, requestID: String?, details: [String: String])
    case invalidResponse(statusCode: Int?, requestID: String?)
}

public enum LicenKitError: Error, LocalizedError, Equatable, Sendable {
    case unactivated
    case trialNotStarted
    case apiError(
        statusCode: Int,
        code: String,
        message: String,
        requestID: String?,
        details: [String: String]
    )
    case transportError(kind: TransportErrorKind, underlyingDescription: String)
    case configurationError(reason: String)
    case missingSigningPublicKey(keyID: String)
    case invalidSignedLicenseToken(reason: String)
    case credentialStorageError(operation: String, status: Int32)
    case fingerprintError(reason: String)
    case protocolError(reason: String)
    case deactivationRecoveryRequired(phase: DeactivationAttemptPhase)

    public var errorDescription: String? {
        switch self {
        case .unactivated:
            return "No License activation is stored on this device."
        case .trialNotStarted:
            return "No Product trial is stored on this device."
        case .apiError(let statusCode, let code, let message, let requestID, _):
            return "LicenKit API error HTTP \(statusCode) [\(code)]\(requestID.map { " request=\($0)" } ?? ""): \(message)"
        case .transportError(_, let description):
            return "LicenKit transport error: \(description)"
        case .configurationError(let reason):
            return "LicenKit configuration is invalid: \(reason)"
        case .missingSigningPublicKey(let keyID):
            return "No signing public key is embedded for key ID '\(keyID)'."
        case .invalidSignedLicenseToken(let reason):
            return "Signed License Token is invalid: \(reason)"
        case .credentialStorageError(let operation, let status):
            return "Credential storage \(operation) failed with OSStatus \(status)."
        case .fingerprintError(let reason):
            return "Device fingerprint failed: \(reason)"
        case .protocolError(let reason):
            return "LicenKit protocol error: \(reason)"
        case .deactivationRecoveryRequired(let phase):
            return "A deactivation attempt is \(phase.rawValue); retry deactivate() to finish recovery."
        }
    }

    public var isRateLimited: Bool {
        if case .apiError(_, let code, _, _, _) = self {
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

    public var requestID: String? {
        switch self {
        case .apiError(_, _, _, let requestID, _):
            return requestID
        case .transportError(let kind, _):
            switch kind {
            case .server(_, _, let requestID, _), .invalidResponse(_, let requestID):
                return requestID
            default:
                return nil
            }
        default:
            return nil
        }
    }

    var confirmedHTTPFailureStatusCode: Int? {
        switch self {
        case .apiError(let statusCode, _, _, _, _):
            return (200...299).contains(statusCode) ? nil : statusCode
        case .transportError(let kind, _):
            switch kind {
            case .server(let statusCode, _, _, _):
                return statusCode
            case .invalidResponse(let statusCode?, _)
                where !(200...299).contains(statusCode):
                return statusCode
            default:
                return nil
            }
        default:
            return nil
        }
    }
}
