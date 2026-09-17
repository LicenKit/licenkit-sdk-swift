import XCTest
@testable import LicenKit

final class TokenEvaluationTests: XCTestCase {
    
    let evaluator = ClaimsEvaluator()
    let testFingerprint = "5B5F4A9A-1234-5678-ABCD-000000000000"
    
    func testValidClaimsEvaluation() {
        let now = Int64(Date().timeIntervalSince1970)
        let claims = LicenseClaims(
            licenseId: "lic_01",
            licenseKey: "LIC-VALID-KEY",
            accountId: "acc_1",
            productId: "prd_1",
            policyId: "pol_1",
            fingerprint: testFingerprint,
            issuedAtTimestamp: now - 3600,
            expirationTimestamp: now + 86400,
            features: ["export_pdf", "dark_mode"]
        )
        
        let status = evaluator.evaluate(
            claims: claims,
            currentFingerprint: testFingerprint,
            lastValidatedAt: Date(),
            offlineGracePeriodSeconds: 604800 // 7 days
        )
        
        XCTAssertEqual(status, .valid(claims: claims))
        XCTAssertTrue(status.isUsable)
        XCTAssertTrue(status.hasFeature("export_pdf"))
        XCTAssertFalse(status.hasFeature("cloud_sync"))
    }
    
    func testFingerprintMismatchReturnsUntrusted() {
        let now = Int64(Date().timeIntervalSince1970)
        let claims = LicenseClaims(
            licenseId: "lic_02",
            licenseKey: "LIC-PIRATED-KEY",
            accountId: "acc_1",
            productId: "prd_1",
            policyId: "pol_1",
            fingerprint: "MACHINE-ALICE-UUID",
            issuedAtTimestamp: now - 3600,
            expirationTimestamp: now + 86400
        )
        
        let status = evaluator.evaluate(
            claims: claims,
            currentFingerprint: "MACHINE-BOB-UUID"
        )
        
        guard case .untrusted(let reason) = status else {
            XCTFail("Expected .untrusted, got \(status)")
            return
        }
        XCTAssertTrue(reason.contains("Hardware fingerprint mismatch"))
        XCTAssertFalse(status.isUsable)
    }
    
    func testExpiredTokenReturnsExpired() {
        let now = Int64(Date().timeIntervalSince1970)
        let expiredClaims = LicenseClaims(
            licenseId: "lic_03",
            licenseKey: "LIC-EXPIRED-KEY",
            accountId: "acc_1",
            productId: "prd_1",
            policyId: "pol_1",
            fingerprint: testFingerprint,
            issuedAtTimestamp: now - 7200,
            expirationTimestamp: now - 60 // 1 minute ago
        )
        
        let status = evaluator.evaluate(
            claims: expiredClaims,
            currentFingerprint: testFingerprint
        )
        
        XCTAssertEqual(status, .expired(claims: expiredClaims))
        XCTAssertFalse(status.isUsable)
    }
    
    func testGracePeriodEvaluation() {
        let now = Date()
        let nowTimestamp = Int64(now.timeIntervalSince1970)
        let claims = LicenseClaims(
            licenseId: "lic_04",
            licenseKey: "LIC-GRACE-KEY",
            accountId: "acc_1",
            productId: "prd_1",
            policyId: "pol_1",
            fingerprint: testFingerprint,
            issuedAtTimestamp: nowTimestamp - 86400,
            expirationTimestamp: nowTimestamp + 86400 * 30
        )
        
        // 允许 100 秒脱网宽限期，当前已脱网 80 秒 (超过 70%)
        let lastValidated = now.addingTimeInterval(-80)
        let status = evaluator.evaluate(
            claims: claims,
            currentFingerprint: testFingerprint,
            lastValidatedAt: lastValidated,
            offlineGracePeriodSeconds: 100
        )
        
        guard case .inGracePeriod(let evaluatedClaims, let remainingSec) = status else {
            XCTFail("Expected .inGracePeriod, got \(status)")
            return
        }
        XCTAssertEqual(evaluatedClaims.licenseKey, "LIC-GRACE-KEY")
        XCTAssertTrue(remainingSec > 0 && remainingSec <= 21)
        XCTAssertTrue(status.isUsable)
    }
    
