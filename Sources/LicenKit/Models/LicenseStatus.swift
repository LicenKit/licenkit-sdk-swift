import Foundation

/// 许可证当前运行态判定结果
public enum LicenseStatus: Equatable, Sendable {
    /// 许可证在有效期内，指纹校验通过
    case valid(claims: LicenseClaims)
    
    /// 脱网宽限期中（虽离线或到期，但在允许的宽限期时限内）
    case inGracePeriod(claims: LicenseClaims, remainingGraceSeconds: TimeInterval)
    
    /// 许可证已过期
    case expired(claims: LicenseClaims?)
    
    /// 凭据不可信（如签名被篡改、硬件指纹被替换等）
    case untrusted(reason: String)
    
    /// 判定当前状态是否允许宿主应用核心功能继续运行
    public var isUsable: Bool {
        switch self {
        case .valid, .inGracePeriod:
            return true
        case .expired, .untrusted:
            return false
        }
    }
    
    /// 获取当前生效的 Claims (若可用)
    public var claims: LicenseClaims? {
        switch self {
        case .valid(let claims), .inGracePeriod(let claims, _):
            return claims
        case .expired(let claims):
            return claims
        case .untrusted:
            return nil
        }
    }
    
    /// 快速检查是否拥有某项特定功能授权
    public func hasFeature(_ featureKey: String) -> Bool {
        guard let claims = claims else { return false }
        return claims.features.contains(featureKey)
    }
}
