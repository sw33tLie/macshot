import Foundation
@preconcurrency import Vision

// macshotOCR.xpc: runs Vision text recognition for the app in a process that
// can be thrown away. On macOS 27 an accurate request can block forever and
// poison every later request in the same process (FB25403069). The app gives
// up waiting after a few seconds and answers from the fast model; this process
// ends itself when a request outlives its hard deadline, or when the app drops
// the connection, and launchd starts a fresh one on the next request.

/// Result handoff between Vision's completion and the waiting work thread.
private final class Outcome: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<[OCRTextObservation], Error>?
    func set(_ result: Result<[OCRTextObservation], Error>) { lock.lock(); value = result; lock.unlock() }
    func get() -> Result<[OCRTextObservation], Error>? { lock.lock(); defer { lock.unlock() }; return value }
}

final class OCRService: NSObject, OCRServiceProtocol, @unchecked Sendable {
    /// One read at a time. Concurrent reads can occupy every Swift concurrency
    /// thread while Vision waits on its own queue, and nothing finishes.
    private let work = DispatchQueue(label: "com.sw33tlie.macshot.ocr-service.work", qos: .userInitiated)

    func processIdentifier(reply: @escaping (Int32) -> Void) {
        reply(getpid())
    }

    func recognize(_ requestData: Data, pixels: Data, reply: @escaping (Data?, String?) -> Void) {
        guard let request = try? JSONDecoder().decode(OCRServiceRequest.self, from: requestData) else {
            reply(nil, "Invalid OCR request")
            return
        }
        work.async {
            guard let image = OCRServicePixels.unpack(pixels, width: request.width, height: request.height,
                                                      bytesPerRow: request.bytesPerRow) else {
                reply(nil, "Invalid OCR image")
                return
            }

            // A stuck Vision call cannot be cancelled. Ending the process is the
            // only recovery, and the app has already answered from the fast model.
            let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            watchdog.schedule(deadline: .now() + max(1, request.hardDeadline))
            watchdog.setEventHandler { _exit(0) }
            watchdog.resume()
            defer { watchdog.cancel() }

            #if OCR_FAULT_INJECTION
            switch request.debugBehavior {
            case "hang":
                // Same shape as the macOS 27 bug: blocked at 0% CPU, never returns.
                DispatchSemaphore(value: 0).wait()
            case "empty":
                reply(try? JSONEncoder().encode(OCRServiceResponse(lines: [])), nil)
                return
            case "error":
                reply(nil, "Injected recognition failure")
                return
            default:
                break
            }
            #endif

            let finished = DispatchSemaphore(value: 0)
            let outcome = Outcome()
            _ = VisionOCR.startTextRecognition(
                cgImage: image,
                recognitionLevel: request.accurate ? .accurate : .fast,
                preferredLanguages: request.preferredLanguages
            ) { result in
                outcome.set(result)
                finished.signal()
            }
            finished.wait()

            switch outcome.get() {
            case .success(let observations):
                let lines = observations.map { observation in
                    OCRServiceLine(
                        text: observation.text,
                        boundingBox: observation.boundingBox,
                        characterBoxes: request.includeCharacterBoxes
                            ? OCRCharacterBoxes.compute(text: observation.text) { observation.boundingBox(for: $0) }
                            : [])
                }
                do {
                    reply(try JSONEncoder().encode(OCRServiceResponse(lines: lines)), nil)
                } catch {
                    reply(nil, error.localizedDescription)
                }
            case .failure(let error):
                reply(nil, error.localizedDescription)
            case nil:
                reply(nil, "Text recognition finished without a result")
            }
        }
    }
}

final class OCRServiceDelegate: NSObject, NSXPCListenerDelegate {
    private let service = OCRService()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: OCRServiceProtocol.self)
        connection.exportedObject = service
        // The app drops the connection to replace a process it no longer
        // trusts (an error, or no text where the fast model found some). Exit
        // so the next connection gets a fresh process, not this one.
        connection.invalidationHandler = { _exit(0) }
        connection.resume()
        return true
    }
}

let delegate = OCRServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
