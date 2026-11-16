import Cocoa
import CoreText

// Installed as main.swift only in probe-ocr-service.sh's private source copy.
// Runs inside the real, sandboxed app bundle with the embedded macshotOCR.xpc,
// built with OCR_FAULT_INJECTION so the service can be told to hang, fail or
// return nothing, the way Vision misbehaves on macOS 27.

nonisolated(unsafe) var failures = 0

nonisolated func log(_ message: String) {
    print(message)
    fflush(stdout)
}

nonisolated func check(_ condition: Bool, _ message: String) {
    if condition {
        log("  ok   " + message)
    } else {
        failures += 1
        log("  FAIL " + message)
    }
}

nonisolated func textImage(_ lines: [String], width: Int = 1400, height: Int? = nil, fontSize: CGFloat = 34) -> CGImage {
    let lineHeight = Int(fontSize * 1.8)
    let height = height ?? (lines.count * lineHeight + 80)
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    for (index, text) in lines.enumerated() {
        let string = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize), .foregroundColor: NSColor.black,
        ])
        context.textPosition = CGPoint(x: 40, y: CGFloat(height - 60 - index * lineHeight))
        CTLineDraw(CTLineCreateWithAttributedString(string), context)
    }
    return context.makeImage()!
}

struct Outcome {
    let lines: [OCRTextObservation]
    let error: Error?
    let route: OCRServiceClient.Route
    let seconds: Double
    var text: String { lines.map(\.text).joined(separator: " | ") }
}

nonisolated func recognize(_ image: CGImage, languages: [String] = ["en-US"],
                           characterBoxes: Bool = false) -> Outcome {
    let done = DispatchSemaphore(value: 0)
    let started = Date()
    nonisolated(unsafe) var result: Outcome?
    OCRServiceClient.shared.recognize(cgImage: image, preferredLanguages: languages,
                                      includeCharacterBoxes: characterBoxes) { lines, error, route in
        result = Outcome(lines: lines, error: error, route: route, seconds: Date().timeIntervalSince(started))
        done.signal()
    }
    if done.wait(timeout: .now() + 200) == .timedOut {
        failures += 1
        log("  FAIL request never completed (200 s)")
        return Outcome(lines: [], error: nil, route: .inProcess, seconds: 200)
    }
    return result!
}

nonisolated func servicePID() -> Int32? {
    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var pid: Int32?
    OCRServiceClient.shared.serviceProcessIdentifier { pid = $0; done.signal() }
    _ = done.wait(timeout: .now() + 30)
    return pid
}

nonisolated func describe(_ outcome: Outcome) -> String {
    String(format: "%@ in %.2fs: %@", outcome.route.rawValue, outcome.seconds, outcome.text)
}

