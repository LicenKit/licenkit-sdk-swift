import XCTest
import CryptoKit
@testable import LicenKit

final class CryptoTests: XCTestCase {
    
    func testEd25519VerificationAndDecodingSuccess() throws {
        // 1. 生成真实 Ed25519 密钥对用于测试
        let privateKey = Curve25519.Signing.PrivateKey()
        let rawPublicKeyData = privateKey.publicKey.rawRepresentation
        let publicKeyBase64 = rawPublicKeyData.base64EncodedString()
        
        let verifier = Ed25519Verifier()
        
        // 2. 构造测试 Header 与 Payload
        let header = OfflineTokenHeader(alg: "Ed25519", typ: "LK-TOKEN", kid: "test_key_01")
        let headerData = try JSONEncoder().encode(header)
        let headerB64Url = verifier.encodeBase64Url(headerData)
        
        let now = Int64(Date().timeIntervalSince1970)
        let claims = LicenseClaims(
            typ: "license",
            licenseId: "lic_test_12345",
            licenseKey: "LIC-ABCD-1234-EFGH-5678",
            accountId: "acc_unit_test",
            productId: "prd_macos_app",
            policyId: "pol_lifetime",
            fingerprint: "MAC-TEST-UUID-9999",
            issuedAtTimestamp: now,
            expirationTimestamp: now + 3600,
            features: ["feature_a", "feature_b"]
        )
        let payloadData = try JSONEncoder().encode(claims)
        let payloadB64Url = verifier.encodeBase64Url(payloadData)
        
        // 3. 签名 dataToVerify
        let dataToSignString = "\(headerB64Url).\(payloadB64Url)"
        let signatureData = try privateKey.signature(for: Data(dataToSignString.utf8))
        let signatureB64Url = verifier.encodeBase64Url(signatureData)
        
        let fullToken = "\(headerB64Url).\(payloadB64Url).\(signatureB64Url)"
        
        // 4. 执行验签与反序列化
        let (decodedHeader, decodedClaims): (OfflineTokenHeader, LicenseClaims) = try verifier.verifyAndDecodeToken(
            token: fullToken,
            publicKeyInput: publicKeyBase64
        )
        
        XCTAssertEqual(decodedHeader.alg, "Ed25519")
        XCTAssertEqual(decodedHeader.kid, "test_key_01")
        XCTAssertEqual(decodedClaims.licenseKey, "LIC-ABCD-1234-EFGH-5678")
        XCTAssertEqual(decodedClaims.fingerprint, "MAC-TEST-UUID-9999")
        XCTAssertEqual(decodedClaims.features, ["feature_a", "feature_b"])
    }
    
    func testEd25519TamperedTokenFails() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKeyBase64 = privateKey.publicKey.rawRepresentation.base64EncodedString()
        let verifier = Ed25519Verifier()
        
        let header = OfflineTokenHeader(alg: "Ed25519", typ: "LK-TOKEN")
        let headerB64Url = verifier.encodeBase64Url(try JSONEncoder().encode(header))
        
        let claims = LicenseClaims(
            licenseId: "lic_valid",
            licenseKey: "LIC-1111",
            accountId: "acc_1",
            productId: "prd_1",
            policyId: "pol_1",
            fingerprint: "FP-ORIGINAL",
            issuedAtTimestamp: 1000,
            expirationTimestamp: 2000
        )
        let payloadB64Url = verifier.encodeBase64Url(try JSONEncoder().encode(claims))
        
        let signatureData = try privateKey.signature(for: Data("\(headerB64Url).\(payloadB64Url)".utf8))
        let signatureB64Url = verifier.encodeBase64Url(signatureData)
        
        // 恶意篡改 Payload 中的指纹
        let tamperedClaims = LicenseClaims(
            licenseId: "lic_valid",
            licenseKey: "LIC-1111",
            accountId: "acc_1",
            productId: "prd_1",
            policyId: "pol_1",
            fingerprint: "FP-TAMPERED-PIRATE",
            issuedAtTimestamp: 1000,
            expirationTimestamp: 2000
        )
        let tamperedPayloadB64Url = verifier.encodeBase64Url(try JSONEncoder().encode(tamperedClaims))
        
        let forgedToken = "\(headerB64Url).\(tamperedPayloadB64Url).\(signatureB64Url)"
        
        XCTAssertThrowsError(try verifier.verifyAndDecodeToken(token: forgedToken, publicKeyInput: publicKeyBase64) as (OfflineTokenHeader, LicenseClaims)) { error in
            guard case LicenKitError.cryptoError = error else {
                XCTFail("Expected LicenKitError.cryptoError, got \(error)")
                return
            }
        }
    }
    
    func testExtractSPKIPublicKey() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let rawPub = privateKey.publicKey.rawRepresentation
        
        // 标准 12 字节 SPKI Ed25519 前缀
        let spkiPrefix = Data([0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00])
        let fullSpki = spkiPrefix + rawPub
        let spkiBase64 = fullSpki.base64EncodedString()
        let pemFormatted = "-----BEGIN PUBLIC KEY-----\n\(spkiBase64)\n-----END PUBLIC KEY-----"
        
        let verifier = Ed25519Verifier()
        let extracted = try verifier.extractRawEd25519PublicKey(from: pemFormatted)
        XCTAssertEqual(extracted, rawPub)
    }
}
