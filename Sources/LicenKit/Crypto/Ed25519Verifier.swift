import Foundation
import CryptoKit

/// 纯原生 Ed25519 离线验签器与 JWT-like Base64URL Token 解析器
public struct Ed25519Verifier: Sendable {
    
    public init() {}
    
    /// 解析并离线验签三段式 License Token
    /// - Parameters:
    ///   - token: 形如 `header.payload.signature` 的 Base64URL 字符串
    ///   - publicKeyInput: 32字节 Base64 公钥或标准 SPKI 文本
    /// - Returns: 验签成功的 Header 与 Payload (Claims)
    public func verifyAndDecodeToken<T: Decodable>(
        token: String,
        publicKeyInput: String
    ) throws -> (header: OfflineTokenHeader, claims: T) {
        let parts = token.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: ".")
        guard parts.count == 3 else {
            throw LicenKitError.invalidToken("Malformed token format: expected 3 dot-separated segments")
        }
        
        let headerPart = parts[0]
        let payloadPart = parts[1]
        let signaturePart = parts[2]
        
        let signedDataString = "\(headerPart).\(payloadPart)"
        guard let signedData = signedDataString.data(using: .utf8) else {
            throw LicenKitError.invalidToken("Unable to encode signed data to UTF-8")
        }
        
        guard let signatureData = decodeBase64Url(signaturePart) else {
            throw LicenKitError.invalidToken("Failed to decode signature from Base64URL")
        }
        
        guard signatureData.count == 64 else {
            throw LicenKitError.cryptoError("Invalid Ed25519 signature length: expected 64 bytes, got \(signatureData.count)")
        }
        
        // 提取 32 字节 Raw Public Key
        let rawPublicKeyData = try extractRawEd25519PublicKey(from: publicKeyInput)
        
        // 构造 CryptoKit 公钥对象
        guard let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: rawPublicKeyData) else {
            throw LicenKitError.cryptoError("Failed to initialize CryptoKit Ed25519 public key")
        }
        
        // 执行纯离线硬件加速数学签名核验
        let isSignatureValid = publicKey.isValidSignature(signatureData, for: signedData)
        guard isSignatureValid else {
            throw LicenKitError.cryptoError("Cryptographic signature verification failed (Token tampered or wrong public key)")
        }
        
        // 反序列化 Header 与 Payload
        guard let headerData = decodeBase64Url(headerPart),
              let header = try? JSONDecoder().decode(OfflineTokenHeader.self, from: headerData) else {
            throw LicenKitError.invalidToken("Failed to decode or parse token header")
        }
        
        guard let payloadData = decodeBase64Url(payloadPart) else {
            throw LicenKitError.invalidToken("Failed to decode token payload bytes")
        }
        
        do {
            let claims = try JSONDecoder().decode(T.self, from: payloadData)
            return (header, claims)
        } catch {
            throw LicenKitError.invalidToken("Failed to deserialize token claims: \(error.localizedDescription)")
        }
    }
    
    /// 解析并离线验签 Token，自适应识别为正式版 LicenseClaims 或试用版 TrialClaims
    public func verifyAndDecodeAnyToken(
        token: String,
        publicKeyInput: String
    ) throws -> (header: OfflineTokenHeader, claims: OfflineClaims) {
        let parts = token.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: ".")
        guard parts.count == 3 else {
            throw LicenKitError.invalidToken("Malformed token format: expected 3 dot-separated segments")
        }
        
        let headerPart = parts[0]
        let payloadPart = parts[1]
        let signaturePart = parts[2]
        
        let signedDataString = "\(headerPart).\(payloadPart)"
        guard let signedData = signedDataString.data(using: .utf8) else {
            throw LicenKitError.invalidToken("Unable to encode signed data to UTF-8")
        }
        
        guard let signatureData = decodeBase64Url(signaturePart) else {
            throw LicenKitError.invalidToken("Failed to decode signature from Base64URL")
        }
        
        guard signatureData.count == 64 else {
            throw LicenKitError.cryptoError("Invalid Ed25519 signature length: expected 64 bytes, got \(signatureData.count)")
        }
        
        let rawPublicKeyData = try extractRawEd25519PublicKey(from: publicKeyInput)
        guard let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: rawPublicKeyData) else {
            throw LicenKitError.cryptoError("Failed to initialize CryptoKit Ed25519 public key")
        }
        
        let isSignatureValid = publicKey.isValidSignature(signatureData, for: signedData)
        guard isSignatureValid else {
            throw LicenKitError.cryptoError("Cryptographic signature verification failed (Token tampered or wrong public key)")
        }
        
        guard let headerData = decodeBase64Url(headerPart),
              let header = try? JSONDecoder().decode(OfflineTokenHeader.self, from: headerData) else {
            throw LicenKitError.invalidToken("Failed to decode or parse token header")
        }
        
        guard let payloadData = decodeBase64Url(payloadPart) else {
            throw LicenKitError.invalidToken("Failed to decode token payload bytes")
        }
        
        struct Probe: Decodable {
            let typ: String?
        }
        let probe = try? JSONDecoder().decode(Probe.self, from: payloadData)
        
        if header.typ == "LK-TRIAL" || probe?.typ == "trial" {
            do {
                let trialClaims = try JSONDecoder().decode(TrialClaims.self, from: payloadData)
                return (header, .trial(trialClaims))
            } catch {
                throw LicenKitError.invalidToken("Failed to deserialize trial claims: \(error.localizedDescription)")
            }
        } else {
            do {
                let licenseClaims = try JSONDecoder().decode(LicenseClaims.self, from: payloadData)
                return (header, .license(licenseClaims))
            } catch {
                if let trialClaims = try? JSONDecoder().decode(TrialClaims.self, from: payloadData) {
                    return (header, .trial(trialClaims))
                }
                throw LicenKitError.invalidToken("Failed to deserialize license claims: \(error.localizedDescription)")
            }
        }
    }
    
    /// 从原始 Base64 或 SPKI 格式中提取标准的 32 字节 Ed25519 公钥字节流
    public func extractRawEd25519PublicKey(from input: String) throws -> Data {
        let cleanInput = input
            .replacingOccurrences(of: "-----BEGIN PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "-----END PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: " ", with: "")
        
        guard let keyData = Data(base64Encoded: cleanInput) else {
            throw LicenKitError.cryptoError("Invalid Base64 format for public key")
        }
        
        if keyData.count == 32 {
            return keyData
        }
        
        // 标准 SPKI Ed25519 ASN.1 头部为 12 字节 (302a300506032b6570032100) + 32 字节裸公钥 = 44 字节
        if keyData.count == 44 {
            return keyData.subdata(in: 12..<44)
        }
        
        throw LicenKitError.cryptoError("Unsupported public key length: \(keyData.count) bytes (expected 32 bytes raw or 44 bytes SPKI)")
    }
    
    /// 将 Base64URL 字符串转为 Data
    public func decodeBase64Url(_ base64Url: String) -> Data? {
        var base64 = base64Url
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        
        let remainder = base64.count % 4
        if remainder > 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        
        return Data(base64Encoded: base64)
    }
    
    /// 将普通 Data 转为无 Padding 的 Base64URL 字符串
    public func encodeBase64Url(_ data: Data) -> String {
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
