import Foundation

public final class LicenKit: @unchecked Sendable {
    public static let minimumValidationRequestInterval: TimeInterval = 30
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
        self.credentialStore = credentialStore ?? KeychainStore(productID: configuration.productID)
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
    public func validate() async -> LicenKitResult<EntitlementSnapshot> {
        await operationCoordinator.validate { [self] in await performValidation() }
    }

    @discardableResult
    public func deactivate() async -> LicenKitResult<DeactivationData> {
        await operationCoordinator.perform { [self] in await performDeactivation() }
    }

    public func hasFeature(_ feature: String) -> Bool {
        currentSnapshot?.hasFeature(feature, at: now()) ?? false
    }

    public func getMachineFingerprint() async throws -> String {
        try await fingerprintProvider.getFingerprint()
    }

    private func performActivation(
        licenseKey: String,
        machineName: String?
    ) async -> LicenKitResult<ActivationData> {
        var requestStarted = false
        var responseRequestID: String?
        do {
            let build = try configuration.requireBuildIdentity()
            let fingerprint = try await fingerprintProvider.getFingerprint()
            if let stored = try credentialStore.loadSnapshot(for: fingerprint) {
                setCurrentSnapshot(stored.snapshot)
            }
            requestStarted = true
            let response = try await apiClient.activate(request: APIActivateRequest(
                productID: configuration.productID,
                licenseKey: licenseKey,
                fingerprint: fingerprint,
                devicePlatform: Self.devicePlatform,
                name: machineName ?? ProcessInfo.processInfo.hostName,
                releaseVersion: build.version,
                releasePlatform: build.platform,
                releaseArch: build.arch
            ))
            responseRequestID = response.meta.requestID

            let credentials = try credentials(from: response, fingerprint: fingerprint)
            let snapshot = try makeSnapshot(
                state: response.state,
                validation: response.validation,
                signedTokenExpiresAt: credentials.signedLicenseTokenExpiresAt,
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
            try persist(snapshot: snapshot, subject: .license, fingerprint: fingerprint)
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
            if let stored = try credentialStore.loadSnapshot(for: fingerprint) {
                lastKnown = stored.snapshot
                setCurrentSnapshot(stored.snapshot)
            }
            requestStarted = true
            let response = try await apiClient.claimTrial(request: APITrialClaimRequest(
                productID: configuration.productID,
                fingerprint: fingerprint,
                devicePlatform: Self.devicePlatform,
                releaseVersion: build.version,
                releasePlatform: build.platform,
                releaseArch: build.arch
            ))
            responseRequestID = response.meta.requestID
            guard response.status == "active",
                  let token = response.trialToken, !token.isEmpty,
                  let responseExpiresAt = response.expiresAt.date else {
                throw LicenKitError.protocolError(
                    reason: "trial claim response did not contain a one-time active trial token"
                )
            }
            let snapshot = try makeSnapshot(
                state: response.state,
                validation: response.validation,
                signedTokenExpiresAt: nil
            )
            guard case .trial(.active(let stateExpiresAt, let stateFeatures)) = snapshot.state else {
                throw LicenKitError.protocolError(reason: "trial claim did not return trial.active")
            }
            guard datesEqual(responseExpiresAt, stateExpiresAt), response.features == stateFeatures else {
                throw LicenKitError.protocolError(
                    reason: "trial claim operation fields do not match the entitlement state"
                )
            }

            try credentialStore.saveTrialCredentials(
                StoredTrialCredentials(trialID: response.trialID, trialToken: token),
                for: fingerprint
            )
            try persist(snapshot: snapshot, subject: .trial, fingerprint: fingerprint)
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

    private func performValidation() async -> LicenKitResult<EntitlementSnapshot> {
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
            let fingerprint = try await fingerprintProvider.getFingerprint()
            validationFingerprint = fingerprint
            let license = try credentialStore.loadCredentials(for: fingerprint)
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
            validationStoredSnapshot = stored
            if let stored {
                lastKnown = stored.snapshot
                setCurrentSnapshot(stored.snapshot)
            }
            if let stored, stored.subject == subject {
                let decision = validationCooldownDecision(
                    snapshot: stored.snapshot,
                    licenseCredentials: license,
                    fingerprint: fingerprint
                )
                signedCredentialValid = decision.signedCredentialValid
                if let cached = decision.cooldownSnapshot {
                    setCurrentSnapshot(cached)
                    return .notPerformed(
                        reason: .cooldown,
                        cachedValue: cached,
                        metadata: operationMetadata(snapshot: cached, requestID: nil)
                    )
                }
            }

            requestStarted = true
            let response = try await apiClient.validate(request: APIValidateRequest(
                productID: configuration.productID,
                fingerprint: fingerprint,
                releaseVersion: build.version,
                releasePlatform: build.platform,
                releaseArch: build.arch,
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
                signedTokenExpiresAt: license?.signedLicenseTokenExpiresAt,
                lastValidateResponseAt: responseReceivedAt,
                signedCredentialValid: signedCredentialValid
            )
            try require(snapshot.state, isValidFor: subject)

            if case .license(.active) = snapshot.state {
                guard let license, let update = response.credentialUpdate else {
                    throw LicenKitError.protocolError(
                        reason: "active License validation is missing credential_update"
                    )
                }
                let updatedLicense = try applying(update, to: license)
                snapshot = try makeSnapshot(
                    state: response.state,
                    validation: response.validation,
                    signedTokenExpiresAt: updatedLicense.signedLicenseTokenExpiresAt,
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
            try persist(snapshot: snapshot, subject: persistedSubject, fingerprint: fingerprint)
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
                            fingerprint: fingerprint
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

    private func performDeactivation() async -> LicenKitResult<DeactivationData> {
        var lastKnown = currentSnapshot
        var requestStarted = false
        var responseRequestID: String?
        do {
            let fingerprint = try await fingerprintProvider.getFingerprint()
            if let stored = try credentialStore.loadSnapshot(for: fingerprint) {
                lastKnown = stored.snapshot
                setCurrentSnapshot(stored.snapshot)
            }
            guard let credentials = try credentialStore.loadCredentials(for: fingerprint) else {
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

            requestStarted = true
            let response = try await apiClient.deactivate(request: APIDeactivateRequest(
                productID: configuration.productID,
                activationID: credentials.activationID,
                machineToken: credentials.machineToken,
                fingerprint: fingerprint
            ))
            responseRequestID = response.meta.requestID
            guard response.status == "deactivated", response.activationID == credentials.activationID else {
                throw LicenKitError.protocolError(reason: "server did not confirm remote deactivation")
            }
            try credentialStore.clearCredentials(for: fingerprint)
            let (snapshot, subject) = try postDeactivationState(fingerprint: fingerprint, stored: nil)
            try persist(snapshot: snapshot, subject: subject, fingerprint: fingerprint)
            return .success(
                value: DeactivationData(wasDeactivated: true, snapshot: snapshot),
                metadata: OperationMetadata(source: .server, requestID: response.meta.requestID)
            )
        } catch {
            let licenKitError = normalize(error, operation: "deactivate")
            return .failure(
                error: licenKitError,
                lastKnownValue: lastKnown.map {
                    DeactivationData(wasDeactivated: false, snapshot: $0)
                },
                metadata: failureMetadata(
                    error: licenKitError,
                    requestStarted: requestStarted,
                    responseRequestID: responseRequestID
                )
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
            signedLicenseTokenExpiresAt: response.signedLicenseTokenExpiresAt?.date
        )
        try validateCredentialShape(credentials)
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
            signedLicenseTokenExpiresAt: update.signedLicenseTokenExpiresAt?.date
        )
        try validateCredentialShape(updated)
        return updated
    }

    private func validateCredentialShape(_ credentials: StoredCredentials) throws {
        switch credentials.credentialMode {
        case .opaque:
            guard credentials.signedLicenseToken == nil,
                  credentials.signingKeyID == nil,
                  credentials.signedLicenseTokenExpiresAt == nil else {
                throw LicenKitError.protocolError(
                    reason: "opaque credential unexpectedly contained Signed License Token fields"
                )
            }
        case .signed:
            guard let token = credentials.signedLicenseToken, !token.isEmpty,
                  let keyID = credentials.signingKeyID, !keyID.isEmpty,
                  credentials.signedLicenseTokenExpiresAt != nil else {
                throw LicenKitError.protocolError(
                    reason: "signed credential is missing token, key ID, or token expiry"
                )
            }
        }
    }

    private func signedEvaluation(
        _ credentials: StoredCredentials,
        fingerprint: String
    ) throws -> SignedLicenseEvaluation {
        guard let token = credentials.signedLicenseToken,
              let responseKeyID = credentials.signingKeyID,
              let responseExpiry = credentials.signedLicenseTokenExpiresAt else {
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
        guard datesEqual(responseExpiry, claims.tokenExpiresAt) else {
            throw LicenKitError.protocolError(
                reason: "signed_license_token_expires_at does not match the signed exp claim"
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
        case (.license(.active(let terms, let expiresAt)), .active(let claims)):
            guard terms.features == claims.features,
                  datesEqual(terms.updatesUntil?.date, claims.updatesUntil),
                  datesEqual(expiresAt, claims.licenseExpiresAt) else {
                throw LicenKitError.protocolError(
                    reason: "License active state does not match signed claims"
                )
            }
        case (.license(.expired(let expiresAt)), .licenseExpired(let signedExpiresAt)):
            guard datesEqual(expiresAt, signedExpiresAt) else {
                throw LicenKitError.protocolError(reason: "License expiry state does not match signed claims")
            }
        case (.license(.suspended), .active),
             (.license(.revoked), .active),
             (.license(.activationRevoked), .active),
             (.license(.activationDeactivated), .active):
            break
        default:
            throw LicenKitError.protocolError(
                reason: "Server entitlement state conflicts with signed claims"
            )
        }
    }

    private struct ValidationCooldownDecision {
        let cooldownSnapshot: EntitlementSnapshot?
        let signedCredentialValid: Bool?
    }

    private func validationCooldownDecision(
        snapshot: EntitlementSnapshot,
        licenseCredentials: StoredCredentials?,
        fingerprint: String
    ) -> ValidationCooldownDecision {
        var cached = snapshot.withSource(.cache)
        var isSignedCredentialValid: Bool?
        var bypassConfiguredInterval = false

        if let licenseCredentials, licenseCredentials.credentialMode == .signed {
            do {
                try validateSignedStateConsistency(
                    credentials: licenseCredentials,
                    fingerprint: fingerprint,
                    snapshot: snapshot
                )
                isSignedCredentialValid = true
                let source: StateSource
                if case .license(.active) = snapshot.state { source = .signedLocal }
                else { source = .cache }
                cached = snapshot.withSignedCredentialValidity(true, source: source)
            } catch {
                isSignedCredentialValid = false
                bypassConfiguredInterval = true
                cached = snapshot.withSignedCredentialValidity(false, source: .local)
            }
        }

        guard let lastResponseAt = snapshot.lastValidateResponseAt else {
            return ValidationCooldownDecision(
                cooldownSnapshot: nil,
                signedCredentialValid: isSignedCredentialValid
            )
        }
        let elapsed = now().timeIntervalSince(lastResponseAt)
        let minimumElapsed = elapsed >= Self.minimumValidationRequestInterval
        let configuredInterval = snapshot.effectiveValidationInterval
            ?? Self.normalizeInterval(nil)
        let configuredElapsed = elapsed >= configuredInterval
        let mayRequest = minimumElapsed && (bypassConfiguredInterval || configuredElapsed)
        return ValidationCooldownDecision(
            cooldownSnapshot: mayRequest ? nil : cached,
            signedCredentialValid: isSignedCredentialValid
        )
    }

    private func makeSnapshot(
        state apiState: APIEntitlementState,
        validation: APIValidationMetadata,
        signedTokenExpiresAt: Date?,
        lastValidateResponseAt: Date? = nil,
        signedCredentialValid: Bool? = nil
    ) throws -> EntitlementSnapshot {
        guard let validatedAt = validation.validatedAt.date else {
            throw LicenKitError.protocolError(reason: "validation.validated_at must not be null")
        }
        let effectiveInterval = Self.normalizeInterval(validation.validationIntervalSeconds)
        let state = try mapState(apiState)
        return EntitlementSnapshot(
            state: state,
            source: .server,
            validatedAt: validatedAt,
            receivedValidationInterval: validation.validationIntervalSeconds,
            effectiveValidationInterval: effectiveInterval,
            signedLicenseTokenExpiresAt: signedTokenExpiresAt,
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

    private func persist(
        snapshot: EntitlementSnapshot,
        subject: StoredCredentialSubject,
        fingerprint: String
    ) throws {
        try credentialStore.saveSnapshot(
            StoredEntitlementSnapshot(subject: subject, snapshot: snapshot),
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
            effectiveValidationInterval: Self.normalizeInterval(nil),
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

    static func normalizeInterval(_ received: TimeInterval?) -> TimeInterval {
        min(max(received ?? 3_600, 3_600), 86_400)
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
