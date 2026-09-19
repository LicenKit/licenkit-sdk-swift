import Foundation

public struct LicenKitAPIClient: Sendable {
    public let serverURL: URL
    public let timeoutInterval: TimeInterval
    private let urlSession: URLSession

    public init(serverURL: URL, timeoutInterval: TimeInterval = 15, urlSession: URLSession? = nil) {
        self.serverURL = serverURL
        self.timeoutInterval = timeoutInterval
        if let urlSession {
            self.urlSession = urlSession
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = timeoutInterval
            configuration.timeoutIntervalForResource = timeoutInterval
            self.urlSession = URLSession(configuration: configuration)
        }
    }

    public func activate(request: APIActivateRequest) async throws -> APICredentialResponse {
        try await send(path: "api/v1/client/activate", body: request)
    }

    public func validate(request: APIValidateRequest) async throws -> APICredentialResponse {
        try await send(path: "api/v1/client/validate", body: request)
    }

    public func deactivate(request: APIDeactivateRequest) async throws -> APIDeactivateResponse {
        try await send(path: "api/v1/client/deactivate", body: request)
    }

    public func claimTrial(request: APITrialClaimRequest) async throws -> APITrialResponse {
        try await send(path: "api/v1/client/trials/claim", body: request)
    }

    public func validateTrial(request: APITrialValidateRequest) async throws -> APITrialResponse {
        try await send(path: "api/v1/client/trials/validate", body: request)
    }

    private func send<Request: Encodable, Response: Decodable & Sendable>(
        path: String,
        body: Request
    ) async throws -> Response {
        let url = serverURL.appendingPathComponent(path)
        var request = URLRequest(url: url, timeoutInterval: timeoutInterval)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("LicenKit-Swift-SDK/1.0", forHTTPHeaderField: "User-Agent")
        do { request.httpBody = try JSONEncoder().encode(body) }
        catch { throw LicenKitError.protocolError(reason: "request encoding failed: \(error.localizedDescription)") }
        return try await execute(request)
    }

    private func execute<Response: Decodable & Sendable>(_ request: URLRequest) async throws -> Response {
        let data: Data
        let response: URLResponse
        do { (data, response) = try await urlSession.data(for: request) }
        catch let error as URLError {
            throw LicenKitError.transportError(kind: transportKind(for: error), underlyingDescription: error.localizedDescription)
        } catch {
            throw LicenKitError.transportError(kind: .network, underlyingDescription: error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw LicenKitError.transportError(kind: .invalidResponse(statusCode: nil), underlyingDescription: "response was not HTTP")
        }
        let envelope: LicenKitAPIResponse<Response>
        do { envelope = try JSONDecoder().decode(LicenKitAPIResponse<Response>.self, from: data) }
        catch {
            let kind = http.statusCode >= 500
                ? TransportErrorKind.server(statusCode: http.statusCode, code: nil, requestID: http.value(forHTTPHeaderField: "X-Request-ID"), details: [:])
                : .invalidResponse(statusCode: http.statusCode)
            throw LicenKitError.transportError(kind: kind, underlyingDescription: "response JSON did not match the V1 envelope: \(error.localizedDescription)")
        }

        let requestID = envelope.error?.requestID ?? http.value(forHTTPHeaderField: "X-Request-ID")
        let details = sanitize(details: envelope.error?.details ?? [:])
        if http.statusCode >= 500 {
            throw LicenKitError.transportError(
                kind: .server(statusCode: http.statusCode, code: envelope.error?.code, requestID: requestID, details: details),
                underlyingDescription: envelope.error?.message ?? "server returned HTTP \(http.statusCode)"
            )
        }
        if !(200...299).contains(http.statusCode) || envelope.success == false {
            throw LicenKitError.apiError(
                code: envelope.error?.code ?? "HTTP_\(http.statusCode)",
                message: envelope.error?.message ?? "server rejected the request",
                requestID: requestID,
                details: details
            )
        }
        guard envelope.success, let result = envelope.data else {
            throw LicenKitError.transportError(
                kind: .invalidResponse(statusCode: http.statusCode),
                underlyingDescription: "success response did not contain data"
            )
        }
        return result
    }

    private func transportKind(for error: URLError) -> TransportErrorKind {
        switch error.code {
        case .timedOut: return .timeout
        case .cannotFindHost, .dnsLookupFailed: return .dns
        case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
             .clientCertificateRequired: return .tls
        default: return .network
        }
    }

    private func sanitize(details: [String: JSONValue]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: details.map { key, value in
            (key, sanitizedDiagnostic(key: key, value: value))
        })
    }

    private func sanitizedDiagnostic(key: String, value: JSONValue) -> String {
        sanitizedValue(key: key, value: value).diagnosticString
    }

    private func sanitizedValue(key: String, value: JSONValue) -> JSONValue {
        let sensitiveNames = ["token", "secret", "password", "license_key", "authorization"]
        if sensitiveNames.contains(where: { key.lowercased().contains($0) }) { return .string("[REDACTED]") }
        switch value {
        case .object(let object):
            return .object(Dictionary(uniqueKeysWithValues: object.map { nestedKey, nested in
                (nestedKey, sanitizedValue(key: nestedKey, value: nested))
            }))
        case .array(let values):
            return .array(values.map { sanitizedValue(key: key, value: $0) })
        default:
            return value
        }
    }
}
