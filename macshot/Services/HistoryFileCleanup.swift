import Foundation

/// Unindexed originals can be the only surviving part of a failed history
/// transaction. Automatic cleanup reclaims regenerable caches, never captures,
/// raw images, annotations or edit state. Retention/explicit deletion owns those.
enum HistoryFileCleanup {
    @discardableResult
    static func sweep(directory: URL, indexedIDs: Set<String>?, asOf date: Date) -> DirectorySweeper.Result {
        // A missing, unreadable or partly salvaged index is not proof of orphanhood.
        guard let indexedIDs else { return DirectorySweeper.Result() }
        let known = Set(indexedIDs.map { $0.lowercased() })
        return DirectorySweeper.sweep(directory: directory, olderThan: 24 * 60 * 60, now: date) { name in
            guard name.count > 36 else { return false }
            let id = String(name.prefix(36))
            guard UUID(uuidString: id) != nil, !known.contains(id.lowercased()) else { return false }
            return ["_thumb.png", "_preview.png"].contains(String(name.dropFirst(36)))
        }
    }
}
