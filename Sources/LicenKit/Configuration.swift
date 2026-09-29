import Foundation

public enum LicenKitEnvironment: String, Codable, Equatable, Sendable {
    case sandbox
    case live
}

public struct LicenKitConfiguration: Sendable {
    public let serverURL: URL
    public let productID: String
    public let signingPublicKey: String?
    public let environment: LicenKitEnvironment

    let releaseVersion: String
    let releasePlatform: String
    let releaseArch: String

    public init(
        serverURL: URL,
        productID: String,
        signingPublicKey: String? = nil,
        environment: LicenKitEnvironment = .live
    ) {
        self.serverURL = serverURL
        self.productID = productID
        self.signingPublicKey = signingPublicKey
        self.environment = environment
        self.releaseVersion = Self.bundleReleaseVersion(Bundle.main) ?? ""
        self.releasePlatform = "macos"
        self.releaseArch = Self.bundleReleaseArchitecture(Bundle.main) ?? ""
    }

    init(
        serverURL: URL,
        productID: String,
        signingPublicKey: String? = nil,
        releaseVersion: String,
        releasePlatform: String,
        releaseArch: String,
        environment: LicenKitEnvironment = .live
    ) {
        self.serverURL = serverURL
        self.productID = productID
        self.signingPublicKey = signingPublicKey
        self.environment = environment
        self.releaseVersion = releaseVersion
        self.releasePlatform = releasePlatform
        self.releaseArch = releaseArch
    }

    func requireBuildIdentity() throws -> (version: String, platform: String, arch: String) {
        guard !releaseVersion.isEmpty else {
            throw LicenKitError.configurationError(
                reason: "The host App Bundle is missing CFBundleShortVersionString"
            )
        }
        guard !releasePlatform.isEmpty else {
            throw LicenKitError.configurationError(
                reason: "The host App operating system could not be determined"
            )
        }
        guard !releaseArch.isEmpty else {
            throw LicenKitError.configurationError(
                reason: "The host App executable architecture could not be determined"
            )
        }
        return (releaseVersion, releasePlatform, releaseArch)
    }

    private static func bundleReleaseVersion(_ bundle: Bundle) -> String? {
        guard let value = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func bundleReleaseArchitecture(_ bundle: Bundle) -> String? {
        let architectures = Set((bundle.executableArchitectures ?? []).map(\.intValue))
        let hasArm64 = architectures.contains(NSBundleExecutableArchitectureARM64)
        let hasX86_64 = architectures.contains(NSBundleExecutableArchitectureX86_64)
        if hasArm64 && hasX86_64 { return "universal" }
        if hasArm64 { return "arm64" }
        if hasX86_64 { return "x86_64" }
        return nil
    }
}
