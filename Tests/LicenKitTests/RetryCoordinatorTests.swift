import XCTest
@testable import LicenKit

final class RetryCoordinatorTests: XCTestCase {
    
    private var testUserDefaults: UserDefaults!
    private let testRateLimitKey = "LicenKit_Test_RateLimitKey"
    
    override func setUp() {
        super.setUp()
        testUserDefaults = UserDefaults(suiteName: "com.licenkit.tests.retry")!
        testUserDefaults.removePersistentDomain(forName: "com.licenkit.tests.retry")
    }
    
    override func tearDown() {
        testUserDefaults.removePersistentDomain(forName: "com.licenkit.tests.retry")
        testUserDefaults = nil
        super.tearDown()
    }
    
    // MARK: - Foreground Tests
    
    func testForegroundActivationRetriesUpToThreeTimesOnRecoverableError() async {
        let mockMonitor = MockNetworkMonitor(initialOnline: true)
        let coordinator = LicenKitRetryCoordinator(
            networkMonitor: mockMonitor,
            retryDelays: .fastForTesting,
            userDefaults: testUserDefaults,
            rateLimitKey: testRateLimitKey
        )
        
        let attemptsLock = NSLock()
        var attempts = 0
        
        do {
            _ = try await coordinator.execute(scenario: .foregroundActivation) {
                attemptsLock.lock()
                attempts += 1
                attemptsLock.unlock()
                throw LicenKitError.networkError("Connection timed out")
            }
            XCTFail("Should have thrown error after max retries")
        } catch {
            // 初始 1 次 + 3 次重试 = 4 次尝试
            attemptsLock.lock()
            let finalAttempts = attempts
            attemptsLock.unlock()
            XCTAssertEqual(finalAttempts, 4)
            XCTAssertEqual(error as? LicenKitError, .networkError("Connection timed out"))
        }
    }
    
    func testForegroundActivationImmediatelyFailsOnBusinessRejection() async {
        let mockMonitor = MockNetworkMonitor(initialOnline: true)
        let coordinator = LicenKitRetryCoordinator(
            networkMonitor: mockMonitor,
            retryDelays: .fastForTesting,
            userDefaults: testUserDefaults,
            rateLimitKey: testRateLimitKey
        )
        
        var attempts = 0
        do {
            _ = try await coordinator.execute(scenario: .foregroundActivation) {
                attempts += 1
                throw LicenKitError.apiError(code: "LICENSE_NOT_FOUND", message: "License does not exist")
            }
            XCTFail("Should have thrown error immediately")
        } catch {
            // 业务错误不重试，仅 1 次尝试
            XCTAssertEqual(attempts, 1)
            XCTAssertEqual(
                error as? LicenKitError,
                .apiError(code: "LICENSE_NOT_FOUND", message: "License does not exist")
            )
        }
    }
    
    func testForegroundActivationImmediatelyFailsOnMaxMachinesReached() async {
        let mockMonitor = MockNetworkMonitor(initialOnline: true)
        let coordinator = LicenKitRetryCoordinator(
            networkMonitor: mockMonitor,
            retryDelays: .fastForTesting,
            userDefaults: testUserDefaults,
            rateLimitKey: testRateLimitKey
        )
        
        var attempts = 0
        do {
            _ = try await coordinator.execute(scenario: .foregroundActivation) {
                attempts += 1
                throw LicenKitError.maxMachinesReached
            }
            XCTFail("Should have thrown error immediately")
        } catch {
            XCTAssertEqual(attempts, 1)
            XCTAssertEqual(error as? LicenKitError, .maxMachinesReached)
        }
    }
    
    func testForegroundActivationSucceedsOnSecondAttempt() async throws {
        let mockMonitor = MockNetworkMonitor(initialOnline: true)
        let coordinator = LicenKitRetryCoordinator(
            networkMonitor: mockMonitor,
            retryDelays: .fastForTesting,
            userDefaults: testUserDefaults,
            rateLimitKey: testRateLimitKey
        )
        
        let attemptsLock = NSLock()
        var attempts = 0
        
        let result = try await coordinator.execute(scenario: .foregroundActivation) {
            attemptsLock.lock()
            defer { attemptsLock.unlock() }
            attempts += 1
            if attempts == 1 {
                throw LicenKitError.apiError(code: "HTTP_500", message: "Internal server error")
            }
            return "SUCCESS"
        }
        
        XCTAssertEqual(result, "SUCCESS")
        attemptsLock.lock()
        let finalAttempts = attempts
        attemptsLock.unlock()
        XCTAssertEqual(finalAttempts, 2)
    }
    
    // MARK: - Background Tests
    
