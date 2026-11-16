import SwiftUI

struct MicOrderCard: View {
    @EnvironmentObject var engine: Engine

    var body: some View {
        let listed = engine.micOrder.compactMap { uid in engine.micName(for: uid).map { (uid: uid, name: $0) } }
        Card {
            Row(title: "Use the first one that is plugged in", caption: "When a mic higher on this list is plugged in, the app switches to it. When the one in use is unplugged, the app moves down the list.") { EmptyView() }
            ForEach(Array(listed.enumerated()), id: \.element.uid) { i, mic in
                RowDivider()
                Row(title: "\(i + 1). \(mic.name)", caption: caption(mic.uid)) {
                    HStack(spacing: 6) {
                        move("chevron.up", "Move \(mic.name) up", mic.uid, past: i > 0 ? listed[i - 1].uid : nil)
                        move("chevron.down", "Move \(mic.name) down", mic.uid, past: i < listed.count - 1 ? listed[i + 1].uid : nil)
                    }
                }
            }
        }
    }

    private func caption(_ uid: String) -> String? {
        if uid == engine.inputUID { return "In use" }
        return engine.inputs.contains { $0.uid == uid } ? nil : "Not plugged in"
    }

    private func move(_ symbol: String, _ label: String, _ uid: String, past other: String?) -> some View {
        Button { if let other { engine.moveMic(uid, past: other) } } label: {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).frame(width: 14, height: 14)
        }
        .buttonStyle(PillButtonStyle()).disabled(other == nil)
        .accessibilityLabel(label)
    }
}
