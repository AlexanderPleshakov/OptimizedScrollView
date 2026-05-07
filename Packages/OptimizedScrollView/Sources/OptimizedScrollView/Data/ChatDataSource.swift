import Foundation

actor ChatDataSource {
    private let provider: ChatDataSourceProvider
    private var lists: [BatchListID: BatchList] = [:]
    private(set) var currentListId: BatchListID?

    private var loadingInitial = false
    private var loadingPrevious = false
    private var loadingNext = false
    private var loadingForJump: Set<ItemID> = []

    init(provider: ChatDataSourceProvider) {
        self.provider = provider
    }

    func snapshot() -> DataSnapshot? {
        guard let id = currentListId, let list = lists[id] else { return nil }
        return Self.makeSnapshot(listId: id, list: list)
    }

    // MARK: - Initial

    func loadInitial() async throws -> DataSnapshot {
        if loadingInitial, let snap = snapshot() { return snap }
        loadingInitial = true
        defer { loadingInitial = false }

        let batch = try await provider.loadInitial()
        let listId = BatchListID()
        lists[listId] = BatchList(id: listId, batches: [batch])
        currentListId = listId
        mergeAdjacentLists(into: listId)
        return Self.makeSnapshot(listId: listId, list: lists[listId]!)
    }

    // MARK: - Pagination

    func loadPrevious() async throws -> DataSnapshot? {
        guard let listId = currentListId, !loadingPrevious else { return nil }
        guard let cursor = lists[listId]?.topCursor else { return nil }
        loadingPrevious = true
        defer { loadingPrevious = false }

        guard let batch = try await provider.loadPrevious(before: cursor) else { return nil }

        // currentListId may have moved during await (e.g. due to a concurrent jump).
        // Splice into whichever list the batch is adjacent to; if it's no longer
        // the originally-targeted one, the caller will still receive a coherent
        // snapshot of whatever the current list became.
        guard let targetId = currentListId, var list = lists[targetId], targetId == listId else {
            return nil
        }
        list.prepend(batch)
        lists[targetId] = list
        mergeAdjacentLists(into: targetId)
        return Self.makeSnapshot(listId: targetId, list: lists[targetId]!)
    }

    func loadNext() async throws -> DataSnapshot? {
        guard let listId = currentListId, !loadingNext else { return nil }
        guard let cursor = lists[listId]?.bottomCursor else { return nil }
        loadingNext = true
        defer { loadingNext = false }

        guard let batch = try await provider.loadNext(after: cursor) else { return nil }

        guard let targetId = currentListId, var list = lists[targetId], targetId == listId else {
            return nil
        }
        list.append(batch)
        lists[targetId] = list
        mergeAdjacentLists(into: targetId)
        return Self.makeSnapshot(listId: targetId, list: lists[targetId]!)
    }

    // MARK: - Jump

    func loadBatch(containing id: ItemID) async throws -> DataSnapshot? {
        // If the current list already has the item, the caller (ChatScrollView)
        // can skip the fetch and scroll directly. This branch returns the current
        // snapshot so the caller has uniform handling.
        if let listId = currentListId, let list = lists[listId], list.contains(itemId: id) {
            return Self.makeSnapshot(listId: listId, list: list)
        }
        if loadingForJump.contains(id) { return nil }
        loadingForJump.insert(id)
        defer { loadingForJump.remove(id) }

        guard let batch = try await provider.loadBatch(containing: id) else { return nil }

        // Splice into an existing list if its boundary cursors match. The merge
        // pass below will then absorb any further-adjacent lists (e.g. when the
        // freshly-fetched batch is the missing bridge between two previously
        // disjoint lists), leaving a single coherent list at `existingId`.
        for (existingId, var existing) in lists {
            if let bottom = existing.bottomCursor, let top = batch.topCursor, bottom == top {
                existing.append(batch)
                lists[existingId] = existing
                currentListId = existingId
                mergeAdjacentLists(into: existingId)
                return Self.makeSnapshot(listId: existingId, list: lists[existingId]!)
            }
            if let top = existing.topCursor, let bottom = batch.bottomCursor, top == bottom {
                existing.prepend(batch)
                lists[existingId] = existing
                currentListId = existingId
                mergeAdjacentLists(into: existingId)
                return Self.makeSnapshot(listId: existingId, list: lists[existingId]!)
            }
        }

        // Not adjacent to anything we have — start a new list and switch.
        let newListId = BatchListID()
        lists[newListId] = BatchList(id: newListId, batches: [batch])
        currentListId = newListId
        mergeAdjacentLists(into: newListId)
        return Self.makeSnapshot(listId: newListId, list: lists[newListId]!)
    }

    // MARK: - Push

    /// Appends items at the bottom of *history* — i.e. the `BatchList` whose
    /// `bottomCursor == nil`. The user's currently-shown list (`currentListId`)
    /// is not changed: if they happen to be reading a history slice, the items
    /// land in a different list and the host fires the new-items delegate so
    /// the user can tap a banner to navigate back via `scrollToLiveTail`.
    func append(items newItems: [any ChatItem]) -> DataSnapshot? {
        guard !newItems.isEmpty else { return snapshot() }

        let targetId: BatchListID
        if let id = liveTailId() {
            targetId = id
        } else {
            // Caller pushed before a live tail exists (e.g. before loadInitial).
            // Synthesize one so the items aren't dropped on the floor; if no
            // current view exists yet, make this list the current one too.
            let id = BatchListID()
            lists[id] = BatchList(id: id, batches: [])
            if currentListId == nil { currentListId = id }
            targetId = id
        }

        var tail = lists[targetId]!
        if tail.batches.isEmpty {
            tail.batches.append(Batch(
                id: BatchID(raw: UUID().uuidString),
                items: newItems,
                topCursor: nil,
                bottomCursor: nil
            ))
        } else {
            let lastIdx = tail.batches.count - 1
            let last = tail.batches[lastIdx]
            tail.batches[lastIdx] = Batch(
                id: last.id,
                items: last.items + newItems,
                topCursor: last.topCursor,
                bottomCursor: last.bottomCursor   // stays nil — still at history bottom
            )
        }
        lists[targetId] = tail
        // Push doesn't change boundary cursors of the live tail (it just appends
        // items inside the bottom batch), so no merge pass is needed.
        return Self.makeSnapshot(listId: targetId, list: tail)
    }

    /// Makes the live-tail list (`bottomCursor == nil`) the current list and
    /// returns its snapshot. Used by `ChatScrollView.scrollToLiveTail` when the
    /// user taps a "new messages" banner and we need to navigate them back to
    /// the live conversation tail from a history slice.
    func switchToLiveTail() -> DataSnapshot? {
        guard let id = liveTailId() else { return nil }
        currentListId = id
        return Self.makeSnapshot(listId: id, list: lists[id]!)
    }

    // MARK: - Merging

    /// Absorbs any list whose boundary cursor matches `focalId`'s into `focalId`,
    /// repeating until no further merge is possible. The focal id is always the
    /// survivor — keeping the user's `currentListId` stable through the merge —
    /// and any absorbed list is removed from `lists`. If `currentListId` happened
    /// to point at the absorbed list, it is reassigned to `focalId`.
    ///
    /// Run this at the end of any mutation that could change a list's top or
    /// bottom cursor (loadInitial / loadNext / loadPrevious / loadBatch). Push
    /// is exempt because it only mutates items inside the bottom batch.
    private func mergeAdjacentLists(into focalId: BatchListID) {
        var changed = true
        while changed {
            changed = false
            guard let focal = lists[focalId] else { return }

            // focal.bottom == other.top -> other goes after focal.
            if let bottom = focal.bottomCursor {
                for (otherId, other) in lists where otherId != focalId {
                    if other.topCursor == bottom {
                        var merged = focal
                        merged.batches.append(contentsOf: other.batches)
                        lists[focalId] = merged
                        lists.removeValue(forKey: otherId)
                        if currentListId == otherId { currentListId = focalId }
                        changed = true
                        break
                    }
                }
                if changed { continue }
            }

            // focal.top == other.bottom -> other goes before focal.
            if let top = focal.topCursor {
                for (otherId, other) in lists where otherId != focalId {
                    if other.bottomCursor == top {
                        var merged = focal
                        merged.batches = other.batches + focal.batches
                        lists[focalId] = merged
                        lists.removeValue(forKey: otherId)
                        if currentListId == otherId { currentListId = focalId }
                        changed = true
                        break
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func liveTailId() -> BatchListID? {
        for (id, list) in lists where list.bottomCursor == nil {
            return id
        }
        return nil
    }

    private static func makeSnapshot(listId: BatchListID, list: BatchList) -> DataSnapshot {
        DataSnapshot(
            listId: listId,
            items: list.items,
            topCursor: list.topCursor,
            bottomCursor: list.bottomCursor
        )
    }
}
