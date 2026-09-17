import XCTest
import CryptoKit
@testable import LicenKit

/// 纯内存 Mock 存储器 (支持按指纹隔离和漫游激活码)
final class MockCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var credentialsByFp: [String: StoredCredentials] = [:]
    private var roamingKey: String?
    
    func loadCredentials(for fingerprint: String) throws -> StoredCredentials? {
        lock.lock()
        defer { lock.unlock() }
        return credentialsByFp[fingerprint.lowercased()]
    }
    
    func saveCredentials(_ credentials: StoredCredentials, for fingerprint: String) throws {
        lock.lock()
        defer { lock.unlock() }
        credentialsByFp[fingerprint.lowercased()] = credentials
    }
    
    func clearCredentials(for fingerprint: String) throws {
        lock.lock()
        defer { lock.unlock() }
        credentialsByFp.removeValue(forKey: fingerprint.lowercased())
    }
    
    func loadRoamingLicenseKey() throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return roamingKey
    }
    
    func saveRoamingLicenseKey(_ key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        self.roamingKey = key
    }
    
    func clearRoamingLicenseKey() throws {
        lock.lock()
        defer { lock.unlock() }
        self.roamingKey = nil
    }
}

/// 固定指纹提供器
struct FixedFingerprintProvider: DeviceFingerprintProvider, Sendable {
    let fingerprint: String
    func getFingerprint() async throws -> String {
        return fingerprint
    }
}

final class LicenKitTests: XCTestCase {
    
    func testOfflineVerificationLifecycle() async throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let pubKeyBase64 = privateKey.publicKey.rawRepresentation.base64EncodedString()
        let fixedFp = "MOCK-HARDWARE-UUID-001"
        
        let config = LicenKitConfiguration(
            serverUrl: "https://test.licenkit.io",
            accountId: "acc_test",
            productId: "prd_test",
            publicKey: pubKeyBase64,
            accessGroup: "TEAM123.group.com.mixbayes.licenkit"
        )
        
        let mockStore = MockCredentialStore()
        let client = LicenKit(
            configuration: config,
            credentialStore: mockStore,
            fingerprintProvider: FixedFingerprintProvider(fingerprint: fixedFp)
        )
        
        // 1. 未激活状态下核验应抛出 unactivated
        do {
            try await client.verifyOffline()
            XCTFail("Should throw unactivated error")
        } catch let err as LicenKitError {
            XCTAssertEqual(err, .unactivated)
        }
        
        // 2. 模拟服务端下发并存储合法 Token (按指纹隔离)
        let verifier = Ed25519Verifier()
        let now = Int64(Date().timeIntervalSince1970)
        let header = OfflineTokenHeader()
        let headerB64 = verifier.encodeBase64Url(try JSONEncoder().encode(header))
        
        let claims = LicenseClaims(
            licenseId: "lic_mock_99",
            licenseKey: "LIC-MOCK-TEST",
            accountId: "acc_test",
            productId: "prd_test",
            policyId: "pol_test",
            fingerprint: fixedFp,
            issuedAtTimestamp: now,
            expirationTimestamp: now + 86400 * 365,
            features: ["feature_cloud_backup", "feature_pro"]
        )
        let payloadB64 = verifier.encodeBase64Url(try JSONEncoder().encode(claims))
        let sig = try privateKey.signature(for: Data("\(headerB64).\(payloadB64)".utf8))
        let sigB64 = verifier.encodeBase64Url(sig)
        let token = "\(headerB64).\(payloadB64).\(sigB64)"
        
        try mockStore.saveCredentials(StoredCredentials(
            licenseKey: "LIC-MOCK-TEST",
            token: token,
            lastValidatedAt: Date(),
            offlineGracePeriod: 86400 * 7,
            policyFeatures: ["feature_cloud_backup", "feature_pro"],
            machineId: "mch_test_1"
        ), for: fixedFp)
        
        // 3. 再次离线核验，必须为 .valid
        let status = try await client.verifyOffline()
        guard case .valid(let verifiedClaims) = status else {
            XCTFail("Expected .valid, got \(status)")
            return
        }
        XCTAssertEqual(verifiedClaims.licenseKey, "LIC-MOCK-TEST")
        XCTAssertEqual(verifiedClaims.fingerprint, fixedFp)
        
        // 4. 特性查询
        XCTAssertTrue(client.hasFeature("feature_pro"))
        XCTAssertFalse(client.hasFeature("unknown_feature"))
        
        // 5. 解绑席位
        try await client.deactivate()
        XCTAssertNil(try mockStore.loadCredentials(for: fixedFp))
        
        // 6. 解绑后再核验，应再次抛出 unactivated
        do {
            try await client.verifyOffline()
            XCTFail("Should throw unactivated error after deactivation")
        } catch let err as LicenKitError {
            XCTAssertEqual(err, .unactivated)
        }
    }
    
    func testMultiMachineCredentialIsolation() async throws {
        let mockStore = MockCredentialStore()
        let fpMacA = "MACHINE-MAC-A-UUID"
        let fpMacB = "MACHINE-MAC-B-UUID"
        
        let credsA = StoredCredentials(
            licenseKey: "LIC-KEY-A",
            token: "token_for_mac_a",
            lastValidatedAt: Date(),
            offlineGracePeriod: 604800,
            policyFeatures: ["pro"],
            machineId: "mach_a"
        )
        
        let credsB = StoredCredentials(
            licenseKey: "LIC-KEY-B",
            token: "token_for_mac_b",
            lastValidatedAt: Date(),
            offlineGracePeriod: 604800,
            policyFeatures: ["enterprise"],
            machineId: "mach_b"
        )
        
        // 模拟 iCloud Keychain 同步两台 Mac 的凭据
        try mockStore.saveCredentials(credsA, for: fpMacA)
        try mockStore.saveCredentials(credsB, for: fpMacB)
        
        // 验证两台机器互不覆盖、互不冲突
        let loadedA = try mockStore.loadCredentials(for: fpMacA)
        let loadedB = try mockStore.loadCredentials(for: fpMacB)
        
        XCTAssertEqual(loadedA?.token, "token_for_mac_a")
        XCTAssertEqual(loadedB?.token, "token_for_mac_b")
        
        // 解绑 Mac A，Mac B 的凭据依然完好
        try mockStore.clearCredentials(for: fpMacA)
        XCTAssertNil(try mockStore.loadCredentials(for: fpMacA))
        XCTAssertEqual(try mockStore.loadCredentials(for: fpMacB)?.token, "token_for_mac_b")
    }
    
    func testRoamingLicenseKeyPersistence() async throws {
        let mockStore = MockCredentialStore()
        let config = LicenKitConfiguration(
            serverUrl: "https://test.licenkit.io",
            accountId: "acc_1",
            productId: "prd_1",
            publicKey: "pub_key"
        )
        let client = LicenKit(
            configuration: config,
            credentialStore: mockStore,
            fingerprintProvider: FixedFingerprintProvider(fingerprint: "FP_NEW_MAC")
        )
        
        // 保存漫游激活码
        try mockStore.saveRoamingLicenseKey("LIC-ROAMING-KEY-999")
        XCTAssertEqual(try client.getRoamingLicenseKey(), "LIC-ROAMING-KEY-999")
        
        // 解绑但保留漫游 Key
        try await client.deactivate(clearRoamingKey: false)
        XCTAssertEqual(try client.getRoamingLicenseKey(), "LIC-ROAMING-KEY-999")
        
        // 彻底注销并清除漫游 Key
        try await client.deactivate(clearRoamingKey: true)
        XCTAssertNil(try client.getRoamingLicenseKey())
    }
}
