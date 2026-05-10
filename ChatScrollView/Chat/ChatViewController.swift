import UIKit
import OptimizedScrollView

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
    
    func didScrollToItem(id: ItemID) {
        guard let cellView = chat.visibleView(for: id) else { return }
        flashHighlight(on: cellView)
    }

    /// Layers a translucent yellow overlay on top of the cell and fades it
    /// out. Using a sibling overlay (rather than mutating the cell's own
    /// backgroundColor) keeps the flash independent of `configure(with:)`,
    /// which sets the background based on `isOutgoing` and would otherwise
    /// clobber a mid-animation colour if the cell were recycled.
    private func flashHighlight(on cellView: UIView) {
        let overlay = UIView(frame: cellView.bounds)
        overlay.backgroundColor = UIColor.systemYellow.withAlphaComponent(0.45)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.isUserInteractionEnabled = false
        overlay.layer.cornerRadius = cellView.layer.cornerRadius
        cellView.addSubview(overlay)

        UIView.animate(
            withDuration: 0.9,
            delay: 0.15,
            options: [.curveEaseOut]
        ) {
            overlay.alpha = 0
        } completion: { _ in
            overlay.removeFromSuperview()
        }
    }
}
