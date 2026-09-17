import XCTest
import CryptoKit
@testable import LicenKit

/// 用于拦截网络请求并返回自定义 HTTP 响应或错误的 MockURLProtocol
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    
    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }
    
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }
    
    override func startLoading() {
        MockURLProtocol.lock.lock()
        let handler = MockURLProtocol.requestHandler
        MockURLProtocol.lock.unlock()
        
        guard let handler = handler else {
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

final class ResilienceEvaluationTests: XCTestCase {
    
    private var mockSession: URLSession!
    private let fixedFp = "MOCK-HW-UUID-RESILIENCE"
    private var privateKey: Curve25519.Signing.PrivateKey!
    private var pubKeyBase64: String!
    private var testConfig: LicenKitConfiguration!
    
    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        mockSession = URLSession(configuration: config)
        
        privateKey = Curve25519.Signing.PrivateKey()
        pubKeyBase64 = privateKey.publicKey.rawRepresentation.base64EncodedString()
        
        testConfig = LicenKitConfiguration(
            serverUrl: "https://mock.licenkit.io",
            accountId: "acc_test",
            productId: "prd_test",
            publicKey: pubKeyBase64
        )
    }
    
    override func tearDown() {
        MockURLProtocol.lock.lock()
        MockURLProtocol.requestHandler = nil
        MockURLProtocol.lock.unlock()
        mockSession = nil
        super.tearDown()
    }
    
    // MARK: - Helper to generate signed token
    
    private func makeSignedToken(
        issuedAt: Date = Date().addingTimeInterval(-3600),
        expiresAt: Date = Date().addingTimeInterval(86400 * 30)
    ) throws -> String {
        let verifier = Ed25519Verifier()
        let header = OfflineTokenHeader()
        let headerB64 = verifier.encodeBase64Url(try JSONEncoder().encode(header))
        
        let claims = LicenseClaims(
            licenseId: "lic_mock_resilience",
            licenseKey: "LIC-RESILIENCE-001",
            accountId: "acc_test",
            productId: "prd_test",
            policyId: "pol_resilience",
            fingerprint: fixedFp,
            issuedAtTimestamp: Int64(issuedAt.timeIntervalSince1970),
            expirationTimestamp: Int64(expiresAt.timeIntervalSince1970),
            features: ["pro", "export"]
        )
        let payloadB64 = verifier.encodeBase64Url(try JSONEncoder().encode(claims))
        let signingInput = "\(headerB64).\(payloadB64)".data(using: .utf8)!
        let signature = try privateKey.signature(for: signingInput)
        let sigB64 = verifier.encodeBase64Url(signature)
        
        return "\(headerB64).\(payloadB64).\(sigB64)"
    }
    
    // MARK: - Tests
    
    func testValidateFallsBackToOfflineWhenServerReturns500WithinGracePeriod() async throws {
        let token = try makeSignedToken()
        let mockStore = MockCredentialStore()
        
        // 凭据宽限期为 7 天，上次探活为 10 分钟前（宽限期非常充裕）
        let creds = StoredCredentials(
            licenseKey: "LIC-RESILIENCE-001",
            token: token,
            lastValidatedAt: Date().addingTimeInterval(-600),
            offlineGracePeriod: 7 * 86400,
            policyFeatures: ["pro"],
            machineId: "m_001"
        )
        try mockStore.saveCredentials(creds, for: fixedFp)
        
        // 模拟服务端持续返回 500
        MockURLProtocol.lock.lock()
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 500,
                httpVersion: nil,
                headerFields: nil
            )!
            let data = """
            {"success": false, "error": {"code": "INTERNAL_ERROR", "message": "Database outage"}}
            """.data(using: .utf8)!
            return (response, data)
        }
        MockURLProtocol.lock.unlock()
        
        let mockMonitor = MockNetworkMonitor(initialOnline: true)
        let coordinator = LicenKitRetryCoordinator(
            networkMonitor: mockMonitor,
            retryDelays: .fastForTesting
        )
        let apiClient = LicenKitAPIClient(
            serverUrl: testConfig.serverUrl,
            urlSession: mockSession
        )
        
        let licenKit = LicenKit(
            configuration: testConfig,
            credentialStore: mockStore,
            fingerprintProvider: FixedFingerprintProvider(fingerprint: fixedFp),
            retryCoordinator: coordinator,
            apiClient: apiClient
        )
        
        // 执行验证：服务端 500，应自动静默保底 (Fail-Silent)，返回有效状态
        let result = try await licenKit.validate()
        XCTAssertTrue(result.valid)
        XCTAssertEqual(result.token, token)
        XCTAssertTrue(result.reason?.contains("Fail-silent") == true)
        
        // 验证内存缓存状态依然是有效
        guard case .valid = licenKit.cachedStatus else {
            XCTFail("Cached status should be .valid")
            return
        }
    }
    
    func testValidateThrowsWhenStatusIsExpiredAndServerReturns500() async throws {
        let token = try makeSignedToken()
        let mockStore = MockCredentialStore()
        
        // 宽限期 3 天，但距上次校验已过去 5 天（宽限期已耗尽）
        let creds = StoredCredentials(
            licenseKey: "LIC-RESILIENCE-001",
            token: token,
            lastValidatedAt: Date().addingTimeInterval(-5 * 86400),
            offlineGracePeriod: 3 * 86400,
            policyFeatures: ["pro"],
            machineId: "m_001"
        )
        try mockStore.saveCredentials(creds, for: fixedFp)
        
        // 模拟服务端 502 Bad Gateway
        MockURLProtocol.lock.lock()
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 502,
                httpVersion: nil,
                headerFields: nil
            )!
            let data = "<html>Bad Gateway</html>".data(using: .utf8)!
            return (response, data)
        }
        MockURLProtocol.lock.unlock()
        
        // 设备处于有网状态 (Online)
        let mockMonitor = MockNetworkMonitor(initialOnline: true)
        let coordinator = LicenKitRetryCoordinator(
            networkMonitor: mockMonitor,
            retryDelays: .fastForTesting
        )
        let apiClient = LicenKitAPIClient(
            serverUrl: testConfig.serverUrl,
            urlSession: mockSession
        )
        
        let licenKit = LicenKit(
            configuration: testConfig,
            credentialStore: mockStore,
            fingerprintProvider: FixedFingerprintProvider(fingerprint: fixedFp),
            retryCoordinator: coordinator,
            apiClient: apiClient
        )
        
        // 核心纠偏验证：主状态已过期时，绝不因服务端 502 伪造放行，必须抛出异常且保持过期！
        do {
            _ = try await licenKit.validate()
            XCTFail("Should have thrown error when expired rather than granting fake validity")
        } catch {
            guard case .expired = licenKit.cachedStatus else {
                XCTFail("Cached status should remain .expired")
                return
            }
        }
    }
    
    func testValidateThrowsWhenGracePeriodExpiredAndDeviceIsPhysicallyOffline() async throws {
        let token = try makeSignedToken()
        let mockStore = MockCredentialStore()
        
        // 宽限期 3 天，但距上次校验已过去 5 天（已过期）
        let creds = StoredCredentials(
            licenseKey: "LIC-RESILIENCE-001",
            token: token,
            lastValidatedAt: Date().addingTimeInterval(-5 * 86400),
            offlineGracePeriod: 3 * 86400,
            policyFeatures: ["pro"],
            machineId: "m_001"
        )
        try mockStore.saveCredentials(creds, for: fixedFp)
        
        // 模拟断网超时
        MockURLProtocol.lock.lock()
        MockURLProtocol.requestHandler = { _ in
            throw URLError(.notConnectedToInternet)
        }
        MockURLProtocol.lock.unlock()
        
        // 设备处于完全断网状态 (Offline)
        let mockMonitor = MockNetworkMonitor(initialOnline: false)
        let coordinator = LicenKitRetryCoordinator(
            networkMonitor: mockMonitor,
            retryDelays: .fastForTesting
        )
        let apiClient = LicenKitAPIClient(
            serverUrl: testConfig.serverUrl,
            urlSession: mockSession
        )
        
        let licenKit = LicenKit(
            configuration: testConfig,
            credentialStore: mockStore,
            fingerprintProvider: FixedFingerprintProvider(fingerprint: fixedFp),
            retryCoordinator: coordinator,
            apiClient: apiClient
        )
        
        do {
            _ = try await licenKit.validate()
            XCTFail("Should have thrown network error demanding reconnection")
        } catch {
            guard case .expired = licenKit.cachedStatus else {
                XCTFail("Cached status should remain .expired")
                return
            }
        }
    }
    
    func testValidateDoesNotFallBackOnExplicitBusinessRejection() async throws {
        let token = try makeSignedToken()
        let mockStore = MockCredentialStore()
        
        let creds = StoredCredentials(
            licenseKey: "LIC-RESILIENCE-001",
            token: token,
            lastValidatedAt: Date().addingTimeInterval(-600),
            offlineGracePeriod: 7 * 86400,
            policyFeatures: ["pro"],
            machineId: "m_001"
        )
        try mockStore.saveCredentials(creds, for: fixedFp)
        
        // 模拟服务端明确返回业务 404 LICENSE_NOT_FOUND (已在后台注销)
        MockURLProtocol.lock.lock()
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 404,
                httpVersion: nil,
                headerFields: nil
            )!
            let data = """
            {"success": false, "error": {"code": "LICENSE_NOT_FOUND", "message": "License was deleted"}}
            """.data(using: .utf8)!
            return (response, data)
        }
        MockURLProtocol.lock.unlock()
        
        let mockMonitor = MockNetworkMonitor(initialOnline: true)
        let coordinator = LicenKitRetryCoordinator(
            networkMonitor: mockMonitor,
            retryDelays: .fastForTesting
        )
        let apiClient = LicenKitAPIClient(
            serverUrl: testConfig.serverUrl,
            urlSession: mockSession
        )
        
        let licenKit = LicenKit(
            configuration: testConfig,
            credentialStore: mockStore,
            fingerprintProvider: FixedFingerprintProvider(fingerprint: fixedFp),
            retryCoordinator: coordinator,
            apiClient: apiClient
        )
        
        // 业务明确拒绝：坚决封锁，禁止离线放行
        do {
            _ = try await licenKit.validate()
            XCTFail("Should have thrown business error")
        } catch let err as LicenKitError {
            XCTAssertTrue(err.isExplicitBusinessRejection)
        }
        
        // 状态应被标记为 untrusted
        guard case .untrusted = licenKit.cachedStatus else {
            XCTFail("Status should be untrusted")
            return
        }
    }
    
    func testGatewayHtml404FallsBackToFailSilentWithoutRevokingLicense() async throws {
        let token = try makeSignedToken()
        let mockStore = MockCredentialStore()
        
        let creds = StoredCredentials(
            licenseKey: "LIC-RESILIENCE-001",
            token: token,
            lastValidatedAt: Date().addingTimeInterval(-600),
            offlineGracePeriod: 7 * 86400,
            policyFeatures: ["pro"],
            machineId: "m_001"
        )
        try mockStore.saveCredentials(creds, for: fixedFp)
        
        // 模拟网关/代理配置失误返回 HTML 404（非业务 JSON 404）
        MockURLProtocol.lock.lock()
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 404,
                httpVersion: nil,
                headerFields: nil
            )!
            let data = "<html><head><title>404 Not Found</title></head><body>nginx</body></html>".data(using: .utf8)!
            return (response, data)
        }
        MockURLProtocol.lock.unlock()
        
        let mockMonitor = MockNetworkMonitor(initialOnline: true)
        let coordinator = LicenKitRetryCoordinator(
            networkMonitor: mockMonitor,
            retryDelays: .fastForTesting
        )
        let apiClient = LicenKitAPIClient(
            serverUrl: testConfig.serverUrl,
            urlSession: mockSession
        )
        
        let licenKit = LicenKit(
            configuration: testConfig,
            credentialStore: mockStore,
            fingerprintProvider: FixedFingerprintProvider(fingerprint: fixedFp),
            retryCoordinator: coordinator,
            apiClient: apiClient
        )
        
        // 网关 HTML 404 属于基础设施故障，绝不应误杀吊销，而是 Fail-Silent 保持可用
        let result = try await licenKit.validate()
        XCTAssertTrue(result.valid)
        guard case .valid = licenKit.cachedStatus else {
            XCTFail("Status should remain .valid and NOT be marked untrusted")
            return
        }
    }
    
    func testRefreshSucceedsAndRestoresValidStatus() async throws {
        let token = try makeSignedToken()
        let mockStore = MockCredentialStore()
        
        // 状态原本已过期
        let creds = StoredCredentials(
            licenseKey: "LIC-RESILIENCE-001",
            token: token,
            lastValidatedAt: Date().addingTimeInterval(-10 * 86400),
            offlineGracePeriod: 3 * 86400,
            policyFeatures: ["pro"],
            machineId: "m_001"
        )
        try mockStore.saveCredentials(creds, for: fixedFp)
        
        // 新生成的延期 Token
        let renewedToken = try makeSignedToken(
            issuedAt: Date(),
            expiresAt: Date().addingTimeInterval(86400 * 365)
        )
        
        // 服务端返回 200 刷新成功
        MockURLProtocol.lock.lock()
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let data = """
            {
                "success": true,
                "data": {
                    "valid": true,
                    "token": "\(renewedToken)",
                    "token_expires_at": "2027-09-18T00:00:00Z",
                    "license_expires_at": "2027-09-18T00:00:00Z"
                }
            }
            """.data(using: .utf8)!
            return (response, data)
        }
        MockURLProtocol.lock.unlock()
        
        let mockMonitor = MockNetworkMonitor(initialOnline: true)
        let coordinator = LicenKitRetryCoordinator(
            networkMonitor: mockMonitor,
            retryDelays: .fastForTesting
        )
        let apiClient = LicenKitAPIClient(
            serverUrl: testConfig.serverUrl,
            urlSession: mockSession
        )
        
        let licenKit = LicenKit(
            configuration: testConfig,
            credentialStore: mockStore,
            fingerprintProvider: FixedFingerprintProvider(fingerprint: fixedFp),
            retryCoordinator: coordinator,
            apiClient: apiClient
        )
        
        // 用户在前台主动点击刷新
        let result = try await licenKit.refresh()
        XCTAssertTrue(result.valid)
        XCTAssertEqual(result.token, renewedToken)
        
        // 验证主状态成功恢复为 .valid
        guard case .valid = licenKit.cachedStatus else {
            XCTFail("Cached status should be restored to .valid")
            return
        }
    }
    
    func testRefreshThrowsOnNetworkErrorWithoutCorruptingStatus() async throws {
        let token = try makeSignedToken()
        let mockStore = MockCredentialStore()
        
        let creds = StoredCredentials(
            licenseKey: "LIC-RESILIENCE-001",
            token: token,
            lastValidatedAt: Date().addingTimeInterval(-10 * 86400),
            offlineGracePeriod: 3 * 86400,
            policyFeatures: ["pro"],
            machineId: "m_001"
        )
        try mockStore.saveCredentials(creds, for: fixedFp)
        
        // 模拟服务端 503 挂掉
        MockURLProtocol.lock.lock()
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 503,
                httpVersion: nil,
                headerFields: nil
            )!
            let data = "Service Unavailable".data(using: .utf8)!
            return (response, data)
        }
        MockURLProtocol.lock.unlock()
        
        let mockMonitor = MockNetworkMonitor(initialOnline: true)
        let coordinator = LicenKitRetryCoordinator(
            networkMonitor: mockMonitor,
            retryDelays: .fastForTesting
        )
        let apiClient = LicenKitAPIClient(
            serverUrl: testConfig.serverUrl,
            urlSession: mockSession
        )
        
        let licenKit = LicenKit(
            configuration: testConfig,
            credentialStore: mockStore,
            fingerprintProvider: FixedFingerprintProvider(fingerprint: fixedFp),
            retryCoordinator: coordinator,
            apiClient: apiClient
        )
        
        // refresh 遇到网络故障应直接向调用方抛错供 UI Toast 提示
        do {
            _ = try await licenKit.refresh()
            XCTFail("Refresh should throw network error on 503")
        } catch {
            // 主状态保持不变 (依旧是 .expired)
            guard case .expired = licenKit.cachedStatus else {
                XCTFail("Status should remain .expired")
                return
            }
        }
    }
}
