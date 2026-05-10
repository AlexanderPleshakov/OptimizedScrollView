# OptimizedScrollView

Custom UIScrollView-based component for chat UIs. Optimized for: smooth 60fps scrolling on long histories, async bidirectional pagination, jump-to-id with batch backfill, stable offset preservation across content mutations, and view recycling.

The component is a Swift Package (`Packages/OptimizedScrollView`, iOS 15+, Swift 5.9). The host app (`ChatScrollView.xcodeproj`) consumes it as a local SPM dependency. `ChatViewController` is the development harness.

## Repository layout

```
ChatScrollView.xcodeproj/         # host app (consumes the package)
ChatScrollView/                   # host app sources — split per type:
  ChatViewController.swift          # the harness controller
  Message.swift / DateHeader.swift  # ChatItem models
  MessageCell.swift / DateHeaderCell.swift
  MockChatProvider.swift            # in-memory provider, grid-aligned cursors
Packages/OptimizedScrollView/     # the actual component
  Package.swift                     # depends on apple/swift-collections (DequeModule)
  Sources/OptimizedScrollView/
    Public/        # API surface — protocols, facade, public value types
    Layout/        # frames, anchor, layout engine
    Rendering/     # reuse pool, viewport, cell management
    Data/          # actor data source, batches, batch lists
    Internal/      # scroll state, diff applier, helpers
```

Add new files to the matching subdirectory. The four directories under `Sources/OptimizedScrollView/` are the architectural seams — never reach across them with concrete types; cross only through value types and protocols defined in `Public/`.

## Architecture — three layers, no leaks across boundaries

```
ChatScrollView (UIScrollView subclass)  ── facade, public API
   │
   ├── ChatDataSource (actor, background)   ← Data
   │     batches, batch lists, snapshots, cursor-based merge
   │
   ├── LayoutEngine + LayoutStore (main)    ← Layout
   │     [ItemID: CGRect], items + sticky-header y-flow, anchor math,
   │     incremental append + negative-y prepend
   │
   └── Renderer + ReusePool (main)          ← Rendering
         visible window, dequeue/enqueue, configure, headersHost
```

Hard rules:

- **Data** never imports UIKit. It deals in `ItemID`, `Batch`, `DataSnapshot` — pure values.
- **Layout** never imports UIKit beyond `CGRect`/`CGFloat`. No `UIView` references.
- **Rendering** is the only layer that owns `UIView` instances.
- Cross-layer communication is one-way through value types or via the facade. No back-references from Renderer to DataSource.

## Core types (single source of truth — define once in `Public/`)

```swift
public struct ItemID: Hashable, Sendable {
    public let raw: String
    public init(_ raw: String)
}

public protocol ChatItem: Sendable {
    var id: ItemID { get }
    var height: CGFloat { get }    // authoritative; computed by the host
    var groupId: ItemID? { get }   // sticky-header grouping; default nil
}

public protocol ChatCellView: UIView {
    associatedtype Model: ChatItem
    static var reuseId: String { get }
    func configure(with model: Model)
}

public struct Anchor {
    public let id: ItemID
    public let offsetFromTop: CGFloat   // y(item) - contentOffset.y at capture time
}

public struct LayoutAttributes {
    public let id: ItemID
    public var frame: CGRect
}

public struct Cursor: Hashable, Sendable        // opaque, host-designed
public struct BatchID: Hashable, Sendable
public struct BatchListID: Hashable, Sendable

public struct Batch: Sendable {
    public let id: BatchID
    public let items: [any ChatItem]
    public let topCursor: Cursor?      // nil → top of history
    public let bottomCursor: Cursor?   // nil → bottom of history (live tail)
}

public struct DataSnapshot: Sendable {
    public let listId: BatchListID
    public let items: [any ChatItem]
    public let topCursor: Cursor?
    public let bottomCursor: Cursor?
}
```

Generic `ChatCellView` with `associatedtype Model` is a deliberate decision — type-erasure happens at registration time inside the reuse pool, not at the cell API. Cells stay strongly typed for their model.

## Non-negotiable design decisions

These were resolved up front. Don't relitigate without explicit user request.

