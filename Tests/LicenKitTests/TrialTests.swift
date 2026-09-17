import XCTest
import CryptoKit
@testable import LicenKit

final class TrialTests: XCTestCase {
    
    // MARK: - Crypto & Token Verification
    
    func testEd25519TrialTokenSigningAndVerification() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let pubKeyBase64 = privateKey.publicKey.rawRepresentation.base64EncodedString()
        let verifier = Ed25519Verifier()
        
        let now = Int64(Date().timeIntervalSince1970)
        let header = OfflineTokenHeader(alg: "Ed25519", typ: "LK-TRIAL", kid: "key_trial_v1")
        let claims = TrialClaims(
            typ: "trial",
            accountId: "acc_test_123",
            productId: "prd_super_app",
            fingerprint: "MOCK-HARDWARE-UUID-TRIAL",
            issuedAtTimestamp: now,
            expirationTimestamp: now + 86400 * 14,
            features: ["feature_a", "feature_b", "pro_export"]
        )
        
        let headerData = try JSONEncoder().encode(header)
        let payloadData = try JSONEncoder().encode(claims)
        
        let headerB64 = verifier.encodeBase64Url(headerData)
        let payloadB64 = verifier.encodeBase64Url(payloadData)
        let signedData = "\(headerB64).\(payloadB64)".data(using: .utf8)!
        
        let signature = try privateKey.signature(for: signedData)
        let signatureB64 = verifier.encodeBase64Url(signature)
        let token = "\(headerB64).\(payloadB64).\(signatureB64)"
        
        // 1. 指定泛型解码为 TrialClaims
        let (decodedHeader, decodedClaims): (OfflineTokenHeader, TrialClaims) = try verifier.verifyAndDecodeToken(
            token: token,
            publicKeyInput: pubKeyBase64
        )
        XCTAssertEqual(decodedHeader.typ, "LK-TRIAL")
        XCTAssertEqual(decodedClaims.accountId, "acc_test_123")
        XCTAssertEqual(decodedClaims.productId, "prd_super_app")
        XCTAssertEqual(decodedClaims.fingerprint, "MOCK-HARDWARE-UUID-TRIAL")
        XCTAssertEqual(decodedClaims.features, ["feature_a", "feature_b", "pro_export"])
        XCTAssertFalse(decodedClaims.isExpired)
        
