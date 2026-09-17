import Foundation

/// 请求交互场景分类
public enum RequestScenario: Sendable {
    /// 前台阻塞型操作 (用户在界面前等待 Loading，如输入激活码激活)
    case foregroundActivation
    
    /// 后台静默型操作 (用户在主界面正常使用，如启动时探活、定时心跳)
    case backgroundSync
}

/// 重试延时配置（支持生产环境默认值与测试环境微秒级覆写）
public struct RetryDelays: Sendable {
    /// 前台常规瞬时故障重试间隔 (默认: 2s -> 4s -> 8s)
    public let foregroundStandard: [TimeInterval]
    
    /// 前台 429 限流重试间隔 (默认: 4s -> 8s -> 16s)
    public let foregroundRateLimited: [TimeInterval]
    
    /// 后台探活第 1 次失败后等待第 2 次的间隔 (默认: 60s)
    public let backgroundRetryDelay: TimeInterval
    
    /// 是否在重试间隔中注入微量随机抖动 (0 ~ 0.5s)
    public let enableJitter: Bool
    
    public init(
        foregroundStandard: [TimeInterval] = [2.0, 4.0, 8.0],
        foregroundRateLimited: [TimeInterval] = [4.0, 8.0, 16.0],
        backgroundRetryDelay: TimeInterval = 60.0,
        enableJitter: Bool = true
    ) {
        self.foregroundStandard = foregroundStandard
        self.foregroundRateLimited = foregroundRateLimited
        self.backgroundRetryDelay = backgroundRetryDelay
        self.enableJitter = enableJitter
    }
    
    /// 供单元测试极速运行的配置
    public static let fastForTesting = RetryDelays(
        foregroundStandard: [0.005, 0.01, 0.015],
        foregroundRateLimited: [0.01, 0.02, 0.03],
        backgroundRetryDelay: 0.01,
        enableJitter: false
    )
}

/// LicenKit 双轨容灾重试调度器
public final class LicenKitRetryCoordinator: @unchecked Sendable {
    
    public static let shared = LicenKitRetryCoordinator()
    
    private let networkMonitor: NetworkMonitorProtocol
    private let retryDelays: RetryDelays
    private let userDefaults: UserDefaults
    private let rateLimitKey: String
    
    private let lock = NSLock()
    private var _sessionHeartbeatBlocked: Bool = false
    
    public init(
        networkMonitor: NetworkMonitorProtocol? = nil,
        retryDelays: RetryDelays = RetryDelays(),
        userDefaults: UserDefaults = .standard,
        rateLimitKey: String = "LicenKit_RateLimitedUntil"
    ) {
        let monitor = networkMonitor ?? SystemNetworkMonitor()
        self.networkMonitor = monitor
        self.retryDelays = retryDelays
        self.userDefaults = userDefaults
        self.rateLimitKey = rateLimitKey
        
        // 启动网络监听；当网络从离线切为在线时，自动重置当前 Session 的探活熔断状态
        self.networkMonitor.start { [weak self] isOnline in
            if isOnline {
                self?.resetSessionBlock()
            }
        }
    }
    
    deinit {
        networkMonitor.stop()
    }
    
    // MARK: - Status Queries
    
    /// 当前底层物理网络是否通畅
    public var isOnline: Bool {
        return networkMonitor.isOnline
    }
    
    /// 当前进程生命周期内是否已探活失败并被熔断
    public var isSessionBlocked: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _sessionHeartbeatBlocked
    }
    
    /// 判定当天是否处于 HTTP 429 限流冷却期中
    public var isRateLimitedToday: Bool {
        if let until = userDefaults.object(forKey: rateLimitKey) as? Date {
            return Date() < until
        }
        return false
    }
    
    // MARK: - State Modifiers
    
    /// 标记当天进入 429 限流冷却期 (冷却至明天或 24 小时后)
    public func markRateLimitedForToday() {
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date().addingTimeInterval(86400)
        userDefaults.set(tomorrow, forKey: rateLimitKey)
    }
    
    /// 重置当天限流状态（主要用于测试或管理员强制重置）
    public func resetRateLimitForToday() {
        userDefaults.removeObject(forKey: rateLimitKey)
    }
    
    /// 重置当前 Session 的熔断状态 (当系统切网或宽限期进入紧迫阶段时唤醒)
    public func resetSessionBlock() {
        lock.lock()
        defer { lock.unlock() }
        _sessionHeartbeatBlocked = false
    }
    
    /// 强制设置当前 Session 熔断状态 (主要用于测试)
    public func setSessionBlocked(_ blocked: Bool) {
        lock.lock()
        defer { lock.unlock() }
        _sessionHeartbeatBlocked = blocked
    }
    
    // MARK: - Execution Engine
    
    /// 执行符合场景诉求的自适应双轨重试
    public func execute<T: Sendable>(
        scenario: RequestScenario,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        switch scenario {
        case .foregroundActivation:
            return try await executeForeground(operation)
        case .backgroundSync:
            return try await executeBackground(operation)
        }
    }
    
    // MARK: - Track A: Foreground Activation (2s -> 4s -> 8s)
    
    private func executeForeground<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        var attempt = 0
        
        while true {
            try Task.checkCancellation()
            
            do {
                return try await operation()
            } catch {
                let licenError = error as? LicenKitError
                let isRecoverable = licenError?.isRecoverable ?? false
                let is429 = licenError?.isRateLimited ?? false
                
                let delayList = is429 ? retryDelays.foregroundRateLimited : retryDelays.foregroundStandard
                let maxRetries = delayList.count
                
                // 若为不可恢复错误 (404, 409, 密码学篡改等) 或已达最大重试次数，立即抛出
                guard isRecoverable, attempt < maxRetries else {
                    throw error
                }
                
                var delay = delayList[attempt]
                if retryDelays.enableJitter {
                    delay += Double.random(in: 0...0.5)
                }
                
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }
    
    // MARK: - Track B: Background Sync (Wait 60s, Retry Once, Then Give Up This Session)
    
    private func executeBackground<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        // 1. 若当天被 429 限流，或本次 Session 已发生过探活失败熔断，直接中止走离线
        if isRateLimitedToday || isSessionBlocked {
            throw LicenKitError.networkError("Background sync skipped (session blocked or rate limited today)")
        }
        
        // 2. 第 1 次尝试
        do {
            return try await operation()
        } catch {
            // 若服务端返回 429，立即标记当天不再尝试
            if let licenError = error as? LicenKitError, licenError.isRateLimited {
                markRateLimitedForToday()
                throw error
            }
            
            // 若为不可恢复业务错误 (已明确注销、席位被踢等)，直接抛出
            let isRecoverable = (error as? LicenKitError)?.isRecoverable ?? false
            guard isRecoverable else {
                throw error
            }
            
            // 3. 第 1 次遇可恢复故障失败，静默等待重试间隔 (默认 60s)
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: UInt64(retryDelays.backgroundRetryDelay * 1_000_000_000))
            
            // 4. 第 2 次尝试
            do {
                return try await operation()
            } catch {
                if let licenError = error as? LicenKitError, licenError.isRateLimited {
                    markRateLimitedForToday()
                }
                // 第 2 次依然失败，标记本次 Session 彻底放弃不再尝试
                setSessionBlocked(true)
                throw error
            }
        }
    }
}