    func testGracePeriodExceededReturnsExpired() {
        let now = Date()
        let nowTimestamp = Int64(now.timeIntervalSince1970)
        let claims = LicenseClaims(
            licenseId: "lic_05",
            licenseKey: "LIC-GRACE-EXCEEDED-KEY",
            accountId: "acc_1",
            productId: "prd_1",
            policyId: "pol_1",
            fingerprint: testFingerprint,
            issuedAtTimestamp: nowTimestamp - 86400 * 30,
            expirationTimestamp: nowTimestamp + 86400 * 365
        )
        
        // 允许 100 秒脱网宽限期，当前已脱网 150 秒 (超过 100 秒)
        let lastValidated = now.addingTimeInterval(-150)
        let status = evaluator.evaluate(
            claims: claims,
            currentFingerprint: testFingerprint,
            lastValidatedAt: lastValidated,
            offlineGracePeriodSeconds: 100
        )
        
        XCTAssertEqual(status, .expired(claims: claims))
        XCTAssertFalse(status.isUsable)
    }
    
    func testClockRollbackBeyondOneHourReturnsUntrusted() {
        let now = Date()
        let nowTimestamp = Int64(now.timeIntervalSince1970)
        let claims = LicenseClaims(
            licenseId: "lic_06",
            licenseKey: "LIC-ROLLBACK-KEY",
            accountId: "acc_1",
            productId: "prd_1",
            policyId: "pol_1",
            fingerprint: testFingerprint,
            issuedAtTimestamp: nowTimestamp - 86400,
            expirationTimestamp: nowTimestamp + 86400 * 365
        )
        
        // 模拟系统时钟被故意向后回滚 2 小时 (当前时间比上次验证时间早 7200 秒，超出 1 小时模糊容差)
        let lastValidatedInFuture = now.addingTimeInterval(7200)
        let status = evaluator.evaluate(
            claims: claims,
            currentFingerprint: testFingerprint,
            lastValidatedAt: lastValidatedInFuture,
            offlineGracePeriodSeconds: 86400 * 7
        )
        
        guard case .untrusted(let reason) = status else {
            XCTFail("Expected .untrusted due to clock rollback > 1 hour, got \(status)")
            return
        }
        XCTAssertTrue(reason.contains("clock rollback"))
        XCTAssertFalse(status.isUsable)
    }
    
    func testClockSkewWithinOneHourIsTolerated() {
        let now = Date()
        let nowTimestamp = Int64(now.timeIntervalSince1970)
        let claims = LicenseClaims(
            licenseId: "lic_07",
            licenseKey: "LIC-SKEW-KEY",
            accountId: "acc_1",
            productId: "prd_1",
            policyId: "pol_1",
            fingerprint: testFingerprint,
            issuedAtTimestamp: nowTimestamp - 3600,
            expirationTimestamp: nowTimestamp + 86400 * 365
        )
        
        // 模拟因系统休眠唤醒或微小 NTP 漂移，上次校验时间在未来 30 分钟 (1800 秒，在 1 小时模糊容差内)
        let minorDriftInFuture = now.addingTimeInterval(1800)
        let status = evaluator.evaluate(
            claims: claims,
            currentFingerprint: testFingerprint,
            lastValidatedAt: minorDriftInFuture,
            offlineGracePeriodSeconds: 86400 * 7
        )
        
        // 1 小时内正常容差，不应误判为 untrusted
        XCTAssertEqual(status, .valid(claims: claims))
        XCTAssertTrue(status.isUsable)
    }
    
