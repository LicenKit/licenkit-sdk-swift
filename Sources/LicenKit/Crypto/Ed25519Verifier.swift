import CryptoKit
import Foundation

public struct Ed25519Verifier: Sendable {
    public init() {}

    public func decodeProtectedHeader(token: String) throws -> SignedLicenseTokenHeader {
        let parts = token.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let data = decodeBase64URL(String(parts[0])) else {
            throw LicenKitError.invalidSignedLicenseToken(reason: "expected three valid Base64URL JWS segments")
        }
        try rejectDuplicateTopLevelKeys(in: data)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            throw LicenKitError.invalidSignedLicenseToken(reason: "protected header must be an object")
        }
        let allowed: Set<String> = ["alg", "typ", "kid"]
        guard Set(dictionary.keys).isSubset(of: allowed) else {
            let unknown = Set(dictionary.keys).subtracting(allowed).sorted().joined(separator: ",")
            throw LicenKitError.invalidSignedLicenseToken(reason: "unsupported protected header: \(unknown)")
        }
        let header = try JSONDecoder().decode(SignedLicenseTokenHeader.self, from: data)
        guard header.alg == "EdDSA" else {
            throw LicenKitError.invalidSignedLicenseToken(reason: "protected alg must be EdDSA")
        }
        guard header.typ == "licenkit-license+jwt" else {
            throw LicenKitError.invalidSignedLicenseToken(reason: "protected typ must be licenkit-license+jwt")
        }
        guard !header.kid.isEmpty else {
            throw LicenKitError.invalidSignedLicenseToken(reason: "protected kid is required")
        }
        return header
    }

    public func verifyAndDecodeToken(
        token: String,
        signingPublicKey: String?
    ) throws -> (header: SignedLicenseTokenHeader, claims: LicenseClaims) {
        let parts = token.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else {
            throw LicenKitError.invalidSignedLicenseToken(reason: "expected three JWS segments")
        }
        let header = try decodeProtectedHeader(token: token)
        guard let signingPublicKey, !signingPublicKey.isEmpty else {
            throw LicenKitError.missingSigningPublicKey(keyID: header.kid)
        }
        guard let signature = decodeBase64URL(String(parts[2])), signature.count == 64 else {
            throw LicenKitError.invalidSignedLicenseToken(reason: "signature must be 64-byte Base64URL Ed25519 data")
        }
        let keyData = try extractRawEd25519PublicKey(from: signingPublicKey)
        let verifier: Curve25519.Signing.PublicKey
        do { verifier = try Curve25519.Signing.PublicKey(rawRepresentation: keyData) }
        catch { throw LicenKitError.configurationError(reason: "trusted Ed25519 public key is invalid") }
        let signedData = Data("\(parts[0]).\(parts[1])".utf8)
        guard verifier.isValidSignature(signature, for: signedData) else {
            throw LicenKitError.invalidSignedLicenseToken(reason: "Ed25519 signature verification failed")
        }
        guard let payload = decodeBase64URL(String(parts[1])) else {
            throw LicenKitError.invalidSignedLicenseToken(reason: "payload is not valid Base64URL")
        }
        try rejectDuplicateTopLevelKeys(in: payload)
        let payloadObject = try JSONSerialization.jsonObject(with: payload)
        guard let payloadDictionary = payloadObject as? [String: Any] else {
            throw LicenKitError.invalidSignedLicenseToken(reason: "claims payload must be an object")
        }
        guard payloadDictionary["acc"] == nil else {
            throw LicenKitError.invalidSignedLicenseToken(reason: "legacy tenant claim is not accepted")
        }
        let requiredClaims: Set<String> = [
            "lic", "act", "ins", "prd", "ver", "plt", "arc", "fp", "iat", "lexp", "upd", "fea"
        ]
        guard requiredClaims.isSubset(of: Set(payloadDictionary.keys)) else {
            let missing = requiredClaims.subtracting(Set(payloadDictionary.keys)).sorted().joined(separator: ",")
            throw LicenKitError.invalidSignedLicenseToken(reason: "required claims are missing: \(missing)")
        }
        guard Set(payloadDictionary.keys) == requiredClaims else {
            let unsupported = Set(payloadDictionary.keys).subtracting(requiredClaims).sorted().joined(separator: ",")
            throw LicenKitError.invalidSignedLicenseToken(reason: "unsupported claims are present: \(unsupported)")
        }
        let claims: LicenseClaims
        do { claims = try JSONDecoder().decode(LicenseClaims.self, from: payload) }
        catch { throw LicenKitError.invalidSignedLicenseToken(reason: "claims could not be decoded: \(error.localizedDescription)") }
        return (header, claims)
    }

    public func extractRawEd25519PublicKey(from input: String) throws -> Data {
        let cleaned = input
            .replacingOccurrences(of: "-----BEGIN PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "-----END PUBLIC KEY-----", with: "")
            .components(separatedBy: .whitespacesAndNewlines).joined()
        guard let data = Data(base64Encoded: cleaned) else {
            throw LicenKitError.configurationError(reason: "trusted public key is not valid Base64")
        }
        if data.count == 32 { return data }
        let prefix = Data([0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00])
        if data.count == 44, data.prefix(prefix.count) == prefix { return data.suffix(32) }
        throw LicenKitError.configurationError(reason: "trusted public key must be raw 32-byte or Ed25519 SPKI data")
    }

    public func decodeBase64URL(_ value: String) -> Data? {
        guard !value.isEmpty, value.unicodeScalars.allSatisfy({
            (65...90).contains($0.value) || (97...122).contains($0.value) || (48...57).contains($0.value) || $0 == "-" || $0 == "_"
        }) else { return nil }
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }

    public func encodeBase64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func rejectDuplicateTopLevelKeys(in data: Data) throws {
        let bytes = Array(data)
        var index = 0
        func isWhitespace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 || byte == 0x0a || byte == 0x0d }
        func skipWhitespace() { while index < bytes.count && isWhitespace(bytes[index]) { index += 1 } }
        func scanString() throws -> String {
            let start = index
            index += 1
            var escaped = false
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                if escaped { escaped = false }
                else if byte == 0x5c { escaped = true }
                else if byte == 0x22 {
                    return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index]))
                }
            }
            throw LicenKitError.invalidSignedLicenseToken(reason: "unterminated JSON string")
        }

        skipWhitespace()
        guard index < bytes.count, bytes[index] == 0x7b else {
            throw LicenKitError.invalidSignedLicenseToken(reason: "token segment must be a JSON object")
        }
        index += 1
        var keys = Set<String>()
        while index < bytes.count {
            skipWhitespace()
            guard index < bytes.count else {
                throw LicenKitError.invalidSignedLicenseToken(reason: "token JSON object is not closed")
            }
            if bytes[index] == 0x7d { return }
            guard bytes[index] == 0x22 else {
                throw LicenKitError.invalidSignedLicenseToken(reason: "token object key must be a string")
            }
            let key = try scanString()
            guard keys.insert(key).inserted else {
                throw LicenKitError.invalidSignedLicenseToken(reason: "duplicate token field '\(key)'")
            }
            skipWhitespace()
            guard index < bytes.count, bytes[index] == 0x3a else {
                throw LicenKitError.invalidSignedLicenseToken(reason: "token object field is missing ':'")
            }
            index += 1
            var nestedDepth = 0
            var inString = false
            var escaped = false
            while index < bytes.count {
                let byte = bytes[index]
                if inString {
                    if escaped { escaped = false }
                    else if byte == 0x5c { escaped = true }
                    else if byte == 0x22 { inString = false }
                } else if byte == 0x22 { inString = true }
                else if byte == 0x7b || byte == 0x5b { nestedDepth += 1 }
                else if byte == 0x7d || byte == 0x5d {
                    if nestedDepth == 0 && byte == 0x7d { break }
                    nestedDepth -= 1
                } else if byte == 0x2c && nestedDepth == 0 { break }
                index += 1
            }
            if index < bytes.count, bytes[index] == 0x2c { index += 1 }
        }
        throw LicenKitError.invalidSignedLicenseToken(reason: "token JSON object is not closed")
    }
}
