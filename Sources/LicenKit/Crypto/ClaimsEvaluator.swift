import Foundation

/// 离线 Claims 约束判定器
public struct ClaimsEvaluator: Sendable {
    
    public init() {}
    
    /// 综合评估 Claims 在当前设备与系统约束下的生效状态
    /// - Parameters:
    ///   - claims: 已通过 Ed25519 签名验证的 LicenseClaims
    ///   - currentFingerprint: 当前设备采集到的硬件指纹
    ///   - lastValidatedAt: 上次联网在线探活成功的时间戳
    ///   - offlineGracePeriodSeconds: 允许的最大脱网宽限期 (秒)
    /// - Returns: 许可证状态枚举
    public func evaluate(
        claims: LicenseClaims,
        currentFingerprint: String,
        lastValidatedAt: Date? = nil,
        offlineGracePeriodSeconds: TimeInterval? = nil
    ) -> LicenseStatus {
        let now = Date()
        
        // 1. 硬件指纹一致性防伪检查
        let expectedFp = claims.fingerprint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let actualFp = currentFingerprint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        
        guard expectedFp == actualFp else {
            return .untrusted(reason: "Hardware fingerprint mismatch: token is bound to '\(claims.fingerprint)', but current host is '\(currentFingerprint)'")
        }
        
        // 2. 本地系统时钟漂移与回退检查 (Clock Skew & Rollback Defense)
        // 允许 1 小时 (3600 秒) 模糊容差，兼顾 NTP 同步漂移与休眠唤醒微调，严防恶意回拨系统时钟
        let clockSkewLeeway: TimeInterval = 3600
        
        if let lastValidated = lastValidatedAt, now < lastValidated.addingTimeInterval(-clockSkewLeeway) {
            return .untrusted(reason: "System clock rollback detected: current time is more than 1 hour earlier than last validated time")
        }
        
        if now < claims.issuedAt.addingTimeInterval(-clockSkewLeeway) {
            return .untrusted(reason: "System clock anomaly: current time is more than 1 hour earlier than token issue time")
        }
        
        // 3. 绝对到期时间判定
        if now > claims.expirationDate {
            return .expired(claims: claims)
        }
        
        // 4. 脱网宽限期判定 (若配置了脱网限制)
        if let lastValidated = lastValidatedAt, let gracePeriod = offlineGracePeriodSeconds, gracePeriod > 0 {
            let offlineDuration = now.timeIntervalSince(lastValidated)
            if offlineDuration > gracePeriod {
                // 离线时间已经超过宽限期上限，判定为已过期
                return .expired(claims: claims)
            } else if offlineDuration > (gracePeriod * 0.7) {
                // 距离宽限期耗尽不到 30%，标记为宽限期中，提示后台静默探活
                let remainingGrace = gracePeriod - offlineDuration
                return .inGracePeriod(claims: claims, remainingGraceSeconds: remainingGrace)
            }
        }
        
        // 5. 正常有效
        return .valid(claims: claims)
    }
}