1. **AutoLayout in cells is allowed.** Each `ChatCellView` decides for itself whether to use AutoLayout or manual frame math. The component must not assume either; height is reported by the data source, and the cell is responsible for laying out within the given frame.
2. **Generic cell protocol with `associatedtype Model`.** Type erasure for the reuse pool happens at registration (the pool stores `(reuseId) -> any ChatCellView` factories, plus per-reuseId configure-thunks that downcast to `Cell.Model`). Public-facing cell code stays generic.
3. **Sticky headers (date dividers etc.) are first-class.** Adjacent items sharing a `groupId` form a group; the host supplies a header model per group via `setStickyHeaderProvider`. Headers *displace* — they occupy y-space above the first item of each group, so contentHeight reflects them. Sticky pinning is computed at render time: `pinnedY = max(naturalY, min(viewportTop, nextHeaderNaturalY - headerHeight))`. Headers live in a dedicated `headersHost` z-layer above item cells; items are inserted *below* it so we don't pay `bringSubviewToFront` per scroll tick.
4. **Header ids are layout-internal, not host-controlled.** When the same `groupId` appears non-adjacently in layout (e.g. a push-today message lands inside a history slice and a subsequent loadNext fills in the gap), the engine disambiguates by suffixing later occurrences with `#N`. The first occurrence keeps the host's `header.id` verbatim. Hosts must not assume `header.id` is the lookup key — the renderer resolves models through `headerProvider(groupId)`.
5. **No `reloadData()`, ever.** All updates go through diff/anchor. Full rebuilds are an internal-only operation reserved for the very first snapshot, a `bounds.size` change, or an incremental fast path falling back on a structural conflict (see § Incremental layout).
6. **Bottom-pinning is rare.** Apply only on initial load and on `bounds.size` changes. Never inside a layout pass triggered by scrolling or content mutation.
7. **Anchor before, restore after.** Any operation that can change a frame *above* the current viewport must capture an `Anchor` first and restore offset after. **Exception:** the negative-y prepend fast path explicitly preserves `contentOffset.y` directly — see § Incremental layout.
8. **`contentInset.top` carries prepend headroom only — bottom-pin lives in stored frames.** Short-content bottom-pin is implemented as a `bottomFlowOffset` baked into stored item/header frames (`LayoutEngine.setViewportHeight` + `LayoutStore.shiftAllFrames`), not as a `contentInset.top` shortcut. The previous "inset sum" approach caused unanimated push jerks because UIKit doesn't coordinate `contentInset` + `contentSize` + `contentOffset` changes inside a single layout pass. With the flow offset in stored frames, push in short-content mode shifts existing items via plain frame assignment, which animates correctly when wrapped in `UIView.animate`. The remaining contributor to `contentInset.top` is `prependHeadroom = max(0, -engine.topY)` — extra room above contentSize so the negative-y prepend region is reachable. Whoever changes the layout's `topY` (rebuildAll resets it; `prependItems` decreases it; `setViewportHeight` reconciles it) is responsible for syncing `contentInset.top` immediately. A stale inset is the difference between `capture.topInset` and `currentTopInset` in `AnchorController`'s formula — it manifests as "viewport snaps by `prependHeadroom` after the next mutation".

## Concurrency model

- `ChatDataSource` is an `actor`. All batch state lives inside it. It never returns mutable references — only immutable `DataSnapshot` values.
- Layout and Rendering are `@MainActor`. Don't sprinkle `MainActor.run` inside them; assume main, enforce at the boundary.
- `ChatDataSourceProvider` is `Sendable`. Async loaders (`loadInitial`, `loadNext`, `loadPrevious`, `loadBatch(containing:)`) return data models, never views or layout.
- In-flight loads are deduped per kind inside the actor: `loadingInitial`, `loadingPrevious`, `loadingNext` flags, plus `loadingForJump: Set<ItemID>`. After every `await`, the actor re-validates `currentListId` so a state change during the await (concurrent jump, list merge) is detected before mutating.
- Swift 6 strict concurrency is the target. Every public type that crosses an actor boundary must be `Sendable`.

## Data model — batches, lists, cursors, merge

