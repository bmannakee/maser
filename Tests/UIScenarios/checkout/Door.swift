// A door controller.
enum DoorState { case closed, opening, open, closing, locked }

struct Door {
    var state = DoorState.closed

    mutating func handle(_ event: String) {
        switch (state, event) {
        case (.closed, "open"): state = .opening
        case (.opening, "done"): state = .open
        case (.open, "close"): state = .closing
        case (.closing, "done"): state = .closed
        case (.closed, "lock"): state = .locked
        case (.locked, "unlock"): state = .closed
        // Safety: an obstruction while closing reopens the door.
        case (.closing, "obstructed"): state = .opening
        default: break
        }
    }
}
