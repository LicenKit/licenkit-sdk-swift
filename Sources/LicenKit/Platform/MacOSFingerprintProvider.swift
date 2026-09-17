import Foundation
import CryptoKit

#if os(macOS)
import IOKit

/// macOS 平台原生硬件指纹提取器
public struct MacOSFingerprintProvider: DeviceFingerprintProvider, Sendable {
    
    public init() {}
    
    public func getFingerprint() async throws -> String {
        if let uuid = queryIOPlatformUUID(), !uuid.isEmpty {
            return uuid.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        return computeFallbackFingerprint()
    }
    
    /// 从 IOKit IOPlatformExpertDevice 获取内核级硬件 UUID
    private func queryIOPlatformUUID() -> String? {
        let matchingDict = IOServiceMatching("IOPlatformExpertDevice")
        let platformExpert = IOServiceGetMatchingService(kIOMainPortDefault, matchingDict)
        guard platformExpert != 0 else { return nil }
        defer { IOObjectRelease(platformExpert) }
        
        guard let property = IORegistryEntryCreateCFProperty(
            platformExpert,
            kIOPlatformUUIDKey as CFString,
            kCFAllocatorDefault,
            0
        ) else { return nil }
        
        return property.takeRetainedValue() as? String
    }
    
    /// 降级策略：使用主机名与 MAC 地址列表计算稳定的 SHA-256 指纹
    private func computeFallbackFingerprint() -> String {
        let hostname = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let macAddresses = getNetworkMACAddresses().sorted().joined(separator: ",")
        let rawSeed = "\(hostname):macOS:\(macAddresses)"
        
        let digest = SHA256.hash(data: Data(rawSeed.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
    
    /// 枚举物理网络接口的 MAC 地址
    private func getNetworkMACAddresses() -> [String] {
        var addresses: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return addresses
        }
        defer { freeifaddrs(ifaddr) }
        
        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            
            // AF_LINK (Link layer interface, contains MAC)
            if addrFamily == UInt8(AF_LINK) {
                let name = String(cString: interface.ifa_name)
                // 仅收集以太网与无线网卡 (en0, en1, ...)
                if name.hasPrefix("en") {
                    interface.ifa_addr.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { dlPtr in
                        let sdlData = dlPtr.pointee.sdl_data
                        let nlen = Int(dlPtr.pointee.sdl_nlen)
                        let alen = Int(dlPtr.pointee.sdl_alen)
                        
                        if alen == 6 { // 标准 6 字节 MAC 地址
                            withUnsafeBytes(of: sdlData) { rawPtr in
                                let buffer = rawPtr.bindMemory(to: UInt8.self)
                                let macBytes = (0..<6).map { buffer[nlen + $0] }
                                let macStr = macBytes.map { String(format: "%02x", $0) }.joined(separator: ":")
                                if macStr != "00:00:00:00:00:00" {
                                    addresses.push(macStr)
                                }
                            }
                        }
                    }
                }
            }
        }
        
        return addresses
    }
}

private extension Array {
    mutating func push(_ element: Element) {
        append(element)
    }
}

#endif