The data source maintains **multiple `BatchList`s** keyed by `BatchListID`. Each list is an ordered chain of adjacent batches (top → bottom); `topCursor` / `bottomCursor` are derived from the first/last batch. `currentListId` selects which list is currently visible.

`BatchList.batches` is a `Deque<Batch>` (from `swift-collections`) so `loadPrevious` adds at the head in amortized O(1). `Array.insert(at: 0)` was O(n), the shift cost compounded across pagination chains.

- **Adjacency is cursor equality.** `B` is adjacent below `A` iff `B.topCursor == A.bottomCursor`. Hosts design `Cursor` values to make this work — and crucially, **all four provider methods must lay batches on a single grid**. If `loadInitial` produces ranges aligned to one stride and `loadBatch(containing:)` to another (e.g. centred on the target index), the chains never meet at equal cursors and `mergeAdjacentLists` can't bridge them. The harness's `MockChatProvider` floors all ranges to multiples of `pageSize` for this reason.
- **Live tail = the list whose `bottomCursor == nil`** (no batch below). At most one is expected; the merge pass below maintains this invariant in the steady state.
- **`append(items:)` (push) targets the live tail**, regardless of `currentListId`. If the user is on a history slice, the items land in a different list and the facade fires `didReceiveNewItemsWhileScrolledUp` instead of touching the view. `scrollToLiveTail(animated:)` switches `currentListId` to the live tail and scrolls to its end.
- **`loadBatch(containing:)` splices into an existing list when its boundary cursor matches**, otherwise creates a new list and switches to it.
- **Merge pass (`mergeAdjacentLists(into:)`)** runs at the end of `loadInitial`/`loadNext`/`loadPrevious`/`loadBatch`. If the focal list's top or bottom cursor matches some other list's opposite-side cursor, the other list is absorbed into the focal one and removed; the cycle repeats while merges are still possible. The **focal id is always the survivor**, keeping `ChatScrollView.currentListId` valid through the merge. This handles bridging batches (a single fetch making two previously disjoint lists adjacent) and prevents the "two live tails" pathology when a long pagination chain meets the original tail.
- **Push does not trigger merge** because it only mutates items inside the bottom batch, not boundary cursors.

## Incremental layout — fast paths and the negative-y prepend

`LayoutStore` keeps items and headers in `Deque<ItemID>` / `Deque<LayoutAttributes>` so head-prepend is O(1) at the storage layer. Three structural mutation paths exist; the facade picks one per `apply(_:)` call.

### Tail append (`engine.appendItems`)

Triggered by `pureTailAppend(from changes:)` — all `.insert`s at contiguous indices starting at `currentOrder.count`. Used by `loadNext` snapshot diffs and direct push.

- New attrs are laid out from `store.contentHeight` down (block-local y starts at the previous bottom).
- `LayoutStore.appendItems` extends the deques and **adds new keys** to `indexById` / `headerIndexById` without rebuilding either dictionary. Cost: O(new items + new headers).
- Engine maintains `lastItemGroupId` (seam `prevGroup`) and `occurrenceByGroup` (`#N` counter); both are updated as new headers are emitted.

### Head prepend (`engine.tryPrependIncrementally`)

Triggered by `pureHeadPrepend(from changes:)` — all `.insert`s at indices `0..<K`. Used by `loadPrevious` snapshot diffs.

