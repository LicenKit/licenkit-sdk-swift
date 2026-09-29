import CryptoKit
import XCTest
@testable import LicenKit

final class MemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var licenses: [String: StoredCredentials] = [:]
    private var trials: [String: StoredTrialCredentials] = [:]
    private var snapshots: [String: StoredEntitlementSnapshot] = [:]
    private var validationAttempts: [String: StoredValidationAttempt] = [:]
    private var deactivationAttempts: [String: StoredDeactivationAttempt] = [:]
    private var shouldFailNextLicenseSave = false
    private var shouldFailNextTrialSave = false
    private var shouldFailNextSnapshotSave = false
    private var shouldFailNextLicenseClear = false
    private var shouldFailNextDeactivationAttemptSave = false
    private var shouldFailNextConfirmedDeactivationAttemptSave = false

    func loadDeactivationAttempt(for fingerprint: String) throws -> StoredDeactivationAttempt? {
        lock.withLock { deactivationAttempts[fingerprint] }
    }

    func saveDeactivationAttempt(_ attempt: StoredDeactivationAttempt, for fingerprint: String) throws {
        let shouldFail = lock.withLock {
            defer { shouldFailNextDeactivationAttemptSave = false }
            if attempt.phase == .confirmed, shouldFailNextConfirmedDeactivationAttemptSave {
                shouldFailNextConfirmedDeactivationAttemptSave = false
                return true
            }
            return shouldFailNextDeactivationAttemptSave
        }
        if shouldFail {
            throw LicenKitError.credentialStorageError(operation: "write", status: -1)
        }
        lock.withLock { deactivationAttempts[fingerprint] = attempt }
    }

    func clearDeactivationAttempt(for fingerprint: String) throws {
        _ = lock.withLock { deactivationAttempts.removeValue(forKey: fingerprint) }
    }

    func loadValidationAttempt(for fingerprint: String) throws -> StoredValidationAttempt? {
        lock.withLock { validationAttempts[fingerprint] }
    }
    func saveValidationAttempt(_ attempt: StoredValidationAttempt, for fingerprint: String) throws {
        lock.withLock { validationAttempts[fingerprint] = attempt }
    }

    func failNextLicenseSave() {
        lock.withLock { shouldFailNextLicenseSave = true }
    }

    func failNextTrialSave() {
        lock.withLock { shouldFailNextTrialSave = true }
    }

    func failNextSnapshotSave() {
        lock.withLock { shouldFailNextSnapshotSave = true }
    }

    func failNextLicenseClear() {
        lock.withLock { shouldFailNextLicenseClear = true }
    }

    func failNextDeactivationAttemptSave() {
        lock.withLock { shouldFailNextDeactivationAttemptSave = true }
    }

    func failNextConfirmedDeactivationAttemptSave() {
        lock.withLock { shouldFailNextConfirmedDeactivationAttemptSave = true }
    }

    func loadCredentials(for fingerprint: String) throws -> StoredCredentials? {
        lock.withLock { licenses[fingerprint] }
    }
    func saveCredentials(_ credentials: StoredCredentials, for fingerprint: String) throws {
        let shouldFail = lock.withLock {
            defer { shouldFailNextLicenseSave = false }
            return shouldFailNextLicenseSave
        }
        if shouldFail {
            throw LicenKitError.credentialStorageError(operation: "write", status: -1)
        }
        lock.withLock { licenses[fingerprint] = credentials }
    }
    func clearCredentials(for fingerprint: String) throws {
        let shouldFail = lock.withLock {
            defer { shouldFailNextLicenseClear = false }
            return shouldFailNextLicenseClear
        }
        if shouldFail {
            throw LicenKitError.credentialStorageError(operation: "delete", status: -1)
        }
        _ = lock.withLock { licenses.removeValue(forKey: fingerprint) }
    }
    func loadTrialCredentials(for fingerprint: String) throws -> StoredTrialCredentials? {
        lock.withLock { trials[fingerprint] }
    }
    func saveTrialCredentials(_ credentials: StoredTrialCredentials, for fingerprint: String) throws {
        let shouldFail = lock.withLock {
            defer { shouldFailNextTrialSave = false }
            return shouldFailNextTrialSave
        }
        if shouldFail {
            throw LicenKitError.credentialStorageError(operation: "write", status: -1)
        }
        lock.withLock { trials[fingerprint] = credentials }
    }
    func clearTrialCredentials(for fingerprint: String) throws {
        _ = lock.withLock { trials.removeValue(forKey: fingerprint) }
    }
    func loadSnapshot(for fingerprint: String) throws -> StoredEntitlementSnapshot? {
        lock.withLock { snapshots[fingerprint] }
    }
    func saveSnapshot(_ snapshot: StoredEntitlementSnapshot, for fingerprint: String) throws {
        let shouldFail = lock.withLock {
            defer { shouldFailNextSnapshotSave = false }
            return shouldFailNextSnapshotSave
        }
        if shouldFail {
            throw LicenKitError.credentialStorageError(operation: "write", status: -1)
        }
        lock.withLock {
            let binding = LicenKit.credentialBinding(
                productID: "prd_1",
                fingerprint: fingerprint,
                license: snapshot.subject == .license ? licenses[fingerprint] : nil,
                trial: snapshot.subject == .trial ? trials[fingerprint] : nil
            )
            snapshots[fingerprint] = StoredEntitlementSnapshot(
                subject: snapshot.subject,
                snapshot: snapshot.snapshot,
                validatedBuild: snapshot.validatedBuild,
                credentialBinding: snapshot.credentialBinding ?? binding,
                confirmedRemoteDeactivation: snapshot.confirmedRemoteDeactivation
            )
        }
    }

    func saveUnboundSnapshot(_ snapshot: StoredEntitlementSnapshot, for fingerprint: String) {
        lock.withLock { snapshots[fingerprint] = snapshot }
    }
}

struct FixedFingerprint: DeviceFingerprintProvider, Sendable {
    let value: String
    func getFingerprint() async throws -> String { value }
}

final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    func now() -> Date { lock.withLock { value } }
    func set(_ value: Date) { lock.withLock { self.value = value } }
}

final class ContractURLProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let handler = Self.lock.withLock { Self.handler }
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

final class V1ContractTests: XCTestCase {
    private let fingerprint = "sha256:test-device"
    private let currentBuild = ValidationBuildIdentity(version: "2.4.0", platform: "macos", arch: "arm64")
    private let validatedAt = FlexibleDate.parseISO8601("2030-01-01T00:00:00Z")!
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ContractURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDown() {
        ContractURLProtocol.lock.withLock { ContractURLProtocol.handler = nil }
        session.invalidateAndCancel()
        session = nil
        super.tearDown()
    }

    func testLocalRestorationSeparatesOfflineAccessFromNetworkValidation() async throws {
        let emptyStore = MemoryCredentialStore()
        let requests = LockedBox(0)
        setHandler { _ in
            requests.mutate { $0 += 1 }
            throw URLError(.notConnectedToInternet)
        }
        let newDevice = makeClient(store: emptyStore)
        let newDeviceResult = await newDevice.restoreLocalEntitlement()
        XCTAssertEqual(newDeviceResult, .verificationRequired(reason: .noCredential))

        let store = MemoryCredentialStore()
        try store.saveCredentials(opaqueCredentials(), for: fingerprint)
        try store.saveSnapshot(
            .init(subject: .license, snapshot: licenseSnapshot(validatedAt: validatedAt, interval: 3_600)),
            for: fingerprint
        )
        let existingDevice = makeClient(store: store)
        guard case .usable(let local) = await existingDevice.restoreLocalEntitlement() else {
            return XCTFail("A bound active License must be usable before networking")
        }
        XCTAssertEqual(local.source, .cache)
        XCTAssertEqual(requests.get(), 0)
        guard case .failure(.transportError(.network, _), _, _) = await existingDevice.validate(trigger: .silent) else {
            return XCTFail("The later offline validation must retain its real transport error")
        }
        XCTAssertEqual(requests.get(), 1)
        XCTAssertTrue(existingDevice.currentSnapshot?.isUsable(at: validatedAt.addingTimeInterval(10)) ?? false)
    }

    func testLocalRestorationRejectsMissingOrMismatchedEvidenceAndRestoresBlockedState() async throws {
        let missingCredentials = MemoryCredentialStore()
        missingCredentials.saveUnboundSnapshot(
            .init(subject: .license, snapshot: licenseSnapshot(validatedAt: validatedAt, interval: 3_600)),
            for: fingerprint
        )
        let missingResult = await makeClient(store: missingCredentials).restoreLocalEntitlement()
        XCTAssertEqual(missingResult, .verificationRequired(reason: .noCredential))

        let mismatched = MemoryCredentialStore()
        try mismatched.saveCredentials(opaqueCredentials(), for: fingerprint)
        mismatched.saveUnboundSnapshot(
            .init(subject: .license, snapshot: licenseSnapshot(validatedAt: validatedAt, interval: 3_600)),
            for: fingerprint
        )
        let mismatchedResult = await makeClient(store: mismatched).restoreLocalEntitlement()
        XCTAssertEqual(mismatchedResult, .verificationRequired(reason: .noMatchingSnapshot))

        let blocked = MemoryCredentialStore()
        let snapshot = EntitlementSnapshot(
            state: .activationRequired(trial: .unknown), source: .server,
            validatedAt: validatedAt, receivedValidationInterval: 3_600,
            effectiveValidationInterval: 3_600
        )
        try blocked.saveSnapshot(.init(subject: .none, snapshot: snapshot), for: fingerprint)
        guard case .confirmedBlocked(let restored) = await makeClient(store: blocked).restoreLocalEntitlement() else {
            return XCTFail("A Server-confirmed blocked cache must restore as blocked")
        }
        XCTAssertEqual(restored.source, .cache)

        let deactivated = MemoryCredentialStore()
        let deactivatedSnapshot = EntitlementSnapshot(
            state: .license(.activationDeactivated), source: .server,
            validatedAt: validatedAt, receivedValidationInterval: 3_600,
            effectiveValidationInterval: 3_600
        )
        try deactivated.saveSnapshot(
            .init(subject: .none, snapshot: deactivatedSnapshot), for: fingerprint
        )
        guard case .confirmedBlocked = await makeClient(store: deactivated).restoreLocalEntitlement() else {
            return XCTFail("A Server-confirmed deactivation remains a blocked business state")
        }
    }

    func testLocalTrialRestorationRespectsBusinessExpiry() async throws {
        let store = MemoryCredentialStore()
        try store.saveTrialCredentials(.init(trialID: "trl_1"), for: fingerprint)
        let expiry = validatedAt.addingTimeInterval(100)
        let snapshot = EntitlementSnapshot(
            state: .trial(.active(expiresAt: expiry, features: ["export"])),
            source: .server, validatedAt: validatedAt,
            receivedValidationInterval: 3_600, effectiveValidationInterval: 3_600
        )
        try store.saveSnapshot(.init(subject: .trial, snapshot: snapshot), for: fingerprint)
        guard case .usable = await makeClient(
            store: store, clock: MutableClock(expiry.addingTimeInterval(-1))
        ).restoreLocalEntitlement() else {
            return XCTFail("A bound active Trial must restore without networking")
        }
        let expired = await makeClient(
            store: store, clock: MutableClock(expiry)
        ).restoreLocalEntitlement()
        XCTAssertEqual(expired, .verificationRequired(reason: .expired))
    }

