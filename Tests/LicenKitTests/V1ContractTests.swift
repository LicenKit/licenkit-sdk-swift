import CryptoKit
import XCTest
@testable import LicenKit

final class MemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var licenses: [String: StoredCredentials] = [:]
    private var trials: [String: StoredTrialCredentials] = [:]

    func loadCredentials(for fingerprint: String) throws -> StoredCredentials? {
        lock.withLock { licenses[fingerprint] }
    }
    func saveCredentials(_ credentials: StoredCredentials, for fingerprint: String) throws {
        lock.withLock { licenses[fingerprint] = credentials }
    }
    func clearCredentials(for fingerprint: String) throws {
        _ = lock.withLock { licenses.removeValue(forKey: fingerprint) }
    }
    func loadTrialCredentials(for fingerprint: String) throws -> StoredTrialCredentials? {
        lock.withLock { trials[fingerprint] }
    }
    func saveTrialCredentials(_ credentials: StoredTrialCredentials, for fingerprint: String) throws {
        lock.withLock { trials[fingerprint] = credentials }
    }
    func clearTrialCredentials(for fingerprint: String) throws {
        _ = lock.withLock { trials.removeValue(forKey: fingerprint) }
    }
}

struct FixedFingerprint: DeviceFingerprintProvider, Sendable {
    let value: String
    func getFingerprint() async throws -> String { value }
}

final class ContractURLProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let handler = Self.lock.withLock { Self.handler }
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

final class V1ContractTests: XCTestCase {
    private let fingerprint = "sha256:test-device"
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ContractURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDown() {
        ContractURLProtocol.lock.withLock { ContractURLProtocol.handler = nil }
        session.invalidateAndCancel()
        session = nil
        super.tearDown()
    }

    func testOpaqueActivationRequiresNoSigningKeyAndLocalStatusIsNotCryptographicValidity() async throws {
        let store = MemoryCredentialStore()
        setJSONResponse(status: 200, body: credentialEnvelope(mode: "opaque"))
        let client = makeClient(store: store, keys: [:])
        let result = try await client.activate(licenseKey: "LK-ONE-TIME")
        XCTAssertEqual(result.credentialMode, .opaque)
        XCTAssertTrue(result.status.isUsable)
        let local = try await client.checkLocalStatus()
        guard case .temporarilyUnverified(_, let terms) = local else {
            return XCTFail("Opaque mode must not report validLocally: \(local)")
        }
        XCTAssertEqual(terms?.features, ["export"])
    }

