import Foundation

/// 硬件指纹提取器协议抽象，用于解耦各操作系统底层实现
public protocol DeviceFingerprintProvider: Sendable {
    /// 获取当前设备全局唯一的硬件指纹字符串
    func getFingerprint() async throws -> String
}

/// 当宿主运行于未受支持或未内置原生提取器的平台时的占位提供器
public struct UnsupportedPlatformFingerprintProvider: DeviceFingerprintProvider, Sendable {
    public init() {}
    public func getFingerprint() async throws -> String {
        throw LicenKitError.cryptoError("Native hardware fingerprint extraction is not supported on this platform. Please inject a custom DeviceFingerprintProvider.")
    }
}
