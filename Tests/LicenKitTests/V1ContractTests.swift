import CryptoKit
import XCTest
@testable import LicenKit

final class MemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var licenses: [String: StoredCredentials] = [:]
    private var trials: [String: StoredTrialCredentials] = [:]
    private var snapshots: [String: StoredEntitlementSnapshot] = [:]
    private var shouldFailNextLicenseSave = false

    func failNextLicenseSave() {
        lock.withLock { shouldFailNextLicenseSave = true }
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
        _ = lock.withLock { licenses.removeValue(forKey: fingerprint) }
    }
    func loadTrialCredentials(for fingerprint: String) throws -> StoredTrialCredentials? {
        lock.withLock { trials[fingerprint] }
    }
    func saveTrialCredentials(_ credentials: StoredTrialCredentials, for fingerprint: String) throws {
        lock.withLock { trials[fingerprint] = credentials }
    }
    func clearTrialCredentials(for fingerprint: String) throws {
        _ = lock.withLock { trials.removeValue(forKey: fingerprint) }
    }
    func loadSnapshot(for fingerprint: String) throws -> StoredEntitlementSnapshot? {
        lock.withLock { snapshots[fingerprint] }
    }
    func saveSnapshot(_ snapshot: StoredEntitlementSnapshot, for fingerprint: String) throws {
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
            let result = await makeClient(store: MemoryCredentialStore()).validate()
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
            let result = await makeClient(store: MemoryCredentialStore()).validate()
            guard case .failure(.protocolError, _, let metadata) = result else {
                return XCTFail("Expected strict Trial reason/code protocol failure")
            }
            XCTAssertEqual(metadata.requestID, "req_1")
        }
    }

    func testLicenseCredentialHasPriorityOverResidualTrialCredential() async throws {
        let store = MemoryCredentialStore()
        try store.saveCredentials(opaqueCredentials(), for: fingerprint)
        try store.saveTrialCredentials(.init(trialID: "trl_1", trialToken: "ttk_secret"), for: fingerprint)
        let seenKind = LockedBox<String?>(nil)
        setHandler { request in
            let json = try self.requestJSON(request)
            let credential = try XCTUnwrap(json["credential"] as? [String: Any])
            seenKind.set(credential["kind"] as? String)
            return self.response(data: self.validateData(state: self.licenseState()))
        }
        let result = await makeClient(store: store).validate()
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
                .init(trialID: "trl_1", trialToken: "ttk_secret"),
                for: fingerprint
            )
            var state: [String: Any] = [
                "kind": "trial", "status": status, "code": code,
                "details": ["trial_id": "trl_1", "trial_token": "secret"]
            ]
            if status == "expired" { state["expires_at"] = iso(validatedAt.addingTimeInterval(-10)) }
            if status == "revoked" { state["reason"] = "abuse" }
            setJSONResponse(data: validateData(state: state))
            let result = await makeClient(store: trialStore).validate()
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
            let result = await makeClient(store: store).validate()
            guard case .success(let snapshot, _) = result else { return XCTFail("Expected success for \(code)") }
            XCTAssertEqual(snapshot.state, expected)
            XCTAssertEqual(snapshot.businessCode, code)
            if status == "activation_deactivated" {
                XCTAssertNil(try store.loadCredentials(for: fingerprint))
            }
        }
    }

    func testReleaseFailuresAreNotLicenseExpiry() async throws {
        let cases: [([String: Any], EntitlementState)] = [
            ([
                "kind": "release_not_eligible", "status": "unknown_release",
                "code": "PRODUCT_RELEASE_UNKNOWN", "release_version": "2.4.0",
                "release_platform": "macos-arm64"
            ], .releaseNotEligible(.unknownRelease(
                code: "PRODUCT_RELEASE_UNKNOWN", version: "2.4.0", platform: "macos-arm64"
            ))),
            ([
                "kind": "release_not_eligible", "status": "update_required",
                "code": "UPDATE_ENTITLEMENT_REQUIRED", "updates_until": "2029-01-01T00:00:00Z",
                "release_version": "2.4.0", "released_at": "2030-01-01T00:00:00Z"
            ], .releaseNotEligible(.updateRequired(
                code: "UPDATE_ENTITLEMENT_REQUIRED",
                updatesUntil: FlexibleDate.parseISO8601("2029-01-01T00:00:00Z"),
                releaseVersion: "2.4.0",
                releasedAt: validatedAt
            ))),
        ]
        for (state, expected) in cases {
            setJSONResponse(data: validateData(state: state))
            let result = await makeClient(store: MemoryCredentialStore()).validate()
            guard case .success(let snapshot, _) = result else { return XCTFail("Expected success") }
            XCTAssertEqual(snapshot.state, expected)
        }
    }

    func testReleaseStatesRejectMissingIdentityFields() async throws {
        let states: [[String: Any]] = [
            [
                "kind": "release_not_eligible", "status": "unknown_release",
                "code": "PRODUCT_RELEASE_UNKNOWN", "release_version": "2.4.0"
            ],
            [
                "kind": "release_not_eligible", "status": "update_required",
                "code": "UPDATE_ENTITLEMENT_REQUIRED"
            ],
        ]
        for state in states {
            setJSONResponse(data: validateData(state: state))
            let result = await makeClient(store: MemoryCredentialStore()).validate()
            guard case .failure(.protocolError, _, let metadata) = result else {
                return XCTFail("Expected missing Release identity to fail")
            }
            XCTAssertEqual(metadata.requestID, "req_1")
        }
    }

    func testIntervalNormalizationAndCooldownDoNotRequest() async throws {
        XCTAssertEqual(LicenKit.normalizeInterval(nil), 3_600)
        XCTAssertEqual(LicenKit.normalizeInterval(12), 3_600)
        XCTAssertEqual(LicenKit.normalizeInterval(4_000), 4_000)
        XCTAssertEqual(LicenKit.normalizeInterval(99_999), 86_400)

        let store = MemoryCredentialStore()
        try store.saveCredentials(opaqueCredentials(), for: fingerprint)
        let snapshot = licenseSnapshot(
            validatedAt: validatedAt,
            interval: 3_600,
            lastValidateResponseAt: validatedAt
        )
        try store.saveSnapshot(.init(subject: .license, snapshot: snapshot), for: fingerprint)
        let requests = LockedBox(0)
        setHandler { _ in requests.mutate { $0 += 1 }; return self.response(data: self.validateData(state: self.licenseState())) }
        let clock = MutableClock(validatedAt.addingTimeInterval(100))
        let result = await makeClient(store: store, clock: clock).validate()
        guard case .notPerformed(.cooldown, let cached, let metadata) = result else {
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
        guard case .success(let first, _) = await client.validate() else {
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
        guard case .notPerformed(.cooldown, _, _) = await client.validate() else {
            return XCTFail("Passing 30 seconds alone must not bypass the configured interval")
        }
        XCTAssertEqual(requests.get(), 0)
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
        async let first = client.validate()
        async let second = client.validate()
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
        try store.saveSnapshot(.init(subject: .license, snapshot: old), for: fingerprint)
        setJSONError(status: 500, code: "DATABASE_UNAVAILABLE", requestID: "req_fail")
        let clock = MutableClock(validatedAt.addingTimeInterval(3_601))
        let result = await makeClient(store: store, clock: clock).validate()
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
        guard case .notPerformed(.cooldown, _, _) = await makeClient(
            store: store,
            clock: clock
        ).validate() else {
            return XCTFail("A definite HTTP failure must start the validate request cooldown")
        }
        XCTAssertEqual(requests.get(), 0)
    }

    func testTrialExpiryDoesNotBypassConfiguredValidateCooldown() async throws {
        let store = MemoryCredentialStore()
        try store.saveTrialCredentials(.init(trialID: "trl_1", trialToken: "ttk"), for: fingerprint)
        let expiry = validatedAt.addingTimeInterval(100)
        let snapshot = EntitlementSnapshot(
            state: .trial(.active(expiresAt: expiry, features: ["export"])),
            source: .server,
            validatedAt: validatedAt,
            receivedValidationInterval: 3_600,
            effectiveValidationInterval: 3_600,
            lastValidateResponseAt: validatedAt
        )
        try store.saveSnapshot(.init(subject: .trial, snapshot: snapshot), for: fingerprint)
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
        guard case .notPerformed(.cooldown, let cached, _) = await client.validate() else {
            return XCTFail("Trial expiry must not bypass the configured validate cooldown")
        }
        XCTAssertFalse(cached?.isUsable(at: clock.now()) ?? true)
        XCTAssertEqual(requests.get(), 0)
    }

    func testActivationUsesServerTimeButFirstValidateStillRequests() async throws {
        let store = MemoryCredentialStore()
        try store.saveTrialCredentials(.init(trialID: "trl_old", trialToken: "ttk_old"), for: fingerprint)
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
        guard case .success = await client.validate() else {
            return XCTFail("Activation must not count as a validate response")
        }
        XCTAssertEqual(requests.get(), 1)
    }

    func testStartTrialUsesServerTimeAndPersistsTrialCredential() async throws {
        let store = MemoryCredentialStore()
        let expiresAt = validatedAt.addingTimeInterval(86_400)
        setJSONResponse(data: [
            "trial_id": "trl_1",
            "trial_token": "ttk_once",
            "status": "active",
            "expires_at": iso(expiresAt),
            "features": ["trial_export"],
            "state": [
                "kind": "trial", "status": "active", "expires_at": iso(expiresAt),
                "features": ["trial_export"]
            ],
            "validation": [
                "validation_interval_seconds": NSNull(),
                "validated_at": iso(validatedAt)
            ],
            "meta": ["request_id": "req_trial"]
        ])
        let result = await makeClient(store: store).startTrial()
        guard case .success(let snapshot, let metadata) = result,
              case .trial(.active(let actualExpiry, let features)) = snapshot.state else {
            return XCTFail("Expected active Trial")
        }
        XCTAssertEqual(actualExpiry, expiresAt)
        XCTAssertEqual(features, ["trial_export"])
        XCTAssertEqual(snapshot.validatedAt, validatedAt)
        XCTAssertNil(snapshot.lastValidateResponseAt)
        XCTAssertEqual(snapshot.effectiveValidationInterval, 3_600)
        XCTAssertEqual(metadata.requestID, "req_trial")
        XCTAssertEqual(try store.loadTrialCredentials(for: fingerprint)?.trialToken, "ttk_once")

        let requests = LockedBox(0)
        setHandler { _ in
            requests.mutate { $0 += 1 }
            return self.response(data: self.validateData(state: [
                "kind": "trial", "status": "active", "expires_at": self.iso(expiresAt),
                "features": ["trial_export"]
            ]))
        }
        guard case .success = await makeClient(store: store).validate() else {
            return XCTFail("Trial claim must not count as a validate response")
        }
        XCTAssertEqual(requests.get(), 1)
    }

    func testServerIntervalIsPreservedAndClamped() async throws {
        for (received, expected) in [(12.0, 3_600.0), (99_999.0, 86_400.0)] {
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
            let result = await makeClient(store: MemoryCredentialStore()).validate()
            guard case .success(let snapshot, let metadata) = result else {
                return XCTFail("Expected interval response")
            }
            XCTAssertEqual(snapshot.receivedValidationInterval, received)
            XCTAssertEqual(snapshot.effectiveValidationInterval, expected)
            XCTAssertEqual(metadata.receivedValidationInterval, received)
            XCTAssertEqual(metadata.effectiveValidationInterval, expected)
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
            )),
            for: fingerprint
        )
        let requests = LockedBox(0)
        setHandler { _ in
            requests.mutate { $0 += 1 }
            return self.response(data: self.validateData(state: self.licenseState()))
        }
        let clock = MutableClock(validatedAt.addingTimeInterval(-0.001))
        guard case .notPerformed(.cooldown, _, _) = await makeClient(
            store: store,
            clock: clock
        ).validate() else {
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
            "signed_license_token_expires_at": iso(validatedAt.addingTimeInterval(7_200)),
            "signing_key_id": "key_1"
        ]
        setJSONResponse(data: data)
        let result = await makeClient(store: store).validate()
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
            )),
            for: fingerprint
        )
        let requests = LockedBox(0)
        setHandler { _ in requests.mutate { $0 += 1 }; return self.response(data: self.validateData(state: self.licenseState())) }
        let clock = MutableClock(validatedAt.addingTimeInterval(3_601))
        guard case .success = await makeClient(store: store, clock: clock).validate() else {
            return XCTFail("Expected online validation")
        }
        XCTAssertEqual(requests.get(), 1)
    }

    func testValidSignedCredentialStillRequiresConfiguredInterval() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let expiry = validatedAt.addingTimeInterval(7_200)
        let token = try makeToken(privateKey: key, tokenExpiry: expiry)
        let store = MemoryCredentialStore()
        try store.saveCredentials(
            signedCredentials(token: token, expiry: expiry),
            for: fingerprint
        )
        try store.saveSnapshot(
            .init(subject: .license, snapshot: licenseSnapshot(
                validatedAt: validatedAt,
                interval: 3_600,
                lastValidateResponseAt: validatedAt,
                signedTokenExpiresAt: expiry,
                signedCredentialValid: true
            )),
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
            keys: ["key_1": key.publicKey.rawRepresentation.base64EncodedString()]
        ).validate()
        guard case .notPerformed(.cooldown, let cached, _) = result else {
            return XCTFail("A valid Signed License must obey the configured interval")
        }
        XCTAssertEqual(cached?.source, .signedLocal)
        XCTAssertEqual(cached?.signedCredentialValid, true)
        XCTAssertEqual(requests.get(), 0)
    }

    func testExpiredSignedCredentialBypassesConfiguredIntervalButNotThirtySeconds() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let expiry = validatedAt.addingTimeInterval(10)
        let token = try makeToken(privateKey: key, tokenExpiry: expiry)
        let store = MemoryCredentialStore()
        try store.saveCredentials(
            signedCredentials(token: token, expiry: expiry),
            for: fingerprint
        )
        try store.saveSnapshot(
            .init(subject: .license, snapshot: licenseSnapshot(
                validatedAt: validatedAt,
                interval: 3_600,
                lastValidateResponseAt: validatedAt,
                signedTokenExpiresAt: expiry,
                signedCredentialValid: true
            )),
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
            keys: ["key_1": key.publicKey.rawRepresentation.base64EncodedString()]
        )
        guard case .notPerformed(.cooldown, let cached, _) = await client.validate() else {
            return XCTFail("Expired Signed credentials must still obey the 30-second throttle")
        }
        XCTAssertEqual(cached?.source, .local)
        XCTAssertEqual(cached?.signedCredentialValid, false)
        XCTAssertEqual(requests.get(), 0)

        clock.set(validatedAt.addingTimeInterval(31))
        guard case .failure = await client.validate() else {
            return XCTFail("Expired Signed credentials may request after 30 seconds")
        }
        XCTAssertEqual(requests.get(), 1)
        XCTAssertEqual(
            try store.loadSnapshot(for: fingerprint)?.snapshot.lastValidateResponseAt,
            validatedAt,
            "A network failure without an HTTP response must not advance the throttle"
        )
    }

    func testInvalidSignedCredentialBypassesConfiguredIntervalButNotThirtySeconds() async throws {
        let signingKey = Curve25519.Signing.PrivateKey()
        let unrelatedKey = Curve25519.Signing.PrivateKey()
        let expiry = validatedAt.addingTimeInterval(7_200)
        let token = try makeToken(privateKey: signingKey, tokenExpiry: expiry)
        let store = MemoryCredentialStore()
        try store.saveCredentials(
            signedCredentials(token: token, expiry: expiry),
            for: fingerprint
        )
        try store.saveSnapshot(
            .init(subject: .license, snapshot: licenseSnapshot(
                validatedAt: validatedAt,
                interval: 3_600,
                lastValidateResponseAt: validatedAt,
                signedTokenExpiresAt: expiry,
                signedCredentialValid: true
            )),
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
            keys: ["key_1": unrelatedKey.publicKey.rawRepresentation.base64EncodedString()]
        )
        guard case .notPerformed(.cooldown, let cached, _) = await client.validate() else {
            return XCTFail("A locally invalid signature must still obey the 30-second throttle")
        }
        XCTAssertEqual(cached?.signedCredentialValid, false)
        XCTAssertEqual(requests.get(), 0)

        clock.set(validatedAt.addingTimeInterval(31))
        guard case .failure = await client.validate() else {
            return XCTFail("A locally invalid signature may request after 30 seconds")
        }
        XCTAssertEqual(requests.get(), 1)
    }

    func testHTTP401StartsFullConfiguredCooldownForValidSignedCredential() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let expiry = validatedAt.addingTimeInterval(10_000)
        let token = try makeToken(privateKey: key, tokenExpiry: expiry)
        let store = MemoryCredentialStore()
        try store.saveCredentials(
            signedCredentials(token: token, expiry: expiry),
            for: fingerprint
        )
        try store.saveSnapshot(
            .init(subject: .license, snapshot: licenseSnapshot(
                validatedAt: validatedAt,
                interval: 3_600,
                lastValidateResponseAt: validatedAt,
                signedTokenExpiresAt: expiry,
                signedCredentialValid: true
            )),
            for: fingerprint
        )
        let clock = MutableClock(validatedAt.addingTimeInterval(3_601))
        setJSONError(status: 401, code: "MACHINE_TOKEN_INVALID", requestID: "req_signed_401")
        let client = makeClient(
            store: store,
            clock: clock,
            keys: ["key_1": key.publicKey.rawRepresentation.base64EncodedString()]
        )
        guard case .failure(.apiError(let status, let code, _, let requestID, _), _, _) = await client.validate() else {
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
        guard case .notPerformed(.cooldown, let cached, _) = await client.validate() else {
            return XCTFail("HTTP 401 must start the full configured interval for a valid Signed Token")
        }
        XCTAssertEqual(cached?.signedCredentialValid, true)
        XCTAssertEqual(requests.get(), 0)
    }

    func testSignedOuterExpiryAndStateMustMatchVerifiedClaims() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let keys = ["key_1": key.publicKey.rawRepresentation.base64EncodedString()]
        let exp = validatedAt.addingTimeInterval(7_200)
        let token = try makeToken(privateKey: key, tokenExpiry: exp, features: ["export"])
        var mismatchedExpiry = activationData(
            mode: "signed", token: token, keyID: "key_1", tokenExpiry: exp.addingTimeInterval(1)
        )
        setJSONResponse(data: mismatchedExpiry)
        let store = MemoryCredentialStore()
        let first = await makeClient(store: store, keys: keys).activate(licenseKey: "LK")
        guard case .failure(.protocolError(let reason), _, let metadata) = first else {
            return XCTFail("Expected signed exp mismatch failure")
        }
        XCTAssertTrue(reason.contains("exp claim"))
        XCTAssertEqual(metadata.requestID, "req_1")
        XCTAssertNil(try store.loadCredentials(for: fingerprint))

        mismatchedExpiry = activationData(
            mode: "signed", token: token, keyID: "key_1", tokenExpiry: exp,
            stateFeatures: ["different"]
        )
        setJSONResponse(data: mismatchedExpiry)
        let second = await makeClient(store: store, keys: keys).activate(licenseKey: "LK")
        guard case .failure(.protocolError(let reason), _, _) = second else {
            return XCTFail("Expected signed state mismatch failure")
        }
        XCTAssertTrue(reason.contains("signed claims"))
        XCTAssertNil(try store.loadCredentials(for: fingerprint))
    }

    func testSignedTokenRejectsLegacyTenantClaimAndInstanceMismatch() throws {
        let key = Curve25519.Signing.PrivateKey()
        let verifier = Ed25519Verifier()
        let legacy = try makeToken(
            privateKey: key,
            tokenExpiry: validatedAt.addingTimeInterval(7_200),
            legacyAccountClaim: true
        )
        XCTAssertThrowsError(try verifier.verifyAndDecodeToken(
            token: legacy,
            trustedSigningKeys: ["key_1": key.publicKey.rawRepresentation.base64EncodedString()]
        ))

        let claims = LicenseClaims(
            licenseID: "lic_1", activationID: "act_1", instanceID: "ins_other",
            productID: "prd_1", releaseID: "rel_1", releaseVersion: "2.4.0",
            releasePlatform: "macos-arm64", releasedAtTimestamp: Int64(validatedAt.timeIntervalSince1970),
            fingerprint: fingerprint, issuedAtTimestamp: Int64(validatedAt.timeIntervalSince1970),
            tokenExpiresAtTimestamp: Int64(validatedAt.addingTimeInterval(7_200).timeIntervalSince1970),
            licenseExpiresAtTimestamp: nil, updatesUntilTimestamp: nil, features: ["export"]
        )
        XCTAssertThrowsError(try ClaimsEvaluator().evaluate(
            claims: claims,
            configuration: configuration(keys: [:]),
            activationID: "act_1",
            currentFingerprint: fingerprint,
            now: validatedAt
        ))
    }

    func testMalformedResponsePreservesHeaderRequestID() async throws {
        let store = MemoryCredentialStore()
        setHandler { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json", "X-Request-ID": "req_header"]
            )!
            return (response, Data("not-json".utf8))
        }
        let result = await makeClient(store: store).validate()
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
        guard case .success = await makeClient(store: store).validate() else {
            return XCTFail("Malformed HTTP 2xx data must not start a validate cooldown")
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
        let result = await makeClient(store: store, clock: clock).validate()
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
        let result = await makeClient(store: store, clock: clock).validate()
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
        guard case .notPerformed(.cooldown, _, _) = await makeClient(
            store: store,
            clock: clock
        ).validate() else {
            return XCTFail("An HTTP 403 must start the full configured cooldown")
        }
        XCTAssertEqual(requests.get(), 0)
    }

    func testHTTP429StartsCooldownAndRemainsRateLimited() async throws {
        let store = MemoryCredentialStore()
        let clock = MutableClock(validatedAt.addingTimeInterval(10))
        setJSONError(status: 429, code: "RATE_LIMITED", requestID: "req_429")
        let result = await makeClient(store: store, clock: clock).validate()
        guard case .failure(let error, let lastKnown, let metadata) = result else {
            return XCTFail("Expected HTTP 429 failure")
        }
        XCTAssertTrue(error.isRateLimited)
        XCTAssertEqual(error.requestID, "req_429")
        XCTAssertNil(lastKnown?.validatedAt)
        XCTAssertEqual(lastKnown?.lastValidateResponseAt, clock.now())
        XCTAssertEqual(metadata.lastValidateResponseAt, clock.now())
    }

    func testTimeoutWithoutHTTPResponseDoesNotStartCooldown() async throws {
        let store = MemoryCredentialStore()
        let clock = MutableClock(validatedAt.addingTimeInterval(10))
        setHandler { _ in throw URLError(.timedOut) }
        guard case .failure(.transportError(.timeout, _), _, _) = await makeClient(
            store: store,
            clock: clock
        ).validate() else {
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
        guard case .success = await makeClient(store: store, clock: clock).validate() else {
            return XCTFail("The retry after a no-response failure must reach the Server")
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
            )),
            for: fingerprint
        )
        store.failNextLicenseSave()
        setJSONResponse(data: validateData(state: licenseState()))
        let clock = MutableClock(validatedAt.addingTimeInterval(10))
        let result = await makeClient(store: store, clock: clock).validate()
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
        let validation = Task { await client.validate() }
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
            return self.response(data: self.activationData(activationID: "act_new", machineToken: "mtk_new"))
        }
        let client = makeClient(store: store)
        let validation = Task { await client.validate() }
        await fulfillment(of: [validationStarted], timeout: 1)
        let activation = Task { await client.activate(licenseKey: "NEW") }
        releaseValidation.signal()
        _ = await validation.value
        guard case .success = await activation.value else { return XCTFail("Expected activation") }
        XCTAssertEqual(try store.loadCredentials(for: fingerprint)?.activationID, "act_new")
    }

    func testOldStoredCredentialJSONStillDecodes() throws {
        let old = """
        {"activationID":"act_1","machineToken":"mtk","credentialMode":"opaque",\
        "signedLicenseToken":null,"signingKeyID":null,"lastValidatedAt":0,\
        "cachedTerms":{"max_activations":1,"features":["export"]}}
        """
        let decoded = try JSONDecoder().decode(StoredCredentials.self, from: Data(old.utf8))
        XCTAssertEqual(decoded.activationID, "act_1")
        XCTAssertNil(decoded.signedLicenseTokenExpiresAt)

        let oldTrial = """
        {"trialID":"trl_1","trialToken":"ttk","expiresAt":0,"features":["export"],"lastValidatedAt":0}
        """
        XCTAssertEqual(
            try JSONDecoder().decode(StoredTrialCredentials.self, from: Data(oldTrial.utf8)).trialID,
            "trl_1"
        )

        let encodedSnapshot = try JSONEncoder().encode(
            licenseSnapshot(validatedAt: validatedAt, interval: 3_600)
        )
        var legacySnapshot = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encodedSnapshot) as? [String: Any]
        )
        legacySnapshot.removeValue(forKey: "lastValidateResponseAt")
        legacySnapshot.removeValue(forKey: "signedCredentialValid")
        let migratedSnapshot = try JSONDecoder().decode(
            EntitlementSnapshot.self,
            from: JSONSerialization.data(withJSONObject: legacySnapshot)
        )
        XCTAssertNil(migratedSnapshot.lastValidateResponseAt)
        XCTAssertNil(migratedSnapshot.signedCredentialValid)
    }

    private func makeClient(
        store: MemoryCredentialStore,
        clock: MutableClock? = nil,
        keys: [String: String] = [:]
    ) -> LicenKit {
        let clock = clock ?? MutableClock(validatedAt.addingTimeInterval(10))
        let configuration = configuration(keys: keys)
        return LicenKit(
            configuration: configuration,
            credentialStore: store,
            fingerprintProvider: FixedFingerprint(value: fingerprint),
            apiClient: LicenKitAPIClient(serverURL: configuration.serverURL, urlSession: session),
            now: { clock.now() }
        )
    }

    private func configuration(keys: [String: String]) -> LicenKitConfiguration {
        LicenKitConfiguration(
            serverURL: URL(string: "https://mock.example")!,
            instanceID: "ins_1",
            productID: "prd_1",
            releaseVersion: "2.4.0",
            releasePlatform: "macos-arm64",
            trustedSigningKeys: keys
        )
    }

    private func opaqueCredentials(
        activationID: String = "act_1",
        machineToken: String = "mtk_secret"
    ) -> StoredCredentials {
        StoredCredentials(
            activationID: activationID,
            machineToken: machineToken,
            credentialMode: .opaque,
            signedLicenseToken: nil,
            signingKeyID: nil,
            signedLicenseTokenExpiresAt: nil
        )
    }

    private func signedCredentials(token: String, expiry: Date) -> StoredCredentials {
        StoredCredentials(
            activationID: "act_1",
            machineToken: "mtk_secret",
            credentialMode: .signed,
            signedLicenseToken: token,
            signingKeyID: "key_1",
            signedLicenseTokenExpiresAt: expiry
        )
    }

    private func licenseSnapshot(
        validatedAt: Date,
        interval: TimeInterval,
        lastValidateResponseAt: Date? = nil,
        signedTokenExpiresAt: Date? = nil,
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
            signedLicenseTokenExpiresAt: signedTokenExpiresAt,
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
        interval: Any = NSNull(),
        requestID: String = "req_1"
    ) -> [String: Any] {
        var data: [String: Any] = [
            "state": state,
            "validation": [
                "validation_interval_seconds": interval,
                "validated_at": iso(validatedAt)
            ],
            "meta": ["request_id": requestID]
        ]
        if state["kind"] as? String == "license", state["status"] as? String == "active" {
            data["credential_update"] = [
                "credential_mode": "opaque",
                "signed_license_token": NSNull(),
                "signed_license_token_expires_at": NSNull(),
                "signing_key_id": NSNull()
            ]
        }
        return data
    }

    private func activationData(
        activationID: String = "act_1",
        machineToken: String = "mtk_secret",
        mode: String = "opaque",
        token: String? = nil,
        keyID: String? = nil,
        tokenExpiry: Date? = nil,
        stateFeatures: [String] = ["export"]
    ) -> [String: Any] {
        var result: [String: Any] = [
            "activation_id": activationID,
            "machine_token": machineToken,
            "credential_mode": mode,
            "signed_license_token": token ?? NSNull(),
            "signed_license_token_expires_at": tokenExpiry.map(iso) ?? NSNull(),
            "signing_key_id": keyID ?? NSNull(),
            "license_expires_at": NSNull(),
            "terms": ["max_activations": 1, "features": stateFeatures, "updates_until": NSNull()],
            "state": licenseState(features: stateFeatures),
            "validation": [
                "validation_interval_seconds": NSNull(),
                "validated_at": iso(validatedAt)
            ],
            "meta": ["request_id": "req_1"]
        ]
        if mode == "opaque" {
            result["signed_license_token"] = NSNull()
            result["signed_license_token_expires_at"] = NSNull()
            result["signing_key_id"] = NSNull()
        }
        return result
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
        tokenExpiry: Date,
        features: [String] = ["export"],
        legacyAccountClaim: Bool = false
    ) throws -> String {
        let header = SignedLicenseTokenHeader(kid: "key_1")
        var payload: [String: Any] = [
            "lic": "lic_1", "act": "act_1", "ins": "ins_1", "prd": "prd_1", "rel": "rel_1",
            "ver": "2.4.0", "plt": "macos-arm64", "rat": Int64(validatedAt.timeIntervalSince1970),
            "fp": fingerprint, "iat": Int64(validatedAt.timeIntervalSince1970),
            "exp": Int64(tokenExpiry.timeIntervalSince1970), "lexp": NSNull(), "upd": NSNull(),
            "fea": features
        ]
        if legacyAccountClaim { payload["acc"] = "acc_legacy" }
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
