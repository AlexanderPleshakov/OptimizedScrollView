@MainActor
enum DiffApplier {
    struct Plan {
        let newOrder: [ItemID]
        let newItems: [ItemID: any ChatItem]
        let inserted: Set<ItemID>
        let removed: Set<ItemID>
        let modelChanged: Set<ItemID>
        let heightChanged: Set<ItemID>
    }

    /// Computes the post-batch state without touching the engine. Caller commits
    /// the result by calling `engine.rebuildAll(items:)` with the new ordered list
    /// and updating its renderer with the inserted/removed/modelChanged sets.
    ///
    /// Order: removes are applied first (so subsequent insert indices are interpreted
    /// against the shrunken list), then inserts in ascending-index order, then updates.
    /// Each insert sees the array after earlier inserts in the same batch.
    static func plan(
        changes: [ChatScrollView.Change],
        currentOrder: [ItemID],
        currentItems: [ItemID: any ChatItem]
    ) -> Plan {
        var inserts: [(item: any ChatItem, at: Int)] = []
        var removes: Set<ItemID> = []
        var updates: [any ChatItem] = []
        for change in changes {
            switch change {
            case .insert(let item, let at): inserts.append((item, at))
            case .remove(let id): removes.insert(id)
            case .update(let item): updates.append(item)
            }
        }

        var newOrder = currentOrder
        var newItems = currentItems
        var insertedIds: Set<ItemID> = []
        var modelChanged: Set<ItemID> = []
        var heightChanged: Set<ItemID> = []

        if !removes.isEmpty {
            newOrder.removeAll { removes.contains($0) }
            for id in removes { newItems.removeValue(forKey: id) }
        }

        inserts.sort { $0.at < $1.at }
        for (item, at) in inserts {
            let clamped = max(0, min(at, newOrder.count))
            newOrder.insert(item.id, at: clamped)
            newItems[item.id] = item
            insertedIds.insert(item.id)
        }

        for item in updates {
            let oldHeight = currentItems[item.id]?.height
            newItems[item.id] = item
            modelChanged.insert(item.id)
            if let old = oldHeight, old != item.height {
                heightChanged.insert(item.id)
            }
        }

        return Plan(
            newOrder: newOrder,
            newItems: newItems,
            inserted: insertedIds,
            removed: removes,
            modelChanged: modelChanged,
            heightChanged: heightChanged
        )
    }
}
