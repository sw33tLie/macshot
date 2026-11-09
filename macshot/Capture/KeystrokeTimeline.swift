import Foundation
import CoreGraphics

/// Turns recorded key presses into on-screen labels: shortcuts appear on
/// their own ("⌘ ⇧ 4"), plain typing accumulates into a short running line.
nonisolated enum KeystrokeTimeline {
    struct Label: Equatable, Sendable {
        var start: Double
        var end: Double
        var text: String
    }

    // NSEvent.ModifierFlags raw values (device independent).
    static let shiftMask: UInt32 = 1 << 17
    static let controlMask: UInt32 = 1 << 18
    static let optionMask: UInt32 = 1 << 19
    static let commandMask: UInt32 = 1 << 20

    static let hold: Double = 1.4
    static let typingJoin: Double = 1.3
    static let maxTypedCharacters = 24

    /// Special keys recorded with their symbol; these read as commands even
    /// without a modifier (Return, Escape, arrows…).
    static let commandSymbols: Set<String> = ["↩", "⇥", "⌫", "⌦", "⎋", "↑", "↓", "←", "→", "↖", "↘", "⇞", "⇟",
                                              "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12"]

    static func labels(from keys: [CursorRecording.Key], shortcutsOnly: Bool) -> [Label] {
        var labels: [Label] = []
        var typing: (start: Double, last: Double, text: String)?

        func flushTyping() {
            guard let current = typing else { return }
            labels.append(Label(start: current.last, end: current.last + hold, text: current.text))
            typing = nil
        }

        for key in keys.sorted(by: { $0.time < $1.time }) {
            let mods = key.modifiers
            let hasCommandModifier = mods & (commandMask | controlMask | optionMask) != 0
            let name = key.characters
            guard !name.isEmpty else { continue }
            let isSpecial = commandSymbols.contains(name)
            if hasCommandModifier || isSpecial {
                flushTyping()
                // "Shortcuts only" hides bare Return/arrow presses too.
                if shortcutsOnly && !hasCommandModifier { continue }
                labels.append(Label(start: key.time, end: key.time + hold, text: shortcutText(modifiers: mods, key: name)))
                continue
            }
            guard !shortcutsOnly else { continue }
            let character = name == "Space" ? " " : name
            if var current = typing, key.time - current.last <= typingJoin {
                // Each keystroke shows the line as typed so far.
                labels.append(Label(start: current.last, end: key.time, text: current.text))
                current.text += character
                if current.text.count > maxTypedCharacters {
                    current.text = "…" + String(current.text.suffix(maxTypedCharacters - 1))
                }
                current.last = key.time
                typing = current
            } else {
                flushTyping()
                typing = (key.time, key.time, character)
            }
        }
        flushTyping()
        // A later label replaces an earlier one immediately.
        labels.sort { $0.start < $1.start }
        for i in labels.indices.dropLast() where labels[i].end > labels[i + 1].start {
            labels[i].end = labels[i + 1].start
        }
        return labels.filter { $0.end > $0.start && !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    static func shortcutText(modifiers: UInt32, key: String) -> String {
        var parts: [String] = []
        if modifiers & controlMask != 0 { parts.append("⌃") }
        if modifiers & optionMask != 0 { parts.append("⌥") }
        if modifiers & shiftMask != 0 { parts.append("⇧") }
        if modifiers & commandMask != 0 { parts.append("⌘") }
        parts.append(key.count == 1 ? key.uppercased() : key)
        return parts.joined(separator: " ")
    }

    /// Active label and its opacity at `t`.
    static func active(at t: Double, in labels: [Label], fadeIn: Double = 0.1, fadeOut: Double = 0.25) -> (Label, CGFloat)? {
        guard let i = labels.lastIndex(where: { $0.start <= t }), t < labels[i].end else { return nil }
        let label = labels[i]
        // A label continuing the previous one (typing) appears instantly;
        // fading every keystroke would make typing flicker.
        let continues = i > 0 && abs(labels[i - 1].end - label.start) < 0.0001
        let appear = continues ? 1 : min(1, (t - label.start) / fadeIn)
        // Replaced labels cut over without fading out.
        let replaced = i + 1 < labels.count && abs(labels[i + 1].start - label.end) < 0.0001
        let vanish = replaced ? 1 : min(1, (label.end - t) / fadeOut)
        return (label, CGFloat(max(0, min(appear, vanish))))
    }
}

/// Splits recognized speech into caption lines of a few words.
nonisolated enum CaptionTimeline {
    struct Word: Equatable, Sendable {
        var text: String
        var start: Double
        var end: Double
    }

    static func segments(from words: [Word], maxWords: Int, maxGap: Double = 0.9) -> [VideoCaptionSegment] {
        var result: [VideoCaptionSegment] = []
        var current: [Word] = []
        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let text = current.map(\.text).joined(separator: " ")
            result.append(VideoCaptionSegment(startTime: first.start, endTime: max(last.end, first.start + 0.4), text: text))
            current.removeAll()
        }
        for word in words where !word.text.trimmingCharacters(in: .whitespaces).isEmpty {
            if let last = current.last, word.start - last.end > maxGap || current.count >= maxWords { flush() }
            current.append(word)
            if word.text.last.map({ ".!?".contains($0) }) == true { flush() }
        }
        flush()
        for i in result.indices.dropLast() where result[i].endTime > result[i + 1].startTime {
            result[i].endTime = result[i + 1].startTime
        }
        return result
    }

    /// `captions` must be sorted by start time.
    static func active(at t: Double, in captions: [VideoCaptionSegment]) -> (VideoCaptionSegment, CGFloat)? {
        guard let caption = captions.last(where: { $0.startTime <= t && t < $0.endTime }) else { return nil }
        let appear = min(1, (t - caption.startTime) / 0.12)
        let vanish = min(1, (caption.endTime - t) / 0.12)
        return (caption, CGFloat(max(0, min(appear, vanish))))
    }

    /// SubRip text for the captions, on the edited (output) clock.
    static func srt(_ captions: [VideoCaptionSegment], mapTime: (Double) -> Double) -> String {
        func stamp(_ seconds: Double) -> String {
            let ms = Int((max(0, seconds) * 1000).rounded())
            return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
        }
        var lines: [String] = []
        for (index, caption) in captions.sorted(by: { $0.startTime < $1.startTime }).enumerated() {
            let start = mapTime(caption.startTime), end = mapTime(caption.endTime)
            guard end > start else { continue }
            lines.append("\(index + 1)\n\(stamp(start)) --> \(stamp(end))\n\(caption.text)\n")
        }
        return lines.joined(separator: "\n")
    }
}
