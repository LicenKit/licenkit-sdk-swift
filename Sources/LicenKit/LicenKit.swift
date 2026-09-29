import Foundation
import Security
import CryptoKit

public final class LicenKit: @unchecked Sendable {
    public static let minimumValidationRequestInterval: TimeInterval = 30
    private static let defaultValidationInterval: TimeInterval = 3_600
    private static let lock = NSLock()
    nonisolated(unsafe) private static var instance: LicenKit?

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
    private let operationCoordinator = OperationCoordinator()
    private let stateLock = NSLock()
    private let now: @Sendable () -> Date
    private var storedSnapshot: EntitlementSnapshot?

    public var currentSnapshot: EntitlementSnapshot? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return storedSnapshot
    }

    public convenience init(configuration: LicenKitConfiguration) {
        self.init(
            configuration: configuration,
            credentialStore: nil,
            fingerprintProvider: nil,
            apiClient: nil
        )
    }

    init(
        configuration: LicenKitConfiguration,
        credentialStore: CredentialStore? = nil,
        fingerprintProvider: DeviceFingerprintProvider? = nil,
        apiClient: LicenKitAPIClient? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.credentialStore = credentialStore ?? KeychainStore(productID: configuration.productID, environment: configuration.environment)
        #if os(macOS)
        self.fingerprintProvider = fingerprintProvider ?? MacOSFingerprintProvider()
        #else
        self.fingerprintProvider = fingerprintProvider ?? UnsupportedPlatformFingerprintProvider()
        #endif
        self.apiClient = apiClient ?? LicenKitAPIClient(serverURL: configuration.serverURL)
        self.now = now
    }

    @discardableResult
    public func activate(
        licenseKey: String,
        machineName: String? = nil
    ) async -> LicenKitResult<ActivationData> {
        await operationCoordinator.perform { [self] in
            await performActivation(licenseKey: licenseKey, machineName: machineName)
        }
    }

    @discardableResult
    public func startTrial() async -> LicenKitResult<EntitlementSnapshot> {
        await operationCoordinator.perform { [self] in await performStartTrial() }
    }

    @discardableResult
    @available(*, deprecated, message: "Specify .silent or .userInitiated with validate(trigger:).")
    public func validate() async -> LicenKitResult<EntitlementSnapshot> {
        await validate(trigger: .silent)
    }

    @discardableResult
    public func validate(trigger: ValidationTrigger) async -> LicenKitResult<EntitlementSnapshot> {
        await operationCoordinator.validate(trigger: trigger) { [self] in
            await performValidation(trigger: trigger)
        }
    }

    /// Restores local evidence without starting a network request. Call before validation at launch.
    public func restoreLocalEntitlement() async -> LocalEntitlementResult {
        await operationCoordinator.perform { [self] in await performLocalRestoration() }
    }

    @discardableResult
    public func deactivate() async -> DeactivationResult {
        await operationCoordinator.perform { [self] in await performDeactivation() }
    }

    public func hasFeature(_ feature: String) -> Bool {
        currentSnapshot?.hasFeature(feature, at: now()) ?? false
    }

    public func getMachineFingerprint() async throws -> String {
        try await fingerprintProvider.getFingerprint()
    }

    private func performLocalRestoration() async -> LocalEntitlementResult {
        clearCurrentSnapshot()
        do {
            _ = try configuration.requireBuildIdentity()
            let fingerprint = try await fingerprintProvider.getFingerprint()
            if let pending = try credentialStore.loadDeactivationAttempt(for: fingerprint),
               pending.phase == .confirmed {
                return .verificationRequired(reason: .deactivationPending(phase: pending.phase))
            }
            let license = try credentialStore.loadCredentials(for: fingerprint)
            if let license, (license.environment ?? .live) != configuration.environment {
                return .verificationRequired(reason: .invalidCredential(.protocolError(reason: "stored License environment does not match SDK configuration")))
            }
            let trial = try credentialStore.loadTrialCredentials(for: fingerprint)
            let subject: StoredCredentialSubject = license != nil ? .license : (trial != nil ? .trial : .none)
            guard let stored = try credentialStore.loadSnapshot(for: fingerprint) else {
                return .verificationRequired(reason: subject == .none ? .noCredential : .noMatchingSnapshot)
            }
            guard stored.subject == subject else {
                return .verificationRequired(reason: subject == .none ? .noCredential : .noMatchingSnapshot)
            }
            guard matchesLocalCredentials(stored, subject: subject, fingerprint: fingerprint, license: license, trial: trial) else {
                return .verificationRequired(reason: subject == .none ? .noCredential : .noMatchingSnapshot)
            }
            do {
                if subject == .none {
                    switch stored.snapshot.state {
                    case .activationRequired, .license(.activationDeactivated):
                        break
                    default:
                        throw LicenKitError.protocolError(reason: "local snapshot state does not match absent credentials")
                    }
                } else {
                    try require(stored.snapshot.state, isValidFor: subject)
                }
                let snapshot: EntitlementSnapshot
                if let license, license.credentialMode == .signed {
                    try validateSignedStateConsistency(
                        credentials: license,
                        fingerprint: fingerprint,
                        snapshot: stored.snapshot
                    )
                    snapshot = stored.snapshot.withSignedCredentialValidity(true, source: .signedLocal)
                } else {
                    snapshot = stored.snapshot.source == .local
                        ? stored.snapshot : stored.snapshot.withSource(.cache)
                }
                setCurrentSnapshot(snapshot)
                if snapshot.isUsable(at: now()) { return .usable(snapshot: snapshot) }
                switch snapshot.state {
                case .trial(.active), .license(.active):
                    return .verificationRequired(reason: .expired)
                default:
                    return .confirmedBlocked(snapshot: snapshot)
                }
            } catch {
                let error = normalize(error, operation: "restore local entitlement")
                switch error {
                case .invalidSignedLicenseToken, .missingSigningPublicKey, .configurationError:
                    return .verificationRequired(reason: .invalidCredential(error))
                default:
                    return .verificationRequired(reason: .invalidSnapshot(error))
                }
            }
        } catch {
            let error = normalize(error, operation: "restore local entitlement")
            switch error {
            case .credentialStorageError:
                return .verificationRequired(reason: .storageFailure(error))
            default:
                return .verificationRequired(reason: .invalidCredential(error))
            }
        }
    }

    static func credentialBinding(
        productID: String,
        fingerprint: String,
        license: StoredCredentials?,
        trial: StoredTrialCredentials?
    ) -> String? {
        let fields: [String]
        if let license {
            fields = [productID, fingerprint, "license", license.activationID, license.machineToken]
        } else if let trial {
            fields = [productID, fingerprint, "trial", trial.trialID, trial.trialToken]
        } else {
            return nil
        }
        let data = Data(fields.map { "\($0.utf8.count):\($0)" }.joined().utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func matchesLocalCredentials(
        _ stored: StoredEntitlementSnapshot,
        subject: StoredCredentialSubject,
        fingerprint: String,
        license: StoredCredentials?,
        trial: StoredTrialCredentials?
    ) -> Bool {
        guard stored.subject == subject else { return false }
        if let license, (license.environment ?? .live) != configuration.environment { return false }
        if subject == .none { return isConfirmedNoCredentialBlock(stored) }
        guard stored.snapshot.source == .server else { return false }
        guard let binding = Self.credentialBinding(
            productID: configuration.productID,
            fingerprint: fingerprint,
            license: license,
            trial: trial
        ) else { return false }
        return stored.credentialBinding == binding
    }

    private func isConfirmedNoCredentialBlock(_ stored: StoredEntitlementSnapshot) -> Bool {
        guard stored.subject == .none, stored.credentialBinding == nil else { return false }
        switch stored.snapshot.state {
        case .activationRequired:
            return stored.snapshot.source == .server
                || (stored.snapshot.source == .local && stored.confirmedRemoteDeactivation == true)
        case .license(.activationDeactivated):
            return stored.snapshot.source == .server
        default:
            return false
        }
    }

    private func isLocalNoCredentialReceipt(
        _ stored: StoredEntitlementSnapshot,
        subject: StoredCredentialSubject
    ) -> Bool {
        guard subject == .none, stored.subject == .none,
              stored.snapshot.source == .local, stored.credentialBinding == nil else { return false }
        if case .unknown = stored.snapshot.state { return true }
        return false
    }

    private func requireNoPendingDeactivation(
        for fingerprint: String,
        allowUnconfirmedRequest: Bool = false
    ) throws {
        if let attempt = try credentialStore.loadDeactivationAttempt(for: fingerprint) {
            if allowUnconfirmedRequest && attempt.phase == .requested { return }
            throw LicenKitError.deactivationRecoveryRequired(phase: attempt.phase)
        }
    }

    private func performActivation(
        licenseKey: String,
        machineName: String?
    ) async -> LicenKitResult<ActivationData> {
        var requestStarted = false
        var responseRequestID: String?
        do {
            let normalizedLicenseKey = licenseKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedLicenseKey.isEmpty else {
                throw LicenKitError.protocolError(reason: "license key must not be empty")
            }
            let build = try configuration.requireBuildIdentity()
            let fingerprint = try await fingerprintProvider.getFingerprint()
            try requireNoPendingDeactivation(for: fingerprint)
            let requestedMachineName = machineName ?? ProcessInfo.processInfo.hostName
            let verification: StoredActivationVerification
            if let existing = try credentialStore.loadActivationVerification(for: fingerprint) {
                verification = existing
            } else {
                let storedCredentials = try credentialStore.loadCredentials(for: fingerprint)
                verification = StoredActivationVerification(
                    machineToken: try (
                        storedCredentials?.machineToken
                            ?? Self.generateVerificationToken(prefix: "mtk")
                    )
                )
                try credentialStore.saveActivationVerification(verification, for: fingerprint)
            }
            requestStarted = true
            let response = try await apiClient.activate(request: APIActivateRequest(
                productID: configuration.productID,
                licenseKey: normalizedLicenseKey,
                machineToken: verification.machineToken,
                fingerprint: fingerprint,
                devicePlatform: Self.devicePlatform,
                name: requestedMachineName,
                releaseVersion: build.version,
                releasePlatform: build.platform,
                releaseArch: build.arch,
                billingEnvironment: configuration.environment
            ))
            responseRequestID = response.meta.requestID
            guard response.machineToken == verification.machineToken else {
                throw LicenKitError.protocolError(
                    reason: "activation response returned a different machine_token"
                )
            }

            let credentials = try credentials(
                from: response,
                fingerprint: fingerprint
            )
            let snapshot = try makeSnapshot(
                state: response.state,
                validation: response.validation,
                signedCredentialValid: credentials.credentialMode == .signed ? true : nil
            )
            try require(snapshot.state, isValidFor: .license)
            try validateSignedStateConsistency(
                credentials: credentials,
                fingerprint: fingerprint,
                snapshot: snapshot
            )
            try validateActivationDuplicates(response, snapshot: snapshot)

            try credentialStore.saveCredentials(credentials, for: fingerprint)
            try credentialStore.clearTrialCredentials(for: fingerprint)
            try persist(snapshot: snapshot, subject: .license, fingerprint: fingerprint, validatedBuild: .init(version: build.version, platform: build.platform, arch: build.arch))
            try credentialStore.clearActivationVerification(for: fingerprint)
            return .success(
                value: ActivationData(
                    activationID: response.activationID,
                    credentialMode: response.credentialMode,
                    snapshot: snapshot
                ),
                metadata: operationMetadata(snapshot: snapshot, requestID: response.meta.requestID)
            )
        } catch {
            let licenKitError = normalize(error, operation: "activate")
            return .failure(
                error: licenKitError,
                lastKnownValue: nil,
                metadata: failureMetadata(
                    error: licenKitError,
                    requestStarted: requestStarted,
                    responseRequestID: responseRequestID
                )
            )
        }
    }

    private func performStartTrial() async -> LicenKitResult<EntitlementSnapshot> {
        var lastKnown = currentSnapshot
        var requestStarted = false
        var responseRequestID: String?
        do {
            let build = try configuration.requireBuildIdentity()
            let fingerprint = try await fingerprintProvider.getFingerprint()
            try requireNoPendingDeactivation(for: fingerprint)
            if let stored = try credentialStore.loadSnapshot(for: fingerprint) {
                lastKnown = stored.snapshot
            }
            let verification: StoredTrialVerification
            if let existing = try credentialStore.loadTrialVerification(for: fingerprint) {
                verification = existing
            } else {
                let trialToken = try (
                    credentialStore.loadTrialCredentials(for: fingerprint)?.trialToken
                        ?? Self.generateVerificationToken(prefix: "ttk")
                )
                verification = StoredTrialVerification(trialToken: trialToken)
                try credentialStore.saveTrialVerification(verification, for: fingerprint)
            }
            requestStarted = true
            let response = try await apiClient.claimTrial(request: APITrialClaimRequest(
                productID: configuration.productID,
                fingerprint: fingerprint,
                trialToken: verification.trialToken,
                devicePlatform: Self.devicePlatform,
                releaseVersion: build.version,
                releasePlatform: build.platform,
                releaseArch: build.arch
            ))
            responseRequestID = response.meta.requestID
            guard response.trialToken == verification.trialToken,
                  !response.trialToken.isEmpty else {
                throw LicenKitError.protocolError(
                    reason: "trial claim response returned a different trial_token"
                )
            }
            let snapshot = try makeSnapshot(
                state: response.state,
                validation: response.validation
            )
            try validateTrialClaimDuplicates(response, snapshot: snapshot)

            try credentialStore.saveTrialCredentials(
                StoredTrialCredentials(trialID: response.trialID, trialToken: response.trialToken),
                for: fingerprint
            )
            try persist(snapshot: snapshot, subject: .trial, fingerprint: fingerprint, validatedBuild: .init(version: build.version, platform: build.platform, arch: build.arch))
            try credentialStore.clearTrialVerification(for: fingerprint)
            return .success(
                value: snapshot,
                metadata: operationMetadata(snapshot: snapshot, requestID: response.meta.requestID)
            )
        } catch {
            let licenKitError = normalize(error, operation: "start trial")
            return .failure(
                error: licenKitError,
                lastKnownValue: lastKnown,
                metadata: failureMetadata(
                    error: licenKitError,
                    requestStarted: requestStarted,
                    responseRequestID: responseRequestID
                )
            )
        }
    }

    private func performValidation(trigger: ValidationTrigger) async -> LicenKitResult<EntitlementSnapshot> {
        var lastKnown = currentSnapshot
        var requestStarted = false
        var responseRequestID: String?
        var validationFingerprint: String?
        var validationSubject: StoredCredentialSubject?
        var validationStoredSnapshot: StoredEntitlementSnapshot?
        var signedCredentialValid: Bool?
        var confirmedResponseSnapshot: EntitlementSnapshot?
        var confirmedResponseSubject: StoredCredentialSubject?
        do {
            let build = try configuration.requireBuildIdentity()
            let buildIdentity = ValidationBuildIdentity(version: build.version, platform: build.platform, arch: build.arch)
            let fingerprint = try await fingerprintProvider.getFingerprint()
            validationFingerprint = fingerprint
            try requireNoPendingDeactivation(for: fingerprint, allowUnconfirmedRequest: true)
            let license = try credentialStore.loadCredentials(for: fingerprint)
            if let license, (license.environment ?? .live) != configuration.environment {
                throw LicenKitError.protocolError(reason: "stored License environment does not match SDK configuration")
            }
            let trial = try credentialStore.loadTrialCredentials(for: fingerprint)
            let subject: StoredCredentialSubject
            let credential: APIValidationCredential
            if let license {
                subject = .license
                credential = .license(
                    activationID: license.activationID,
                    machineToken: license.machineToken
                )
            } else if let trial {
                subject = .trial
                credential = .trial(trialID: trial.trialID, trialToken: trial.trialToken)
            } else {
                subject = .none
                credential = .none
            }
            validationSubject = subject

            let stored = try credentialStore.loadSnapshot(for: fingerprint)
            let attempt = try credentialStore.loadValidationAttempt(for: fingerprint)
            let matchingStored = stored.flatMap {
                (matchesLocalCredentials($0, subject: subject, fingerprint: fingerprint, license: license, trial: trial)
                    || isLocalNoCredentialReceipt($0, subject: subject))
                    ? $0 : nil
            }
            validationStoredSnapshot = matchingStored
            if let matchingStored {
                lastKnown = matchingStored.snapshot
            } else {
                clearCurrentSnapshot()
                lastKnown = nil
            }
            let decision = validationCooldownDecision(
                snapshot: matchingStored?.snapshot,
                validatedBuild: matchingStored?.validatedBuild,
                lastAttempt: attempt,
                licenseCredentials: license,
                fingerprint: fingerprint,
                build: buildIdentity,
                trigger: trigger
            )
            signedCredentialValid = decision.signedCredentialValid
            if let cached = decision.cachedSnapshot {
                lastKnown = cached
                setCurrentSnapshot(cached)
            }
            if let localError = decision.localError { throw localError }
            if let reason = decision.notPerformedReason {
                return .notPerformed(
                    reason: reason,
                    cachedValue: decision.cachedSnapshot,
                    metadata: decision.cachedSnapshot.map { operationMetadata(snapshot: $0, requestID: nil) }
                        ?? OperationMetadata(source: .local)
                )
            }

            try credentialStore.saveValidationAttempt(
                StoredValidationAttempt(startedAt: now(), build: buildIdentity),
                for: fingerprint
            )
            requestStarted = true
            let response = try await apiClient.validate(request: APIValidateRequest(
                productID: configuration.productID,
                fingerprint: fingerprint,
                releaseVersion: build.version,
                releasePlatform: build.platform,
                releaseArch: build.arch,
                billingEnvironment: configuration.environment,
                credential: credential
            ))
            let responseReceivedAt = now()
            responseRequestID = response.meta.requestID

            if subject != .license, response.credentialUpdate != nil {
                throw LicenKitError.protocolError(
                    reason: "credential_update is only valid for License validation"
                )
            }

            var snapshot = try makeSnapshot(
                state: response.state,
                validation: response.validation,
                lastValidateResponseAt: responseReceivedAt,
                signedCredentialValid: signedCredentialValid
            )
            try require(snapshot.state, isValidFor: subject)

            if case .license(.active) = snapshot.state {
                guard (response.billingEnvironment ?? .live) == configuration.environment else {
                    throw LicenKitError.protocolError(reason: "License validation environment does not match SDK configuration")
                }
                guard let license, let update = response.credentialUpdate else {
                    throw LicenKitError.protocolError(
                        reason: "active License validation is missing credential_update"
                    )
                }
                let updatedLicense = try applying(update, to: license)
                snapshot = try makeSnapshot(
                    state: response.state,
                    validation: response.validation,
                    lastValidateResponseAt: responseReceivedAt,
                    signedCredentialValid: updatedLicense.credentialMode == .signed ? true : nil
                )
                try validateSignedStateConsistency(
                    credentials: updatedLicense,
                    fingerprint: fingerprint,
                    snapshot: snapshot
                )
                confirmedResponseSnapshot = snapshot
                confirmedResponseSubject = subject
                try credentialStore.saveCredentials(updatedLicense, for: fingerprint)
            } else {
                confirmedResponseSnapshot = snapshot
                confirmedResponseSubject = subject
            }

            var persistedSubject = subject
            if case .license(.activationDeactivated) = snapshot.state {
                try credentialStore.clearCredentials(for: fingerprint)
                persistedSubject = .none
                confirmedResponseSubject = .some(.none)
            }
            try persist(snapshot: snapshot, subject: persistedSubject, fingerprint: fingerprint, validatedBuild: buildIdentity)
            if persistedSubject == .license,
               let license,
               let verification = try credentialStore.loadActivationVerification(for: fingerprint),
               verification.machineToken == license.machineToken {
                try credentialStore.clearActivationVerification(for: fingerprint)
            } else if persistedSubject == .trial,
                      let trial,
                      let verification = try credentialStore.loadTrialVerification(for: fingerprint),
                      verification.trialToken == trial.trialToken {
                try credentialStore.clearTrialVerification(for: fingerprint)
            }
            return .success(
                value: snapshot,
                metadata: operationMetadata(snapshot: snapshot, requestID: response.meta.requestID)
            )
        } catch {
            var licenKitError = normalize(error, operation: "validate")
            if let fingerprint = validationFingerprint {
                let receiptState: (snapshot: EntitlementSnapshot, subject: StoredCredentialSubject)?
                if let confirmedResponseSnapshot, let confirmedResponseSubject {
                    receiptState = (confirmedResponseSnapshot, confirmedResponseSubject)
                } else if licenKitError.confirmedHTTPFailureStatusCode != nil,
                          let subject = validationSubject {
                    let receipt = now()
                    let base = validationStoredSnapshot?.subject == subject
                        ? validationStoredSnapshot!.snapshot
                        : localUnknownSnapshot(lastValidateResponseAt: nil)
                    receiptState = (
                        base.withValidationReceipt(
                            receipt,
                            signedCredentialValid: signedCredentialValid
                        ),
                        subject
                    )
                } else {
                    receiptState = nil
                }
                if let receiptState {
                    do {
                        try persist(
                            snapshot: receiptState.snapshot,
                            subject: receiptState.subject,
                            fingerprint: fingerprint,
                            validatedBuild: confirmedResponseSnapshot == nil
                                ? (validationStoredSnapshot?.subject == receiptState.subject
                                    ? validationStoredSnapshot?.validatedBuild : nil)
                                : ValidationBuildIdentity(
                                    version: configuration.releaseVersion,
                                    platform: configuration.releasePlatform,
                                    arch: configuration.releaseArch
                                )
                        )
                        lastKnown = receiptState.snapshot
                    } catch {
                        setCurrentSnapshot(receiptState.snapshot)
                        licenKitError = attachingPersistenceFailure(
                            error,
                            to: licenKitError
                        )
                        lastKnown = receiptState.snapshot
                    }
                }
            }
            return .failure(
                error: licenKitError,
                lastKnownValue: lastKnown,
                metadata: failureMetadata(
                    error: licenKitError,
                    requestStarted: requestStarted,
                    responseRequestID: responseRequestID,
                    lastValidateResponseAt: lastKnown?.lastValidateResponseAt
                )
            )
        }
    }

    private func performDeactivation() async -> DeactivationResult {
        var lastKnown = currentSnapshot
        var requestStarted = false
        var responseRequestID: String?
        var remoteConfirmed = false
        var repairStage: DeactivationRepairStage = .recordConfirmation
        var fingerprintForRecovery: String?
        do {
            let fingerprint = try await fingerprintProvider.getFingerprint()
            fingerprintForRecovery = fingerprint
            if let stored = try credentialStore.loadSnapshot(for: fingerprint) {
                lastKnown = stored.snapshot
            }
            var attempt = try credentialStore.loadDeactivationAttempt(for: fingerprint)
            if attempt == nil, let credentials = try credentialStore.loadCredentials(for: fingerprint) {
                let newAttempt = StoredDeactivationAttempt(
                    activationID: credentials.activationID,
                    machineToken: credentials.machineToken,
                    phase: .requested
                )
                try credentialStore.saveDeactivationAttempt(newAttempt, for: fingerprint)
                attempt = newAttempt
            }
            guard var attempt else {
                if let stored = try credentialStore.loadSnapshot(for: fingerprint),
                   isConfirmedNoCredentialBlock(stored) {
                    setCurrentSnapshot(stored.snapshot)
                    return .success(
                        value: DeactivationData(wasDeactivated: false, snapshot: stored.snapshot),
                        metadata: OperationMetadata(source: .local)
                    )
                }
                let (snapshot, subject) = try postDeactivationState(
                    fingerprint: fingerprint,
                    stored: try credentialStore.loadSnapshot(for: fingerprint)
                )
                try persist(snapshot: snapshot, subject: subject, fingerprint: fingerprint)
                return .success(
                    value: DeactivationData(wasDeactivated: false, snapshot: snapshot),
                    metadata: OperationMetadata(source: .local)
                )
            }

            if attempt.phase == .requested {
                requestStarted = true
                let response = try await apiClient.deactivate(request: APIDeactivateRequest(
                    productID: configuration.productID,
                    activationID: attempt.activationID,
                    machineToken: attempt.machineToken,
                    fingerprint: fingerprint
                ))
                responseRequestID = response.meta.requestID
                guard response.status == "deactivated", response.activationID == attempt.activationID else {
                    throw LicenKitError.protocolError(reason: "server did not confirm remote deactivation")
                }
                remoteConfirmed = true
                setCurrentSnapshot(localUnknownSnapshot(lastValidateResponseAt: nil))
                attempt = StoredDeactivationAttempt(
                    activationID: attempt.activationID,
                    machineToken: attempt.machineToken,
                    phase: .confirmed,
                    requestID: responseRequestID
                )
                repairStage = .recordConfirmation
                try credentialStore.saveDeactivationAttempt(attempt, for: fingerprint)
            } else {
                remoteConfirmed = true
                responseRequestID = attempt.requestID
                setCurrentSnapshot(localUnknownSnapshot(lastValidateResponseAt: nil))
            }

            repairStage = .clearCredential
            try credentialStore.clearCredentials(for: fingerprint)
            repairStage = .resolveRemainingEntitlement
            let (snapshot, subject) = try postDeactivationState(fingerprint: fingerprint, stored: nil)
            repairStage = .saveSnapshot
            try persist(
                snapshot: snapshot,
                subject: subject,
                fingerprint: fingerprint,
                confirmedRemoteDeactivation: true
            )
            repairStage = .clearRecoveryRecord
            try credentialStore.clearDeactivationAttempt(for: fingerprint)
            return .success(
                value: DeactivationData(wasDeactivated: true, snapshot: snapshot),
                metadata: OperationMetadata(source: .server, requestID: responseRequestID)
            )
        } catch {
            let licenKitError = normalize(error, operation: "deactivate")
            if remoteConfirmed {
                return .remoteConfirmedLocalRepairRequired(
                    stage: repairStage,
                    error: licenKitError,
                    metadata: OperationMetadata(source: .server, requestID: responseRequestID)
                )
            }
            var remoteOutcome: DeactivationRemoteOutcome = requestStarted ? .unknown : .notRequested
            var recoveryError: LicenKitError?
            if requestStarted,
               case .apiError(let statusCode, _, _, _, _) = licenKitError,
               (400...499).contains(statusCode),
               let fingerprintForRecovery {
                remoteOutcome = .rejected
                do {
                    try credentialStore.clearDeactivationAttempt(for: fingerprintForRecovery)
                } catch {
                    recoveryError = normalize(error, operation: "clear rejected deactivation attempt")
                }
            }
            return .failure(
                error: licenKitError,
                remoteOutcome: remoteOutcome,
                lastKnownSnapshot: lastKnown,
                metadata: failureMetadata(
                    error: licenKitError,
                    requestStarted: requestStarted,
                    responseRequestID: responseRequestID
                ),
                localRecoveryError: recoveryError
            )
        }
    }

    private func credentials(
        from response: APICredentialResponse,
        fingerprint: String
    ) throws -> StoredCredentials {
        guard !response.activationID.isEmpty, !response.machineToken.isEmpty else {
            throw LicenKitError.protocolError(
                reason: "credential response is missing activation_id or machine_token"
            )
        }
        let credentials = StoredCredentials(
            activationID: response.activationID,
            machineToken: response.machineToken,
            credentialMode: response.credentialMode,
            signedLicenseToken: response.signedLicenseToken,
            signingKeyID: response.signingKeyID,
            environment: response.billingEnvironment
        )
        try validateCredentialShape(credentials)
        guard (credentials.environment ?? .live) == configuration.environment else {
            throw LicenKitError.protocolError(reason: "License activation environment does not match SDK configuration")
        }
        if credentials.credentialMode == .signed {
            _ = try signedEvaluation(credentials, fingerprint: fingerprint)
        }
        return credentials
    }

    private func applying(
        _ update: APICredentialUpdate,
        to current: StoredCredentials
    ) throws -> StoredCredentials {
        guard update.credentialMode == current.credentialMode else {
            throw LicenKitError.protocolError(
                reason: "credential_update cannot change the stored credential mode"
            )
        }
        let updated = StoredCredentials(
            activationID: current.activationID,
            machineToken: current.machineToken,
            credentialMode: update.credentialMode,
            signedLicenseToken: update.signedLicenseToken,
            signingKeyID: update.signingKeyID,
            environment: update.billingEnvironment
        )
        try validateCredentialShape(updated)
        guard (updated.environment ?? .live) == configuration.environment else {
            throw LicenKitError.protocolError(reason: "License credential update environment does not match SDK configuration")
        }
        return updated
    }

    private func validateCredentialShape(_ credentials: StoredCredentials) throws {
        switch credentials.credentialMode {
        case .opaque:
            guard credentials.signedLicenseToken == nil,
                  credentials.signingKeyID == nil else {
                throw LicenKitError.protocolError(
                    reason: "opaque credential unexpectedly contained Signed License Token fields"
                )
            }
        case .signed:
            guard let token = credentials.signedLicenseToken, !token.isEmpty,
                  let keyID = credentials.signingKeyID, !keyID.isEmpty else {
                throw LicenKitError.protocolError(
                    reason: "signed credential is missing token or key ID"
                )
            }
        }
    }

    private func signedEvaluation(
        _ credentials: StoredCredentials,
        fingerprint: String
    ) throws -> SignedLicenseEvaluation {
        guard let token = credentials.signedLicenseToken,
              let responseKeyID = credentials.signingKeyID else {
            throw LicenKitError.protocolError(reason: "stored signed credential is incomplete")
        }
        let (header, claims) = try verifier.verifyAndDecodeToken(
            token: token,
            signingPublicKey: configuration.signingPublicKey
        )
        guard header.kid == responseKeyID else {
            throw LicenKitError.invalidSignedLicenseToken(
                reason: "response signing_key_id does not match protected kid"
            )
        }
        return try claimsEvaluator.evaluate(
            claims: claims,
            configuration: configuration,
            activationID: credentials.activationID,
            currentFingerprint: fingerprint,
            now: now()
        )
    }

    private func validateSignedStateConsistency(
        credentials: StoredCredentials,
        fingerprint: String,
        snapshot: EntitlementSnapshot
    ) throws {
        guard credentials.credentialMode == .signed else { return }
        let evaluation = try signedEvaluation(credentials, fingerprint: fingerprint)
        switch (snapshot.state, evaluation) {
        case (.license(.active(let terms, let expiresAt)), .active(let claims)),
             (.license(.active(let terms, let expiresAt)), .licenseExpired(let claims)):
            guard terms.features == claims.features,
                  datesEqual(terms.updatesUntil?.date, claims.updatesUntil),
                  datesEqual(expiresAt, claims.licenseExpiresAt) else {
                throw LicenKitError.protocolError(
                    reason: "License active state does not match signed claims"
                )
            }
        case (.license(.expired), _),
             (.license(.suspended), _),
             (.license(.revoked), _),
             (.license(.activationRevoked), _),
             (.license(.activationDeactivated), _),
             (.licenseNotValidForVersion, _):
            break
        default:
            throw LicenKitError.protocolError(
                reason: "Server entitlement state conflicts with signed claims"
            )
        }
    }

    private struct ValidationCooldownDecision {
        let notPerformedReason: NotPerformedReason?
        let cachedSnapshot: EntitlementSnapshot?
        let signedCredentialValid: Bool?
        let localError: LicenKitError?
    }

    private func validationCooldownDecision(
        snapshot: EntitlementSnapshot?,
        validatedBuild: ValidationBuildIdentity?,
        lastAttempt: StoredValidationAttempt?,
        licenseCredentials: StoredCredentials?,
        fingerprint: String,
        build: ValidationBuildIdentity,
        trigger: ValidationTrigger
    ) -> ValidationCooldownDecision {
        var cached = snapshot.map { $0.source == .local ? $0 : $0.withSource(.cache) }
        var isSignedCredentialValid: Bool?
        var bypassConfiguredInterval = false
        var localError: LicenKitError?

        if let licenseCredentials, licenseCredentials.credentialMode == .signed {
            do {
                if let snapshot {
                    try validateSignedStateConsistency(
                        credentials: licenseCredentials,
                        fingerprint: fingerprint,
                        snapshot: snapshot
                    )
                } else {
                    _ = try signedEvaluation(licenseCredentials, fingerprint: fingerprint)
                }
                isSignedCredentialValid = true
                if let snapshot {
                    let source: StateSource
                    if case .license(.active) = snapshot.state { source = .signedLocal }
                    else { source = .cache }
                    cached = snapshot.withSignedCredentialValidity(true, source: source)
                }
            } catch {
                isSignedCredentialValid = false
                cached = snapshot?.withSignedCredentialValidity(false, source: .local)
                if case LicenKitError.invalidSignedLicenseToken = error {
                    bypassConfiguredInterval = true
                } else {
                    localError = normalize(error, operation: "local signed validation")
                }
            }
        }

        if let localError {
            return ValidationCooldownDecision(
                notPerformedReason: nil,
                cachedSnapshot: cached,
                signedCredentialValid: isSignedCredentialValid,
                localError: localError
            )
        }

        let currentTime = now()
        // Old snapshots do not have an attempt record; preserve their remaining 30-second window.
        let hardBaseline = lastAttempt?.startedAt ?? snapshot?.lastValidateResponseAt
        if let hardBaseline {
            let elapsed = currentTime.timeIntervalSince(hardBaseline)
            if elapsed < Self.minimumValidationRequestInterval {
                return ValidationCooldownDecision(
                    notPerformedReason: .minimumInterval(
                        retryAfter: Self.minimumValidationRequestInterval - elapsed
                    ),
                    cachedSnapshot: cached,
                    signedCredentialValid: isSignedCredentialValid,
                    localError: nil
                )
            }
        }

        guard trigger == .silent, let snapshot, let lastResponseAt = snapshot.lastValidateResponseAt else {
            return ValidationCooldownDecision(
                notPerformedReason: nil,
                cachedSnapshot: cached,
                signedCredentialValid: isSignedCredentialValid,
                localError: nil
            )
        }
        let expiry: Date?
        switch snapshot.state {
        case .trial(.active(let expiresAt, _)):
            expiry = expiresAt
        case .license(.active(_, let expiresAt)):
            expiry = expiresAt
        default:
            expiry = nil
        }
        let crossedUnreviewedExpiry = expiry.map {
            currentTime >= $0 && lastResponseAt < $0 && (lastAttempt?.startedAt ?? .distantPast) < $0
        } ?? false
        let unreviewedBuildChange = validatedBuild != build && lastAttempt?.build != build
        let nextEligibleAt = lastResponseAt.addingTimeInterval(
            snapshot.effectiveValidationInterval ?? Self.defaultValidationInterval
        )
        let mayRequest = bypassConfiguredInterval || crossedUnreviewedExpiry
            || unreviewedBuildChange || currentTime >= nextEligibleAt
        return ValidationCooldownDecision(
            notPerformedReason: mayRequest ? nil : .productInterval(nextEligibleAt: nextEligibleAt),
            cachedSnapshot: cached,
            signedCredentialValid: isSignedCredentialValid,
            localError: nil
        )
    }

    private func makeSnapshot(
        state apiState: APIEntitlementState,
        validation: APIValidationMetadata,
        lastValidateResponseAt: Date? = nil,
        signedCredentialValid: Bool? = nil
    ) throws -> EntitlementSnapshot {
        guard let validatedAt = validation.validatedAt.date else {
            throw LicenKitError.protocolError(reason: "validation.validated_at must not be null")
        }
        let effectiveInterval = validation.validationIntervalSeconds
        let state = try mapState(apiState)
        return EntitlementSnapshot(
            state: state,
            source: .server,
            validatedAt: validatedAt,
            receivedValidationInterval: validation.validationIntervalSeconds,
            effectiveValidationInterval: effectiveInterval,
            offlineGracePeriod: validation.offlineGraceSeconds,
            lastValidateResponseAt: lastValidateResponseAt,
            signedCredentialValid: signedCredentialValid,
            businessCode: apiState.code ?? apiState.trial?.code,
            details: sanitize(apiState.details)
        )
    }

    private func mapState(_ state: APIEntitlementState) throws -> EntitlementState {
        switch state.kind {
        case "activation_required":
            guard let trial = state.trial else {
                throw LicenKitError.protocolError(
                    reason: "activation_required state is missing trial availability"
                )
            }
            switch trial.status {
            case "available":
                guard let duration = trial.durationSeconds, duration > 0 else {
                    throw LicenKitError.protocolError(
                        reason: "available Trial is missing a positive duration_seconds"
                    )
                }
                return .activationRequired(
                    trial: .available(duration: duration, features: trial.features ?? [])
                )
            case "unavailable":
                switch trial.reason {
                case "not_enabled":
                    guard trial.code == "TRIAL_NOT_ENABLED" else {
                        throw LicenKitError.protocolError(
                            reason: "not_enabled Trial is missing TRIAL_NOT_ENABLED"
                        )
                    }
                    return .activationRequired(trial: .unavailable(reason: .notEnabled))
                case "already_claimed":
                    guard trial.code == "TRIAL_ALREADY_CLAIMED" else {
                        throw LicenKitError.protocolError(
                            reason: "already_claimed Trial is missing TRIAL_ALREADY_CLAIMED"
                        )
                    }
                    return .activationRequired(trial: .unavailable(reason: .alreadyClaimed))
                default:
                    throw LicenKitError.protocolError(
                        reason: "unavailable Trial has an unknown reason"
                    )
                }
            default:
                throw LicenKitError.protocolError(reason: "unknown Trial availability status")
            }
        case "trial":
            switch state.status {
            case "active":
                guard let expiresAt = state.expiresAt?.date else {
                    throw LicenKitError.protocolError(reason: "active Trial is missing expires_at")
                }
                return .trial(.active(expiresAt: expiresAt, features: state.features ?? []))
            case "expired":
                guard state.code == "TRIAL_EXPIRED", let expiresAt = state.expiresAt?.date else {
                    throw LicenKitError.protocolError(
                        reason: "expired Trial is missing TRIAL_EXPIRED or expires_at"
                    )
                }
                return .trial(.expired(expiresAt: expiresAt))
            case "revoked":
                guard state.code == "TRIAL_REVOKED" else {
                    throw LicenKitError.protocolError(reason: "revoked Trial is missing TRIAL_REVOKED")
                }
                return .trial(.revoked(reason: state.reason))
            default:
                throw LicenKitError.protocolError(reason: "unknown Trial entitlement status")
            }
        case "license":
            switch state.status {
            case "active":
                guard let terms = state.terms else {
                    throw LicenKitError.protocolError(reason: "active License is missing terms")
                }
                return .license(.active(terms: terms, expiresAt: state.expiresAt?.date))
            case "expired":
                try requireCode("LICENSE_EXPIRED", in: state)
                return .license(.expired(expiresAt: state.expiresAt?.date))
            case "suspended":
                try requireCode("LICENSE_SUSPENDED", in: state)
                return .license(.suspended(reason: state.reason))
            case "revoked":
                try requireCode("LICENSE_REVOKED", in: state)
                return .license(.revoked(reason: state.reason))
            case "activation_revoked":
                try requireCode("ACTIVATION_REVOKED", in: state)
                return .license(.activationRevoked)
            case "activation_deactivated":
                try requireCode("ACTIVATION_DEACTIVATED", in: state)
                return .license(.activationDeactivated)
            default:
                throw LicenKitError.protocolError(reason: "unknown License entitlement status")
            }
        case "release_not_eligible":
            switch state.status {
            case "update_required":
                try requireCode("UPDATE_ENTITLEMENT_REQUIRED", in: state)
                guard let releaseVersion = state.releaseVersion,
                      let releasePlatform = state.releasePlatform,
                      let releaseArch = state.releaseArch,
                      let updatesUntil = state.updatesUntil?.date,
                      let releasedAt = state.releasedAt?.date else {
                    throw LicenKitError.protocolError(
                        reason: "license-not-valid-for-version state is missing required facts"
                    )
                }
                return .licenseNotValidForVersion(
                    code: "UPDATE_ENTITLEMENT_REQUIRED",
                    updatesUntil: updatesUntil,
                    releaseVersion: releaseVersion,
                    releasePlatform: releasePlatform,
                    releaseArch: releaseArch,
                    releasedAt: releasedAt
                )
            default:
                throw LicenKitError.protocolError(reason: "unknown Release eligibility status")
            }
        default:
            throw LicenKitError.protocolError(reason: "unknown entitlement state kind '\(state.kind)'")
        }
    }

    private func requireCode(_ expected: String, in state: APIEntitlementState) throws {
        guard state.code == expected else {
            throw LicenKitError.protocolError(reason: "state is missing expected code \(expected)")
        }
    }

    private func require(
        _ state: EntitlementState,
        isValidFor subject: StoredCredentialSubject
    ) throws {
        let valid: Bool
        switch (subject, state) {
        case (.license, .license), (.license, .licenseNotValidForVersion),
             (.trial, .trial),
             (.none, .activationRequired):
            valid = true
        default:
            valid = false
        }
        guard valid else {
            throw LicenKitError.protocolError(
                reason: "entitlement state does not match the validated credential kind"
            )
        }
    }

    private func validateActivationDuplicates(
        _ response: APICredentialResponse,
        snapshot: EntitlementSnapshot
    ) throws {
        guard case .license(.active(let terms, let expiresAt)) = snapshot.state else { return }
        guard terms == response.terms,
              datesEqual(expiresAt, response.licenseExpiresAt?.date) else {
            throw LicenKitError.protocolError(
                reason: "activation operation fields do not match the entitlement state"
            )
        }
    }

    private func validateTrialClaimDuplicates(
        _ response: APITrialClaimResponse,
        snapshot: EntitlementSnapshot
    ) throws {
        switch snapshot.state {
        case .trial(.active(let expiresAt, let features)):
            guard response.status == "active",
                  datesEqual(response.expiresAt.date, expiresAt),
                  response.features == features else {
                throw LicenKitError.protocolError(
                    reason: "trial claim operation fields do not match trial.active"
                )
            }
        case .trial(.expired(let expiresAt)):
            guard response.status == "expired",
                  datesEqual(response.expiresAt.date, expiresAt) else {
                throw LicenKitError.protocolError(
                    reason: "trial claim operation fields do not match trial.expired"
                )
            }
        case .trial(.revoked):
            guard response.status == "revoked" else {
                throw LicenKitError.protocolError(
                    reason: "trial claim operation fields do not match trial.revoked"
                )
            }
        default:
            throw LicenKitError.protocolError(reason: "trial claim did not return a Trial state")
        }
    }

    private func persist(
        snapshot: EntitlementSnapshot,
        subject: StoredCredentialSubject,
        fingerprint: String,
        validatedBuild: ValidationBuildIdentity? = nil,
        confirmedRemoteDeactivation: Bool = false
    ) throws {
        let binding = Self.credentialBinding(
            productID: configuration.productID,
            fingerprint: fingerprint,
            license: subject == .license ? try credentialStore.loadCredentials(for: fingerprint) : nil,
            trial: subject == .trial ? try credentialStore.loadTrialCredentials(for: fingerprint) : nil
        )
        if subject != .none, binding == nil {
            throw LicenKitError.protocolError(reason: "cannot persist entitlement without matching credentials")
        }
        try credentialStore.saveSnapshot(
            StoredEntitlementSnapshot(
                subject: subject,
                snapshot: snapshot,
                validatedBuild: validatedBuild,
                credentialBinding: binding,
                confirmedRemoteDeactivation: confirmedRemoteDeactivation ? true : nil
            ),
            for: fingerprint
        )
        setCurrentSnapshot(snapshot)
    }

    private func localActivationRequiredSnapshot() -> EntitlementSnapshot {
        EntitlementSnapshot(
            state: .activationRequired(trial: .unknown),
            source: .local,
            validatedAt: nil,
            receivedValidationInterval: nil,
            effectiveValidationInterval: nil
        )
    }

    private func localUnknownSnapshot(lastValidateResponseAt: Date?) -> EntitlementSnapshot {
        EntitlementSnapshot(
            state: .unknown,
            source: .local,
            validatedAt: nil,
            receivedValidationInterval: nil,
            effectiveValidationInterval: Self.defaultValidationInterval,
            lastValidateResponseAt: lastValidateResponseAt
        )
    }

    private func postDeactivationState(
        fingerprint: String,
        stored: StoredEntitlementSnapshot?
    ) throws -> (EntitlementSnapshot, StoredCredentialSubject) {
        guard try credentialStore.loadTrialCredentials(for: fingerprint) != nil else {
            return (localActivationRequiredSnapshot(), .none)
        }
        if let stored, stored.subject == .trial {
            return (stored.snapshot.withSource(.cache), .trial)
        }
        return (
            EntitlementSnapshot(
                state: .unknown,
                source: .local,
                validatedAt: nil,
                receivedValidationInterval: nil,
                effectiveValidationInterval: nil
            ),
            .trial
        )
    }

    private func operationMetadata(
        snapshot: EntitlementSnapshot,
        requestID: String?
    ) -> OperationMetadata {
        OperationMetadata(
            source: snapshot.source,
            requestID: requestID,
            validatedAt: snapshot.validatedAt,
            receivedValidationInterval: snapshot.receivedValidationInterval,
            effectiveValidationInterval: snapshot.effectiveValidationInterval,
            offlineGracePeriod: snapshot.offlineGracePeriod,
            lastValidateResponseAt: snapshot.lastValidateResponseAt
        )
    }

    private func failureMetadata(
        error: LicenKitError,
        requestStarted: Bool,
        responseRequestID: String?,
        lastValidateResponseAt: Date? = nil
    ) -> OperationMetadata {
        OperationMetadata(
            source: requestStarted ? .server : .local,
            requestID: responseRequestID ?? error.requestID,
            lastValidateResponseAt: lastValidateResponseAt
        )
    }

    private func attachingPersistenceFailure(
        _ persistenceError: Error,
        to original: LicenKitError
    ) -> LicenKitError {
        let diagnostic = persistenceError.localizedDescription
        switch original {
        case .apiError(let statusCode, let code, let message, let requestID, var details):
            details["client_cooldown_persistence_error"] = diagnostic
            return .apiError(
                statusCode: statusCode,
                code: code,
                message: message,
                requestID: requestID,
                details: details
            )
        case .transportError(
            .server(let statusCode, let code, let requestID, var details),
            let description
        ):
            details["client_cooldown_persistence_error"] = diagnostic
            return .transportError(
                kind: .server(
                    statusCode: statusCode,
                    code: code,
                    requestID: requestID,
                    details: details
                ),
                underlyingDescription: description
            )
        case .transportError(let kind, let description):
            return .transportError(
                kind: kind,
                underlyingDescription: "\(description); cooldown persistence failed: \(diagnostic)"
            )
        default:
            return original
        }
    }

    private func normalize(_ error: Error, operation: String) -> LicenKitError {
        if let error = error as? LicenKitError { return error }
        return .protocolError(reason: "\(operation) failed: \(error.localizedDescription)")
    }

    private func setCurrentSnapshot(_ snapshot: EntitlementSnapshot) {
        stateLock.lock()
        storedSnapshot = snapshot
        stateLock.unlock()
    }

    private func clearCurrentSnapshot() {
        stateLock.lock()
        storedSnapshot = nil
        stateLock.unlock()
    }

    private func sanitize(_ details: [String: JSONValue]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: details.map { key, value in
            (key, sanitizedValue(key: key, value: value).diagnosticString)
        })
    }

    private func sanitizedValue(key: String, value: JSONValue) -> JSONValue {
        let sensitiveNames = ["token", "secret", "password", "license_key", "authorization"]
        if sensitiveNames.contains(where: { key.lowercased().contains($0) }) {
            return .string("[REDACTED]")
        }
        switch value {
        case .object(let object):
            return .object(Dictionary(uniqueKeysWithValues: object.map { nestedKey, nested in
                (nestedKey, sanitizedValue(key: nestedKey, value: nested))
            }))
        case .array(let values):
            return .array(values.map { sanitizedValue(key: key, value: $0) })
        default:
            return value
        }
    }

    private func datesEqual(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (lhs?, rhs?): return abs(lhs.timeIntervalSince(rhs)) < 0.001
        default: return false
        }
    }

    private static func generateVerificationToken(prefix: String) throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw LicenKitError.credentialStorageError(
                operation: "generate verification token",
                status: status
            )
        }
        let encoded = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "\(prefix)_\(encoded)"
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
