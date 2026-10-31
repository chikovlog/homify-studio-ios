import Foundation

/// Snapshot-based undo/redo. `Project` is a value type made of small structs,
/// so a snapshot is cheap (copy-on-write arrays) and restoring is O(1).
public struct EditHistory<State> {
    public private(set) var undoStack: [(name: String, state: State)] = []
    public private(set) var redoStack: [(name: String, state: State)] = []
    public let limit: Int

    public init(limit: Int = 200) { self.limit = max(1, limit) }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var undoName: String? { undoStack.last?.name }
    public var redoName: String? { redoStack.last?.name }

    /// Call with the state *before* a change.
    public mutating func record(_ before: State, name: String) {
        undoStack.append((name, before))
        if undoStack.count > limit { undoStack.removeFirst(undoStack.count - limit) }
        redoStack.removeAll()
    }

    public mutating func undo(current: State) -> State? {
        guard let last = undoStack.popLast() else { return nil }
        redoStack.append((last.name, current))
        return last.state
    }

    public mutating func redo(current: State) -> State? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append((next.name, current))
        return next.state
    }

    public mutating func clear() {
        undoStack.removeAll()
        redoStack.removeAll()
    }
}
