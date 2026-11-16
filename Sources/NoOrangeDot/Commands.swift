import Foundation

/// Every menu command that can be given a keyboard shortcut. The app ships with none set: the user
/// chooses them in Settings or with `nod shortcut`. The menus, Settings and the CLI all read this list.
struct MenuCommand: Identifiable, Equatable {
    let id: String
    let menu: String
    let title: String
    /// Works in any app, not only while this one is in front.
    var global = false

    static let mute = "mute", record = "record"

    static let all: [MenuCommand] = [
        MenuCommand(id: mute, menu: "Microphone", title: "Mute or Unmute", global: true),
        MenuCommand(id: "listen", menu: "Microphone", title: "Listen to Yourself"),
        MenuCommand(id: "mic-priority", menu: "Microphone", title: "Microphone Priority…"),
        MenuCommand(id: "system-mic", menu: "Microphone", title: "Use as the Mac's Microphone"),
        MenuCommand(id: "gain-up", menu: "Microphone", title: "Raise Mic Gain"),
        MenuCommand(id: "gain-down", menu: "Microphone", title: "Lower Mic Gain"),
        MenuCommand(id: "gain-lock", menu: "Microphone", title: "Lock Gain"),
        MenuCommand(id: "rename-mic", menu: "Microphone", title: "Rename the Mic…"),

        MenuCommand(id: "eq", menu: "Sound", title: "Equalizer"),
        MenuCommand(id: "curve-warm", menu: "Sound", title: "Warm Voice Curve"),
        MenuCommand(id: "curve-flat", menu: "Sound", title: "Flat Curve"),
        MenuCommand(id: "clear-history", menu: "Sound", title: "Clear Earlier Curves"),
        MenuCommand(id: "gate", menu: "Sound", title: "Noise Gate"),
        MenuCommand(id: "compressor", menu: "Sound", title: "Compressor"),
        MenuCommand(id: "limiter", menu: "Sound", title: "Limiter"),
        MenuCommand(id: "output-up", menu: "Sound", title: "Raise Output Level"),
        MenuCommand(id: "output-down", menu: "Sound", title: "Lower Output Level"),
        MenuCommand(id: "save-preset", menu: "Sound", title: "Save Current as Preset…"),
    ] + (1...9).map { MenuCommand(id: "preset-\($0)", menu: "Sound", title: "Use Preset \($0)") } + [
        MenuCommand(id: "band-add", menu: "Band", title: "Add Band"),
        MenuCommand(id: "band-next", menu: "Band", title: "Select Next Band"),
        MenuCommand(id: "band-previous", menu: "Band", title: "Select Previous Band"),
        MenuCommand(id: "band-on", menu: "Band", title: "Band On"),
        MenuCommand(id: "band-remove", menu: "Band", title: "Remove Band"),
        MenuCommand(id: "band-gain-up", menu: "Band", title: "Raise Gain"),
        MenuCommand(id: "band-gain-down", menu: "Band", title: "Lower Gain"),
        MenuCommand(id: "band-freq-up", menu: "Band", title: "Raise Frequency"),
        MenuCommand(id: "band-freq-down", menu: "Band", title: "Lower Frequency"),
        MenuCommand(id: "band-wider", menu: "Band", title: "Widen"),
        MenuCommand(id: "band-narrower", menu: "Band", title: "Narrow"),

        MenuCommand(id: record, menu: "Recordings", title: "Start or Stop Recording", global: true),
        MenuCommand(id: "play-last", menu: "Recordings", title: "Play Last Recording"),
        MenuCommand(id: "stop-playing", menu: "Recordings", title: "Stop Playing"),
        MenuCommand(id: "loop", menu: "Recordings", title: "Loop"),
        MenuCommand(id: "reveal-last", menu: "Recordings", title: "Show Last Recording in Finder"),
        MenuCommand(id: "open-folder", menu: "Recordings", title: "Open Recordings Folder"),
        MenuCommand(id: "choose-folder", menu: "Recordings", title: "Change Recordings Folder…"),

        MenuCommand(id: "show-sound", menu: "View", title: "Sound"),
        MenuCommand(id: "show-recordings", menu: "View", title: "Recordings"),
        MenuCommand(id: "show-settings", menu: "View", title: "Settings"),
        MenuCommand(id: "see-voice", menu: "View", title: "See Your Voice"),
        MenuCommand(id: "heat-map", menu: "View", title: "Heat Map"),
        MenuCommand(id: "show-window", menu: "View", title: "Show the Window"),

        MenuCommand(id: "check-updates", menu: "App", title: "Check for Updates…"),
        MenuCommand(id: "install-update", menu: "App", title: "Install Update…"),
        MenuCommand(id: "auto-check", menu: "App", title: "Check for Updates Automatically"),
        MenuCommand(id: "open-at-login", menu: "App", title: "Open at Login"),
        MenuCommand(id: "show-in-dock", menu: "App", title: "Show in Dock"),
    ]

    /// The standard Mac shortcuts the menus keep. A user's shortcut may not reuse them.
    static let reserved = ["cmd+q": "Quit", "cmd+h": "Hide", "opt+cmd+h": "Hide Others", "cmd+w": "Close", "cmd+m": "Minimize",
                           "cmd+z": "Undo", "shift+cmd+z": "Redo", "cmd+x": "Cut", "cmd+c": "Copy", "cmd+v": "Paste", "cmd+a": "Select All"]

    static let menus = ["Microphone", "Sound", "Band", "Recordings", "View", "App"]
    static func named(_ id: String) -> MenuCommand? { all.first { $0.id == id } }
}