    func testTokenIssuedInFutureBeyondOneHourReturnsUntrusted() {
        let now = Date()
        let nowTimestamp = Int64(now.timeIntervalSince1970)
        let claims = LicenseClaims(
            licenseId: "lic_08",
            licenseKey: "LIC-FUTURE-KEY",
            accountId: "acc_1",
            productId: "prd_1",
            policyId: "pol_1",
            fingerprint: testFingerprint,
            issuedAtTimestamp: nowTimestamp + 7200, // 签发时间在未来 2 小时
            expirationTimestamp: nowTimestamp + 86400 * 365
        )
        
        let status = evaluator.evaluate(
            claims: claims,
            currentFingerprint: testFingerprint
        )
        
        guard case .untrusted(let reason) = status else {
            XCTFail("Expected .untrusted due to token issued in future, got \(status)")
            return
        }
        XCTAssertTrue(reason.contains("token issue time"))
        XCTAssertFalse(status.isUsable)
    }
    
    func testFlexibleDateDecoding() throws {
        // 1. 测试秒级整数时间戳 (方案 A 标准)
        let timestampJson = "1758110400".data(using: .utf8)!
        let decodedFromInt = try JSONDecoder().decode(FlexibleDate.self, from: timestampJson)
        XCTAssertNotNil(decodedFromInt.date)
        XCTAssertEqual(Int64(decodedFromInt.date!.timeIntervalSince1970), 1758110400)
        
        // 2. 测试带 3 位毫秒的 ISO8601 字符串 (Cloudflare / JS toISOString())
        let isoWithMillisJson = "\"2026-09-17T13:30:24.123Z\"".data(using: .utf8)!
        let decodedFromIsoMillis = try JSONDecoder().decode(FlexibleDate.self, from: isoWithMillisJson)
        XCTAssertNotNil(decodedFromIsoMillis.date)
        
        // 3. 测试标准无毫秒 ISO8601 字符串
        let isoStandardJson = "\"2026-09-17T13:30:24Z\"".data(using: .utf8)!
        let decodedFromIsoStandard = try JSONDecoder().decode(FlexibleDate.self, from: isoStandardJson)
        XCTAssertNotNil(decodedFromIsoStandard.date)
        
        // 4. 测试 null
        let nullJson = "null".data(using: .utf8)!
        let decodedFromNull = try JSONDecoder().decode(FlexibleDate.self, from: nullJson)
        XCTAssertNil(decodedFromNull.date)
    }
    
    func testApiActivateResponseTimestampDecoding() throws {
        let json = """
        {
            "activated": true,
            "reused": false,
            "machine_id": "mac_01",
            "scheme": "ed25519",
            "token": "hdr.payload.sig",
            "token_expires_at": 1758110400,
            "license_expires_at": 1789646400,
            "token_expires_at_iso": "2025-09-17T12:00:00.000Z",
            "license_expires_at_iso": "2026-09-17T12:00:00.000Z",
            "policy": {
                "name": "Standard",
                "max_machines": 2,
                "offline_grace_period": 604800,
                "features": ["pro"]
            }
        }
        """.data(using: .utf8)!
        
        let response = try JSONDecoder().decode(ApiActivateResponse.self, from: json)
        XCTAssertTrue(response.activated)
        XCTAssertEqual(response.tokenExpiresAt?.date?.timeIntervalSince1970, 1758110400)
        XCTAssertEqual(response.licenseExpiresAt?.date?.timeIntervalSince1970, 1789646400)
    }
    
    func testApiValidateResponseTimestampDecoding() throws {
        let json = """
        {
            "valid": true,
            "scheme": "ed25519",
            "token": "hdr.payload.sig",
            "token_expires_at": 1758110400,
            "license_expires_at": 1789646400,
            "token_expires_at_iso": "2025-09-17T12:00:00.000Z",
            "license_expires_at_iso": "2026-09-17T12:00:00.000Z",
            "last_heartbeat_at": 1726574400,
            "last_heartbeat_at_iso": "2024-09-17T12:00:00.000Z"
        }
        """.data(using: .utf8)!
        
        let response = try JSONDecoder().decode(ApiValidateResponse.self, from: json)
        XCTAssertTrue(response.valid)
        XCTAssertEqual(response.tokenExpiresAt?.date?.timeIntervalSince1970, 1758110400)
        XCTAssertEqual(response.licenseExpiresAt?.date?.timeIntervalSince1970, 1789646400)
        XCTAssertEqual(response.lastHeartbeatAt?.date?.timeIntervalSince1970, 1726574400)
    }
}
