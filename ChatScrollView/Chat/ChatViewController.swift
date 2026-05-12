import UIKit
import OptimizedScrollView

final class ChatViewController: UIViewController, ChatScrollViewDelegate, UITextFieldDelegate, UIGestureRecognizerDelegate {
    private let chat = ChatScrollView()
    private let provider = MockChatProvider.makeDefault()

    private let pushButton = UIButton(type: .system)
    private let jumpButton = UIButton(type: .system)
    private let inputField = UITextField()
    private let badgeButton = UIButton(type: .system)

    private var pendingNewItemsCount = 0

    /// `true` once a drag that started in the chat has crossed the input
    /// bar's top edge while the keyboard is up — i.e. we're driving an
    /// interactive keyboard dismiss. While set, `viewDidLayoutSubviews`
    /// passes `shiftingOffset: false` to `setBottomInset` so the chat's
    /// `contentOffset.y` doesn't shift along with the shrinking inset,
    /// and explicitly re-clamps `contentOffset.y` to the locked value
    /// each tick so the scroll content appears frozen while the keyboard
    /// follows the finger off-screen.
    private var isInteractiveDismissing = false
    private var dismissLockOffsetY: CGFloat?
    private var startDismissInset: CGFloat?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setupUI()
        setupChat()
        setupKeyboardObservers()
        chat.loadInitial()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // The chat extends to `view.bottomAnchor`, with the input bar
        // floating on top of it pinned to `keyboardLayoutGuide.topAnchor`.
        // To keep the last message visible just above the input bar (and
        // above the keyboard when it's up), we reserve `contentInset.bottom`
        // equal to the strip between the input bar's top edge and the
        // view's bottom edge.
        //
        // `view.keyboardLayoutGuide` updates the input bar's position
        // continuously during interactive keyboard dismissal, which calls
        // `viewDidLayoutSubviews` for every frame of the gesture. The
        // resulting `setBottomInset` calls track the gesture smoothly.
        // During the system's open/close keyboard animation,
        // `viewDidLayoutSubviews` runs inside `UIView.animate` — the
        // `setBottomInset` (called with `animated: false`) participates
        // in that outer animation and interpolates the inset + offset.
        let inputTopInView = inputField.frame.minY
        let desiredInset = max(0, view.bounds.maxY - inputTopInView)
        if chat.contentInset.bottom != desiredInset {
            // While the user is interactively dragging the keyboard down,
            // we want the visible chat content to look stationary — the
            // inset shrinks (un-obscured area grows), but messages don't
            // slide. Passing `shiftingOffset: false` tells the chat to
            // change `contentInset.bottom` without adjusting
            // `contentOffset.y`; the explicit clamp below also re-pins
            // the offset to the value captured at dismiss-start so the
            // chat's own pan recognizer (which is the same gesture
            // driving the dismiss) can't drag the content along.
            chat.setBottomInset(
                desiredInset,
                animated: false,
                shiftingOffset: !isInteractiveDismissing
            )
        }
        if isInteractiveDismissing,
           let locked = dismissLockOffsetY,
           let originalInset = startDismissInset,
           chat.contentOffset.y != locked {
            
            let totalDelta = chat.contentInset.bottom - originalInset
            chat.contentOffset.y = locked + totalDelta
        }
    }

    private func setupUI() {
        configureButton(pushButton, title: "Push", action: #selector(pushTapped))
        configureButton(jumpButton, title: "Jump", action: #selector(jumpTapped))

        let toolbar = UIStackView(arrangedSubviews: [pushButton, jumpButton])
        toolbar.axis = .horizontal
        toolbar.distribution = .fillEqually
        toolbar.spacing = 8
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        chat.translatesAutoresizingMaskIntoConstraints = false
        chat.backgroundColor = .secondarySystemBackground
        chat.showsStickyHeadersOnlyWhileScrolling = true
        // Pulling the chat content downward while the keyboard is up
        // dismisses the keyboard interactively — UIKit attaches the
        // keyboard to the user's drag once the touch crosses the keyboard's
        // top edge. The `keyboardLayoutGuide` constraint on `inputField`
        // (and the chat.bottom anchor that follows it) updates throughout
        // the gesture, so the chat smoothly grows back to full size as the
        // keyboard slides off.
        chat.keyboardDismissMode = .interactive

        inputField.translatesAutoresizingMaskIntoConstraints = false
        inputField.placeholder = "Message"
        inputField.borderStyle = .roundedRect
        inputField.returnKeyType = .send
        inputField.delegate = self
        inputField.backgroundColor = .secondarySystemBackground

        badgeButton.translatesAutoresizingMaskIntoConstraints = false
        var badgeConfig = UIButton.Configuration.filled()
        badgeConfig.baseBackgroundColor = .systemRed
        badgeConfig.baseForegroundColor = .white
        badgeConfig.cornerStyle = .capsule
        badgeConfig.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 14, bottom: 4, trailing: 14)
        badgeButton.configuration = badgeConfig
        // Chat manages alpha based on scroll position; start fully transparent
        // so the initial bottom-pinned load doesn't briefly show the badge.
        badgeButton.alpha = 0
        badgeButton.addTarget(self, action: #selector(badgeTapped), for: .touchUpInside)
        updateBadgeTitle()

        view.addSubview(toolbar)
        view.addSubview(chat)
        view.addSubview(inputField)
        view.addSubview(badgeButton)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            toolbar.heightAnchor.constraint(equalToConstant: 44),

            // Chat fills the space between the toolbar and the very bottom
            // of the view. The input bar (transparent background) is laid
            // on top of the chat; `contentInset.bottom` carved out at the
            // chat level reserves room so the input bar doesn't cover the
            // last message. When the keyboard opens that inset grows by
            // exactly the keyboard's height, and `setBottomInset` shifts
            // `contentOffset.y` by the same delta — keeping the last
            // visible message anchored just above the input bar.
            chat.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            chat.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            chat.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            chat.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            // Pin the input bar to the keyboard layout guide (iOS 15+).
            // The guide tracks the keyboard's actual position — including
            // mid-flight during interactive dismissal — so the input bar
            // (and the chat above it) follow the keyboard continuously
            // without any notification plumbing on our side.
            inputField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            inputField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            inputField.heightAnchor.constraint(equalToConstant: 36),
            inputField.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -8),

            // Badge floats above the input bar (and so above the keyboard
            // when it's up).
            badgeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            badgeButton.bottomAnchor.constraint(equalTo: inputField.topAnchor, constant: -8),
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
        chat.setNewItemsBadge(badgeButton)
        chat.setDataSourceProvider(provider)
    }

    // MARK: Keyboard handling

    private func setupKeyboardObservers() {
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(keyboardWillShow(_:)),
            name: UIResponder.keyboardWillShowNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(keyboardDidShow(_:)),
            name: UIResponder.keyboardDidShowNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(keyboardDidHide(_:)),
            name: UIResponder.keyboardDidHideNotification,
            object: nil
        )

        // Parallel pan gesture on the chat. We don't drive scrolling
        // from it — the chat's built-in `UIScrollView` pan handles that.
        // This gesture only watches the touch path to detect the moment
        // it crosses into the input bar area while the keyboard is up,
        // which is when an interactive keyboard dismiss has begun.
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleChatPan(_:)))
        pan.delegate = self
        pan.cancelsTouchesInView = false
        chat.addGestureRecognizer(pan)
    }

    @objc private func keyboardWillShow(_ notification: Notification) {
        // Re-entering "keyboard up" — drop any stale interactive-dismiss
        // state so the next show animation runs with normal inset/offset
        // shifting.
        isInteractiveDismissing = false
        dismissLockOffsetY = nil
        startDismissInset = nil
    }

    @objc private func keyboardDidShow(_ notification: Notification) {
        if #available(iOS 17.0, *) {
            // Extend the system's interactive-dismiss zone upward by the
            // input bar's height. With `.interactive` mode + this padding,
            // the keyboard starts following the finger the moment the
            // drag crosses the input bar's top edge — not only after it
            // crosses the keyboard's top. This gives the iMessage feel
            // where touching the input bar area during a downward drag
            // begins the dismiss.
            view.keyboardLayoutGuide.keyboardDismissPadding = inputField.frame.height
        }
    }

    @objc private func keyboardDidHide(_ notification: Notification) {
        isInteractiveDismissing = false
        dismissLockOffsetY = nil
        startDismissInset = nil
        if #available(iOS 17.0, *) {
            view.keyboardLayoutGuide.keyboardDismissPadding = 0
        }
    }

    @objc private func handleChatPan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began, .changed:
            guard !isInteractiveDismissing else { return }
            let velocity = gesture.velocity(in: view)
            let location = gesture.location(in: view)
            // Conditions for "this drag has begun dismissing the keyboard":
            // - the keyboard is actually up (input field is first responder);
            // - the user is dragging downward (velocity.y > 0);
            // - the finger has crossed into the input bar area, i.e. is
            //   at or below the input bar's top edge.
            if inputField.isFirstResponder,
               velocity.y > 0,
               location.y >= inputField.frame.minY {
                isInteractiveDismissing = true
                dismissLockOffsetY = chat.contentOffset.y
                startDismissInset = chat.contentInset.bottom
            }
        case .ended, .cancelled, .failed:
            // Don't reset the flag here — the keyboard's snap-back or
            // dismissal animation still has frames where the inset needs
            // to be applied with `shiftingOffset: false`. The flag is
            // cleared in `keyboardDidHide` (full dismiss path) or in
            // `keyboardWillShow` (snap-back followed by a fresh show).
            break
        default:
            break
        }
    }

    // MARK: UIGestureRecognizerDelegate

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        // Our observer pan must coexist with the chat's built-in scroll pan.
        return true
    }

    // MARK: Actions

    @objc private func pushTapped() {
        chat.appendNewItems([provider.makePushMessage()])
    }

    @objc private func jumpTapped() {
        chat.scroll(to: provider.randomKnownId(), animated: true)
    }

    @objc private func badgeTapped() {
        // Chat will fade the badge to 0 as soon as the scroll reaches the
        // bottom; we still reset the local pending counter so the title is
        // accurate the next time it's shown.
        pendingNewItemsCount = 0
        updateBadgeTitle()
        chat.scrollToLiveTail(animated: true)
    }

    private func updateBadgeTitle() {
        let title = pendingNewItemsCount > 0
            ? "+\(pendingNewItemsCount) new ↓"
            : "↓ Bottom"
        badgeButton.setTitle(title, for: .normal)
    }

    // MARK: UITextFieldDelegate

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        let text = textField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !text.isEmpty {
            chat.appendNewItems([provider.makePushMessage(text: text)])
            textField.text = nil
        } else {
            textField.resignFirstResponder()
        }
        return false
    }

    // MARK: ChatScrollViewDelegate

    func didReceiveNewItemsWhileScrolledUp(count: Int) {
        pendingNewItemsCount += count
        updateBadgeTitle()
    }

    func didFailLoad(_ error: Error) {
        print("Load failed: \(error)")
    }

    func didScrollToItem(id: ItemID) {
        guard let cellView = chat.visibleView(for: id) else { return }
        flashHighlight(on: cellView)
    }

    func didShowItem(id: ItemID) {
        // Items appearing in the viewport drain the "unread" counter. The
        // chat decides badge visibility (it fades to 0 once the user has
        // scrolled all the way down); we only have to keep the title fresh.
        guard pendingNewItemsCount > 0 else { return }
        pendingNewItemsCount -= 1
        updateBadgeTitle()
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