    func testSignedActivationFailsWhenKeyIDIsNotEmbedded() async throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let token = try makeToken(privateKey: privateKey, kid: "key_new")
        setJSONResponse(status: 200, body: credentialEnvelope(mode: "signed", token: token, kid: "key_new"))
        let client = makeClient(store: MemoryCredentialStore(), keys: [:])
        do {
            _ = try await client.activate(licenseKey: "LK-ONE-TIME")
            XCTFail("Expected missing key failure")
        } catch let error as LicenKitError {
            XCTAssertEqual(error, .missingTrustedSigningKey(keyID: "key_new"))
        }
    }

    func testSignedHeaderRejectsDuplicateOrWrongAlgorithmBeforeTrustSelection() throws {
        let verifier = Ed25519Verifier()
        let duplicateHeader = verifier.encodeBase64URL(Data("{\"alg\":\"EdDSA\",\"alg\":\"none\",\"typ\":\"licenkit-license+jwt\",\"kid\":\"key_1\"}".utf8))
        XCTAssertThrowsError(try verifier.decodeProtectedHeader(token: "\(duplicateHeader).e30.AA")) { error in
            guard case LicenKitError.invalidSignedLicenseToken(let reason) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(reason.contains("duplicate"))
        }

        let wrongAlgorithm = verifier.encodeBase64URL(try JSONSerialization.data(withJSONObject: [
            "alg": "none", "typ": "licenkit-license+jwt", "kid": "key_1"
        ]))
        XCTAssertThrowsError(try verifier.decodeProtectedHeader(token: "\(wrongAlgorithm).e30.AA"))
    }

    func testSignedKeyRotationAndLocalReleaseEvaluation() async throws {
        let oldKey = Curve25519.Signing.PrivateKey()
        let newKey = Curve25519.Signing.PrivateKey()
        let keys = [
            "key_old": oldKey.publicKey.rawRepresentation.base64EncodedString(),
            "key_new": newKey.publicKey.rawRepresentation.base64EncodedString(),
        ]
        for (kid, key) in [("key_old", oldKey), ("key_new", newKey)] {
            let token = try makeToken(privateKey: key, kid: kid)
            setJSONResponse(status: 200, body: credentialEnvelope(mode: "signed", token: token, kid: kid))
            let client = makeClient(store: MemoryCredentialStore(), keys: keys)
            _ = try await client.activate(licenseKey: "LK-ONE-TIME")
            guard case .validLocally(let claims) = try await client.checkLocalStatus() else {
                return XCTFail("Expected validLocally for \(kid)")
            }
            XCTAssertEqual(claims.releaseVersion, "2.4.0")
        }
    }

    func testSignedReleaseAfterUpdatesUntilIsIndependentFailure() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let token = try makeToken(privateKey: key, kid: "key_1", releasedAt: 2_000, updatesUntil: 1_999)
        setJSONResponse(status: 200, body: credentialEnvelope(mode: "signed", token: token, kid: "key_1"))
        let client = makeClient(
            store: MemoryCredentialStore(),
            keys: ["key_1": key.publicKey.rawRepresentation.base64EncodedString()]
        )
        do {
            _ = try await client.activate(licenseKey: "LK-ONE-TIME")
            XCTFail("Expected release qualification failure")
        } catch let error as LicenKitError {
            guard case .releaseNotQualified(let status) = error,
                  case .updateEntitlementRequired = status else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testTrialIsAlwaysOnlineAndUsesSeparateTokenStorage() async throws {
        let store = MemoryCredentialStore()
        setJSONResponse(status: 200, body: """
        {"success":true,"data":{"trial_id":"trl_1","trial_token":"ttk_once","status":"active","expires_at":"2030-01-01T00:00:00Z","features":["trial_export"]}}
        """)
        let client = makeClient(store: store, keys: [:])
        guard case .trialValidOnline = try await client.startTrial() else { return XCTFail("Expected online trial") }
        XCTAssertEqual(try store.loadTrialCredentials(for: fingerprint)?.trialToken, "ttk_once")
        let localTrialStatus = try await client.checkLocalStatus()
        XCTAssertEqual(localTrialStatus, .onlineValidationRequired)

        setJSONResponse(status: 200, body: """
        {"success":true,"data":{"trial_id":"trl_1","trial_token":null,"status":"active","expires_at":"2030-01-01T00:00:00Z","features":["trial_export"]}}
        """)
        guard case .trialValidOnline = try await client.validateTrial() else { return XCTFail("Expected refreshed online trial") }
    }

    func testDeactivateTransportFailurePreservesLocalCredentials() async throws {
        let store = MemoryCredentialStore()
        let terms = LicenseTerms(maxActivations: 1, features: ["export"], updatesUntil: nil)
        try store.saveCredentials(
            StoredCredentials(
                activationID: "act_1", machineToken: "mtk_secret", credentialMode: .opaque,
                signedLicenseToken: nil, signingKeyID: nil, lastValidatedAt: Date(), cachedTerms: terms
            ),
            for: fingerprint
        )
        ContractURLProtocol.lock.withLock {
            ContractURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        }
        let client = makeClient(store: store, keys: [:])
        let result = try await client.deactivate()
        guard case .remoteFailed(let preserved, let error) = result else { return XCTFail("Expected remoteFailed") }
        XCTAssertTrue(preserved)
        guard case .transportError = error else { return XCTFail("Expected transport error") }
        XCTAssertNotNil(try store.loadCredentials(for: fingerprint))
    }

    func testBusinessAndServerErrorsRemainDistinctAndPreserveDiagnostics() async throws {
        let apiClient = LicenKitAPIClient(serverURL: URL(string: "https://mock.example")!, urlSession: session)
        setJSONResponse(status: 403, body: """
        {"success":false,"error":{"code":"LICENSE_CHECKOUT_VERIFICATION_ONLY","message":"verification only","request_id":"req_1","details":{"license_id":"lic_1","machine_token":"secret"}}}
        """)
        do {
            _ = try await apiClient.activate(request: activateRequest())
            XCTFail("Expected API error")
        } catch let error as LicenKitError {
            guard case .apiError(let code, _, let requestID, let details) = error else { return XCTFail("Unexpected error") }
            XCTAssertEqual(code, "LICENSE_CHECKOUT_VERIFICATION_ONLY")
            XCTAssertEqual(requestID, "req_1")
            XCTAssertEqual(details["license_id"], "lic_1")
            XCTAssertEqual(details["machine_token"], "[REDACTED]")
        }

        setJSONResponse(status: 503, body: """
        {"success":false,"error":{"code":"DATABASE_UNAVAILABLE","message":"retry","request_id":"req_2","details":{}}}
        """)
        do {
            _ = try await apiClient.activate(request: activateRequest())
            XCTFail("Expected transport error")
        } catch let error as LicenKitError {
            guard case .transportError(let kind, _) = error,
                  case .server(let status, let code, let requestID, _) = kind else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(status, 503)
            XCTAssertEqual(code, "DATABASE_UNAVAILABLE")
            XCTAssertEqual(requestID, "req_2")
        }
    }

    func testStrictDeactivateAndTrialValidatePayloads() throws {
        let deactivate = APIDeactivateRequest(
            accountID: "acc_1", productID: "prd_1", activationID: "act_1",
            machineToken: "mtk_secret", fingerprint: fingerprint
        )
        let deactivateJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(deactivate)) as? [String: Any])
        XCTAssertNil(deactivateJSON["release_version"])
        XCTAssertNil(deactivateJSON["device_platform"])

        let trial = APITrialValidateRequest(
            accountID: "acc_1", productID: "prd_1", trialID: "trl_1", trialToken: "ttk_secret",
            fingerprint: fingerprint, releaseVersion: "2.4.0", releasePlatform: "macos-arm64"
        )
        let trialJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(trial)) as? [String: Any])
        XCTAssertNil(trialJSON["device_platform"])
        XCTAssertEqual(trialJSON["release_version"] as? String, "2.4.0")
    }

    func testMacOSFingerprintTechnologyRemainsStable() async throws {
        #if os(macOS)
        let provider = MacOSFingerprintProvider()
        let first = try await provider.getFingerprint()
        let second = try await provider.getFingerprint()
        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(first, second)
        #endif
    }

    func testReleaseAPIErrorSetsIndependentStatusWithoutLosingRawError() async throws {
        let store = MemoryCredentialStore()
        setJSONResponse(status: 200, body: credentialEnvelope(mode: "opaque"))
        let client = makeClient(store: store, keys: [:])
        _ = try await client.activate(licenseKey: "LK")
        setJSONResponse(status: 403, body: """
        {"success":false,"error":{"code":"PRODUCT_RELEASE_UNKNOWN","message":"unknown build","request_id":"req_release","details":{}}}
        """)
        do {
            _ = try await client.validate()
            XCTFail("Expected raw API error")
        } catch let error as LicenKitError {
            guard case .apiError(let code, _, let requestID, _) = error else { return XCTFail("Unexpected error") }
            XCTAssertEqual(code, "PRODUCT_RELEASE_UNKNOWN")
            XCTAssertEqual(requestID, "req_release")
            XCTAssertEqual(client.cachedStatus, .productReleaseUnknown(version: "2.4.0", platform: "macos-arm64"))
        }
    }

    private func makeClient(store: MemoryCredentialStore, keys: [String: String]) -> LicenKit {
        let configuration = LicenKitConfiguration(
            serverURL: URL(string: "https://mock.example")!,
            accountID: "acc_1",
            productID: "prd_1",
            releaseVersion: "2.4.0",
            releasePlatform: "macos-arm64",
            trustedSigningKeys: keys
        )
        return LicenKit(
            configuration: configuration,
            credentialStore: store,
            fingerprintProvider: FixedFingerprint(value: fingerprint),
            apiClient: LicenKitAPIClient(serverURL: configuration.serverURL, urlSession: session)
        )
    }

    private func setJSONResponse(status: Int, body: String) {
        ContractURLProtocol.lock.withLock {
            ContractURLProtocol.handler = { request in
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: status, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, Data(body.utf8))
            }
        }
    }

    private func credentialEnvelope(mode: String, token: String? = nil, kid: String? = nil) -> String {
        let tokenJSON = token.map { "\"\($0)\"" } ?? "null"
        let kidJSON = kid.map { "\"\($0)\"" } ?? "null"
        return """
        {"success":true,"data":{"activation_id":"act_1","machine_token":"mtk_secret","credential_mode":"\(mode)","signed_license_token":\(tokenJSON),"signing_key_id":\(kidJSON),"license_expires_at":null,"terms":{"max_activations":1,"features":["export"],"updates_until":null}}}
        """
    }

    private func activateRequest() -> APIActivateRequest {
        APIActivateRequest(
            accountID: "acc_1", productID: "prd_1", licenseKey: "LK", fingerprint: fingerprint,
            devicePlatform: "macos-arm64", name: nil, releaseVersion: "2.4.0", releasePlatform: "macos-arm64"
        )
    }

    private func makeToken(
        privateKey: Curve25519.Signing.PrivateKey,
        kid: String,
        releasedAt: Int64? = nil,
        updatesUntil: Int64? = nil
    ) throws -> String {
        let now = Int64(Date().timeIntervalSince1970)
        let header = SignedLicenseTokenHeader(kid: kid)
        let payload: [String: Any] = [
            "lic": "lic_1", "act": "act_1", "acc": "acc_1", "prd": "prd_1", "rel": "rel_1",
            "ver": "2.4.0", "plt": "macos-arm64", "rat": releasedAt ?? now - 60,
            "fp": fingerprint, "iat": now - 60, "exp": now + 3600,
            "lexp": NSNull(), "upd": updatesUntil.map { NSNumber(value: $0) } ?? NSNull(), "fea": ["export"]
        ]
        let verifier = Ed25519Verifier()
        let headerPart = verifier.encodeBase64URL(try JSONEncoder().encode(header))
        let payloadPart = verifier.encodeBase64URL(try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
        let signature = try privateKey.signature(for: Data("\(headerPart).\(payloadPart)".utf8))
        return "\(headerPart).\(payloadPart).\(verifier.encodeBase64URL(signature))"
    }
}
