import Foundation

/// LicenKit SDK 发生的异常错误
public enum LicenKitError: Error, LocalizedError, Equatable, Sendable {
    /// 尚未在此机器上激活任何许可证凭据
    case unactivated
    
    /// 许可证激活席位已达到上限 (HTTP 409)
    case maxMachinesReached
    
    /// 硬件指纹不匹配 (尝试在不同硬件上使用非当前机器的 License Token)
    case fingerprintMismatch(expected: String, actual: String)
    
    /// 凭据格式错误或反序列化失败
    case invalidToken(String)
    
    /// 密码学校验失败 (签名无效、公钥格式非法或 Token 被篡改)
    case cryptoError(String)
    
    /// 网络传输或连接超时异常
    case networkError(String)
    
    /// 服务端返回的业务错误
    case apiError(code: String, message: String)
    
    /// 本地 Keychain 读写或存储错误
    case keychainError(status: Int32, message: String)
    
    /// SDK 尚未初始化
    case uninitialized
    
    public var errorDescription: String? {
        switch self {
        case .unactivated:
            return "No active license credentials found on this device."
        case .maxMachinesReached:
            return "License seat limit reached. Please deactivate another machine first."
        case .fingerprintMismatch(let expected, let actual):
            return "Hardware fingerprint mismatch (expected: \(expected), actual: \(actual))."
        case .invalidToken(let reason):
            return "Invalid license token: \(reason)."
        case .cryptoError(let reason):
            return "Cryptographic verification failed: \(reason)."
        case .networkError(let message):
            return "Network connection error: \(message)."
        case .apiError(let code, let message):
            return "Server error [\(code)]: \(message)."
        case .keychainError(let status, let message):
            return "Keychain error (status: \(status)): \(message)."
        case .uninitialized:
            return "LicenKit is not initialized. Please call LicenKit.configure(with:) first."
        }
    }
}