    func testBackgroundSyncWaitsAndRetriesOnceThenBlocksSession() async {
        let mockMonitor = MockNetworkMonitor(initialOnline: true)
        let coordinator = LicenKitRetryCoordinator(
            networkMonitor: mockMonitor,
            retryDelays: .fastForTesting,
            userDefaults: testUserDefaults,
            rateLimitKey: testRateLimitKey
        )
        
        let attemptsLock = NSLock()
        var attempts = 0
        
        do {
            _ = try await coordinator.execute(scenario: .backgroundSync) {
                attemptsLock.lock()
                attempts += 1
                attemptsLock.unlock()
                throw LicenKitError.apiError(code: "HTTP_502", message: "Bad Gateway")
            }
            XCTFail("Should have thrown after 2 attempts")
        } catch {
            // 第 1 次 + 等待后第 2 次 = 2 次
            attemptsLock.lock()
            let finalAttempts = attempts
            attemptsLock.unlock()
            XCTAssertEqual(finalAttempts, 2)
            XCTAssertTrue(coordinator.isSessionBlocked)
        }
        
        // 随后的调用应当因为 Session 熔断而直接跳过，不再发起请求
        do {
            _ = try await coordinator.execute(scenario: .backgroundSync) {
                attemptsLock.lock()
                attempts += 1
                attemptsLock.unlock()
                return "UNEXPECTED"
            }
            XCTFail("Should have skipped execution due to session block")
        } catch {
            attemptsLock.lock()
            let finalAttempts = attempts
            attemptsLock.unlock()
            XCTAssertEqual(finalAttempts, 2) // 仍然是 2 次，未增加
        }
    }
    
    func testBackgroundSyncRateLimitingBlocksForToday() async {
        let mockMonitor = MockNetworkMonitor(initialOnline: true)
        let coordinator = LicenKitRetryCoordinator(
            networkMonitor: mockMonitor,
            retryDelays: .fastForTesting,
            userDefaults: testUserDefaults,
            rateLimitKey: testRateLimitKey
        )
        
        var attempts = 0
        do {
            _ = try await coordinator.execute(scenario: .backgroundSync) {
                attempts += 1
                throw LicenKitError.apiError(code: "HTTP_429", message: "Rate limit exceeded")
            }
            XCTFail("Should have thrown rate limit")
        } catch {
            XCTAssertEqual(attempts, 1)
            XCTAssertTrue(coordinator.isRateLimitedToday)
        }
        
        // 当天后续探活直接跳过
        do {
            _ = try await coordinator.execute(scenario: .backgroundSync) {
                attempts += 1
                return "UNEXPECTED"
            }
            XCTFail("Should have skipped due to rate limit")
        } catch {
            XCTAssertEqual(attempts, 1)
        }
    }
    
    func testNetworkReconnectionResetsSessionBlock() async {
        let mockMonitor = MockNetworkMonitor(initialOnline: false)
        let coordinator = LicenKitRetryCoordinator(
            networkMonitor: mockMonitor,
            retryDelays: .fastForTesting,
            userDefaults: testUserDefaults,
            rateLimitKey: testRateLimitKey
        )
        
        coordinator.setSessionBlocked(true)
        XCTAssertTrue(coordinator.isSessionBlocked)
        
        // 模拟物理切网：从断网变为连接连通
        mockMonitor.setOnline(true)
        
        // 验证 Session 熔断已自动被解除
        XCTAssertFalse(coordinator.isSessionBlocked)
        XCTAssertTrue(coordinator.isOnline)
    }
    
    func testBackgroundSyncSecondAttemptRateLimitMarksRateLimitedForToday() async {
        let mockMonitor = MockNetworkMonitor(initialOnline: true)
        let coordinator = LicenKitRetryCoordinator(
            networkMonitor: mockMonitor,
            retryDelays: .fastForTesting,
            userDefaults: testUserDefaults,
            rateLimitKey: testRateLimitKey
        )
        
        let attemptsLock = NSLock()
        var attempts = 0
        
        do {
            _ = try await coordinator.execute(scenario: .backgroundSync) {
                attemptsLock.lock()
                defer { attemptsLock.unlock() }
                attempts += 1
                if attempts == 1 {
                    throw LicenKitError.apiError(code: "HTTP_500", message: "Server temporary failure")
                } else {
                    throw LicenKitError.apiError(code: "HTTP_429", message: "Rate limit on retry")
                }
            }
            XCTFail("Should have thrown 429 on second attempt")
        } catch {
            attemptsLock.lock()
            let finalAttempts = attempts
            attemptsLock.unlock()
            XCTAssertEqual(finalAttempts, 2)
            XCTAssertTrue(coordinator.isRateLimitedToday)
            XCTAssertTrue(coordinator.isSessionBlocked)
        }
    }
    
    func testSystemNetworkMonitorStartStopRestart() {
        let monitor = SystemNetworkMonitor()
        monitor.start { _ in }
        XCTAssertTrue(monitor.isOnline)
        monitor.stop()
        
        // 验证 stop() 之后再次调用 start() 能够正常重新实例化启动而不崩溃
        monitor.start { _ in }
        XCTAssertTrue(monitor.isOnline)
        monitor.stop()
    }
}
