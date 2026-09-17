import Foundation

/// LicenKit SDK 运行配置
public struct LicenKitConfiguration: Sendable {
    /// LicenKit 服务端边缘地址 (如 https://license.yourdomain.com)
    public let serverUrl: String
    
    /// 账户 / 工作区 ID
    public let accountId: String
    
    /// 软件产品 ID
    public let productId: String
    
    /// 产品 Ed25519 签名公钥 (32字节 Base64 或 SPKI 格式)
    public let publicKey: String
    
    /// 网络超时时限 (秒)
    public let timeoutInterval: TimeInterval
    
    /// 跨进程共享 Keychain 的 Access Group (可选，如 "TEAMID.group.com.yourcompany.licenkit")
    public let accessGroup: String?
    
    public init(
        serverUrl: String,
        accountId: String,
        productId: String,
        publicKey: String,
        timeoutInterval: TimeInterval = 15.0,
        accessGroup: String? = nil
    ) {
        self.serverUrl = serverUrl
        self.accountId = accountId
        self.productId = productId
        self.publicKey = publicKey
        self.timeoutInterval = timeoutInterval
        self.accessGroup = accessGroup
    }
}
