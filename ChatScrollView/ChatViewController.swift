import UIKit
import OptimizedScrollView

// MARK: - Models

private struct Message: ChatItem {
    let id: ItemID
    let text: String
    let isOutgoing: Bool
    let groupId: ItemID?
    let height: CGFloat
}

private struct DateHeader: ChatItem {
    let id: ItemID
    let dateText: String
    let height: CGFloat
}

// MARK: - Mock provider

/// In-memory `ChatDataSourceProvider` with 800 prebuilt messages spread over
/// ~40 calendar days (one group per day, ~20 messages each). Every request
/// sleeps 500ms to simulate network latency, exercising the actor's dedup
/// machinery and the renderer's anchor preservation under async pagination.
private struct MockChatProvider: ChatDataSourceProvider {
    static let totalCount = 800
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

    func loadInitial() async throws -> Batch {
        try await Self.simulateLatency()
        let start = max(0, Self.totalCount - Self.pageSize)
        return makeBatch(range: start..<Self.totalCount)
    }

    func loadNext(after cursor: Cursor) async throws -> Batch? {
        try await Self.simulateLatency()
        guard let endIdx = Int(cursor.raw), endIdx < Self.totalCount else { return nil }
        return makeBatch(range: endIdx..<min(Self.totalCount, endIdx + Self.pageSize))
    }

    func loadPrevious(before cursor: Cursor) async throws -> Batch? {
        try await Self.simulateLatency()
        guard let startIdx = Int(cursor.raw), startIdx > 0 else { return nil }
        return makeBatch(range: max(0, startIdx - Self.pageSize)..<startIdx)
    }

    func loadBatch(containing id: ItemID) async throws -> Batch? {
        try await Self.simulateLatency()
        guard let i = allMessages.firstIndex(where: { $0.id == id }) else { return nil }
        let half = Self.pageSize / 2
        let start = max(0, min(Self.totalCount - Self.pageSize, i - half))
        let end = min(Self.totalCount, start + Self.pageSize)
        return makeBatch(range: start..<end)
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
        try await Task.sleep(nanoseconds: 500_000_000)
    }
}

extension MockChatProvider {
    func randomKnownId() -> ItemID {
        allMessages.randomElement()!.id
    }

    func makePushMessage() -> Message {
        let cal = Calendar.current
        let date = cal.startOfDay(for: Date())
        let seed = Int.random(in: 0..<10_000)
        let text = "🆕 \(Self.fakeText(seed: seed))"
        return Message(
            id: ItemID("push-\(UUID().uuidString.prefix(8))"),
            text: text,
            isOutgoing: true,
            groupId: ItemID(Self.dayKey(date, cal: cal)),
            height: Self.estimateHeight(text: text)
        )
    }
}

// MARK: - Cells

private final class MessageCell: UIView, ChatCellView {
    typealias Model = Message
    static let reuseId = "MessageCell"

    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.numberOfLines = 0
        label.font = .systemFont(ofSize: 15)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        // Bottom is at .defaultHigh so a slight under-estimate of height by the
        // host produces overflow rather than an AutoLayout conflict warning.
        let bottom = label.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8)
        bottom.priority = .defaultHigh
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            bottom,
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with model: Message) {
        label.text = model.text
        if model.isOutgoing {
            backgroundColor = UIColor.systemBlue.withAlphaComponent(0.12)
            label.textAlignment = .right
            label.textColor = .systemBlue
        } else {
            backgroundColor = UIColor.systemGray5
            label.textAlignment = .left
            label.textColor = .label
        }
    }
}

private final class DateHeaderCell: UIView, ChatCellView {
    typealias Model = DateHeader
    static let reuseId = "DateHeaderCell"

    private let pill = UIView()
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Match chat background so the header pill occludes anything that
        // scrolls underneath when sticky-pinned.
        backgroundColor = .secondarySystemBackground

        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.backgroundColor = .systemGray4
        pill.layer.cornerRadius = 11

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabel

