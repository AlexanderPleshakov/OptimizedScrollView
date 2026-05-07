enum ScrollState {
    case idle
    case userScrolling
    case decelerating
    case programmatic
}

@MainActor
final class ScrollStateMachine {
    private(set) var state: ScrollState = .idle

    var isUserDriven: Bool {
        state == .userScrolling || state == .decelerating
    }

    func willBeginDragging() { state = .userScrolling }

    func didEndDragging(willDecelerate: Bool) {
        state = willDecelerate ? .decelerating : .idle
    }

    func didEndDecelerating() { state = .idle }

    func willBeginProgrammaticScroll() { state = .programmatic }

    func didEndProgrammaticScroll() {
        if state == .programmatic { state = .idle }
    }
}
