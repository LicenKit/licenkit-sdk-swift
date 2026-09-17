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
    
    /// 判定是否属于 HTTP 5xx 等服务端故障
    public var isServerError: Bool {
        if case .apiError(let code, _) = self {
            return code.hasPrefix("HTTP_5") || code == "INTERNAL_SERVER_ERROR" || code == "SERVER_ERROR"
        }
        return false
    }
    
    /// 判定是否属于 HTTP 429 限流
    public var isRateLimited: Bool {
        if case .apiError(let code, _) = self {
            return code == "HTTP_429" || code == "RATE_LIMITED" || code == "TOO_MANY_REQUESTS"
        }
        return false
    }
    
    /// 判定是否属于服务端明确的业务拒绝 (已吊销/已删除/席位超限)
    public var isExplicitBusinessRejection: Bool {
        switch self {
        case .maxMachinesReached:
            return true
        case .apiError(let code, _):
            let rejections: Set<String> = [
                "LICENSE_NOT_FOUND",
                "LICENSE_REVOKED",
                "LICENSE_SUSPENDED",
                "LICENSE_NOT_ACTIVE",
                "MACHINE_REVOKED",
                "MACHINE_DEACTIVATED",
                "MACHINE_NOT_ACTIVATED",
                "MAX_MACHINES_REACHED",
                "SEAT_LIMIT_EXCEEDED",
                "POLICY_DISABLED",
                "POLICY_INACTIVE_OR_DISABLED"
            ]
            return rejections.contains(code)
        default:
            return false
        }
    }
    
    /// 判定是否属于通常可自动重试的临时故障 (网络异常、5xx 错误、429 限流)
    public var isRecoverable: Bool {
        switch self {
        case .networkError:
            return true
        case .apiError:
            return isServerError || isRateLimited
        default:
            return false
        }
    }
}

