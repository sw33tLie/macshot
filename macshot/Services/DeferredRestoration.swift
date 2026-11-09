/// Tracks hidden resources across overlapping capture/restore cycles. A new
/// capture inherits anything still hidden and invalidates every old callback.
struct DeferredRestoration<Item: Equatable> {
    private(set) var pending: [Item] = []
    private var generation: UInt64 = 0

    mutating func begin(adding items: [Item]) {
        generation &+= 1
        for item in items where !pending.contains(item) { pending.append(item) }
    }

    mutating func schedule() -> UInt64? {
        generation &+= 1
        return pending.isEmpty ? nil : generation
    }

    mutating func remove(_ item: Item) {
        pending.removeAll { $0 == item }
        if pending.isEmpty { generation &+= 1 }
    }

    mutating func take(ifCurrent token: UInt64) -> [Item]? {
        guard token == generation else { return nil }
        return takeNow()
    }

    mutating func takeNow() -> [Item] {
        let items = pending
        pending.removeAll()
        generation &+= 1
        return items
    }
}