        // 2. 自适应解码 verifyAndDecodeAnyToken
        let (anyHeader, anyClaims) = try verifier.verifyAndDecodeAnyToken(
            token: token,
            publicKeyInput: pubKeyBase64
        )
        XCTAssertEqual(anyHeader.typ, "LK-TRIAL")
        if case .trial(let tc) = anyClaims {
            XCTAssertEqual(tc.fingerprint, "MOCK-HARDWARE-UUID-TRIAL")
            XCTAssertEqual(tc.features, ["feature_a", "feature_b", "pro_export"])
        } else {
            XCTFail("Expected .trial claims")
        }
    }
    
    // MARK: - Claims Evaluation
    
    func testTrialClaimsEvaluation() {
        let evaluator = ClaimsEvaluator()
        let now = Int64(Date().timeIntervalSince1970)
        let currentFp = "mock-macbook-fingerprint-001"
        
        // 1. 正常有效试用期
        let validClaims = TrialClaims(
            typ: "trial",
            accountId: "acc_1",
            productId: "prd_1",
            fingerprint: currentFp,
            issuedAtTimestamp: now - 3600,
            expirationTimestamp: now + 86400 * 7,
            features: ["feature_basic", "ai_copilot"]
        )
        let validStatus = evaluator.evaluateTrial(claims: validClaims, currentFingerprint: currentFp)
        XCTAssertTrue(validStatus.isUsable)
        XCTAssertTrue(validStatus.isTrial)
        XCTAssertTrue(validStatus.hasFeature("ai_copilot"))
        XCTAssertFalse(validStatus.hasFeature("enterprise_sso"))
        XCTAssertNotNil(validStatus.trialClaims)
        XCTAssertNil(validStatus.claims)
        if case .trial(let c) = validStatus {
            XCTAssertEqual(c.productId, "prd_1")
        } else {
            XCTFail("Expected .trial")
        }
        
        // 2. 试用期已到期
        let expiredClaims = TrialClaims(
            typ: "trial",
            accountId: "acc_1",
            productId: "prd_1",
            fingerprint: currentFp,
            issuedAtTimestamp: now - 86400 * 15,
            expirationTimestamp: now - 86400 * 1,
            features: ["feature_basic"]
        )
        let expiredStatus = evaluator.evaluateTrial(claims: expiredClaims, currentFingerprint: currentFp)
        XCTAssertFalse(expiredStatus.isUsable)
        XCTAssertTrue(expiredStatus.isTrial)
        if case .trialExpired(let c) = expiredStatus {
            XCTAssertEqual(c?.productId, "prd_1")
        } else {
            XCTFail("Expected .trialExpired")
        }
        
        // 3. 硬件指纹不匹配
        let mismatchStatus = evaluator.evaluateTrial(claims: validClaims, currentFingerprint: "OTHER-MACHINE-FP")
        XCTAssertFalse(mismatchStatus.isUsable)
        if case .untrusted(let reason) = mismatchStatus {
            XCTAssertTrue(reason.contains("Hardware fingerprint mismatch"))
        } else {
            XCTFail("Expected .untrusted due to fingerprint mismatch")
        }
        
        // 4. 时钟异常 (签发时间处于未来超过 1 小时)
        let futureClaims = TrialClaims(
            typ: "trial",
            accountId: "acc_1",
            productId: "prd_1",
            fingerprint: currentFp,
            issuedAtTimestamp: now + 7200,
            expirationTimestamp: now + 86400 * 7,
            features: []
        )
        let clockAnomalyStatus = evaluator.evaluateTrial(claims: futureClaims, currentFingerprint: currentFp)
        XCTAssertFalse(clockAnomalyStatus.isUsable)
        if case .untrusted(let reason) = clockAnomalyStatus {
            XCTAssertTrue(reason.contains("System clock anomaly"))
        } else {
            XCTFail("Expected .untrusted due to clock anomaly")
        }
    }
    
    // MARK: - StoredCredentials Backward Compatibility
    
    func testStoredCredentialsTrialCompatibility() throws {
        // 1. 序列化与反序列化带有 isTrial = true 的凭据
        let creds = StoredCredentials(
            licenseKey: "",
            token: "sample.trial.token",
            lastValidatedAt: Date(),
            offlineGracePeriod: 0,
            policyFeatures: ["trial_feature_1"],
            machineId: "",
            isTrial: true
        )
        let data = try JSONEncoder().encode(creds)
        let decoded = try JSONDecoder().decode(StoredCredentials.self, from: data)
        XCTAssertTrue(decoded.isTrial)
        XCTAssertEqual(decoded.token, "sample.trial.token")
        XCTAssertEqual(decoded.licenseKey, "")
        
        // 2. 向后兼容解析不包含 isTrial、licenseKey 等字段的旧版 JSON
        let legacyJson = """
        {
            "licenseKey": "LIC-OLD-1234",
            "token": "sample.legacy.token",
            "lastValidatedAt": \(Date().timeIntervalSince1970),
            "offlineGracePeriod": 604800,
            "policyFeatures": ["export"],
            "machineId": "mac_123"
        }
        """.data(using: .utf8)!
        
        let legacyDecoded = try JSONDecoder().decode(StoredCredentials.self, from: legacyJson)
        XCTAssertFalse(legacyDecoded.isTrial)
        XCTAssertEqual(legacyDecoded.licenseKey, "LIC-OLD-1234")
    }
    
    // MARK: - ApiTrialResponse JSON Decoding
    
    func testApiTrialResponseDecoding() throws {
        let json = """
        {
            "success": true,
            "data": {
                "trial_claimed": true,
                "already_claimed": false,
                "expired": false,
                "claimed_at": "2026-09-17T10:00:00.000Z",
                "expires_at": "2026-10-01T10:00:00.000Z",
                "token": "header.payload.signature",
                "features": ["feat_1", "feat_2"]
            }
        }
        """.data(using: .utf8)!
        
        let wrapper = try JSONDecoder().decode(LicenKitApiResponse<ApiTrialResponse>.self, from: json)
        XCTAssertTrue(wrapper.success)
        guard let data = wrapper.data else {
            XCTFail("Missing data")
            return
        }
        
        XCTAssertTrue(data.trialClaimed)
        XCTAssertFalse(data.alreadyClaimed)
        XCTAssertFalse(data.expired)
        XCTAssertEqual(data.token, "header.payload.signature")
        XCTAssertEqual(data.features, ["feat_1", "feat_2"])
        XCTAssertNotNil(data.claimedAt?.date)
        XCTAssertNotNil(data.expiresAt?.date)
    }
    
    // MARK: - LicenKit Lifecycle: Trial to License Transition
    
    func testLicenKitOfflineVerificationWithTrialToken() async throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let pubKeyBase64 = privateKey.publicKey.rawRepresentation.base64EncodedString()
        let fixedFp = "MOCK-HARDWARE-UUID-TRIAL-001"
        
        let config = LicenKitConfiguration(
            serverUrl: "https://test.licenkit.io",
            accountId: "acc_test",
            productId: "prd_test",
            publicKey: pubKeyBase64
        )
        
        let mockStore = MockCredentialStore()
        let client = LicenKit(
            configuration: config,
            credentialStore: mockStore,
            fingerprintProvider: FixedFingerprintProvider(fingerprint: fixedFp)
        )
        
        let verifier = Ed25519Verifier()
        let now = Int64(Date().timeIntervalSince1970)
        
        // 1. 生成合法试用 Token
        let trialHeader = OfflineTokenHeader(alg: "Ed25519", typ: "LK-TRIAL")
        let trialClaims = TrialClaims(
            typ: "trial",
            accountId: "acc_test",
            productId: "prd_test",
            fingerprint: fixedFp,
            issuedAtTimestamp: now,
            expirationTimestamp: now + 86400 * 14,
            features: ["cloud_sync", "pdf_export"]
        )
        let trialToken = try signToken(header: trialHeader, claims: trialClaims, privateKey: privateKey, verifier: verifier)
        
        // 2. 模拟试用凭据持久化
        let trialCreds = StoredCredentials(
            licenseKey: "",
            token: trialToken,
            lastValidatedAt: Date(),
            offlineGracePeriod: 0,
            policyFeatures: ["cloud_sync", "pdf_export"],
            machineId: "",
            isTrial: true
        )
        try mockStore.saveCredentials(trialCreds, for: fixedFp)
        
        // 3. 脱网离线验证，状态应为 .trial
        let trialStatus = try await client.verifyOffline()
        XCTAssertTrue(trialStatus.isUsable)
        XCTAssertTrue(trialStatus.isTrial)
        XCTAssertTrue(client.hasFeature("cloud_sync"))
        XCTAssertTrue(client.hasFeature("pdf_export"))
        XCTAssertFalse(client.hasFeature("enterprise_team"))
        
        if case .trial(let tc) = client.cachedStatus {
            XCTAssertEqual(tc.fingerprint, fixedFp)
        } else {
            XCTFail("Expected cached status to be .trial")
        }
        
        // 4. 用户随后购买正式 License，凭据切换为商业版
        let licenseHeader = OfflineTokenHeader(alg: "Ed25519", typ: "LK-TOKEN")
        let licenseClaims = LicenseClaims(
            licenseId: "lic_purchased_123",
            licenseKey: "LIC-PAID-FULL-ACCESS",
            accountId: "acc_test",
            productId: "prd_test",
            policyId: "pol_commercial",
            fingerprint: fixedFp,
            issuedAtTimestamp: now,
            expirationTimestamp: now + 86400 * 365,
            features: ["cloud_sync", "pdf_export", "enterprise_team"]
        )
        let licenseToken = try signToken(header: licenseHeader, claims: licenseClaims, privateKey: privateKey, verifier: verifier)
        
        let licenseCreds = StoredCredentials(
            licenseKey: "LIC-PAID-FULL-ACCESS",
            token: licenseToken,
            lastValidatedAt: Date(),
            offlineGracePeriod: 604800,
            policyFeatures: ["cloud_sync", "pdf_export", "enterprise_team"],
            machineId: "mach_active_999",
            isTrial: false
        )
        try mockStore.saveCredentials(licenseCreds, for: fixedFp)
        
        // 5. 重新脱网核验，平滑切换为商业有效状态 .valid
        let paidStatus = try await client.verifyOffline()
        XCTAssertTrue(paidStatus.isUsable)
        XCTAssertFalse(paidStatus.isTrial)
        XCTAssertTrue(client.hasFeature("enterprise_team"))
        
        if case .valid(let lc) = client.cachedStatus {
            XCTAssertEqual(lc.licenseKey, "LIC-PAID-FULL-ACCESS")
        } else {
            XCTFail("Expected cached status to be .valid")
        }
    }
    
    // MARK: - Helpers
    
    private func signToken<H: Encodable, C: Encodable>(
        header: H,
        claims: C,
        privateKey: Curve25519.Signing.PrivateKey,
        verifier: Ed25519Verifier
    ) throws -> String {
        let headerData = try JSONEncoder().encode(header)
        let payloadData = try JSONEncoder().encode(claims)
        let headerB64 = verifier.encodeBase64Url(headerData)
        let payloadB64 = verifier.encodeBase64Url(payloadData)
        let signedData = "\(headerB64).\(payloadB64)".data(using: .utf8)!
        let signature = try privateKey.signature(for: signedData)
        let signatureB64 = verifier.encodeBase64Url(signature)
        return "\(headerB64).\(payloadB64).\(signatureB64)"
    }
}
