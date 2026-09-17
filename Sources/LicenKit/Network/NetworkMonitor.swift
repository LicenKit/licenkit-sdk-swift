import Foundation
import Network

/// 网络物理连通性监测协议
public protocol NetworkMonitorProtocol: Sendable {
    /// 当前设备是否具备可用网络连接 (Wi-Fi, 有线或蜂窝网络)
    var isOnline: Bool { get }
    
    /// 启动网络状态监听
    /// - Parameter onStatusChange: 当网络状态发生变化（如断网或连网）时的回调闭包
    func start(onStatusChange: (@Sendable (Bool) -> Void)?)
    
    /// 停止网络监听
    func stop()
}

/// 基于 Apple 原生 Network.framework (NWPathMonitor) 的生产级网络监测实现
public final class SystemNetworkMonitor: NetworkMonitorProtocol, @unchecked Sendable {
    private var monitor: NWPathMonitor?
    private let queue = DispatchQueue(label: "com.licenkit.networkmonitor", qos: .utility)
    private let lock = NSLock()
    
    private var _isOnline: Bool = true
    private var statusChangeCallback: (@Sendable (Bool) -> Void)?
    private var isStarted = false
    
    public init() {}
    
    deinit {
        stop()
    }
    
    public var isOnline: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isOnline
    }
    
    public func start(onStatusChange: (@Sendable (Bool) -> Void)? = nil) {
        lock.lock()
        defer { lock.unlock() }
        
        guard !isStarted else { return }
        self.isStarted = true
        self.statusChangeCallback = onStatusChange
        
        let newMonitor = NWPathMonitor()
        newMonitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            let currentlyOnline = (path.status == .satisfied)
            
            self.lock.lock()
            let previousOnline = self._isOnline
            self._isOnline = currentlyOnline
            let callback = self.statusChangeCallback
            self.lock.unlock()
            
            if previousOnline != currentlyOnline {
                callback?(currentlyOnline)
            }
        }
        
        self.monitor = newMonitor
        newMonitor.start(queue: queue)
    }
    
    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        
        guard isStarted else { return }
        monitor?.cancel()
        monitor = nil
        isStarted = false
        statusChangeCallback = nil
    }
}

/// 用于单元测试的模拟网络监听器
public final class MockNetworkMonitor: NetworkMonitorProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _isOnline: Bool
    private var statusChangeCallback: (@Sendable (Bool) -> Void)?
    
    public init(initialOnline: Bool = true) {
        self._isOnline = initialOnline
    }
    
    public var isOnline: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isOnline
    }
    
    public func setOnline(_ online: Bool) {
        lock.lock()
        let previous = _isOnline
        _isOnline = online
        let callback = statusChangeCallback
        lock.unlock()
        
        if previous != online {
            callback?(online)
        }
    }
    
    public func start(onStatusChange: (@Sendable (Bool) -> Void)? = nil) {
        lock.lock()
        defer { lock.unlock() }
        self.statusChangeCallback = onStatusChange
    }
    
    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        statusChangeCallback = nil
    }
}
