import Foundation

public struct LicenKitConfiguration: Sendable {
    public let serverURL: URL
    public let accountID: String
    public let productID: String
    public let releaseVersion: String
    public let releasePlatform: String
    public let trustedSigningKeys: [String: String]
    public let timeoutInterval: TimeInterval
    public let accessGroup: String?

    public init(
        serverURL: URL,
        accountID: String,
        productID: String,
        releaseVersion: String,
        releasePlatform: String,
        trustedSigningKeys: [String: String] = [:],
        timeoutInterval: TimeInterval = 15,
        accessGroup: String? = nil
    ) {
        self.serverURL = serverURL
        self.accountID = accountID
        self.productID = productID
        self.releaseVersion = releaseVersion
        self.releasePlatform = releasePlatform
        self.trustedSigningKeys = trustedSigningKeys
        self.timeoutInterval = timeoutInterval
        self.accessGroup = accessGroup
    }
}
