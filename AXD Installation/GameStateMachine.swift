import Foundation

enum GamePlayerState {
    case rooftop
    case swinging
    case falling
    case grounded
}

final class GameStateMachine {
    private(set) var state: GamePlayerState = .rooftop

    var isRooftop: Bool { state == .rooftop }
    var isGrounded: Bool { state == .grounded }

    func transition(to newState: GamePlayerState) {
        state = newState
    }
}

