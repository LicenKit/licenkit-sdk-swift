import Foundation

/// 许可证当前运行态判定结果
public enum LicenseStatus: Equatable, Sendable {
    /// 许可证在有效期内，指纹校验通过
    case valid(claims: LicenseClaims)
    
    /// 试用期内，指纹校验通过
    case trial(claims: TrialClaims)
    
    /// 脱网宽限期中（虽离线或到期，但在允许的宽限期时限内）
    case inGracePeriod(claims: LicenseClaims, remainingGraceSeconds: TimeInterval)
    
    /// 许可证已过期
    case expired(claims: LicenseClaims?)
    
    /// 试用期已结束
    case trialExpired(claims: TrialClaims?)
    
    /// 凭据不可信（如签名被篡改、硬件指纹被替换等）
    case untrusted(reason: String)
    
    /// 判定当前状态是否允许宿主应用核心功能继续运行
    public var isUsable: Bool {
        switch self {
        case .valid, .inGracePeriod, .trial:
            return true
        case .expired, .trialExpired, .untrusted:
            return false
        }
    }
    
    /// 判定当前许可证状态是否合法生效 (isUsable 的等价语义别名)
    public var isValid: Bool {
        return isUsable
    }
    
    /// 是否处于试用状态 (进行中或已过期)
    public var isTrial: Bool {
        switch self {
        case .trial, .trialExpired:
            return true
        default:
            return false
        }
    }
    
    /// 获取当前生效的商业许可证 Claims (若为正式版)
    public var claims: LicenseClaims? {
        switch self {
        case .valid(let claims), .inGracePeriod(let claims, _):
            return claims
        case .expired(let claims):
            return claims
        default:
            return nil
        }
    }
    
    /// 获取当前生效的试用版 Claims (若为试用版)
    public var trialClaims: TrialClaims? {
        switch self {
        case .trial(let claims):
            return claims
        case .trialExpired(let claims):
            return claims
        default:
            return nil
        }
    }
    
    /// 获取统一的离线 Claims 抽象 (若存在)
    public var offlineClaims: OfflineClaims? {
        switch self {
        case .valid(let claims), .inGracePeriod(let claims, _):
            return .license(claims)
        case .expired(let claims):
            return claims.map { .license($0) }
        case .trial(let claims):
            return .trial(claims)
        case .trialExpired(let claims):
            return claims.map { .trial($0) }
        case .untrusted:
            return nil
        }
    }
    
    /// 获取当前许可证或试用的过期时间 (若可用)
    public var expirationDate: Date? {
        switch self {
        case .valid(let claims), .inGracePeriod(let claims, _):
            return claims.expirationDate
        case .expired(let claims):
            return claims?.expirationDate
        case .trial(let claims):
            return claims.expirationDate
        case .trialExpired(let claims):
            return claims?.expirationDate
        case .untrusted:
            return nil
        }
    }
    
    /// 当前生效或声明的所有功能特性列表
    public var features: [String] {
        switch self {
        case .valid(let claims), .inGracePeriod(let claims, _):
            return claims.features
        case .expired(let claims):
            return claims?.features ?? []
        case .trial(let claims):
            return claims.features
        case .trialExpired(let claims):
            return claims?.features ?? []
        case .untrusted:
            return []
        }
    }
    
    /// 快速检查是否拥有某项特定功能授权
    public func hasFeature(_ featureKey: String) -> Bool {
        return features.contains(featureKey)
    }
}
