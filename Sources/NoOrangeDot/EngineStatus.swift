import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import ServiceManagement
import SwiftUI

extension Engine {
    // MARK: Status in words

    var markState: AppMark.State { muted ? .muted : recording && !recordingPaused ? .recording : running ? .live : .idle }

    var statusColor: Color {
        if recording { return recordingPaused ? .secondary : .red }
        if muted { return .orange }
        return running ? .green : .secondary
    }

    var statusTitle: String {
        if !driverInstalled { return "Driver missing" }
        if recording { return recordingPaused ? "Recording paused" : "Recording" }
        if muted { return "Muted" }
        if inputUID.isEmpty { return "Choose a microphone" }
        if !running { return "Mic off" }
        let who = Self.sentenceList(listeners)
        if !who.isEmpty { return "\(who) \(listeners.count == 1 ? "is" : "are") using the mic" }
        return listenBack ? "Listening to yourself" : monitoring ? "Mic open for the live view" : "Mic open"
    }

    var statusDetail: String {
        if !driverInstalled { return "Run the installer to put the microphone back" }
        let who = Self.sentenceList(listeners)
        if muted { return who.isEmpty ? "The mic stays closed" : "\(who) \(listeners.count == 1 ? "hears" : "hear") silence" }
        if recording { return "Saving to \(recordingsURL.lastPathComponent)" }
        if inputUID.isEmpty { return "No microphone is connected" }
        if !running { return "No app is using it" }
        return ""
    }

    /// Said under the status when an app reads the real microphone directly, around the EQ.
    var directUseNote: String? {
        let who = Self.sentenceList(directUsers)
        guard !who.isEmpty, let mic = inputs.first(where: { $0.uid == inputUID })?.name else { return nil }
        return "\(who) \(directUsers.count == 1 ? "is" : "are") using \(mic) directly, so \(directUsers.count == 1 ? "it hears" : "they hear") it without the EQ."
    }

    func refreshDirectUsers() {
        let names = HAL.device(uid: inputUID).map { HAL.inputClients(of: $0).map(\.name) } ?? []
        if names != directUsers { directUsers = names }
    }

    static func sentenceList(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return "\(names[0]) and \(names.count - 1) others"
        }
    }

    func refreshListeners() {
        let now = clientsActive, let_mic = micDevice
        guard now, let mic = let_mic else { if !listeners.isEmpty { listeners = []; listenerIcon = nil; listenerPID = 0 }; return }
        let clients = HAL.inputClients(of: mic), names = clients.map(\.name)
        if names != listeners { listeners = names }
        let pid = clients.first?.pid ?? 0
        if pid != listenerPID { listenerPID = pid; listenerIcon = pid == 0 ? nil : NSRunningApplication(processIdentifier: pid)?.icon }
    }
}