    func testNoCredentialTrialAvailabilityMapsWithoutLeakingClaimData() async throws {
        for (trial, expected) in [
            (
                ["status": "available", "duration_seconds": 86_400, "features": ["export"]] as [String: Any],
                TrialAvailability.available(duration: 86_400, features: ["export"])
            ),
            (
                [
                    "status": "unavailable", "reason": "not_enabled",
                    "code": "TRIAL_NOT_ENABLED"
                ] as [String: Any],
                TrialAvailability.unavailable(reason: .notEnabled)
            ),
            (
                [
                    "status": "unavailable", "reason": "already_claimed",
                    "code": "TRIAL_ALREADY_CLAIMED"
                ] as [String: Any],
                TrialAvailability.unavailable(reason: .alreadyClaimed)
            ),
        ] {
            setJSONResponse(data: validateData(state: ["kind": "activation_required", "trial": trial]))
            let result = await makeClient(store: MemoryCredentialStore()).validate(trigger: .silent)
            guard case .success(let snapshot, _) = result,
                  case .activationRequired(let actual) = snapshot.state else {
                return XCTFail("Expected activationRequired, got \(result)")
            }
            XCTAssertEqual(actual, expected)
            XCTAssertNil(snapshot.details["trial_id"])
            switch expected {
            case .unavailable(reason: .notEnabled):
                XCTAssertEqual(snapshot.businessCode, "TRIAL_NOT_ENABLED")
            case .unavailable(reason: .alreadyClaimed):
                XCTAssertEqual(snapshot.businessCode, "TRIAL_ALREADY_CLAIMED")
            default:
                XCTAssertNil(snapshot.businessCode)
            }
        }
    }

    func testTrialUnavailableRejectsMissingOrMismatchedBusinessCode() async throws {
        for trial in [
            ["status": "unavailable", "reason": "not_enabled"],
            [
                "status": "unavailable", "reason": "already_claimed",
                "code": "TRIAL_NOT_ENABLED"
            ],
        ] {
            setJSONResponse(data: validateData(state: [
                "kind": "activation_required", "trial": trial
            ]))
            let result = await makeClient(store: MemoryCredentialStore()).validate(trigger: .silent)
            guard case .failure(.protocolError, _, let metadata) = result else {
                return XCTFail("Expected strict Trial reason/code protocol failure")
            }
            XCTAssertEqual(metadata.requestID, "req_1")
        }
    }

    func testLicenseCredentialHasPriorityOverResidualTrialCredential() async throws {
        let store = MemoryCredentialStore()
        try store.saveCredentials(opaqueCredentials(), for: fingerprint)
        try store.saveTrialCredentials(.init(trialID: "trl_1"), for: fingerprint)
        let seenKind = LockedBox<String?>(nil)
        setHandler { request in
            let json = try self.requestJSON(request)
            let credential = try XCTUnwrap(json["credential"] as? [String: Any])
            seenKind.set(credential["kind"] as? String)
            return self.response(data: self.validateData(state: self.licenseState()))
        }
        let result = await makeClient(store: store).validate(trigger: .silent)
        guard case .success(let snapshot, _) = result,
              case .license(.active) = snapshot.state else { return XCTFail("Expected License success") }
        XCTAssertEqual(seenKind.get(), "license")
    }

    func testTrialAndLicenseTerminalStatesPreserveBusinessCodeAndSafeDetails() async throws {
        let trialCases: [(String, String, EntitlementState)] = [
            ("expired", "TRIAL_EXPIRED", .trial(.expired(expiresAt: validatedAt.addingTimeInterval(-10)))),
            ("revoked", "TRIAL_REVOKED", .trial(.revoked(reason: "abuse"))),
        ]
        for (status, code, expected) in trialCases {
            let trialStore = MemoryCredentialStore()
            try trialStore.saveTrialCredentials(
                .init(trialID: "trl_1"),
                for: fingerprint
            )
            var state: [String: Any] = [
                "kind": "trial", "status": status, "code": code,
                "details": ["trial_id": "trl_1", "trial_token": "secret"]
            ]
            if status == "expired" { state["expires_at"] = iso(validatedAt.addingTimeInterval(-10)) }
            if status == "revoked" { state["reason"] = "abuse" }
            setJSONResponse(data: validateData(state: state))
            let result = await makeClient(store: trialStore).validate(trigger: .silent)
            guard case .success(let snapshot, _) = result else { return XCTFail("Expected success") }
            XCTAssertEqual(snapshot.state, expected)
            XCTAssertEqual(snapshot.businessCode, code)
            XCTAssertEqual(snapshot.details["trial_id"], "trl_1")
            XCTAssertEqual(snapshot.details["trial_token"], "[REDACTED]")
        }

        let licenseCases: [(String, String, EntitlementState)] = [
            ("expired", "LICENSE_EXPIRED", .license(.expired(expiresAt: validatedAt.addingTimeInterval(-10)))),
            ("suspended", "LICENSE_SUSPENDED", .license(.suspended(reason: "payment"))),
            ("revoked", "LICENSE_REVOKED", .license(.revoked(reason: "refund"))),
            ("activation_revoked", "ACTIVATION_REVOKED", .license(.activationRevoked)),
            ("activation_deactivated", "ACTIVATION_DEACTIVATED", .license(.activationDeactivated)),
        ]
        for (status, code, expected) in licenseCases {
            let store = MemoryCredentialStore()
            try store.saveCredentials(opaqueCredentials(), for: fingerprint)
            var state: [String: Any] = ["kind": "license", "status": status, "code": code]
            if status == "expired" { state["expires_at"] = iso(validatedAt.addingTimeInterval(-10)) }
            if status == "suspended" { state["reason"] = "payment" }
            if status == "revoked" { state["reason"] = "refund" }
            setJSONResponse(data: validateData(state: state))
            let result = await makeClient(store: store).validate(trigger: .silent)
            guard case .success(let snapshot, _) = result else { return XCTFail("Expected success for \(code)") }
            XCTAssertEqual(snapshot.state, expected)
            XCTAssertEqual(snapshot.businessCode, code)
            if status == "activation_deactivated" {
                XCTAssertNil(try store.loadCredentials(for: fingerprint))
            }
        }
    }

    func testLicenseNotValidForVersionIsNotLicenseExpiry() async throws {
        let state: [String: Any] = [
            "kind": "release_not_eligible", "status": "update_required",
            "code": "UPDATE_ENTITLEMENT_REQUIRED", "updates_until": "2029-01-01T00:00:00Z",
            "release_version": "2.4.0", "release_platform": "macos", "release_arch": "arm64",
            "released_at": "2030-01-01T00:00:00Z"
        ]
        let expected = EntitlementState.licenseNotValidForVersion(
            code: "UPDATE_ENTITLEMENT_REQUIRED",
            updatesUntil: FlexibleDate.parseISO8601("2029-01-01T00:00:00Z")!,
            releaseVersion: "2.4.0",
            releasePlatform: "macos",
            releaseArch: "arm64",
            releasedAt: validatedAt
        )
        setJSONResponse(data: validateData(state: state))
        let store = MemoryCredentialStore()
        try store.saveCredentials(opaqueCredentials(), for: fingerprint)
        let result = await makeClient(store: store).validate(trigger: .silent)
        guard case .success(let snapshot, _) = result else { return XCTFail("Expected success") }
        XCTAssertEqual(snapshot.state, expected)
    }

    func testReleaseStatesRejectMissingRequiredFacts() async throws {
        let states: [[String: Any]] = [
            ["kind": "release_not_eligible", "status": "update_required", "code": "UPDATE_ENTITLEMENT_REQUIRED"],
            [
                "kind": "release_not_eligible", "status": "update_required",
                "code": "UPDATE_ENTITLEMENT_REQUIRED", "release_version": "2.4.0",
                "release_platform": "macos"
            ],
            [
                "kind": "release_not_eligible", "status": "update_required",
                "code": "UPDATE_ENTITLEMENT_REQUIRED", "release_version": "2.4.0",
                "release_platform": "macos", "release_arch": "arm64",
                "released_at": "2030-01-01T00:00:00Z"
            ],
            [
                "kind": "release_not_eligible", "status": "update_required",
                "code": "UPDATE_ENTITLEMENT_REQUIRED", "release_version": "2.4.0",
                "release_platform": "macos", "release_arch": "arm64",
                "updates_until": "2029-01-01T00:00:00Z"
            ],
        ]
        for state in states {
            setJSONResponse(data: validateData(state: state))
            let result = await makeClient(store: MemoryCredentialStore()).validate(trigger: .silent)
            guard case .failure(.protocolError, _, let metadata) = result else {
                return XCTFail("Expected missing License/version facts to fail")
            }
            XCTAssertEqual(metadata.requestID, "req_1")
        }
    }

    func testValidationCooldownDoesNotRequestBeforeConfiguredInterval() async throws {
        let store = MemoryCredentialStore()
        try store.saveCredentials(opaqueCredentials(), for: fingerprint)
        let snapshot = licenseSnapshot(
            validatedAt: validatedAt,
            interval: 3_600,
            lastValidateResponseAt: validatedAt
        )
        try store.saveSnapshot(.init(subject: .license, snapshot: snapshot, validatedBuild: currentBuild), for: fingerprint)
        let requests = LockedBox(0)
        setHandler { _ in requests.mutate { $0 += 1 }; return self.response(data: self.validateData(state: self.licenseState())) }
        let clock = MutableClock(validatedAt.addingTimeInterval(100))
        let result = await makeClient(store: store, clock: clock).validate(trigger: .silent)
        guard case .notPerformed(.productInterval, let cached, let metadata) = result else {
            return XCTFail("Expected cooldown")
        }
        XCTAssertEqual(requests.get(), 0)
        XCTAssertEqual(cached?.source, .cache)
        XCTAssertNil(metadata.requestID)

        clock.set(validatedAt.addingTimeInterval(3_601))
        XCTAssertEqual(requests.get(), 0, "No timer or background request may run")
    }

    func testNoCredentialValidationRequiresBothCooldownGates() async throws {
        let store = MemoryCredentialStore()
        let clock = MutableClock(validatedAt.addingTimeInterval(10))
        setJSONResponse(data: validateData(state: [
            "kind": "activation_required",
            "trial": [
                "status": "unavailable", "reason": "not_enabled",
                "code": "TRIAL_NOT_ENABLED"
            ]
        ]))
        let client = makeClient(store: store, clock: clock)
        guard case .success(let first, _) = await client.validate(trigger: .silent) else {
            return XCTFail("Expected the first no-credential validation to reach the Server")
        }
        XCTAssertEqual(first.lastValidateResponseAt, clock.now())

        clock.set(validatedAt.addingTimeInterval(41))
        let requests = LockedBox(0)
        setHandler { _ in
            requests.mutate { $0 += 1 }
            return self.response(data: self.validateData(state: [
                "kind": "activation_required",
                "trial": [
                    "status": "unavailable", "reason": "not_enabled",
                    "code": "TRIAL_NOT_ENABLED"
                ]
            ]))
        }
        guard case .notPerformed(.productInterval, _, _) = await client.validate(trigger: .silent) else {
            return XCTFail("Passing 30 seconds alone must not bypass the configured interval")
        }
        XCTAssertEqual(requests.get(), 0)
    }

    func testUserInitiatedValidationBypassesProductIntervalButReportsThirtySeconds() async throws {
        let store = MemoryCredentialStore()
        try store.saveCredentials(opaqueCredentials(), for: fingerprint)
        try store.saveSnapshot(.init(
            subject: .license,
            snapshot: licenseSnapshot(validatedAt: validatedAt, interval: 3_600, lastValidateResponseAt: validatedAt),
            validatedBuild: currentBuild
        ), for: fingerprint)
        let requests = LockedBox(0)
        setHandler { _ in
            requests.mutate { $0 += 1 }
            return self.response(data: self.validateData(state: self.licenseState()))
        }
        let clock = MutableClock(validatedAt.addingTimeInterval(100))
        let client = makeClient(store: store, clock: clock)
        guard case .success = await client.validate(trigger: .userInitiated) else {
            return XCTFail("A user action must bypass the Product interval")
        }
        XCTAssertEqual(requests.get(), 1)

        clock.set(validatedAt.addingTimeInterval(120))
        guard case .notPerformed(.minimumInterval(let retryAfter), _, _) = await client.validate(trigger: .userInitiated) else {
            return XCTFail("A user action must still obey the minimum interval")
        }
        XCTAssertEqual(retryAfter, 10, accuracy: 0.001)
        XCTAssertEqual(NotPerformedReason.minimumInterval(retryAfter: retryAfter).code, "SDK_VALIDATION_MIN_INTERVAL")
        XCTAssertEqual(requests.get(), 1)

        clock.set(validatedAt.addingTimeInterval(131))
        guard case .success = await client.validate(trigger: .userInitiated) else {
            return XCTFail("User validation must retry after 30 seconds")
        }
        XCTAssertEqual(requests.get(), 2)
    }

