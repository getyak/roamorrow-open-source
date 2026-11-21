import XCTest
import Photos
@testable import SoloCompass

@MainActor
final class CompanionPhotoLibraryTests: XCTestCase {
    func testOnlyAuthorizedAndLimitedAccessCanFetchRecents() {
        for status: PHAuthorizationStatus in [.notDetermined, .denied, .restricted] {
            XCTAssertFalse(CompanionPhotoLibrary.canRead(status))
        }
        XCTAssertTrue(CompanionPhotoLibrary.canRead(.authorized))
        XCTAssertTrue(CompanionPhotoLibrary.canRead(.limited))
    }

    func testCancellationBeforeRequestStartsDoesNotInvokePhotoKit() async {
        let request = CompanionPhotoRequest<Int>()
        let gate = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await request.value { _ in
                    XCTFail("A previously cancelled task must not access Photos")
                    return {}
                }
                XCTFail("Cancellation should throw")
            } catch { XCTAssertTrue(error is CancellationError) }
        }
        await gate.value
    }

    func testCancellationBeforePhotoKitReturnsItsIDCancelsTheReturnedRequest() async {
        let cancelled = expectation(description: "Underlying request cancelled")
        let request = CompanionPhotoRequest<Int>()
        let task = Task { @MainActor in
            do {
                _ = try await request.value { finish in
                    withUnsafeCurrentTask { $0?.cancel() }
                    // A late successful callback must not overwrite cancellation.
                    finish(.success(9))
                    return { cancelled.fulfill() }
                }
                XCTFail("Cancellation must win")
            } catch { XCTAssertTrue(error is CancellationError) }
        }
        await task.value
        await fulfillment(of: [cancelled], timeout: 1)
    }

    func testRepeatedPhotoCallbacksDeliverOnlyTheFirstValue() async throws {
        let value = try await CompanionPhotoRequest<Int>().value { finish in
            finish(.success(7))
            finish(.success(9))
            return { XCTFail("A finished request needs no cancellation") }
        }
        XCTAssertEqual(value, 7)
    }

    func testCancellationAfterIDIsInstalledCancelsOutstandingPhotoRequest() async {
        let started = expectation(description: "Photo request started")
        let cancelled = expectation(description: "Photo request cancelled")
        let request = CompanionPhotoRequest<Int>()
        let task = Task {
            try await request.value { _ in
                started.fulfill()
                return { cancelled.fulfill() }
            }
        }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        await fulfillment(of: [cancelled], timeout: 1)
    }
}
