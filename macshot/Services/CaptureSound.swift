import AVFoundation
import Foundation

/// The capture sound, played off the main thread.
///
/// Starting playback waits for the audio device to start. With a slow device
/// (Bluetooth headphones waking, an aggregate device) that took up to ~9 s,
/// and `NSSound.play()` on the main thread froze macshot for all of it (#418).
/// Everything here runs on one serial queue that owns the player, so a stalled
/// start delays only the sound. Nonisolated: the app defaults to MainActor
/// isolation, and the player must never be touched from the main thread.
nonisolated final class CaptureSound: @unchecked Sendable {

    static let shared = CaptureSound(start: CaptureSound.playerStart())

    private let queue = DispatchQueue(label: "com.sw33tlie.macshot.capture-sound", qos: .userInitiated)
    /// Runs on `queue`: (re)starts the sound from the beginning, or only
    /// prepares it when `prepareOnly` is true.
    private let start: (_ prepareOnly: Bool) -> Void

    init(start: @escaping (_ prepareOnly: Bool) -> Void) {
        self.start = start
    }

    /// Plays the sound from the start. Returns immediately.
    func play() {
        queue.async { self.start(false) }
    }

    /// Loads the sound and opens the audio device ahead of the first capture.
    /// Returns immediately.
    func warmUp() {
        queue.async { self.start(true) }
    }

    /// Blocks until queued work has run. For tests.
    func drain() {
        queue.sync {}
    }

    // MARK: - Player

    private static let soundURLs = [
        URL(fileURLWithPath: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"),
        URL(fileURLWithPath: "/System/Library/Sounds/Tink.aiff"),
    ]

    /// A player confined to the sound queue.
    private static func playerStart() -> (Bool) -> Void {
        var player: AVAudioPlayer?
        return { prepareOnly in
            if player == nil {
                player = soundURLs.lazy.compactMap { try? AVAudioPlayer(contentsOf: $0) }.first
            }
            guard let player else { return }
            if prepareOnly {
                player.prepareToPlay()
                return
            }
            player.stop()
            player.currentTime = 0
            player.play()
        }
    }
}