    func testSilentProductIntervalHasDistinctCode() async throws {
        let store = MemoryCredentialStore()
        try store.saveCredentials(opaqueCredentials(), for: fingerprint)
        try store.saveSnapshot(.init(
            subject: .license,
            snapshot: licenseSnapshot(validatedAt: validatedAt, interval: 3_600, lastValidateResponseAt: validatedAt),
            validatedBuild: currentBuild
        ), for: fingerprint)
        let clock = MutableClock(validatedAt.addingTimeInterval(100))
        guard case .notPerformed(.productInterval(let nextEligibleAt), _, _) = await makeClient(
            store: store, clock: clock
        ).validate(trigger: .silent) else {
            return XCTFail("A routine silent call must follow the Product interval")
        }
        XCTAssertEqual(nextEligibleAt, validatedAt.addingTimeInterval(3_600))
        XCTAssertEqual(NotPerformedReason.productInterval(nextEligibleAt: nextEligibleAt).code, "SDK_VALIDATION_PRODUCT_INTERVAL")
    }

    func testMinimumIntervalStartsWhenRequestIsSentNotWhenResponseArrives() async throws {
        let store = MemoryCredentialStore()
        let clock = MutableClock(validatedAt.addingTimeInterval(100))
        let requests = LockedBox(0)
        setHandler { _ in
            requests.mutate { $0 += 1 }
            if requests.get() == 1 {
                clock.set(self.validatedAt.addingTimeInterval(125))
            }
            return self.response(data: self.validateData(state: [
                "kind": "activation_required",
                "trial": ["status": "unavailable", "reason": "not_enabled", "code": "TRIAL_NOT_ENABLED"]
            ]))
        }
        let client = makeClient(store: store, clock: clock)
        guard case .success = await client.validate(trigger: .userInitiated) else {
            return XCTFail("Expected first user request")
        }
        XCTAssertEqual(try store.loadValidationAttempt(for: fingerprint)?.startedAt, validatedAt.addingTimeInterval(100))
        clock.set(validatedAt.addingTimeInterval(131))
        guard case .success = await client.validate(trigger: .userInitiated) else {
            return XCTFail("The 30-second interval must not restart when the response arrives")
        }
        XCTAssertEqual(requests.get(), 2)
    }

    func testDifferentTriggerRechecksAfterConcurrentSilentSkip() async {
        let coordinator = OperationCoordinator()
        let silentStarted = expectation(description: "silent decision started")
        let releaseSilent = LockedBox<CheckedContinuation<Void, Never>?>(nil)
        let snapshot = licenseSnapshot(validatedAt: validatedAt, interval: 3_600)
        let nextEligibleAt = validatedAt.addingTimeInterval(3_600)
        let silent = Task {
            await coordinator.validate(trigger: .silent) {
                await withCheckedContinuation { continuation in
                    releaseSilent.set(continuation)
                    silentStarted.fulfill()
                }
                return .notPerformed(
                    reason: .productInterval(nextEligibleAt: nextEligibleAt),
                    cachedValue: snapshot,
                    metadata: OperationMetadata(source: .cache)
                )
            }
        }
        await fulfillment(of: [silentStarted], timeout: 1)
        let manual = Task {
            await coordinator.validate(trigger: .userInitiated) {
                .success(value: snapshot, metadata: OperationMetadata(source: .server))
            }
        }
        await Task.yield()
        releaseSilent.get()?.resume()
        _ = await silent.value
        guard case .success = await manual.value else {
            return XCTFail("A silent Product skip must not consume a user request")
        }
    }

    func testOpaqueLicenseExpiryBypassesProductIntervalOnceEvenAfterTimeout() async throws {
        let store = MemoryCredentialStore()
        try store.saveCredentials(opaqueCredentials(), for: fingerprint)
        let expiry = validatedAt.addingTimeInterval(100)
        let snapshot = EntitlementSnapshot(
            state: .license(.active(terms: LicenseTerms(maxActivations: 1, features: ["export"], updatesUntil: nil), expiresAt: expiry)),
            source: .server,
            validatedAt: validatedAt,
            receivedValidationInterval: 3_600,
            effectiveValidationInterval: 3_600,
            lastValidateResponseAt: validatedAt
        )
        try store.saveSnapshot(.init(subject: .license, snapshot: snapshot, validatedBuild: currentBuild), for: fingerprint)
        let requests = LockedBox(0)
        setHandler { _ in
            requests.mutate { $0 += 1 }
            throw URLError(.timedOut)
        }
        let clock = MutableClock(expiry.addingTimeInterval(1))
        let client = makeClient(store: store, clock: clock)
        XCTAssertFalse(snapshot.isUsable(at: clock.now()))
        guard case .failure(.transportError(.timeout, _), _, _) = await client.validate(trigger: .silent) else {
            return XCTFail("A newly expired opaque License must be checked early")
        }
        XCTAssertEqual(requests.get(), 1)
        clock.set(clock.now().addingTimeInterval(31))
        guard case .notPerformed(.productInterval, _, _) = await client.validate(trigger: .silent) else {
            return XCTFail("The same expiry must not trigger repeated silent requests")
        }
        XCTAssertEqual(requests.get(), 1)
    }

    func testReleaseChangeBypassesProductIntervalOnceForOpaqueLicense() async throws {
        let store = MemoryCredentialStore()
        try store.saveCredentials(opaqueCredentials(), for: fingerprint)
        try store.saveSnapshot(.init(
            subject: .license,
            snapshot: licenseSnapshot(validatedAt: validatedAt, interval: 3_600, lastValidateResponseAt: validatedAt),
            validatedBuild: .init(version: "2.3.0", platform: "macos", arch: "arm64")
        ), for: fingerprint)
        let requests = LockedBox(0)
        setHandler { _ in
            requests.mutate { $0 += 1 }
            throw URLError(.timedOut)
        }
        let clock = MutableClock(validatedAt.addingTimeInterval(100))
        let client = makeClient(store: store, clock: clock)
        guard case .failure(.transportError(.timeout, _), _, _) = await client.validate(trigger: .silent) else {
            return XCTFail("A new Release identity must be checked early")
        }
        XCTAssertEqual(requests.get(), 1)
        XCTAssertEqual(try store.loadValidationAttempt(for: fingerprint)?.build, currentBuild)
        clock.set(clock.now().addingTimeInterval(31))
        guard case .notPerformed(.productInterval, _, _) = await client.validate(trigger: .silent) else {
            return XCTFail("The same Release change must not trigger repeated silent requests")
        }
        XCTAssertEqual(requests.get(), 1)
    }

    func testLegacySnapshotWithoutBuildIdentityGetsOneEarlyReview() async throws {
        let store = MemoryCredentialStore()
        try store.saveCredentials(opaqueCredentials(), for: fingerprint)
        let old = licenseSnapshot(validatedAt: validatedAt, interval: 3_600, lastValidateResponseAt: validatedAt)
        let legacyData = try JSONEncoder().encode(StoredEntitlementSnapshot(subject: .license, snapshot: old))
        let decoded = try JSONDecoder().decode(StoredEntitlementSnapshot.self, from: legacyData)
        XCTAssertNil(decoded.validatedBuild)
        try store.saveSnapshot(decoded, for: fingerprint)
        let requests = LockedBox(0)
        setHandler { _ in
            requests.mutate { $0 += 1 }
            throw URLError(.timedOut)
        }
        let clock = MutableClock(validatedAt.addingTimeInterval(100))
        let client = makeClient(store: store, clock: clock)
        guard case .failure(.transportError(.timeout, _), _, _) = await client.validate(trigger: .silent) else {
            return XCTFail("An old snapshot needs one Release identity review")
        }
        clock.set(clock.now().addingTimeInterval(31))
        guard case .notPerformed(.productInterval, _, _) = await client.validate(trigger: .silent) else {
            return XCTFail("A failed legacy review must not repeat on every silent call")
        }
        XCTAssertEqual(requests.get(), 1)
    }

    func testValidationIntervalRejectsLegacyNullAndOutOfRangeValues() async {
        let state: [String: Any] = [
            "kind": "activation_required",
            "trial": [
                "status": "unavailable",
                "reason": "not_enabled",
                "code": "TRIAL_NOT_ENABLED"
            ]
        ]
        for interval: Any in [NSNull(), 3_599, 86_401] {
            setJSONResponse(data: validateData(state: state, interval: interval))
            guard case .failure(
                .transportError(.invalidResponse(let statusCode, _), _),
                _,
                _
            ) = await makeClient(store: MemoryCredentialStore()).validate(trigger: .silent),
            statusCode == 200 else {
                return XCTFail("Expected strict validation interval rejection")
            }
        }
    }

    func testConcurrentValidateSharesOneServerRequestAndResult() async throws {
        let requests = LockedBox(0)
        setHandler { _ in
            requests.mutate { $0 += 1 }
            Thread.sleep(forTimeInterval: 0.05)
            return self.response(data: self.validateData(state: [
                "kind": "activation_required",
                "trial": [
                    "status": "unavailable", "reason": "not_enabled",
                    "code": "TRIAL_NOT_ENABLED"
                ]
            ]))
        }
        let client = makeClient(store: MemoryCredentialStore())
        async let first = client.validate(trigger: .silent)
        async let second = client.validate(trigger: .silent)
        let results = await [first, second]
        XCTAssertEqual(requests.get(), 1)
        for result in results {
            guard case .success = result else { return XCTFail("Both callers must share success") }
        }
    }

    func testFailureDoesNotAdvanceSnapshotAndPreservesRawError() async throws {
        let store = MemoryCredentialStore()
        try store.saveCredentials(opaqueCredentials(), for: fingerprint)
        let old = licenseSnapshot(
            validatedAt: validatedAt,
            interval: 3_600,
            lastValidateResponseAt: validatedAt
        )
        try store.saveSnapshot(.init(subject: .license, snapshot: old, validatedBuild: currentBuild), for: fingerprint)
        setJSONError(status: 500, code: "DATABASE_UNAVAILABLE", requestID: "req_fail")
        let clock = MutableClock(validatedAt.addingTimeInterval(3_601))
        let result = await makeClient(store: store, clock: clock).validate(trigger: .silent)
        guard case .failure(let error, let lastKnown, let metadata) = result else {
            return XCTFail("Expected failure")
        }
        guard case .transportError(.server(_, let code, let requestID, _), _) = error else {
            return XCTFail("Expected server transport error")
        }
        XCTAssertEqual(code, "DATABASE_UNAVAILABLE")
        XCTAssertEqual(requestID, "req_fail")
        XCTAssertEqual(metadata.requestID, "req_fail")
        XCTAssertEqual(lastKnown?.validatedAt, validatedAt)
        XCTAssertEqual(lastKnown?.lastValidateResponseAt, clock.now())
        let stored = try XCTUnwrap(store.loadSnapshot(for: fingerprint)?.snapshot)
        XCTAssertEqual(stored.validatedAt, validatedAt)
        XCTAssertEqual(stored.lastValidateResponseAt, clock.now())

        let requests = LockedBox(0)
        setHandler { _ in
            requests.mutate { $0 += 1 }
            return self.response(data: self.validateData(state: self.licenseState()))
        }
        guard case .notPerformed(.minimumInterval, _, _) = await makeClient(
            store: store,
            clock: clock
        ).validate(trigger: .silent) else {
            return XCTFail("A definite HTTP failure must start the validate request cooldown")
        }
        XCTAssertEqual(requests.get(), 0)
    }

