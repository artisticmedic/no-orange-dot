import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import ServiceManagement
import SwiftUI

extension Engine {
    // MARK: Status in words

    var markState: AppMark.State { muted ? .muted : recording ? .recording : running ? .live : .idle }

    var statusColor: Color {
        if recording { return .red }
        if muted { return .orange }
        return running ? .green : .secondary
    }

    var statusTitle: String {
        if !driverInstalled { return "Driver missing" }
        if recording { return "Recording" }
        if muted { return "Muted" }
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
        if !running { return "No app is using it" }
        return ""
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
