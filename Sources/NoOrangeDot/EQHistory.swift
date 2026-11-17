import Foundation

struct EQHistory {
    private struct Edit {
        var before: [Band]
        var after: [Band]
        let date: Date
        let mic: String
    }

    private(set) var snapshots: [EQSnapshot]
    private var micUID = ""
    private var micName = ""
    private var undoByMic: [String: [[Band]]] = [:]
    private var redoByMic: [String: [[Band]]] = [:]
    private var pending: Edit?

    init(snapshots: [EQSnapshot] = []) { self.snapshots = snapshots }

    var canUndo: Bool {
        if let pending, pending.before != pending.after { return true }
        return !(undoByMic[micUID] ?? []).isEmpty
    }
    var canRedo: Bool { pending == nil && !(redoByMic[micUID] ?? []).isEmpty }

    mutating func selectMic(_ uid: String, name: String) {
        if uid != micUID { flush(); micUID = uid }
        micName = name
    }

    mutating func record(before: [Band], after: [Band], date: Date = Date()) {
        guard !micUID.isEmpty, before != after else { return }
        if pending == nil { pending = Edit(before: before, after: after, date: date, mic: micName) }
        else { pending?.after = after }
        redoByMic[micUID] = []
    }

    mutating func replace(before: [Band], after: [Band], date: Date = Date()) {
        flush()
        record(before: before, after: after, date: date)
        flush()
    }

    @discardableResult
    mutating func flush() -> Bool {
        guard let edit = pending else { return false }
        pending = nil
        guard edit.before != edit.after else { return false }
        undoByMic[micUID, default: []].append(edit.before)
        if undoByMic[micUID, default: []].count > 40 { undoByMic[micUID]?.removeFirst() }
        return remember(edit.before, mic: edit.mic, date: edit.date)
    }

    mutating func undo(current: [Band], date: Date = Date()) -> [Band]? {
        flush()
        guard let previous = undoByMic[micUID]?.popLast() else { return nil }
        redoByMic[micUID, default: []].append(current)
        remember(current, mic: micName, date: date)
        return previous
    }

    mutating func redo(current: [Band], date: Date = Date()) -> [Band]? {
        flush()
        guard let next = redoByMic[micUID]?.popLast() else { return nil }
        undoByMic[micUID, default: []].append(current)
        remember(current, mic: micName, date: date)
        return next
    }

    mutating func clear() {
        pending = nil
        undoByMic = [:]; redoByMic = [:]
        snapshots = []
    }

    mutating func replaceSnapshots(_ snapshots: [EQSnapshot]) { self.snapshots = snapshots }

    @discardableResult
    private mutating func remember(_ bands: [Band], mic: String, date: Date) -> Bool {
        if snapshots.first?.bands == bands, snapshots.first?.micUID == micUID { return false }
        snapshots.insert(EQSnapshot(date: date, mic: mic, bands: bands, micUID: micUID), at: 0)
        if snapshots.count > 40 { snapshots.removeLast(snapshots.count - 40) }
        return true
    }
}
