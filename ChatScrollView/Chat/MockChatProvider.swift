import Foundation
import OptimizedScrollView

/// In-memory `ChatDataSourceProvider` with prebuilt messages spread over
/// ~40 calendar days (one group per day, ~20 messages each). Every request
/// sleeps a tiny amount to simulate network latency, exercising the actor's
/// dedup machinery and the renderer's anchor preservation under async pagination.
struct MockChatProvider: ChatDataSourceProvider {
    static let totalCount = 1500
    static let pageSize = 30

    let allMessages: [Message]

    static func makeDefault() -> MockChatProvider {
        let cal = Calendar.current
        let baseDate = cal.startOfDay(for: Date())
        var msgs: [Message] = []
        msgs.reserveCapacity(totalCount)
        for i in 0..<totalCount {
            let dayOffset = i / 20  // 20 messages per day → ~40 days
            let date = cal.date(byAdding: .day, value: -(40 - dayOffset), to: baseDate)!
            let groupId = ItemID(dayKey(date, cal: cal))
            let text = "[\(i)] " + fakeText(seed: i)
            msgs.append(Message(
                id: ItemID("msg-\(i)"),
                text: text,
                isOutgoing: i % 3 == 0,
                groupId: groupId,
                height: estimateHeight(text: text)
            ))
        }
        return MockChatProvider(allMessages: msgs)
    }

    static func dayKey(_ date: Date, cal: Calendar) -> String {
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    static func dateLabel(for groupId: ItemID) -> String {
        let parts = groupId.raw.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return groupId.raw }
        var c = DateComponents()
        c.year = parts[0]; c.month = parts[1]; c.day = parts[2]
        guard let date = Calendar.current.date(from: c) else { return groupId.raw }
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f.string(from: date)
    }

    static func fakeText(seed: Int) -> String {
        let pool = [
            "hi", "hello", "ok", "got it", "sure",
            "lorem ipsum dolor sit amet",
            "the quick brown fox jumps over the lazy dog",
            "lol 😂", "yep", "let me check that one",
            "👍 done", "wait what",
        ]
        var n = seed
        var result = ""
        for _ in 0..<((seed % 4) + 1) {
            result += pool[abs(n) % pool.count] + " "
            n = n &* 1103515245 &+ 12345
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Coarse height estimate from text length. Real chat would measure properly
    /// (or have rich models with image/attachment heights baked in); for the
    /// harness this is enough — all that matters to the engine is that the
    /// number we hand it matches whatever the cell will actually render.
    static func estimateHeight(text: String) -> CGFloat {
        let approxCharsPerLine = 36
        let lines = max(1, (text.count + approxCharsPerLine - 1) / approxCharsPerLine)
        return CGFloat(lines * 22 + 16)
    }

    // MARK: - Grid-aligned ranges
    //
    // Every method below returns a batch whose [start, end) lies on the same
    // global grid of multiples of `pageSize`. That guarantee is what makes
    // `ChatDataSource.mergeAdjacentLists` work: when two lists' boundary
    // cursors coincide (e.g. after a jump+scroll-back-up reaches the original
    // initial-load slice), the cursors will be exactly equal — they were both
    // minted from the same grid stride. Without alignment the chain from
    // `loadBatch` rides a shifted grid (because it centres on the target item)
    // and never meets `loadInitial`'s boundaries.

    func loadInitial() async throws -> Batch {
        try await Self.simulateLatency()
        // Bottom batch on the grid: largest multiple of pageSize that's still
        // strictly less than totalCount. For totalCount=1500, pageSize=100 →
        // start=1400.
        let start = Self.gridFloor(max(0, Self.totalCount - Self.pageSize))
        return makeBatch(range: start..<Self.totalCount)
    }

    func loadNext(after cursor: Cursor) async throws -> Batch? {
        try await Self.simulateLatency()
        guard let endIdx = Int(cursor.raw), endIdx < Self.totalCount else { return nil }
        // `endIdx` itself comes from a previously-emitted batch that was
        // grid-aligned, so [endIdx, endIdx+pageSize) stays on the grid.
        return makeBatch(range: endIdx..<min(Self.totalCount, endIdx + Self.pageSize))
    }

    func loadPrevious(before cursor: Cursor) async throws -> Batch? {
        try await Self.simulateLatency()
        guard let startIdx = Int(cursor.raw), startIdx > 0 else { return nil }
        // Same reasoning as `loadNext`: `startIdx` is grid-aligned, so the
        // step back of `pageSize` produces another grid-aligned range.
        return makeBatch(range: max(0, startIdx - Self.pageSize)..<startIdx)
    }

    func loadBatch(containing id: ItemID) async throws -> Batch? {
        try await Self.simulateLatency()
        guard let i = allMessages.firstIndex(where: { $0.id == id }) else { return nil }
        // Three grid buckets around the target: one bucket before, the bucket
        // containing the target, and one bucket after. This guarantees the
        // target falls roughly in the middle third of the loaded content so
        // `ChatScrollView`'s `centeredOffsetY(for:)` has room above and below
        // to actually centre it — a single-bucket batch puts targets whose
        // index lies near a grid boundary (e.g. i=1200) at the top of the
        // loaded range and the centring clamp fires, dumping the user at
        // the top of the viewport instead of centring the target.
        //
        // start/end stay multiples of `pageSize` so `mergeAdjacentLists`
        // can still bridge this batch with prior `loadInitial` / `loadNext`
        // chains via cursor equality.
        let bucket = Self.gridFloor(i)
        let start = max(0, bucket - Self.pageSize)
        let end = min(Self.totalCount, bucket + 2 * Self.pageSize)
        return makeBatch(range: start..<end)
    }

    /// Floor `value` to the nearest multiple of `pageSize` (≤ value).
    private static func gridFloor(_ value: Int) -> Int {
        (value / Self.pageSize) * Self.pageSize
    }

    private func makeBatch(range: Range<Int>) -> Batch {
        let items: [any ChatItem] = Array(allMessages[range])
        let topCursor: Cursor? = range.lowerBound > 0
            ? Cursor(raw: "\(range.lowerBound)") : nil
        let bottomCursor: Cursor? = range.upperBound < Self.totalCount
            ? Cursor(raw: "\(range.upperBound)") : nil
        return Batch(
            id: BatchID(raw: "b-\(range.lowerBound)-\(range.upperBound)"),
            items: items,
            topCursor: topCursor,
            bottomCursor: bottomCursor
        )
    }

    static func simulateLatency() async throws {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}

extension MockChatProvider {
    func randomKnownId() -> ItemID {
//        allMessages[600].id
        allMessages.randomElement()!.id
    }

    func makePushMessage() -> Message {
        let seed = Int.random(in: 0..<10_000)
        return makePushMessage(text: "🆕 \(Self.fakeText(seed: seed))")
    }

    func makePushMessage(text: String) -> Message {
        let cal = Calendar.current
        let date = cal.startOfDay(for: Date())
        return Message(
            id: ItemID("push-\(UUID().uuidString.prefix(8))"),
            text: text,
            isOutgoing: true,
            groupId: ItemID(Self.dayKey(date, cal: cal)),
            height: Self.estimateHeight(text: text)
        )
    }
}
