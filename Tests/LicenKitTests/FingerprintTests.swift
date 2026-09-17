import XCTest
@testable import LicenKit

final class FingerprintTests: XCTestCase {
    
    func testMacOSFingerprintExtraction() async throws {
        #if os(macOS)
        let provider = MacOSFingerprintProvider()
        let fingerprint1 = try await provider.getFingerprint()
        let fingerprint2 = try await provider.getFingerprint()
        
        XCTAssertFalse(fingerprint1.isEmpty, "Hardware fingerprint should not be empty")
        XCTAssertGreaterThanOrEqual(fingerprint1.count, 8, "Hardware fingerprint should have reasonable length")
        XCTAssertEqual(fingerprint1, fingerprint2, "Hardware fingerprint must be deterministic across calls")
        #endif
    }
}