    func testTrialExpiryBypassesConfiguredIntervalOnce() async throws {
        let store = MemoryCredentialStore()
        try store.saveTrialCredentials(.init(trialID: "trl_1"), for: fingerprint)
        let expiry = validatedAt.addingTimeInterval(100)
        let snapshot = EntitlementSnapshot(
            state: .trial(.active(expiresAt: expiry, features: ["export"])),
            source: .server,
            validatedAt: validatedAt,
            receivedValidationInterval: 3_600,
            effectiveValidationInterval: 3_600,
            lastValidateResponseAt: validatedAt
        )
        try store.saveSnapshot(.init(subject: .trial, snapshot: snapshot, validatedBuild: currentBuild), for: fingerprint)
        let requests = LockedBox(0)
        setHandler { _ in
            requests.mutate { $0 += 1 }
            return self.response(data: self.validateData(state: [
                "kind": "trial", "status": "expired", "code": "TRIAL_EXPIRED",
                "expires_at": self.iso(expiry)
            ]))
        }
        let clock = MutableClock(expiry.addingTimeInterval(1))
        let client = makeClient(store: store, clock: clock)
        XCTAssertFalse(snapshot.hasFeature("export", at: clock.now()))
        XCTAssertEqual(requests.get(), 0)
        guard case .success(let confirmed, _) = await client.validate(trigger: .silent) else {
            return XCTFail("Trial expiry must trigger an early silent validation")
        }
        XCTAssertEqual(confirmed.businessCode, "TRIAL_EXPIRED")
        XCTAssertFalse(confirmed.isUsable(at: clock.now()))
        XCTAssertEqual(requests.get(), 1)
        clock.set(clock.now().addingTimeInterval(31))
        guard case .notPerformed(.productInterval, _, _) = await client.validate(trigger: .silent) else {
            return XCTFail("A confirmed expired Trial must not continuously bypass the Product interval")
        }
        XCTAssertEqual(requests.get(), 1)
    }

    func testActivationUsesServerTimeButFirstValidateStillRequests() async throws {
        let store = MemoryCredentialStore()
        try store.saveTrialCredentials(.init(trialID: "trl_old"), for: fingerprint)
        setJSONResponse(data: activationData())
        let client = makeClient(store: store)
        let activation = await client.activate(licenseKey: "LK")
        guard case .success(let data, let metadata) = activation else { return XCTFail("Expected activation") }
        XCTAssertEqual(data.snapshot.validatedAt, validatedAt)
        XCTAssertNil(data.snapshot.lastValidateResponseAt)
        XCTAssertEqual(metadata.requestID, "req_1")
        XCTAssertNil(try store.loadTrialCredentials(for: fingerprint))

        let requests = LockedBox(0)
        setHandler { _ in requests.mutate { $0 += 1 }; return self.response(data: self.validateData(state: self.licenseState())) }
        guard case .success = await client.validate(trigger: .silent) else {
            return XCTFail("Activation must not count as a validate response")
        }
        XCTAssertEqual(requests.get(), 1)
    }

    func testActivationRetryAfterCredentialWriteFailureUsesLicenseKeyAndFingerprint() async throws {
        let store = MemoryCredentialStore()
        store.failNextLicenseSave()
        let requests = LockedBox(0)
        setHandler { request in
            XCTAssertNil(try self.requestJSON(request)["machine_token"])
            XCTAssertEqual(try self.requestJSON(request)["fingerprint"] as? String, self.fingerprint)
            requests.mutate { $0 += 1 }
            return self.response(data: self.activationData(activationID: "act_reissued"))
        }
        guard case .failure(.credentialStorageError, _, _) = await makeClient(store: store).activate(licenseKey: "LK") else {
            return XCTFail("Expected the first credential write to fail")
        }
        guard case .success(let repeated, _) = await makeClient(store: store).activate(licenseKey: "LK") else {
            return XCTFail("Expected retry to receive the existing activation")
        }
        XCTAssertEqual(repeated.activationID, "act_reissued")
        XCTAssertEqual(requests.get(), 2)
        XCTAssertEqual(try store.loadCredentials(for: fingerprint)?.activationID, "act_reissued")
    }

    func testActivationRetryAfterLostResponseDoesNotRequireStoredVerificationToken() async throws {
        let store = MemoryCredentialStore()
        setHandler { request in
            XCTAssertNil(try self.requestJSON(request)["machine_token"])
            throw URLError(.networkConnectionLost)
        }
        guard case .failure(.transportError, _, _) = await makeClient(store: store).activate(licenseKey: "LK") else {
            return XCTFail("Expected the original response to be lost")
        }
        setHandler { request in
            XCTAssertTrue(request.url?.path.hasSuffix("/activate") == true)
            XCTAssertNil(try self.requestJSON(request)["machine_token"])
            return self.response(data: self.activationData(activationID: "act_reissued"))
        }
        guard case .success(let activation, _) = await makeClient(store: store).activate(licenseKey: "LK"),
              case .license(.active) = activation.snapshot.state else {
            return XCTFail("Expected activation retry to succeed")
        }
        XCTAssertEqual(try store.loadCredentials(for: fingerprint)?.activationID, "act_reissued")
    }

    func testValidateDoesNotActivateOrClaimTrial() async throws {
        let store = MemoryCredentialStore()
        setHandler { request in
            XCTAssertTrue(request.url?.path.hasSuffix("/validate") == true)
            let credential = try XCTUnwrap(self.requestJSON(request)["credential"] as? [String: Any])
            XCTAssertEqual(credential["kind"] as? String, "none")
            return self.response(data: self.validateData(state: [
                "kind": "activation_required",
                "trial": ["status": "unavailable", "reason": "not_enabled", "code": "TRIAL_NOT_ENABLED"]
            ]))
        }
        guard case .success = await makeClient(store: store).validate(trigger: .silent) else {
            return XCTFail("Expected validation without claiming a license or trial")
        }
    }

    func testStartTrialUsesServerTimeAndPersistsTrialID() async throws {
        let store = MemoryCredentialStore()
        setHandler { request in
            XCTAssertNil(try self.requestJSON(request)["trial_token"])
            return self.response(data: self.trialClaimData(trialID: "trl_1"))
        }
        let result = await makeClient(store: store).startTrial()
        guard case .success(let snapshot, let metadata) = result,
              case .trial(.active(let actualExpiry, let features)) = snapshot.state else {
            return XCTFail("Expected active Trial")
        }
        XCTAssertEqual(actualExpiry, validatedAt.addingTimeInterval(86_400))
        XCTAssertEqual(features, ["trial_export"])
        XCTAssertEqual(snapshot.validatedAt, validatedAt)
        XCTAssertNil(snapshot.lastValidateResponseAt)
        XCTAssertEqual(metadata.requestID, "req_trial")
        XCTAssertEqual(try store.loadTrialCredentials(for: fingerprint)?.trialID, "trl_1")
    }

    func testTrialRetryAfterCredentialWriteFailureUsesFingerprint() async throws {
        let store = MemoryCredentialStore()
        store.failNextTrialSave()
        let requests = LockedBox(0)
        setHandler { request in
            XCTAssertNil(try self.requestJSON(request)["trial_token"])
            requests.mutate { $0 += 1 }
            return self.response(data: self.trialClaimData())
        }
        guard case .failure(.credentialStorageError, _, _) = await makeClient(store: store).startTrial() else {
            return XCTFail("Expected the first Trial credential write to fail")
        }
        guard case .success = await makeClient(store: store).startTrial() else {
            return XCTFail("Expected retry to receive existing Trial")
        }
        XCTAssertEqual(requests.get(), 2)
        XCTAssertEqual(try store.loadTrialCredentials(for: fingerprint)?.trialID, "trl_reissued")
    }

    func testTrialRetryAfterLostResponseDoesNotRequireStoredToken() async throws {
        let store = MemoryCredentialStore()
        setHandler { request in
            XCTAssertNil(try self.requestJSON(request)["trial_token"])
            throw URLError(.networkConnectionLost)
        }
        guard case .failure(.transportError, _, _) = await makeClient(store: store).startTrial() else {
            return XCTFail("Expected lost Trial response")
        }
        setHandler { request in
            XCTAssertNil(try self.requestJSON(request)["trial_token"])
            return self.response(data: self.trialClaimData())
        }
        guard case .success = await makeClient(store: store).startTrial() else {
            return XCTFail("Expected retry to receive existing Trial")
        }
        XCTAssertEqual(try store.loadTrialCredentials(for: fingerprint)?.trialID, "trl_reissued")
    }

    func testOfflineGraceExceededRemainsUsableForOpaqueAndSignedLicenses() {
        let grace: TimeInterval = 2_592_000
        let graceExceededAt = validatedAt.addingTimeInterval(grace + 1)
        for signedCredentialValid in [nil, true] as [Bool?] {
            let snapshot = licenseSnapshot(
                validatedAt: validatedAt,
                interval: 3_600,
                offlineGracePeriod: grace,
                signedCredentialValid: signedCredentialValid
            )
            XCTAssertEqual(
                snapshot.freshness(at: graceExceededAt),
                .offlineGraceExceeded(since: validatedAt.addingTimeInterval(grace))
            )
            XCTAssertTrue(snapshot.isUsable(at: graceExceededAt))
            XCTAssertTrue(snapshot.hasFeature("export", at: graceExceededAt))
        }
    }

    func testServerIntervalIsPreservedWithinContractRange() async throws {
        for received in [3_600.0, 86_400.0] {
            setJSONResponse(data: validateData(
                state: [
                    "kind": "activation_required",
                    "trial": [
                        "status": "unavailable", "reason": "not_enabled",
                        "code": "TRIAL_NOT_ENABLED"
                    ]
                ],
                interval: received
            ))
            let result = await makeClient(store: MemoryCredentialStore()).validate(trigger: .silent)
            guard case .success(let snapshot, let metadata) = result else {
                return XCTFail("Expected interval response")
            }
            XCTAssertEqual(snapshot.receivedValidationInterval, received)
            XCTAssertEqual(snapshot.effectiveValidationInterval, received)
            XCTAssertEqual(metadata.receivedValidationInterval, received)
            XCTAssertEqual(metadata.effectiveValidationInterval, received)
        }
    }

    func testClockRollbackKeepsValidateInCooldown() async throws {
        let store = MemoryCredentialStore()
        try store.saveCredentials(opaqueCredentials(), for: fingerprint)
        try store.saveSnapshot(
            .init(subject: .license, snapshot: licenseSnapshot(
                validatedAt: validatedAt,
                interval: 3_600,
                lastValidateResponseAt: validatedAt
            ), validatedBuild: currentBuild),
            for: fingerprint
        )
        let requests = LockedBox(0)
        setHandler { _ in
            requests.mutate { $0 += 1 }
            return self.response(data: self.validateData(state: self.licenseState()))
        }
        let clock = MutableClock(validatedAt.addingTimeInterval(-0.001))
        guard case .notPerformed(.minimumInterval, _, _) = await makeClient(
            store: store,
            clock: clock
        ).validate(trigger: .silent) else {
            return XCTFail("A backward wall clock must not defeat the request throttle")
        }
        XCTAssertEqual(requests.get(), 0)
    }

    func testActiveValidateRejectsCredentialModeChange() async throws {
        let store = MemoryCredentialStore()
        try store.saveCredentials(opaqueCredentials(), for: fingerprint)
        var data = validateData(state: licenseState())
        data["credential_update"] = [
            "credential_mode": "signed",
            "signed_license_token": "invalid",
            "signing_key_id": "key_1"
        ]
        setJSONResponse(data: data)
        let result = await makeClient(store: store).validate(trigger: .silent)
        guard case .failure(.protocolError(let reason), _, let metadata) = result else {
            return XCTFail("Expected mode-change protocol failure")
        }
        XCTAssertTrue(reason.contains("cannot change"))
        XCTAssertEqual(metadata.requestID, "req_1")
        XCTAssertEqual(try store.loadCredentials(for: fingerprint)?.credentialMode, .opaque)
    }