- The new block is laid out at block-local y in `[0, blockHeight)`. Block-internal `#N` counters are independent of the existing layout.
- **Conflict check.** For each `groupId` in the block, if it already has occurrences in the existing layout, refuse — accepting would force renumbering existing `#N` ids, and the renderer's `visibleHeaders` is keyed by layout id. **Exception (seam case):** the block's last group equals `firstExistingGroup`, the block has exactly one occurrence of it, and the existing layout has a leading header at `topY`. Then we drop that leading header (its `header.id` is identical to the new block's last header id, so swapping is invisible) and proceed.
- **Negative-y placement.** Existing items keep their stored y values untouched. New attrs translate by `topY - blockHeight`; the block's bottom (y=blockHeight) lands at the current `topY`, so the new block is at y in `[topY - blockHeight, topY)`. After: `topY -= blockHeight`. `contentHeight` is unchanged (nothing was added below).
- **Cost: O(prepended).** No y-shift of existing items, no Dictionary rebuild — only existing `indexById` / `headerIndexById` values are bumped by the count of new keys.
- **Refusal is fine.** If the conflict check fails, `tryPrependIncrementally` returns `false` *without mutating the store*, and the facade falls through to the full-`rebuildAll` slow path.

### Slow path (`engine.rebuildAll` via `DiffApplier.plan`)

Anything else — mixed inserts, removes, updates, or a refused prepend. `DiffApplier.plan` builds the new `[ItemID]` order; the facade calls `engine.rebuildAll` which lays the whole layout from y=0, resetting `topY` to 0.

### `topY`, `bottomFlowOffset`, `contentInset.top`

`LayoutStore.topY` is tri-state and represents the y of the topmost subview:

- `topY == 0` — long content, no prepend, no flow offset. Default after `rebuildAll`.
- `topY < 0` — long content with prepended history in the negative-y region. `prependHeadroom = -topY` goes into `contentInset.top`.
- `topY > 0` — **short-content bottom-pin via stored-frame shift** (Approach B). Items shorter than the viewport have been translated downward so the last item's `maxY == viewportHeight`. `LayoutStore.bottomFlowOffset = max(0, topY)` exposes this. `contentInset.top` is 0 in this regime.

`LayoutEngine.setViewportHeight(_)` is the single point that reconciles the flow offset: it computes `desiredOffset = max(0, viewport - itemsTotal)` and `currentOffset = max(0, topY)` and applies `shift = desiredOffset - currentOffset` via `LayoutStore.shiftAllFrames`. Mutation methods (`rebuildAll`, `appendItems`, `tryPrependIncrementally`, `updateHeight`) call it at their tail so the store is always in a viewport-consistent state. The facade calls `engine.setViewportHeight(bounds.height - contentInset.bottom)` on bounds changes and on `setBottomInset` so the engine's notion of viewport stays current.

The two regimes are orthogonal because `currentOffset = max(0, topY)`: a prepend that crosses short→long sets `topY < 0` (the new block went into negative-y); reconcile sees `currentOffset = 0`, `desiredOffset = 0`, and is a no-op.

- `LayoutStore.totalScrollableHeight = contentHeight - min(0, topY)` — full vertical extent including any negative-y prepended region. Currently unused after Approach B (kept for diagnostic purposes).
- `ChatScrollView.contentInset.top = max(0, -engine.topY)` — pure prepend headroom. UIScrollView accepts `contentOffset.y` in `[-contentInset.top, contentSize.height + contentInset.bottom - bounds.height]`, so this is what makes the negative-y region reachable by scrolling up.
- `ChatScrollView.contentSize.height = engine.contentHeight`. In short mode `contentHeight` already includes `bottomFlowOffset` (last item's maxY = viewport), so contentSize equals viewport and the scrollable region degenerates to a point — the desired UIScrollView behavior for short content.
- `tickPrefetch.nearTop` checks `viewport.minY - engine.topY <= threshold`, **not** `viewport.minY <= threshold`. Comparing against a fixed 0 caused a runaway loadPrevious chain after the first prepend (because `viewport.minY` could go arbitrarily negative).

### Push in short-content mode animates frames, not insets

Before Approach B, push in short content moved `contentInset.top` from `viewport - oldHeight` to `viewport - newHeight`. UIKit doesn't animate `contentInset` changes inside a regular layout pass, and the simultaneous `contentSize` + `contentOffset` updates produced a visible snap.

Now: push grows `itemsTotal`, `setViewportHeight` shrinks the bottom-flow offset, `LayoutStore.shiftAllFrames` walks every stored frame and shifts them upward by the offset delta. `Renderer.updateVisible` then assigns the new frames to the live `UIView`s. Wrapping the whole `apply(_:)` chain in `UIView.animate(withDuration: 0.25)` (in `applyAppendedSnapshot` and `commitPushApply`) makes the per-cell `view.frame = target` assignments interpolate, producing a smooth shift. The animation predicate is `wasAtBottom && engine.bottomFlowOffset > 0` — long-mode push doesn't move existing items at all, so the wrapping is unnecessary and skipped.

### `commitPrependIncremental` bypasses the anchor formula

The standard `commitMutation` flow uses `AnchorController.restoredOffsetY = anchored.minY - offsetFromTop + (currentTopInset - capture.topInset)` — designed for the y-shift world where prepend moved the anchored item down by `blockHeight` and topInset stayed the same. With the negative-y trick the anchored item's y didn't change but topInset grew by `blockHeight`; the formula's `+delta_topInset` term would visually move the anchor by exactly the wrong amount. So `commitPrependIncremental` saves `contentOffset.y` before mutating and writes it back verbatim afterwards — no anchor capture/restore.

### Sync `contentInset.top` after `rebuildAll`

`setItemsInternal` calls `updateTopInsetForBottomAnchoring()` *immediately after* `engine.rebuildAll`. The store now has `topY = 0` (no prepended region), but `contentInset.top` still carries `prependHeadroom` from the previous layout's prepended history. If we let it stay stale, the *next* mutation that runs through `commitMutation` would see `capture.topInset = stale_prependHeadroom` and `currentTopInset = 0` (post-update); the anchor formula would subtract `stale_prependHeadroom` from the restored offset and visually toss the user up. This was the symptom of "after jump + scroll-down, append fires and viewport snaps to a much earlier message".

## Implementation order — phases (all complete)

Each phase has a verifiable deliverable; later phases assume the earlier one is correct.

| Phase | Scope | Done when |
|---|---|---|
| 1 | `LayoutStore`, `LayoutEngine`, `Anchor`, `BottomAnchoring`, `ScrollState`. No virtualization, no reuse, no batches. | 200-item list with host-provided heights renders, insert/delete/height-change does not move the visible anchor. Bottom-pin works on initial load and on resize only. |
| 2 | `ReusePool`, `Renderer`, `ContentWindow`, `DiffApplier`. Sticky headers retrofitted at the end of phase 2. | 10 000 items, ~30 live views, smooth scroll. No `reloadData`. |
| 3 | `ChatDataSource` actor, `Batch`, `BatchList`, prefetch, jump-to-id with backfill, push insert policy, multi-list merge. | Bidirectional pagination with simulated latency, jump-to-id from arbitrary history point, "+N new" delegate event when scrolled up, bridging batches collapse separate lists into one. |
| 4 | Deque-backed storage, incremental tail-append + negative-y prepend, fast paths in `apply(_:)`. | `loadPrevious`/`loadNext`/push avoid `Dictionary(uniqueKeysWithValues:)` rebuild. Prepend visually stable without y-shifting existing content. |

Notes on phase 2's sticky-header retrofit: `LayoutEngine.rebuildAll` lays out items + headers in a single y-flow; `Renderer` keeps a separate `headersHost` view and pins visible headers each `updateVisible`. The slow-path structural mutation (`apply` rebuildAll fallback, `setItems`) goes through `rebuildAll` (O(n)). `updateHeight` stays incremental and shifts both items and headers below the change.

`DiffApplier.plan` is a pure planner: takes `[Change]` + current order + items, returns the new order, new items, and id sets (`inserted/removed/modelChanged/heightChanged`). The facade commits the plan with one `engine.rebuildAll` call. The fast-path detectors `pureTailAppend` / `pureHeadPrepend` short-circuit ahead of the planner when the change set has the right shape.

## Public API surface (facade)

```swift
// Registration
chatView.register(MessageCell.self)
chatView.setStickyHeaderProvider { groupId in DateHeader(...) }
chatView.setReuseIdResolver { item in ... }   // optional; type-based by default

// Data source (phase 3)
chatView.setDataSourceProvider(myProvider)
chatView.chatDelegate = self
chatView.loadInitial()                   // fire-and-forget; errors via delegate
chatView.appendNewItems([newMessage])    // push at bottom of history

// Direct mutations (phase 1/2)
chatView.setItems([...])                 // hard replace
chatView.apply([.insert(item, at: 5), .remove(id), .update(item)])
chatView.updateHeight(id: ItemID("x"), to: 84)

// Scroll
chatView.scroll(to: ItemID("msg-N"), animated: true)   // backfills via loadBatch if needed
chatView.scrollToBottom(animated: true)
chatView.scrollToLiveTail(animated: true)
chatView.setBottomInset(200, animated: true)
```

Conventions:

- The facade is `ChatScrollView: UIScrollView`. Public methods read like a chat scroll, not like a UICollectionView clone.
- Keyboard observation lives **outside** the component. The host wires up `keyboardWillChangeFrame` and calls `setBottomInset(_:animated:)`.
- Delegate callbacks (`didReceiveNewItemsWhileScrolledUp(count:)`, `didFailLoad(_:)`) go through a single delegate protocol with default empty implementations.
- All public types are `Sendable` where they cross actors. All mutating APIs are `@MainActor`.

## Coding standards

- No `fatalError` in shipped paths except the synthesized `init(coder:)`. Preconditions only at true invariant boundaries (e.g. unknown `reuseId`, missing `dataSource` in `loadInitial`).
- No comments that restate the code. Comments explain *why* a non-obvious choice was made (e.g. "delta applied here because UIScrollView batches contentOffset assignments inside layoutSubviews", "negative-y because shifting existing items would be O(n) per prepend").
- No premature abstractions. If only one type implements a protocol and there is no test seam, it is a concrete type.
- File-per-type unless types are tightly coupled.
- Tests go under `Tests/OptimizedScrollViewTests/` mirroring the source layout. Layout math, `DiffApplier.plan`, the merge pass in `ChatDataSource`, and `tryPrependIncrementally`'s conflict check are pure and must be unit-tested (not yet — known gap). Renderer/facade can be exercised via integration tests against a synthetic data source.

## Things to avoid

- AutoLayout *outside* of cells (in the layout engine, the facade, sticky headers). The engine is manual frame math.
- Heavy work in `layoutSubviews`, `scrollViewDidScroll`. Both must be O(visible items).
- `DispatchQueue.main.async` from rendering code as a "fix" for jumps — that almost always indicates a missing anchor capture or a stale `contentInset.top`.
- Storing `UIView` references inside layout structs.
- Public API that exposes `BatchList` internals. `Batch` is public (hosts construct it from their fetcher); `BatchList` is internal — consumers see `DataSnapshot`s.
- Assuming the host's `header.id` is the layout id of a sticky header — for non-adjacent same-`groupId` occurrences the layout id is suffixed with `#N`.
- Mutating `engine.topY` (via `prependItems` or `rebuildAll` or `setViewportHeight`) without immediately syncing `contentInset.top` afterwards. The facade's `commitMutation` / `commitPrependIncremental` / `setItemsInternal` all do this; new code paths must too.
- Comparing `viewport.minY` to a fixed origin in prefetch / "near top" logic. The layout origin is `engine.topY`, which can be deeply negative (prepend) or deeply positive (short-content bottom-pin).
- Reintroducing `contentInset.top` as a bottom-pin shortcut. The bottom-pin lives in `bottomFlowOffset` baked into stored frames; the inset is reserved for prepend headroom only.
- Forgetting to call `engine.setViewportHeight(...)` after a `bounds.size` or `contentInset.bottom` change. The engine caches the last-known viewport and reconciles on every mutation — a stale value silently desynchronizes short-content layout.

## Host app

`ChatViewController` is the development harness. The harness lives in `ChatScrollView/`, split per type:

- `Message.swift`, `DateHeader.swift` — the two `ChatItem` models the harness uses.
- `MessageCell.swift`, `DateHeaderCell.swift` — `ChatCellView` implementations.
- `MockChatProvider.swift` — `ChatDataSourceProvider` with 1500 prebuilt messages spread over ~40 calendar days (one group per day, ~20 messages each), `pageSize = 100`, ~10ms simulated latency. Every method (`loadInitial` / `loadNext` / `loadPrevious` / `loadBatch(containing:)`) returns ranges floored to multiples of `pageSize` so the merge pass works after a jump-and-scroll-back-down sequence.
- `ChatViewController.swift` — three buttons (Push / Jump / Inset) and a "+N new ↓" badge wired to `scrollToLiveTail`. Use it to exercise the component during implementation; it is not the production consumer.

Keep its setup minimal — fixture data, a few buttons, no real networking.
