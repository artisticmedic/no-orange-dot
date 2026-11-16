import Foundation

enum MicrophonePriority {
    static func select(order: [String], available: [String], previouslyAvailable: [String], manual: String?, current: String? = nil) -> String? {
        let connected = Set(available)
        let arrived = connected.subtracting(previouslyAvailable)
        if let manual, connected.contains(manual), !order.contains(where: arrived.contains) { return manual }
        if let preferred = order.first(where: connected.contains) { return preferred }
        if let current, connected.contains(current) { return current }
        return available.first
    }
}
