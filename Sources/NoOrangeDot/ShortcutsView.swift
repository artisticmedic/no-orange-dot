import SwiftUI

/// Settings for keyboard shortcuts. The app ships with none: each one here is the user's choice.
struct ShortcutsCard: View {
    @EnvironmentObject var engine: Engine
    @State private var showAll = false

    private var setCount: Int { MenuCommand.all.filter { !$0.global && Shortcut(engine.shortcut(for: $0.id)) != nil }.count }

    var body: some View {
        VStack(spacing: 12) {
            Card {
                ForEach(Array(MenuCommand.all.filter(\.global).enumerated()), id: \.element.id) { i, c in
                    if i > 0 { RowDivider() }
                    Row(title: c.title, caption: "Works in any app. Click to set it, or press × to remove it.") { recorder(c) }
                }
            }
            Card {
                Row(title: "Menu commands", caption: setCount == 0 ? "Give any command in the menus its own shortcut. These work while this app is in front."
                                                                   : "\(setCount) set. These work while this app is in front.") {
                    Button(showAll ? "Hide" : "Show All") { showAll.toggle() }.buttonStyle(PillButtonStyle())
                }
                if showAll {
                    ForEach(MenuCommand.menus, id: \.self) { menu in
                        RowDivider()
                        Text(menu).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 2)
                        ForEach(MenuCommand.all.filter { $0.menu == menu && !$0.global }) { c in
                            HStack {
                                Text(c.title).font(.system(size: 14))
                                Spacer(minLength: 8)
                                recorder(c)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 4)
                        }
                    }
                    Spacer().frame(height: 8)
                }
            }
        }
    }

    /// Refuses keys that something else in the app already uses, and says what holds them.
    private func recorder(_ c: MenuCommand) -> some View {
        ShortcutButton(text: Binding(get: { engine.shortcut(for: c.id) }, set: { text in
            if let s = Shortcut(text), let holder = MainMenu.current?.holder(of: s, except: c.id) {
                engine.error = "\(s.display) is already used by \(holder)."
                return
            }
            engine.setShortcut(text, for: c.id)
        }))
        .accessibilityLabel("Shortcut for \(c.title)")
    }
}
