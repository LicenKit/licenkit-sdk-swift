import Foundation

public final class LicenKit: @unchecked Sendable {
    private static let lock = NSLock()
    private static var instance: LicenKit?

    public static func configure(with configuration: LicenKitConfiguration) {
        lock.lock()
        defer { lock.unlock() }
        instance = LicenKit(configuration: configuration)
    }

    public static var shared: LicenKit {
        lock.lock()
        defer { lock.unlock() }
        guard let instance else { fatalError("Call LicenKit.configure(with:) before using LicenKit.shared") }
        return instance
    }

    public let configuration: LicenKitConfiguration
    private let credentialStore: CredentialStore
    private let fingerprintProvider: DeviceFingerprintProvider
    private let verifier = Ed25519Verifier()
    private let claimsEvaluator = ClaimsEvaluator()
    private let apiClient: LicenKitAPIClient
    private let stateLock = NSLock()
    private var storedCachedStatus: LicenseStatus?

    public var cachedStatus: LicenseStatus? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return storedCachedStatus
    }

    public init(
        configuration: LicenKitConfiguration,
        credentialStore: CredentialStore? = nil,
        fingerprintProvider: DeviceFingerprintProvider? = nil,
        apiClient: LicenKitAPIClient? = nil
    ) {
        self.configuration = configuration
        self.credentialStore = credentialStore ?? KeychainStore(
            productID: configuration.productID,
            accessGroup: configuration.accessGroup
        )
        #if os(macOS)
        self.fingerprintProvider = fingerprintProvider ?? MacOSFingerprintProvider()
        #else
        self.fingerprintProvider = fingerprintProvider ?? UnsupportedPlatformFingerprintProvider()
        #endif
        self.apiClient = apiClient ?? LicenKitAPIClient(
            serverURL: configuration.serverURL,
            timeoutInterval: configuration.timeoutInterval
        )
    }

    @discardableResult
    public func activate(licenseKey: String, machineName: String? = nil) async throws -> ActivationResult {
        let fingerprint = try await fingerprintProvider.getFingerprint()
        let response = try await apiClient.activate(request: APIActivateRequest(
            accountID: configuration.accountID,
            productID: configuration.productID,
            licenseKey: licenseKey,
            fingerprint: fingerprint,
            devicePlatform: Self.devicePlatform,
            name: machineName ?? ProcessInfo.processInfo.hostName,
            releaseVersion: configuration.releaseVersion,
            releasePlatform: configuration.releasePlatform
        ))
        let localStatus = try verifyCredentialResponse(response, fingerprint: fingerprint)
        guard localStatus.isUsable else {
            if case .updateEntitlementRequired = localStatus {
                throw LicenKitError.releaseNotQualified(status: localStatus)
            }
            throw LicenKitError.invalidSignedLicenseToken(reason: "signed credential is not locally valid: \(localStatus)")
        }
        let credentials = storedCredentials(from: response)
        try credentialStore.saveCredentials(credentials, for: fingerprint)
        try credentialStore.clearTrialCredentials(for: fingerprint)
        let status = LicenseStatus.validOnline(terms: response.terms)
        setCachedStatus(status)
        return ActivationResult(
            activationID: response.activationID,
            credentialMode: response.credentialMode,
            status: status
        )
    }

    @discardableResult
    public func validate() async throws -> LicenseStatus {
        let fingerprint = try await fingerprintProvider.getFingerprint()
        guard let current = try credentialStore.loadCredentials(for: fingerprint) else {
            setCachedStatus(.unactivated)
            throw LicenKitError.unactivated
        }
        do {
            let response = try await apiClient.validate(request: APIValidateRequest(
                accountID: configuration.accountID,
                productID: configuration.productID,
                activationID: current.activationID,
                machineToken: current.machineToken,
                fingerprint: fingerprint,
                devicePlatform: Self.devicePlatform,
                releaseVersion: configuration.releaseVersion,
                releasePlatform: configuration.releasePlatform
            ))
            guard response.activationID == current.activationID else {
                throw LicenKitError.protocolError(reason: "validation response changed activation_id")
            }
            let localStatus = try verifyCredentialResponse(response, fingerprint: fingerprint)
            guard localStatus.isUsable else {
                if case .updateEntitlementRequired = localStatus {
                    throw LicenKitError.releaseNotQualified(status: localStatus)
                }
                throw LicenKitError.invalidSignedLicenseToken(reason: "refreshed credential is not locally valid: \(localStatus)")
            }
            try credentialStore.saveCredentials(storedCredentials(from: response), for: fingerprint)
            let status = LicenseStatus.validOnline(terms: response.terms)
            setCachedStatus(status)
            return status
        } catch let error as LicenKitError {
            updateCachedStatus(for: error, currentCredentials: current)
            throw error
        }
    }

    @discardableResult
    public func checkLocalStatus() async throws -> LicenseStatus {
        let fingerprint = try await fingerprintProvider.getFingerprint()
        if let credentials = try credentialStore.loadCredentials(for: fingerprint) {
            switch credentials.credentialMode {
            case .opaque:
                let status = LicenseStatus.temporarilyUnverified(
                    lastValidatedAt: credentials.lastValidatedAt,
                    cachedTerms: credentials.cachedTerms
                )
                setCachedStatus(status)
                return status
            case .signed:
                guard let token = credentials.signedLicenseToken else {
                    let status = LicenseStatus.untrusted(reason: "stored signed credential has no Signed License Token")
                    setCachedStatus(status)
                    return status
                }
                let (_, claims) = try verifier.verifyAndDecodeToken(
                    token: token,
                    trustedSigningKeys: configuration.trustedSigningKeys
                )
                let status = claimsEvaluator.evaluate(
                    claims: claims,
                    configuration: configuration,
                    activationID: credentials.activationID,
                    currentFingerprint: fingerprint
                )
                setCachedStatus(status)
                return status
            }
        }
        if try credentialStore.loadTrialCredentials(for: fingerprint) != nil {
            setCachedStatus(.onlineValidationRequired)
            return .onlineValidationRequired
        }
        setCachedStatus(.unactivated)
        return .unactivated
    }

    @discardableResult
    public func startTrial() async throws -> LicenseStatus {
        let fingerprint = try await fingerprintProvider.getFingerprint()
        let response = try await apiClient.claimTrial(request: APITrialClaimRequest(
            accountID: configuration.accountID,
            productID: configuration.productID,
            fingerprint: fingerprint,
            devicePlatform: Self.devicePlatform,
            releaseVersion: configuration.releaseVersion,
            releasePlatform: configuration.releasePlatform
        ))
        guard response.status == "active",
              let token = response.trialToken, !token.isEmpty,
              let expiresAt = response.expiresAt.date else {
            throw LicenKitError.protocolError(reason: "trial claim response did not contain a one-time active trial token")
        }
        try credentialStore.saveTrialCredentials(
            StoredTrialCredentials(
                trialID: response.trialID,
                trialToken: token,
                expiresAt: expiresAt,
                features: response.features,
                lastValidatedAt: Date()
            ),
            for: fingerprint
        )
        let status = LicenseStatus.trialValidOnline(expiresAt: expiresAt, features: response.features)
        setCachedStatus(status)
        return status
    }

    @discardableResult
    public func validateTrial() async throws -> LicenseStatus {
        let fingerprint = try await fingerprintProvider.getFingerprint()
        guard let current = try credentialStore.loadTrialCredentials(for: fingerprint) else {
            throw LicenKitError.trialNotStarted
        }
        do {
            let response = try await apiClient.validateTrial(request: APITrialValidateRequest(
                accountID: configuration.accountID,
                productID: configuration.productID,
                trialID: current.trialID,
                trialToken: current.trialToken,
                fingerprint: fingerprint,
                releaseVersion: configuration.releaseVersion,
                releasePlatform: configuration.releasePlatform
            ))
            guard response.trialID == current.trialID,
                  response.status == "active",
                  let expiresAt = response.expiresAt.date else {
                throw LicenKitError.protocolError(reason: "trial validation response is inconsistent with stored credentials")
            }
            try credentialStore.saveTrialCredentials(
                StoredTrialCredentials(
                    trialID: current.trialID,
                    trialToken: current.trialToken,
                    expiresAt: expiresAt,
                    features: response.features,
                    lastValidatedAt: Date()
                ),
                for: fingerprint
            )
            let status = LicenseStatus.trialValidOnline(expiresAt: expiresAt, features: response.features)
            setCachedStatus(status)
            return status
        } catch let error as LicenKitError {
            updateCachedTrialStatus(for: error, credentials: current)
            throw error
        }
    }

    public func deactivate() async throws -> DeactivationResult {
        let fingerprint = try await fingerprintProvider.getFingerprint()
        guard let credentials = try credentialStore.loadCredentials(for: fingerprint) else {
            setCachedStatus(.unactivated)
            return .completed
        }
        do {
            let response = try await apiClient.deactivate(request: APIDeactivateRequest(
                accountID: configuration.accountID,
                productID: configuration.productID,
                activationID: credentials.activationID,
                machineToken: credentials.machineToken,
                fingerprint: fingerprint
            ))
            guard response.status == "deactivated", response.activationID == credentials.activationID else {
                return .remoteFailed(
                    localCredentialsPreserved: true,
                    underlying: .protocolError(reason: "server did not confirm remote deactivation")
                )
            }
        } catch let error as LicenKitError {
            return .remoteFailed(localCredentialsPreserved: true, underlying: error)
        } catch {
            return .remoteFailed(
                localCredentialsPreserved: true,
                underlying: .protocolError(reason: error.localizedDescription)
            )
        }
        try credentialStore.clearCredentials(for: fingerprint)
        setCachedStatus(.unactivated)
        return .completed
    }

    public func clearLocalTrial() async throws {
        let fingerprint = try await fingerprintProvider.getFingerprint()
        try credentialStore.clearTrialCredentials(for: fingerprint)
        setCachedStatus(.unactivated)
    }

    public func hasFeature(_ feature: String) -> Bool { cachedStatus?.hasFeature(feature) ?? false }
    public func getMachineFingerprint() async throws -> String { try await fingerprintProvider.getFingerprint() }

    private func verifyCredentialResponse(_ response: APICredentialResponse, fingerprint: String) throws -> LicenseStatus {
        guard !response.activationID.isEmpty, !response.machineToken.isEmpty else {
            throw LicenKitError.protocolError(reason: "credential response is missing activation_id or machine_token")
        }
        switch response.credentialMode {
        case .opaque:
            guard response.signedLicenseToken == nil else {
                throw LicenKitError.protocolError(reason: "opaque response unexpectedly contained a Signed License Token")
            }
            return .validOnline(terms: response.terms)
        case .signed:
            guard let token = response.signedLicenseToken, let responseKeyID = response.signingKeyID else {
                throw LicenKitError.protocolError(reason: "signed response is missing signed_license_token or signing_key_id")
            }
            let (header, claims) = try verifier.verifyAndDecodeToken(
                token: token,
                trustedSigningKeys: configuration.trustedSigningKeys
            )
            guard header.kid == responseKeyID else {
                throw LicenKitError.invalidSignedLicenseToken(reason: "response signing_key_id does not match protected kid")
            }
            return claimsEvaluator.evaluate(
                claims: claims,
                configuration: configuration,
                activationID: response.activationID,
                currentFingerprint: fingerprint
            )
        }
    }

    private func storedCredentials(from response: APICredentialResponse) -> StoredCredentials {
        StoredCredentials(
            activationID: response.activationID,
            machineToken: response.machineToken,
            credentialMode: response.credentialMode,
            signedLicenseToken: response.signedLicenseToken,
            signingKeyID: response.signingKeyID,
            lastValidatedAt: Date(),
            cachedTerms: response.terms
        )
    }

    private func updateCachedStatus(for error: LicenKitError, currentCredentials: StoredCredentials) {
        guard case .apiError(let code, _, _, let details) = error else { return }
        let status: LicenseStatus?
        switch code {
        case "PRODUCT_RELEASE_UNKNOWN":
            status = .productReleaseUnknown(version: configuration.releaseVersion, platform: configuration.releasePlatform)
        case "LICENSE_SUSPENDED": status = .suspended(reason: details["status_reason"] ?? details["reason"])
        case "LICENSE_REVOKED": status = .revoked(reason: details["status_reason"] ?? details["reason"])
        case "ACTIVATION_REVOKED": status = .activationRevoked
        case "LICENSE_EXPIRED": status = .expired(expiresAt: parseDate(details["expires_at"]))
        case "UPDATE_ENTITLEMENT_REQUIRED":
            if let updatesUntil = parseDate(details["updates_until"]),
               let releasedAt = parseDate(details["released_at"]) {
                status = .updateEntitlementRequired(
                    updatesUntil: updatesUntil,
                    releaseVersion: details["release_version"] ?? configuration.releaseVersion,
                    releasedAt: releasedAt
                )
            } else { status = nil }
        default: status = nil
        }
        if let status { setCachedStatus(status) }
        else if code.hasPrefix("LICENSE_") { setCachedStatus(.untrusted(reason: code)) }
        else { _ = currentCredentials }
    }

    private func updateCachedTrialStatus(for error: LicenKitError, credentials: StoredTrialCredentials) {
        guard case .apiError(let code, _, _, let details) = error else { return }
        switch code {
        case "TRIAL_EXPIRED": setCachedStatus(.trialExpired(expiresAt: parseDate(details["expires_at"]) ?? credentials.expiresAt))
        case "TRIAL_REVOKED": setCachedStatus(.trialRevoked(reason: details["revoke_reason"] ?? details["reason"]))
        case "PRODUCT_RELEASE_UNKNOWN":
            setCachedStatus(.productReleaseUnknown(version: configuration.releaseVersion, platform: configuration.releasePlatform))
        default: break
        }
    }

    private func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        if let seconds = TimeInterval(value) { return Date(timeIntervalSince1970: seconds) }
        return FlexibleDate.parseISO8601(value)
    }

    private func setCachedStatus(_ status: LicenseStatus) {
        stateLock.lock()
        storedCachedStatus = status
        stateLock.unlock()
    }

    private static var devicePlatform: String {
        #if os(macOS)
        let osName = "macos"
        #elseif os(iOS)
        let osName = "ios"
        #else
        let osName = "apple"
        #endif
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unknown"
        #endif
        return "\(osName)-\(architecture)"
    }
}