        addSubview(pill)
        pill.addSubview(label)
        NSLayoutConstraint.activate([
            pill.centerXAnchor.constraint(equalTo: centerXAnchor),
            pill.centerYAnchor.constraint(equalTo: centerYAnchor),
            pill.heightAnchor.constraint(equalToConstant: 22),
            label.topAnchor.constraint(equalTo: pill.topAnchor),
            label.bottomAnchor.constraint(equalTo: pill.bottomAnchor),
            label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with model: DateHeader) {
        label.text = model.dateText
    }
}

// MARK: - View controller

final class ChatViewController: UIViewController, ChatScrollViewDelegate {
    private let chat = ChatScrollView()
    private let provider = MockChatProvider.makeDefault()

    private let pushButton = UIButton(type: .system)
    private let jumpButton = UIButton(type: .system)
    private let insetButton = UIButton(type: .system)
    private let badgeButton = UIButton(type: .system)

    private var bottomInsetActive = false
    private var pendingNewItemsCount = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setupUI()
        setupChat()
        chat.loadInitial()
    }

    private func setupUI() {
        configureButton(pushButton, title: "Push", action: #selector(pushTapped))
        configureButton(jumpButton, title: "Jump", action: #selector(jumpTapped))
        configureButton(insetButton, title: "Inset", action: #selector(insetTapped))

        let toolbar = UIStackView(arrangedSubviews: [pushButton, jumpButton, insetButton])
        toolbar.axis = .horizontal
        toolbar.distribution = .fillEqually
        toolbar.spacing = 8
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        chat.translatesAutoresizingMaskIntoConstraints = false
        chat.backgroundColor = .secondarySystemBackground

        badgeButton.translatesAutoresizingMaskIntoConstraints = false
        var badgeConfig = UIButton.Configuration.filled()
        badgeConfig.baseBackgroundColor = .systemRed
        badgeConfig.baseForegroundColor = .white
        badgeConfig.cornerStyle = .capsule
        badgeConfig.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 14, bottom: 4, trailing: 14)
        badgeButton.configuration = badgeConfig
        badgeButton.isHidden = true
        badgeButton.addTarget(self, action: #selector(badgeTapped), for: .touchUpInside)

        view.addSubview(toolbar)
        view.addSubview(chat)
        view.addSubview(badgeButton)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            toolbar.heightAnchor.constraint(equalToConstant: 44),

            chat.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            chat.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            chat.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            chat.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            badgeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            badgeButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            badgeButton.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    private func configureButton(_ button: UIButton, title: String, action: Selector) {
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    private func setupChat() {
        chat.register(MessageCell.self)
        chat.register(DateHeaderCell.self)
        chat.setStickyHeaderProvider { groupId in
            DateHeader(
                id: ItemID("header-\(groupId.raw)"),
                dateText: MockChatProvider.dateLabel(for: groupId),
                height: 32
            )
        }
        chat.chatDelegate = self
        chat.setDataSourceProvider(provider)
    }

    // MARK: Actions

    @objc private func pushTapped() {
        chat.appendNewItems([provider.makePushMessage()])
    }

    @objc private func jumpTapped() {
        chat.scroll(to: provider.randomKnownId(), animated: true)
    }

    @objc private func insetTapped() {
        bottomInsetActive.toggle()
        chat.setBottomInset(bottomInsetActive ? 200 : 0, animated: true)
    }

    @objc private func badgeTapped() {
        pendingNewItemsCount = 0
        badgeButton.isHidden = true
        chat.scrollToLiveTail(animated: true)
    }

    // MARK: ChatScrollViewDelegate

    func didReceiveNewItemsWhileScrolledUp(count: Int) {
        pendingNewItemsCount += count
        badgeButton.setTitle("+\(pendingNewItemsCount) new ↓", for: .normal)
        badgeButton.isHidden = false
    }

    func didFailLoad(_ error: Error) {
        print("Load failed: \(error)")
    }
}