nonisolated func runScenarios() {
    let client = OCRServiceClient.shared
    let english = textImage(["Invoice 2026 total due Friday", "Golden Gate Bridge"])
    let mixed = textImage(["隐私与安全性 Privacy & Security"])
    let zh = ["zh-Hans-CN", "en-US"]

    log("== Setup")
    log("app pid \(getpid()), sandbox container: \(ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] ?? "none")")
    check(ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil, "app runs sandboxed")
    check(client.serviceName != nil, "embedded service found: \(client.serviceName ?? "nil")")

    log("== 1. First request (may include the one-time model compile)")
    var first = recognize(english)
    log("  " + describe(first))
    check(first.text.contains("Invoice"), "first request returns text without waiting for the compile")
    check(first.seconds < 12, "first request answered within the soft timeout")
    let warmStart = Date()
    var polls = 0
    while first.route != .service && Date().timeIntervalSince(warmStart) < 150 {
        Thread.sleep(forTimeInterval: 2)
        first = recognize(english)
        polls += 1
        if polls % 5 == 1 { log("  waiting for the service: " + describe(first)) }
    }
    log(String(format: "  service ready after %.0fs extra", Date().timeIntervalSince(warmStart)))
    check(first.route == .service, "service answers once warm")

    log("== 2. Accurate model in the service (fast model can't read Chinese)")
    let chinese = recognize(mixed, languages: zh)
    log("  " + describe(chinese))
    check(chinese.route == .service && chinese.text.contains("隐私"), "Chinese recognized by the service")
    let appPID = getpid()
    let pidA = servicePID()
    log("  service pid \(pidA.map(String.init) ?? "nil")")
    check(pidA != nil && pidA != appPID, "service runs in its own process")

    log("== 3. Substring boxes across the process boundary")
    let contact = recognize(textImage(["Contact hello@example.com today"]), characterBoxes: true)
    log("  " + describe(contact))
    if let line = contact.lines.first(where: { $0.text.contains("hello@example.com") }),
       let range = line.text.range(of: "hello@example.com"), let box = line.boundingBox(for: range) {
        log(String(format: "  line x=%.3f w=%.3f, email x=%.3f w=%.3f", line.boundingBox.minX, line.boundingBox.width, box.minX, box.width))
        check(box.width > 0 && box.width < line.boundingBox.width * 0.8 && box.minX > line.boundingBox.minX,
              "email box is inside and narrower than its line")
    } else {
        check(false, "email substring box available")
    }

    log("== 4. Stuck service (the macOS 27 hang)")
    client.setTiming(.init(softTimeout: 4, hardDeadline: 12, fastTimeout: 10))
    client.injectNextServiceBehavior("hang")
    let hung = recognize(english)
    log("  " + describe(hung))
    check(hung.route == .fastAfterTimeout && hung.text.contains("Invoice"), "hung request answered by the fast model")
    check(hung.seconds < 6, "answered at the soft timeout, not the hang")
    let busy = recognize(english)
    log("  " + describe(busy))
    check(busy.route == .fastWhileServiceBusy && busy.seconds < 2, "next request skips the stuck service")
    log("  waiting for the service's own deadline")
    Thread.sleep(forTimeInterval: 12)
    let recovered = recognize(mixed, languages: zh)
    log("  " + describe(recovered))
    let pidB = servicePID()
    log("  service pid \(pidB.map(String.init) ?? "nil")")
    check(recovered.route == .service && recovered.text.contains("隐私"), "accurate OCR works again without relaunching")
    check(pidB != nil && pidB != pidA, "a new service process replaced the stuck one")

    log("== 5. Service error")
    client.injectNextServiceBehavior("error")
    let failed = recognize(english)
    log("  " + describe(failed))
    check(failed.route == .fastAfterServiceFailure && failed.text.contains("Invoice"), "error answered by the fast model")
    let restarting = recognize(english)
    log("  " + describe(restarting))
    check(restarting.route == .fastWhileServiceRestarts && restarting.seconds < 2,
          "no waiting on launchd while the replacement is throttled")
    Thread.sleep(forTimeInterval: 11)
    let afterError = recognize(english)
    let pidC = servicePID()
    log("  " + describe(afterError) + ", pid \(pidC.map(String.init) ?? "nil")")
    check(afterError.route == .service && pidC != nil && pidC != pidB, "failed service replaced")

    log("== 6. Silent empty result")
    client.injectNextServiceBehavior("empty")
    let empty = recognize(english)
    log("  " + describe(empty))
    check(empty.route == .fastAfterEmptyResult && empty.text.contains("Invoice"), "empty accurate result rescued by the fast model")
    Thread.sleep(forTimeInterval: 11)
    let afterEmpty = recognize(english)
    let pidD = servicePID()
    log("  " + describe(afterEmpty) + ", pid \(pidD.map(String.init) ?? "nil")")
    check(afterEmpty.route == .service && pidD != pidC, "untrusted service replaced")
    let blank = recognize(textImage([]))
    log("  blank image: " + describe(blank))
    check(blank.lines.isEmpty && blank.route == .service, "a blank image is just empty, no replacement")
    check(servicePID() == pidD, "service kept after a genuinely empty image")

    client.setTiming(.init())

    log("== 7. Sequential requests")
    var times: [Double] = []
    var sequentialOK = true
    for index in 0..<25 {
        let outcome = recognize(textImage(["Line \(index) of the sequential run", "Straße Résumé 1234 5678"]))
        times.append(outcome.seconds)
        if outcome.route != .service || !outcome.text.contains("sequential") { sequentialOK = false; log("  " + describe(outcome)) }
    }
    times.sort()
    log(String(format: "  median %.3fs, max %.3fs", times[times.count / 2], times.last!))
    check(sequentialOK, "25 sequential requests answered by the service")

    log("== 8. Burst of 12 concurrent requests")
    let group = DispatchGroup()
    let lock = NSLock()
    nonisolated(unsafe) var burst: [Outcome] = []
    let burstStart = Date()
    for index in 0..<12 {
        group.enter()
        DispatchQueue.global().async {
            let outcome = recognize(textImage(["Burst request number \(index)"]))
            lock.lock(); burst.append(outcome); lock.unlock()
            group.leave()
        }
    }
    _ = group.wait(timeout: .now() + 120)
    log(String(format: "  %d finished in %.2fs; routes: %@", burst.count, Date().timeIntervalSince(burstStart),
               Dictionary(grouping: burst, by: \.route.rawValue).mapValues(\.count).description))
    check(burst.count == 12 && burst.allSatisfy { $0.text.contains("Burst") }, "every burst request returned its text")

    log("== 9. Full-screen sized capture")
    let big = textImage((0..<30).map { "Row \($0): The quick brown fox jumps over the lazy dog" },
                        width: 5120, height: 2880, fontSize: 40)
    let large = recognize(big)
    log(String(format: "  %@ in %.2fs, %d lines", large.route.rawValue, large.seconds, large.lines.count))
    check(large.route == .service && large.lines.count >= 25, "5K capture recognized by the service")

    log(failures == 0 ? "PROBE PASSED" : "PROBE FAILED: \(failures) check(s)")
    log("SERVICE PID \(servicePID().map(String.init) ?? "nil")")
}

@MainActor
final class OCRProbeDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Thread.detachNewThread {
            runScenarios()
            let status: Int32 = failures == 0 ? 0 : 1
            DispatchQueue.main.async {
                NSApp.terminate(nil)
                exit(status)
            }
        }
    }
}

// The probe runs on macOS 27, so assumeIsolated is always available.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let probeDelegate = OCRProbeDelegate()
    app.delegate = probeDelegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(probeDelegate) { app.run() }
}