    func testPermanentLicenseStillValidatesAfterCooldown() async throws {
        let store = MemoryCredentialStore()
        try store.saveCredentials(opaqueCredentials(), for: fingerprint)
        try store.saveSnapshot(
            .init(subject: .license, snapshot: licenseSnapshot(
                validatedAt: validatedAt,
                interval: 3_600,
                lastValidateResponseAt: validatedAt
            ), validatedBuild: currentBuild),
            for: fingerprint
        )
        let requests = LockedBox(0)
        setHandler { _ in requests.mutate { $0 += 1 }; return self.response(data: self.validateData(state: self.licenseState())) }
        let clock = MutableClock(validatedAt.addingTimeInterval(3_601))
        guard case .success = await makeClient(store: store, clock: clock).validate(trigger: .silent) else {
            return XCTFail("Expected online validation")
        }
        XCTAssertEqual(requests.get(), 1)
    }

    func testValidSignedCredentialStillRequiresConfiguredInterval() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let token = try makeToken(privateKey: key)
        let store = MemoryCredentialStore()
        try store.saveCredentials(
            signedCredentials(token: token),
            for: fingerprint
        )
        try store.saveSnapshot(
            .init(subject: .license, snapshot: licenseSnapshot(
                validatedAt: validatedAt,
                interval: 3_600,
                lastValidateResponseAt: validatedAt,
                signedCredentialValid: true
            ), validatedBuild: currentBuild),
            for: fingerprint
        )
        let requests = LockedBox(0)
        setHandler { _ in
            requests.mutate { $0 += 1 }
            return self.response(data: self.validateData(state: self.licenseState()))
        }
        let clock = MutableClock(validatedAt.addingTimeInterval(100))
        let result = await makeClient(
            store: store,
            clock: clock,
            signingPublicKey: key.publicKey.rawRepresentation.base64EncodedString()
        ).validate(trigger: .silent)
        guard case .notPerformed(.productInterval, let cached, _) = result else {
            return XCTFail("A valid Signed License must obey the configured interval")
        }
        XCTAssertEqual(cached?.source, .signedLocal)
        XCTAssertEqual(cached?.signedCredentialValid, true)
        XCTAssertEqual(requests.get(), 0)
    }

    func testSignedCredentialHasNoIndependentExpiry() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let token = try makeToken(privateKey: key)
        let store = MemoryCredentialStore()
        try store.saveCredentials(
            signedCredentials(token: token),
            for: fingerprint
        )
        try store.saveSnapshot(
            .init(subject: .license, snapshot: licenseSnapshot(
                validatedAt: validatedAt,
                interval: 86_400,
                lastValidateResponseAt: validatedAt,
                signedCredentialValid: true
            ), validatedBuild: currentBuild),
            for: fingerprint
        )
        let clock = MutableClock(validatedAt.addingTimeInterval(7_200))
        let requests = LockedBox(0)
        setHandler { _ in
            requests.mutate { $0 += 1 }
            return self.response(data: self.validateData(state: self.licenseState()))
        }
        let client = makeClient(
            store: store,
            clock: clock,
            signingPublicKey: key.publicKey.rawRepresentation.base64EncodedString()
        )
        guard case .notPerformed(.productInterval, let cached, _) = await client.validate(trigger: .silent) else {
            return XCTFail("Signed credentials must not acquire an independent expiry")
        }
        XCTAssertEqual(cached?.source, .signedLocal)
        XCTAssertEqual(cached?.signedCredentialValid, true)
        XCTAssertEqual(requests.get(), 0)
    }

    func testExpiredSignedActiveCacheCanReachServerForBothValidationTriggers() async throws {
        for trigger in [ValidationTrigger.silent, .userInitiated] {
            let key = Curve25519.Signing.PrivateKey()
            let expiry = validatedAt.addingTimeInterval(100)
            let token = try makeToken(privateKey: key, licenseExpiresAt: expiry)
            let store = MemoryCredentialStore()
            try store.saveCredentials(signedCredentials(token: token), for: fingerprint)
            let active = EntitlementSnapshot(
                state: .license(.active(
                    terms: LicenseTerms(maxActivations: 1, features: ["export"], updatesUntil: nil),
                    expiresAt: expiry
                )),
                source: .server, validatedAt: validatedAt,
                receivedValidationInterval: 3_600, effectiveValidationInterval: 3_600,
                lastValidateResponseAt: validatedAt, signedCredentialValid: true
            )
            try store.saveSnapshot(.init(subject: .license, snapshot: active, validatedBuild: currentBuild), for: fingerprint)
            let clock = MutableClock(expiry.addingTimeInterval(1))
            let requests = LockedBox(0)
            setHandler { _ in
                requests.mutate { $0 += 1 }
                return self.response(data: self.validateData(state: [
                    "kind": "license", "status": "expired", "code": "LICENSE_EXPIRED",
                    "expires_at": self.iso(expiry)
                ]))
            }
            let client = makeClient(
                store: store, clock: clock,
                signingPublicKey: key.publicKey.rawRepresentation.base64EncodedString()
            )
            let localResult = await client.restoreLocalEntitlement()
            XCTAssertEqual(localResult, .verificationRequired(reason: .expired))
            guard case .success(let confirmed, _) = await client.validate(trigger: trigger),
                  case .license(.expired(let returnedExpiry)) = confirmed.state else {
                return XCTFail("An elapsed signed cache must reach the Server")
            }
            XCTAssertEqual(returnedExpiry, expiry)
            XCTAssertEqual(requests.get(), 1)
        }
    }

    func testExpiredSignedCacheStillRejectsRealClaimMismatchBeforeRequest() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let expiry = validatedAt.addingTimeInterval(100)
        let token = try makeToken(privateKey: key, features: ["other"], licenseExpiresAt: expiry)
        let store = MemoryCredentialStore()
        try store.saveCredentials(signedCredentials(token: token), for: fingerprint)
        let active = EntitlementSnapshot(
            state: .license(.active(
                terms: LicenseTerms(maxActivations: 1, features: ["export"], updatesUntil: nil),
                expiresAt: expiry
            )),
            source: .server, validatedAt: validatedAt,
            receivedValidationInterval: 3_600, effectiveValidationInterval: 3_600,
            lastValidateResponseAt: validatedAt, signedCredentialValid: true
        )
        try store.saveSnapshot(.init(subject: .license, snapshot: active, validatedBuild: currentBuild), for: fingerprint)
        let requests = LockedBox(0)
        setHandler { _ in
            requests.mutate { $0 += 1 }
            throw URLError(.notConnectedToInternet)
        }
        let result = await makeClient(
            store: store,
            clock: MutableClock(expiry.addingTimeInterval(1)),
            signingPublicKey: key.publicKey.rawRepresentation.base64EncodedString()
        ).validate(trigger: .silent)
        guard case .failure(.protocolError(let reason), _, _) = result else {
            return XCTFail("A true claims mismatch must retain its protocol error")
        }
        XCTAssertTrue(reason.contains("signed claims"))
        XCTAssertEqual(requests.get(), 0)
    }

    func testLocalSignedRestorationRejectsInvalidSignatureButRestoresServerBlockedState() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let otherKey = Curve25519.Signing.PrivateKey()
        let token = try makeToken(privateKey: key)
        let store = MemoryCredentialStore()
        try store.saveCredentials(signedCredentials(token: token), for: fingerprint)
        try store.saveSnapshot(
            .init(subject: .license, snapshot: licenseSnapshot(
                validatedAt: validatedAt, interval: 3_600, signedCredentialValid: true
            )),
            for: fingerprint
        )
        let invalid = await makeClient(
            store: store,
            signingPublicKey: otherKey.publicKey.rawRepresentation.base64EncodedString()
        ).restoreLocalEntitlement()
        guard case .verificationRequired(.invalidCredential(.invalidSignedLicenseToken)) = invalid else {
            return XCTFail("An invalid signature cannot authorize local access")
        }

        let blocked = EntitlementSnapshot(
            state: .license(.suspended(reason: "payment")), source: .server,
            validatedAt: validatedAt, receivedValidationInterval: 3_600,
            effectiveValidationInterval: 3_600, signedCredentialValid: true
        )
        try store.saveSnapshot(.init(subject: .license, snapshot: blocked), for: fingerprint)
        guard case .confirmedBlocked(let restored) = await makeClient(
            store: store,
            signingPublicKey: key.publicKey.rawRepresentation.base64EncodedString()
        ).restoreLocalEntitlement() else {
            return XCTFail("A valid signed credential must not hide a confirmed Server block")
        }
        XCTAssertEqual(restored.state, blocked.state)
    }

    func testInvalidSignedCredentialBypassesConfiguredIntervalButNotThirtySeconds() async throws {
        let signingKey = Curve25519.Signing.PrivateKey()
        let unrelatedKey = Curve25519.Signing.PrivateKey()
        let token = try makeToken(privateKey: signingKey)
        let store = MemoryCredentialStore()
        try store.saveCredentials(
            signedCredentials(token: token),
            for: fingerprint
        )
        try store.saveSnapshot(
            .init(subject: .license, snapshot: licenseSnapshot(
                validatedAt: validatedAt,
                interval: 3_600,
                lastValidateResponseAt: validatedAt,
                signedCredentialValid: true
            ), validatedBuild: currentBuild),
            for: fingerprint
        )
        let clock = MutableClock(validatedAt.addingTimeInterval(20))
        let requests = LockedBox(0)
        setHandler { _ in
            requests.mutate { $0 += 1 }
            throw URLError(.notConnectedToInternet)
        }
        let client = makeClient(
            store: store,
            clock: clock,
            signingPublicKey: unrelatedKey.publicKey.rawRepresentation.base64EncodedString()
        )
        guard case .notPerformed(.minimumInterval, let cached, _) = await client.validate(trigger: .silent) else {
            return XCTFail("A locally invalid signature must still obey the 30-second throttle")
        }
        XCTAssertEqual(cached?.signedCredentialValid, false)
        XCTAssertEqual(requests.get(), 0)

        clock.set(validatedAt.addingTimeInterval(31))
        guard case .failure = await client.validate(trigger: .silent) else {
            return XCTFail("A locally invalid signature may request after 30 seconds")
        }
        XCTAssertEqual(requests.get(), 1)
    }

    func testMissingSigningKeyKeepsConfigurationErrorWithoutOnlineRetry() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let store = MemoryCredentialStore()
        try store.saveCredentials(signedCredentials(token: try makeToken(privateKey: key)), for: fingerprint)
        try store.saveSnapshot(.init(
            subject: .license,
            snapshot: licenseSnapshot(
                validatedAt: validatedAt,
                interval: 3_600,
                lastValidateResponseAt: validatedAt,
                signedCredentialValid: true
            ),
            validatedBuild: currentBuild
        ), for: fingerprint)
        let requests = LockedBox(0)
        setHandler { _ in
            requests.mutate { $0 += 1 }
            return self.response(data: self.validateData(state: self.licenseState()))
        }
        let clock = MutableClock(validatedAt.addingTimeInterval(100))
        guard case .failure(.missingSigningPublicKey, let lastKnown, _) = await makeClient(
            store: store, clock: clock
        ).validate(trigger: .silent) else {
            return XCTFail("A missing trusted key is a local configuration error")
        }
        XCTAssertEqual(lastKnown?.signedCredentialValid, false)
        XCTAssertFalse(lastKnown?.isUsable(at: clock.now()) ?? true)
        XCTAssertEqual(requests.get(), 0)
    }

    func testHTTP401StartsFullConfiguredCooldownForValidSignedCredential() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let token = try makeToken(privateKey: key)
        let store = MemoryCredentialStore()
        try store.saveCredentials(
            signedCredentials(token: token),
            for: fingerprint
        )
        try store.saveSnapshot(
            .init(subject: .license, snapshot: licenseSnapshot(
                validatedAt: validatedAt,
                interval: 3_600,
                lastValidateResponseAt: validatedAt,
                signedCredentialValid: true
            ), validatedBuild: currentBuild),
            for: fingerprint
        )
        let clock = MutableClock(validatedAt.addingTimeInterval(3_601))
        setJSONError(status: 401, code: "MACHINE_TOKEN_INVALID", requestID: "req_signed_401")
        let client = makeClient(
            store: store,
            clock: clock,
            signingPublicKey: key.publicKey.rawRepresentation.base64EncodedString()
        )
        guard case .failure(.apiError(let status, let code, _, let requestID, _), _, _) = await client.validate(trigger: .silent) else {
            return XCTFail("Expected HTTP 401 API failure")
        }
        XCTAssertEqual(status, 401)
        XCTAssertEqual(code, "MACHINE_TOKEN_INVALID")
        XCTAssertEqual(requestID, "req_signed_401")
        XCTAssertEqual(
            try store.loadSnapshot(for: fingerprint)?.snapshot.lastValidateResponseAt,
            clock.now()
        )

        clock.set(validatedAt.addingTimeInterval(3_632))
        let requests = LockedBox(0)
        setHandler { _ in
            requests.mutate { $0 += 1 }
            throw URLError(.notConnectedToInternet)
        }
        guard case .notPerformed(.productInterval, let cached, _) = await client.validate(trigger: .silent) else {
            return XCTFail("HTTP 401 must start the full configured interval for a valid Signed Token")
        }
        XCTAssertEqual(cached?.signedCredentialValid, true)
        XCTAssertEqual(requests.get(), 0)
    }

    func testSignedTokenRejectsLegacyExpAndStateMustMatchVerifiedClaims() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let signingPublicKey = key.publicKey.rawRepresentation.base64EncodedString()
        let exp = validatedAt.addingTimeInterval(7_200)
        let legacyToken = try makeToken(
            privateKey: key,
            features: ["export"],
            legacyExpirationClaim: exp
        )
        let store = MemoryCredentialStore()
        setJSONResponse(data: activationData(
            mode: "signed", token: legacyToken, keyID: "key_1"
        ))
        let first = await makeClient(store: store, signingPublicKey: signingPublicKey).activate(licenseKey: "LK")
        guard case .failure(.invalidSignedLicenseToken(let reason), _, let metadata) = first else {
            return XCTFail("Expected legacy exp rejection")
        }
        XCTAssertTrue(reason.contains("unsupported claims"))
        XCTAssertEqual(metadata.requestID, "req_1")
        XCTAssertNil(try store.loadCredentials(for: fingerprint))

        let token = try makeToken(privateKey: key, features: ["export"])
        let mismatchedState = activationData(
            mode: "signed", token: token, keyID: "key_1",
            stateFeatures: ["different"]
        )
        setJSONResponse(data: mismatchedState)
        let second = await makeClient(store: store, signingPublicKey: signingPublicKey).activate(licenseKey: "LK")
        guard case .failure(.protocolError(let reason), _, _) = second else {
            return XCTFail("Expected signed state mismatch failure")
        }
        XCTAssertTrue(reason.contains("signed claims"))
        XCTAssertNil(try store.loadCredentials(for: fingerprint))
    }

    func testSignedTokenRejectsLegacyTenantClaimAndProductMismatch() throws {
        let key = Curve25519.Signing.PrivateKey()
        let verifier = Ed25519Verifier()
        let legacy = try makeToken(
            privateKey: key,
            legacyAccountClaim: true
        )
        XCTAssertThrowsError(try verifier.verifyAndDecodeToken(
            token: legacy,
            signingPublicKey: key.publicKey.rawRepresentation.base64EncodedString()
        ))

        let claims = LicenseClaims(
            licenseID: "lic_1", activationID: "act_1", instanceID: "ins_other",
            productID: "prd_other", releaseVersion: "2.4.0",
            releasePlatform: "macos", releaseArch: "arm64",
            fingerprint: fingerprint, issuedAtTimestamp: Int64(validatedAt.timeIntervalSince1970),
            licenseExpiresAtTimestamp: nil, updatesUntilTimestamp: nil, features: ["export"]
        )
        XCTAssertThrowsError(try ClaimsEvaluator().evaluate(
            claims: claims,
            configuration: configuration(signingPublicKey: nil),
            activationID: "act_1",
            currentFingerprint: fingerprint,
            now: validatedAt
        ))
    }

    func testSignedLicenseEnvironmentRejectsSandboxInLiveAndPreservesLegacyLiveClaims() throws {
        let sandboxClaims = LicenseClaims(
            licenseID: "lic_1", activationID: "act_1", instanceID: "ins_1",
            productID: "prd_1", environment: .sandbox, releaseVersion: "2.4.0",
            releasePlatform: "macos", releaseArch: "arm64", fingerprint: fingerprint,
            issuedAtTimestamp: Int64(validatedAt.timeIntervalSince1970),
            licenseExpiresAtTimestamp: nil, updatesUntilTimestamp: nil, features: ["export"]
        )
        let evaluator = ClaimsEvaluator()
        XCTAssertThrowsError(try evaluator.evaluate(
            claims: sandboxClaims, configuration: configuration(signingPublicKey: nil),
            activationID: "act_1", currentFingerprint: fingerprint, now: validatedAt
        ))
        XCTAssertNoThrow(try evaluator.evaluate(
            claims: sandboxClaims, configuration: configuration(signingPublicKey: nil, environment: .sandbox),
            activationID: "act_1", currentFingerprint: fingerprint, now: validatedAt
        ))
        let legacyLiveClaims = LicenseClaims(
            licenseID: "lic_1", activationID: "act_1", instanceID: "ins_1",
            productID: "prd_1", releaseVersion: "2.4.0", releasePlatform: "macos",
            releaseArch: "arm64", fingerprint: fingerprint,
            issuedAtTimestamp: Int64(validatedAt.timeIntervalSince1970),
            licenseExpiresAtTimestamp: nil, updatesUntilTimestamp: nil, features: ["export"]
        )
        XCTAssertNoThrow(try evaluator.evaluate(
            claims: legacyLiveClaims, configuration: configuration(signingPublicKey: nil),
            activationID: "act_1", currentFingerprint: fingerprint, now: validatedAt
        ))
        XCTAssertThrowsError(try evaluator.evaluate(
            claims: legacyLiveClaims, configuration: configuration(signingPublicKey: nil, environment: .sandbox),
            activationID: "act_1", currentFingerprint: fingerprint, now: validatedAt
        ))
    }

    func testOpaqueSandboxCredentialCannotRestoreOrValidateInLiveConfiguration() async throws {
        let store = MemoryCredentialStore()
        try store.saveCredentials(.init(
            activationID: "act_1", credentialMode: .opaque,
            signedLicenseToken: nil, signingKeyID: nil, environment: .sandbox
        ), for: fingerprint)
        let requests = LockedBox(0)
        setHandler { _ in
            requests.mutate { $0 += 1 }
            throw URLError(.notConnectedToInternet)
        }
        let client = makeClient(store: store)
        guard case .verificationRequired(.invalidCredential) = await client.restoreLocalEntitlement() else {
            return XCTFail("Live restoration must reject a stored Sandbox credential")
        }
        guard case .failure(.protocolError, _, _) = await client.validate(trigger: .userInitiated) else {
            return XCTFail("Live validation must reject a stored Sandbox credential")
        }
        XCTAssertEqual(requests.get(), 0)
    }

    func testMalformedResponsePreservesHeaderRequestID() async throws {
        let store = MemoryCredentialStore()
        let clock = MutableClock(validatedAt.addingTimeInterval(10))
        setHandler { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json", "X-Request-ID": "req_header"]
            )!
            return (response, Data("not-json".utf8))
        }
        let result = await makeClient(store: store, clock: clock).validate(trigger: .silent)
        guard case .failure(.transportError(.invalidResponse(_, let requestID), _), _, let metadata) = result else {
            return XCTFail("Expected invalid response")
        }
        XCTAssertEqual(requestID, "req_header")
        XCTAssertEqual(metadata.requestID, "req_header")
        XCTAssertNil(try store.loadSnapshot(for: fingerprint))

        let requests = LockedBox(0)
        setHandler { _ in
            requests.mutate { $0 += 1 }
            return self.response(data: self.validateData(state: [
                "kind": "activation_required",
                "trial": [
                    "status": "unavailable", "reason": "not_enabled",
                    "code": "TRIAL_NOT_ENABLED"
                ]
            ]))
        }
        guard case .notPerformed(.minimumInterval, _, _) = await makeClient(store: store, clock: clock).validate(trigger: .silent) else {
            return XCTFail("Malformed HTTP 2xx data must still count as a request attempt")
        }
        XCTAssertEqual(requests.get(), 0)
        clock.set(clock.now().addingTimeInterval(31))
        guard case .success = await makeClient(store: store, clock: clock).validate(trigger: .silent) else {
            return XCTFail("Malformed HTTP 2xx data must not start the Product interval")
        }
        XCTAssertEqual(requests.get(), 1)
    }

    func testMalformedHTTPFailurePreservesDiagnosticsAndStartsCooldown() async throws {
        let store = MemoryCredentialStore()
        let clock = MutableClock(validatedAt.addingTimeInterval(10))
        setHandler { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 401, httpVersion: nil,
                headerFields: ["Content-Type": "text/plain", "X-Request-ID": "req_401"]
            )!
            return (response, Data("not-json".utf8))
        }
        let result = await makeClient(store: store, clock: clock).validate(trigger: .silent)
        guard case .failure(
            .transportError(.invalidResponse(let status, let requestID), _),
            let lastKnown,
            let metadata
        ) = result else {
            return XCTFail("Expected malformed HTTP failure diagnostics")
        }
        XCTAssertEqual(status, 401)
        XCTAssertEqual(requestID, "req_401")
        XCTAssertEqual(metadata.requestID, "req_401")
        XCTAssertNil(lastKnown?.validatedAt)
        XCTAssertEqual(lastKnown?.lastValidateResponseAt, clock.now())
        XCTAssertEqual(
            try store.loadSnapshot(for: fingerprint)?.snapshot.lastValidateResponseAt,
            clock.now()
        )
    }

    func testAPIHTTPFailurePreservesRawFieldsAndStartsCooldown() async throws {
        let store = MemoryCredentialStore()
        let clock = MutableClock(validatedAt.addingTimeInterval(10))
        setJSONError(status: 403, code: "LICENSE_SCOPE_DENIED", requestID: "req_403")
        let result = await makeClient(store: store, clock: clock).validate(trigger: .silent)
        guard case .failure(
            .apiError(let status, let code, _, let requestID, let details),
            let lastKnown,
            _
        ) = result else {
            return XCTFail("Expected structured API failure")
        }
        XCTAssertEqual(status, 403)
        XCTAssertEqual(code, "LICENSE_SCOPE_DENIED")
        XCTAssertEqual(requestID, "req_403")
        XCTAssertEqual(details, [:])
        XCTAssertNil(lastKnown?.validatedAt)
        XCTAssertEqual(lastKnown?.lastValidateResponseAt, clock.now())

        let requests = LockedBox(0)
        setHandler { _ in
            requests.mutate { $0 += 1 }
            return self.response(data: self.validateData(state: [
                "kind": "activation_required",
                "trial": [
                    "status": "unavailable", "reason": "not_enabled",
                    "code": "TRIAL_NOT_ENABLED"
                ]
            ]))
        }
        clock.set(validatedAt.addingTimeInterval(41))
        guard case .notPerformed(.productInterval, _, _) = await makeClient(
            store: store,
            clock: clock
        ).validate(trigger: .silent) else {
            return XCTFail("An HTTP 403 must start the full configured cooldown")
        }
        XCTAssertEqual(requests.get(), 0)
    }

    func testHTTP429StartsCooldownAndRemainsRateLimited() async throws {
        let store = MemoryCredentialStore()
        let clock = MutableClock(validatedAt.addingTimeInterval(10))
        setJSONError(status: 429, code: "RATE_LIMITED", requestID: "req_429")
        let result = await makeClient(store: store, clock: clock).validate(trigger: .silent)
        guard case .failure(let error, let lastKnown, let metadata) = result else {
            return XCTFail("Expected HTTP 429 failure")
        }
        XCTAssertTrue(error.isRateLimited)
        XCTAssertEqual(error.requestID, "req_429")
        XCTAssertNil(lastKnown?.validatedAt)
        XCTAssertEqual(lastKnown?.lastValidateResponseAt, clock.now())
        XCTAssertEqual(metadata.lastValidateResponseAt, clock.now())
    }

    func testTimeoutStartsMinimumIntervalButNotProductInterval() async throws {
        let store = MemoryCredentialStore()
        let clock = MutableClock(validatedAt.addingTimeInterval(10))
        setHandler { _ in throw URLError(.timedOut) }
        guard case .failure(.transportError(.timeout, _), _, _) = await makeClient(
            store: store,
            clock: clock
        ).validate(trigger: .silent) else {
            return XCTFail("Expected timeout failure")
        }
        XCTAssertNil(try store.loadSnapshot(for: fingerprint))

        let requests = LockedBox(0)
        setHandler { _ in
            requests.mutate { $0 += 1 }
            return self.response(data: self.validateData(state: [
                "kind": "activation_required",
                "trial": [
                    "status": "unavailable", "reason": "not_enabled",
                    "code": "TRIAL_NOT_ENABLED"
                ]
            ]))
        }
        guard case .notPerformed(.minimumInterval, _, _) = await makeClient(store: store, clock: clock).validate(trigger: .silent) else {
            return XCTFail("A timeout still counts as a request attempt")
        }
        XCTAssertEqual(requests.get(), 0)
        clock.set(clock.now().addingTimeInterval(31))
        guard case .success = await makeClient(store: store, clock: clock).validate(trigger: .silent) else {
            return XCTFail("A timeout must not start the Product interval")
        }
        XCTAssertEqual(requests.get(), 1)
    }

    func testLegalValidateResponseRecordsCooldownEvenWhenCredentialSaveFails() async throws {
        let store = MemoryCredentialStore()
        try store.saveCredentials(opaqueCredentials(), for: fingerprint)
        let oldValidatedAt = validatedAt.addingTimeInterval(-7_200)
        try store.saveSnapshot(
            .init(subject: .license, snapshot: licenseSnapshot(
                validatedAt: oldValidatedAt,
                interval: 3_600,
                lastValidateResponseAt: oldValidatedAt
            ), validatedBuild: currentBuild),
            for: fingerprint
        )
        store.failNextLicenseSave()
        setJSONResponse(data: validateData(state: licenseState()))
        let clock = MutableClock(validatedAt.addingTimeInterval(10))
        let result = await makeClient(store: store, clock: clock).validate(trigger: .silent)
        guard case .failure(
            .credentialStorageError(let operation, let status),
            let lastKnown,
            let metadata
        ) = result else {
            return XCTFail("Expected the original credential storage error")
        }
        XCTAssertEqual(operation, "write")
        XCTAssertEqual(status, -1)
        XCTAssertEqual(lastKnown?.validatedAt, validatedAt)
        XCTAssertEqual(lastKnown?.lastValidateResponseAt, clock.now())
        XCTAssertEqual(metadata.lastValidateResponseAt, clock.now())
        XCTAssertEqual(
            try store.loadSnapshot(for: fingerprint)?.snapshot.lastValidateResponseAt,
            clock.now()
        )
    }

    func testStateWritesSerializeValidateThenDeactivate() async throws {
        let store = MemoryCredentialStore()
        try store.saveCredentials(opaqueCredentials(), for: fingerprint)
        let validationStarted = expectation(description: "validation started")
        let releaseValidation = DispatchSemaphore(value: 0)
        setHandler { request in
            if request.url!.path.hasSuffix("/validate") {
                validationStarted.fulfill()
                _ = releaseValidation.wait(timeout: .now() + 2)
                return self.response(data: self.validateData(state: self.licenseState()))
            }
            return self.response(data: [
                "activation_id": "act_1", "status": "deactivated",
                "meta": ["request_id": "req_deactivate"]
            ])
        }
        let client = makeClient(store: store)
        let validation = Task { await client.validate(trigger: .silent) }
        await fulfillment(of: [validationStarted], timeout: 1)
        let deactivation = Task { await client.deactivate() }
        releaseValidation.signal()
        _ = await validation.value
        guard case .success(let data, _) = await deactivation.value else {
            return XCTFail("Expected deactivation")
        }
        XCTAssertTrue(data.wasDeactivated)
        XCTAssertNil(try store.loadCredentials(for: fingerprint), "Old validation must not revive credentials")
        XCTAssertEqual(
            try store.loadSnapshot(for: fingerprint)?.subject,
            StoredCredentialSubject.none
        )
        guard case .confirmedBlocked(let restored) = await makeClient(store: store).restoreLocalEntitlement() else {
            return XCTFail("A confirmed remote deactivation must restore as blocked after restart")
        }
        XCTAssertEqual(restored.source, .local)
        guard case .success(let repeated, _) = await client.deactivate() else {
            return XCTFail("A repeated local no-op must preserve the confirmed deactivation record")
        }
        XCTAssertFalse(repeated.wasDeactivated)
        guard case .confirmedBlocked = await makeClient(store: store).restoreLocalEntitlement() else {
            return XCTFail("A repeated no-op must not erase the prior remote confirmation")
        }
    }

    func testDeactivationReportsRemoteConfirmationAndRecoversAfterLocalFailures() async throws {
        for failingStage in [DeactivationRepairStage.clearCredential, .saveSnapshot] {
            let store = MemoryCredentialStore()
            try store.saveCredentials(opaqueCredentials(), for: fingerprint)
            try store.saveSnapshot(
                .init(subject: .license, snapshot: licenseSnapshot(validatedAt: validatedAt, interval: 3_600)),
                for: fingerprint
            )
            switch failingStage {
            case .clearCredential: store.failNextLicenseClear()
            case .saveSnapshot: store.failNextSnapshotSave()
            default: return XCTFail("Unexpected test stage")
            }
            let requests = LockedBox(0)
            setHandler { _ in
                requests.mutate { $0 += 1 }
                return self.response(data: [
                    "activation_id": "act_1", "status": "deactivated",
                    "meta": ["request_id": "req_deactivate"]
                ])
            }
            let client = makeClient(store: store)
            guard case .remoteConfirmedLocalRepairRequired(
                let stage, .credentialStorageError, let metadata
            ) = await client.deactivate() else {
                return XCTFail("Remote confirmation and local failure must both be explicit")
            }
            XCTAssertEqual(stage, failingStage)
            XCTAssertEqual(metadata.requestID, "req_deactivate")
            XCTAssertEqual(requests.get(), 1)
            XCTAssertEqual(try store.loadDeactivationAttempt(for: fingerprint)?.phase, .confirmed)
            XCTAssertFalse(client.currentSnapshot?.isUsable(at: validatedAt) ?? true)

            let restarted = makeClient(store: store)
            let local = await restarted.restoreLocalEntitlement()
            XCTAssertEqual(local, .verificationRequired(reason: .deactivationPending(phase: .confirmed)))
            guard case .success(let completed, let recoveredMetadata) = await restarted.deactivate() else {
                return XCTFail("Retry must finish local cleanup without repeating confirmed remote work")
            }
            XCTAssertTrue(completed.wasDeactivated)
            XCTAssertEqual(recoveredMetadata.requestID, "req_deactivate")
            XCTAssertEqual(requests.get(), 1)
            XCTAssertNil(try store.loadCredentials(for: fingerprint))
            XCTAssertNil(try store.loadDeactivationAttempt(for: fingerprint))
        }
    }

    func testDeactivationRetriesWhenRecordingRemoteConfirmationFails() async throws {
        let store = MemoryCredentialStore()
        try store.saveCredentials(opaqueCredentials(), for: fingerprint)
        try store.saveSnapshot(
            .init(subject: .license, snapshot: licenseSnapshot(validatedAt: validatedAt, interval: 3_600)),
            for: fingerprint
        )
        store.failNextConfirmedDeactivationAttemptSave()
        let requests = LockedBox(0)
        setHandler { _ in
            requests.mutate { $0 += 1 }
            return self.response(data: [
                "activation_id": "act_1", "status": "deactivated",
                "meta": ["request_id": "req_deactivate"]
            ])
        }
        let first = makeClient(store: store)
        guard case .remoteConfirmedLocalRepairRequired(
            .recordConfirmation, .credentialStorageError, let metadata
        ) = await first.deactivate() else {
            return XCTFail("Remote confirmation and failed local recording must both remain visible")
        }
        XCTAssertEqual(metadata.requestID, "req_deactivate")
        XCTAssertFalse(first.currentSnapshot?.isUsable(at: validatedAt) ?? true)
        XCTAssertEqual(try store.loadDeactivationAttempt(for: fingerprint)?.phase, .requested)

        let restarted = makeClient(store: store)
        guard case .success(let completed, _) = await restarted.deactivate() else {
            return XCTFail("Retry must reconfirm the server outcome using the original token")
        }
        XCTAssertTrue(completed.wasDeactivated)
        XCTAssertEqual(requests.get(), 2)
        XCTAssertNil(try store.loadDeactivationAttempt(for: fingerprint))
        XCTAssertNil(try store.loadCredentials(for: fingerprint))
    }

    func testDeactivationUnknownRemoteOutcomeRetainsRecoveryRecordAcrossRestart() async throws {
        let store = MemoryCredentialStore()
        try store.saveCredentials(opaqueCredentials(), for: fingerprint)
        try store.saveSnapshot(
            .init(subject: .license, snapshot: licenseSnapshot(validatedAt: validatedAt, interval: 3_600)),
            for: fingerprint
        )
        setHandler { _ in throw URLError(.networkConnectionLost) }
        let first = makeClient(store: store)
        guard case .failure(.transportError, .unknown, _, _, nil) = await first.deactivate() else {
            return XCTFail("A lost response must not be reported as remote rejection")
        }
        XCTAssertEqual(try store.loadDeactivationAttempt(for: fingerprint)?.phase, .requested)
        let restarted = makeClient(store: store)
        let local = await restarted.restoreLocalEntitlement()
        guard case .usable(let snapshot) = local else {
            return XCTFail("An unconfirmed remote request must retain existing credible access")
        }
        XCTAssertTrue(snapshot.isUsable(at: validatedAt))
        XCTAssertEqual(try store.loadDeactivationAttempt(for: fingerprint)?.phase, .requested)

        try store.clearCredentials(for: fingerprint)
        let requests = LockedBox(0)
        setHandler { request in
            requests.mutate { $0 += 1 }
            let body = try self.requestJSON(request)
            XCTAssertNil(body["machine_token"])
            XCTAssertEqual(body["activation_id"] as? String, "act_1")
            return self.response(data: [
                "activation_id": "act_1", "status": "deactivated",
                "meta": ["request_id": "req_retry"]
            ])
        }
        guard case .success(let completed, _) = await restarted.deactivate() else {
            return XCTFail("Recovery record must permit an idempotent retry without the main credential")
        }
        XCTAssertTrue(completed.wasDeactivated)
        XCTAssertEqual(requests.get(), 1)
        XCTAssertNil(try store.loadDeactivationAttempt(for: fingerprint))
    }

    func testValidationCanRefreshStateWhileDeactivationOutcomeIsUnknown() async throws {
        let store = MemoryCredentialStore()
        try store.saveCredentials(opaqueCredentials(), for: fingerprint)
        try store.saveSnapshot(
            .init(subject: .license, snapshot: licenseSnapshot(validatedAt: validatedAt, interval: 3_600)),
            for: fingerprint
        )
        try store.saveDeactivationAttempt(
            .init(activationID: "act_1", phase: .requested),
            for: fingerprint
        )
        setJSONResponse(data: validateData(state: [
            "kind": "license", "status": "activation_deactivated", "code": "ACTIVATION_DEACTIVATED"
        ]))
        let client = makeClient(store: store)
        guard case .usable = await client.restoreLocalEntitlement() else {
            return XCTFail("Pending remote confirmation must preserve the old credible local result")
        }
        guard case .success(let snapshot, _) = await client.validate(trigger: .silent) else {
            return XCTFail("Online validation must remain available while deactivation is unconfirmed")
        }
        XCTAssertEqual(snapshot.state, .license(.activationDeactivated))
        XCTAssertNil(try store.loadCredentials(for: fingerprint))
        guard case .confirmedBlocked(let restored) = await makeClient(store: store).restoreLocalEntitlement() else {
            return XCTFail("The confirmed server result must replace the prior local access decision")
        }
        XCTAssertEqual(restored.state, .license(.activationDeactivated))
        XCTAssertEqual(try store.loadDeactivationAttempt(for: fingerprint)?.phase, .requested)
    }

    func testDeactivationDoesNotRequestWhenRecoveryRecordCannotBeSaved() async throws {
        let store = MemoryCredentialStore()
        try store.saveCredentials(opaqueCredentials(), for: fingerprint)
        store.failNextDeactivationAttemptSave()
        let requests = LockedBox(0)
        setHandler { _ in
            requests.mutate { $0 += 1 }
            throw URLError(.notConnectedToInternet)
        }
        guard case .failure(.credentialStorageError, .notRequested, _, _, nil) = await makeClient(store: store).deactivate() else {
            return XCTFail("A failed preflight write must prevent the remote request")
        }
        XCTAssertEqual(requests.get(), 0)
        XCTAssertNotNil(try store.loadCredentials(for: fingerprint))
    }

    func testDeactivationDefinitiveRejectionPreservesCredentialAndClearsRecoveryRecord() async throws {
        let store = MemoryCredentialStore()
        try store.saveCredentials(opaqueCredentials(), for: fingerprint)
        try store.saveSnapshot(
            .init(subject: .license, snapshot: licenseSnapshot(validatedAt: validatedAt, interval: 3_600)),
            for: fingerprint
        )
        setJSONError(status: 429, code: "RATE_LIMITED", requestID: "req_rejected")
        guard case .failure(
            .apiError(_, let code, _, let requestID, _),
            .rejected, _, let metadata, nil
        ) = await makeClient(store: store).deactivate() else {
            return XCTFail("A confirmed Server rejection must retain the original error")
        }
        XCTAssertEqual(code, "RATE_LIMITED")
        XCTAssertEqual(requestID, "req_rejected")
        XCTAssertEqual(metadata.requestID, "req_rejected")
        XCTAssertNil(try store.loadDeactivationAttempt(for: fingerprint))
        XCTAssertNotNil(try store.loadCredentials(for: fingerprint))
        guard case .usable = await makeClient(store: store).restoreLocalEntitlement() else {
            return XCTFail("An unchanged bound cache remains the local evidence after rejection")
        }
    }

    func testStateWritesSerializeValidateThenActivate() async throws {
        let store = MemoryCredentialStore()
        try store.saveCredentials(opaqueCredentials(), for: fingerprint)
        let validationStarted = expectation(description: "validation started")
        let releaseValidation = DispatchSemaphore(value: 0)
        setHandler { request in
            if request.url!.path.hasSuffix("/validate") {
                validationStarted.fulfill()
                _ = releaseValidation.wait(timeout: .now() + 2)
                return self.response(data: self.validateData(state: self.licenseState()))
            }
            return self.response(data: self.activationData(activationID: "act_new"))
        }
        let client = makeClient(store: store)
        let validation = Task { await client.validate(trigger: .silent) }
        await fulfillment(of: [validationStarted], timeout: 1)
        let activation = Task { await client.activate(licenseKey: "NEW") }
        releaseValidation.signal()
        _ = await validation.value
        guard case .success = await activation.value else { return XCTFail("Expected activation") }
        XCTAssertEqual(try store.loadCredentials(for: fingerprint)?.activationID, "act_new")
    }

    func testIncompleteStoredCredentialJSONIsRejected() throws {
        let old = """
        {"activationID":"act_1",\
        "signedLicenseToken":null,"signingKeyID":null,"lastValidatedAt":0,\
        "cachedTerms":{"max_activations":1,"features":["export"]}}
        """
        XCTAssertThrowsError(
            try JSONDecoder().decode(StoredCredentials.self, from: Data(old.utf8))
        )
    }

    private func makeClient(
        store: MemoryCredentialStore,
        clock: MutableClock? = nil,
        signingPublicKey: String? = nil
    ) -> LicenKit {
        let clock = clock ?? MutableClock(validatedAt.addingTimeInterval(10))
        let configuration = configuration(signingPublicKey: signingPublicKey)
        return LicenKit(
            configuration: configuration,
            credentialStore: store,
            fingerprintProvider: FixedFingerprint(value: fingerprint),
            apiClient: LicenKitAPIClient(serverURL: configuration.serverURL, urlSession: session),
            now: { clock.now() }
        )
    }

    private func configuration(signingPublicKey: String?) -> LicenKitConfiguration {
        configuration(signingPublicKey: signingPublicKey, environment: .live)
    }

    private func configuration(signingPublicKey: String?, environment: LicenKitEnvironment) -> LicenKitConfiguration {
        LicenKitConfiguration(
            serverURL: URL(string: "https://mock.example")!,
            productID: "prd_1",
            signingPublicKey: signingPublicKey,
            releaseVersion: "2.4.0",
            releasePlatform: "macos",
            releaseArch: "arm64",
            environment: environment
        )
    }

    private func opaqueCredentials(
        activationID: String = "act_1"
    ) -> StoredCredentials {
        StoredCredentials(
            activationID: activationID,
            credentialMode: .opaque,
            signedLicenseToken: nil,
            signingKeyID: nil
        )
    }

    private func signedCredentials(token: String) -> StoredCredentials {
        StoredCredentials(
            activationID: "act_1",
            credentialMode: .signed,
            signedLicenseToken: token,
            signingKeyID: "key_1"
        )
    }

    private func licenseSnapshot(
        validatedAt: Date,
        interval: TimeInterval,
        lastValidateResponseAt: Date? = nil,
        offlineGracePeriod: TimeInterval? = 2_592_000,
        signedCredentialValid: Bool? = nil
    ) -> EntitlementSnapshot {
        EntitlementSnapshot(
            state: .license(.active(
                terms: LicenseTerms(maxActivations: 1, features: ["export"], updatesUntil: nil),
                expiresAt: nil
            )),
            source: .server,
            validatedAt: validatedAt,
            receivedValidationInterval: interval,
            effectiveValidationInterval: interval,
            offlineGracePeriod: offlineGracePeriod,
            lastValidateResponseAt: lastValidateResponseAt,
            signedCredentialValid: signedCredentialValid
        )
    }

    private func licenseState(features: [String] = ["export"]) -> [String: Any] {
        [
            "kind": "license", "status": "active", "expires_at": NSNull(),
            "terms": ["max_activations": 1, "features": features, "updates_until": NSNull()]
        ]
    }

    private func validateData(
        state: [String: Any],
        interval: Any = 3_600,
        offlineGrace: Any = 2_592_000,
        requestID: String = "req_1"
    ) -> [String: Any] {
        var data: [String: Any] = [
            "state": state,
            "validation": [
                "validation_interval_seconds": interval,
                "offline_grace_seconds": offlineGrace,
                "validated_at": iso(validatedAt)
            ],
            "meta": ["request_id": requestID]
        ]
        if state["kind"] as? String == "license", state["status"] as? String == "active" {
            data["credential_update"] = [
                "credential_mode": "opaque",
                "signed_license_token": NSNull(),
                "signing_key_id": NSNull()
            ]
        }
        return data
    }

    private func activationData(
        activationID: String = "act_1",
        mode: String = "opaque",
        token: String? = nil,
        keyID: String? = nil,
        stateFeatures: [String] = ["export"]
    ) -> [String: Any] {
        var result: [String: Any] = [
            "activation_id": activationID,
            "credential_mode": mode,
            "signed_license_token": token ?? NSNull(),
            "signing_key_id": keyID ?? NSNull(),
            "license_expires_at": NSNull(),
            "terms": ["max_activations": 1, "features": stateFeatures, "updates_until": NSNull()],
            "state": licenseState(features: stateFeatures),
            "validation": [
                "validation_interval_seconds": 3_600,
                "offline_grace_seconds": 2_592_000,
                "validated_at": iso(validatedAt)
            ],
            "meta": ["request_id": "req_1"]
        ]
        if mode == "opaque" {
            result["signed_license_token"] = NSNull()
            result["signing_key_id"] = NSNull()
        }
        return result
    }

    private func trialClaimData(
        trialID: String = "trl_reissued",
        status: String = "active"
    ) -> [String: Any] {
        let expiresAt = validatedAt.addingTimeInterval(86_400)
        return [
            "trial_id": trialID,
            "status": status,
            "expires_at": iso(expiresAt),
            "features": ["trial_export"],
            "state": [
                "kind": "trial",
                "status": status,
                "expires_at": iso(expiresAt),
                "features": ["trial_export"]
            ],
            "validation": [
                "validation_interval_seconds": 3_600,
                "offline_grace_seconds": NSNull(),
                "validated_at": iso(validatedAt)
            ],
            "meta": ["request_id": "req_trial"]
        ]
    }

    private func setJSONResponse(data: [String: Any], status: Int = 200) {
        setHandler { request in self.response(data: data, status: status, url: request.url!) }
    }

    private func setJSONError(status: Int, code: String, requestID: String) {
        setHandler { request in
            let body: [String: Any] = [
                "success": false,
                "error": ["code": code, "message": "failure", "request_id": requestID, "details": [:]]
            ]
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, try JSONSerialization.data(withJSONObject: body))
        }
    }

    private func setHandler(
        _ handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) {
        ContractURLProtocol.lock.withLock { ContractURLProtocol.handler = handler }
    }

    private func response(
        data: [String: Any],
        status: Int = 200,
        url: URL = URL(string: "https://mock.example")!
    ) -> (HTTPURLResponse, Data) {
        let envelope: [String: Any] = ["success": true, "data": data]
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, try! JSONSerialization.data(withJSONObject: envelope))
    }

    private func requestJSON(_ request: URLRequest) throws -> [String: Any] {
        let data: Data
        if let httpBody = request.httpBody {
            data = httpBody
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var result = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count < 0 { throw XCTSkip("Could not read request body stream") }
                if count == 0 { break }
                result.append(buffer, count: count)
            }
            data = result
        } else {
            return try XCTUnwrap(nil as [String: Any]?)
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private func makeToken(
        privateKey: Curve25519.Signing.PrivateKey,
        features: [String] = ["export"],
        licenseExpiresAt: Date? = nil,
        legacyAccountClaim: Bool = false,
        legacyExpirationClaim: Date? = nil
    ) throws -> String {
        let header = SignedLicenseTokenHeader(kid: "key_1")
        var payload: [String: Any] = [
            "lic": "lic_1", "act": "act_1", "ins": "ins_1", "prd": "prd_1",
            "ver": "2.4.0", "plt": "macos", "arc": "arm64",
            "fp": fingerprint, "iat": Int64(validatedAt.timeIntervalSince1970),
            "lexp": NSNull(), "upd": NSNull(),
            "fea": features
        ]
        if let licenseExpiresAt { payload["lexp"] = Int64(licenseExpiresAt.timeIntervalSince1970) }
        if legacyAccountClaim { payload["acc"] = "acc_legacy" }
        if let legacyExpirationClaim {
            payload["exp"] = Int64(legacyExpirationClaim.timeIntervalSince1970)
        }
        let verifier = Ed25519Verifier()
        let headerPart = verifier.encodeBase64URL(try JSONEncoder().encode(header))
        let payloadPart = verifier.encodeBase64URL(
            try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        )
        let signature = try privateKey.signature(for: Data("\(headerPart).\(payloadPart)".utf8))
        return "\(headerPart).\(payloadPart).\(verifier.encodeBase64URL(signature))"
    }
}

final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.withLock { value } }
    func set(_ value: Value) { lock.withLock { self.value = value } }
    func mutate(_ body: (inout Value) -> Void) { lock.withLock { body(&value) } }
}
