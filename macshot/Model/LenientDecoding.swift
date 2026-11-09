import Foundation

// MARK: - Forward/backward compatible decoding
//
// Swift's synthesized `init(from:)` requires a key for every non-optional
// property *even when the property has a default value*. That makes the
// default a lie for persisted data: a capture written before a field existed
// throws `keyNotFound`, and because the whole file decodes as one array, a
// single missing key drops every annotation in that capture.
//
// Persisted models therefore decode through the helpers below: a missing or
// wrong-typed value falls back to the model's default instead of destroying
// the payload.

extension KeyedDecodingContainer {

    /// Decodes `key`, falling back to `fallback` when it is absent, null, or
    /// stored with an unexpected type (all of which happen with files written
    /// by older or newer builds).
    nonisolated func decode<T: Decodable>(_ key: Key, or fallback: T) -> T {
        guard let value = try? decodeIfPresent(T.self, forKey: key) else { return fallback }
        return value
    }

    /// Optional variant: absent or unreadable decodes to nil rather than
    /// throwing.
    nonisolated func decodeOptional<T: Decodable>(_ key: Key, as type: T.Type = T.self) -> T? {
        guard let value = try? decodeIfPresent(T.self, forKey: key) else { return nil }
        return value
    }
}

/// Decodes an array element-wise, skipping entries that fail. One corrupt
/// annotation (or history row) then costs that entry, not the whole file.
enum LenientArrayDecoder {

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> [T]? {
        let decoder = JSONDecoder()
        if let values = try? decoder.decode([T].self, from: data) {
            return values
        }
        // Strict decoding failed — fall back to salvaging what we can.
        guard let raw = try? decoder.decode([FailableElement<T>].self, from: data) else {
            return nil
        }
        let salvaged = raw.compactMap(\.value)
        return salvaged.isEmpty ? nil : salvaged
    }

    /// Wrapper whose decoding never fails: an element that can't be read
    /// becomes `nil` instead of aborting the array.
    private struct FailableElement<T: Decodable>: Decodable {
        let value: T?

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            value = try? container.decode(T.self)
        }
    }
}
