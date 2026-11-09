import Foundation
import XCTest

/// The capture sound must never block the main thread (#418): starting
/// playback waits for the audio device, which took ~9 s on a slow device.
final class CaptureSoundTests: XCTestCase {

    /// A start that blocks for a long time (a slow audio device) must not
    /// delay `play()`'s caller.
    @MainActor
    func testPlayReturnsWhileStartingTheSoundIsStalled() {
        let release = DispatchSemaphore(value: 0)
        let started = expectation(description: "sound started")
        let sound = CaptureSound(start: { _ in
            started.fulfill()
            _ = release.wait(timeout: .now() + 5)
        })
        let before = Date()
        sound.play()
        XCTAssertLessThan(Date().timeIntervalSince(before), 0.05, "play() waited for the audio device")
        wait(for: [started], timeout: 2)
        release.signal()
        sound.drain()
    }

    @MainActor
    func testTheSoundIsNeverStartedOnTheMainThread() {
        var onMain: [Bool] = []
        let lock = NSLock()
        let sound = CaptureSound(start: { _ in
            lock.lock(); onMain.append(Thread.isMainThread); lock.unlock()
        })
        sound.warmUp()
        sound.play()
        sound.play()
        sound.drain()
        XCTAssertEqual(onMain, [false, false, false])
    }

    /// Warm-up only prepares; each play starts from the beginning, in order.
    func testWarmUpPreparesAndPlaysRunInOrder() {
        var calls: [Bool] = []
        let sound = CaptureSound(start: { prepareOnly in calls.append(prepareOnly) })
        sound.warmUp()
        sound.play()
        sound.play()
        sound.drain()
        XCTAssertEqual(calls, [true, false, false])
    }

    /// The real player loads the system sound (or its fallback) and prepares
    /// without trouble; playing is left out so the test suite stays silent.
    func testTheRealSoundLoadsAndPrepares() {
        CaptureSound.shared.warmUp()
        CaptureSound.shared.drain()
    }
}
