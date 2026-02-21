/// WorkWorkDaemon — persistent macOS daemon for WorkWork sound notifications.
///
/// Listens on a Unix domain socket, receives hook events as JSON,
/// routes to sound categories, plays audio via AVAudioEngine (Sound Effects device),
/// and returns TTY escape sequences for tab title/color.
///
/// All CLI commands are handled in-daemon — zero external dependencies.
///
/// Build: swiftc -O -o daemon/workworkd daemon/WorkWorkDaemon.swift \
///   -framework AVFoundation -framework CoreAudio -framework AudioToolbox \
///   -framework AppKit -framework Foundation

import AVFoundation
import CoreAudio
import AudioToolbox
import AppKit
import Foundation

// MARK: - Configuration Model

struct DaemonConfig {
    var enabled: Bool = true
    var volume: Float = 0.5
    var desktopNotifications: Bool = true
    var useSoundEffectsDevice: Bool = true
    var notificationStyle: String = "overlay"
    var defaultPack: String = "peon"
    var packRotation: [String] = []
    var packRotationMode: String = "random"
    var pathRules: [[String: String]] = []
    var sessionTTLDays: Int = 7
    var annoyedThreshold: Int = 3
    var annoyedWindowSeconds: Double = 10
    var silentWindowSeconds: Double = 0
    var suppressSubagentComplete: Bool = false
    var categories: [String: Bool] = [
        "session.start": true,
        "task.acknowledge": false,
        "task.complete": true,
        "task.error": true,
        "input.required": true,
        "resource.limit": true,
        "user.spam": true
    ]
    var tabColorEnabled: Bool = true
    var tabColorColors: [String: [Int]] = [
        "ready":          [65, 115, 80],
        "working":        [130, 105, 50],
        "done":           [65, 100, 140],
        "needs_approval": [150, 70, 70]
    ]
    var tabColorProfiles: [String: [String: [Int]]] = [:]

    private static let configKeys: Set<String> = [
        "enabled", "volume", "desktop_notifications", "use_sound_effects_device",
        "notification_style", "default_pack", "pack_rotation", "pack_rotation_mode",
        "path_rules", "session_ttl_days", "annoyed_threshold", "annoyed_window_seconds",
        "silent_window_seconds", "suppress_subagent_complete", "categories", "tab_color"
    ]

    static func load(from path: String) -> DaemonConfig {
        var cfg = DaemonConfig()
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return cfg
        }
        cfg.applyJSON(json)
        return cfg
    }

    mutating func applyJSON(_ json: [String: Any]) {
        if let v = json["enabled"] as? Bool { enabled = v }
        if let v = json["volume"] as? Double { volume = Float(v) }
        if let v = json["desktop_notifications"] as? Bool { desktopNotifications = v }
        if let v = json["use_sound_effects_device"] as? Bool { useSoundEffectsDevice = v }
        if let v = json["notification_style"] as? String { notificationStyle = v }
        if let v = json["default_pack"] as? String { defaultPack = v }
        else if let v = json["active_pack"] as? String { defaultPack = v }
        if let v = json["pack_rotation"] as? [String] { packRotation = v }
        if let v = json["pack_rotation_mode"] as? String { packRotationMode = v }
        if let v = json["path_rules"] as? [[String: String]] { pathRules = v }
        if let v = json["session_ttl_days"] as? Int { sessionTTLDays = v }
        if let v = json["annoyed_threshold"] as? Int { annoyedThreshold = v }
        if let v = json["annoyed_window_seconds"] as? Double { annoyedWindowSeconds = v }
        if let v = json["silent_window_seconds"] as? Double { silentWindowSeconds = v }
        if let v = json["suppress_subagent_complete"] as? Bool { suppressSubagentComplete = v }
        if let cats = json["categories"] as? [String: Any] {
            let defaultOff: Set<String> = ["task.acknowledge"]
            for key in ["session.start", "task.acknowledge", "task.complete", "task.error",
                        "input.required", "resource.limit", "user.spam"] {
                let dflt = !defaultOff.contains(key)
                if let v = cats[key] as? Bool { categories[key] = v }
                else { categories[key] = dflt }
            }
        }
        if let tc = json["tab_color"] as? [String: Any] {
            if let en = tc["enabled"] as? Bool { tabColorEnabled = en }
            if let cols = tc["colors"] as? [String: [Int]] {
                for (k, v) in cols { tabColorColors[k] = v }
            }
            if let profs = tc["color_profiles"] as? [String: [String: [Int]]] {
                tabColorProfiles = profs
            }
        }
    }

    /// Write a single key back to config.json, preserving all other keys
    static func writeKey(_ key: String, value: Any, configPath: String) {
        var json: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: configPath),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = parsed
        }
        json[key] = value
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: configPath))
        }
    }

    /// Read current JSON from disk
    static func readJSON(from path: String) -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return json
    }
}

// MARK: - State Model

class DaemonState {
    var lastActive: [String: Any] = [:]
    var lastStopTime: Double = 0
    var lastPlayed: [String: String] = [:]
    var promptTimestamps: [String: [Double]] = [:]
    var promptStartTimes: [String: Double] = [:]
    var sessionStartTimes: [String: Double] = [:]
    var sessionPacks: [String: Any] = [:]
    var subagentSessions: [String: Double] = [:]
    var agentSessions: Set<String> = []
    var pendingSubagentPack: [String: Any] = [:]
    var rotationIndex: Int = 0

    var dirty = false
    private let filePath: String

    init(filePath: String) {
        self.filePath = filePath
        load()
    }

    func load() {
        guard let data = FileManager.default.contents(atPath: filePath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let v = json["last_active"] as? [String: Any] { lastActive = v }
        if let v = json["last_stop_time"] as? Double { lastStopTime = v }
        if let v = json["last_played"] as? [String: String] { lastPlayed = v }
        if let v = json["prompt_timestamps"] as? [String: [Double]] { promptTimestamps = v }
        if let v = json["prompt_start_times"] as? [String: Double] { promptStartTimes = v }
        if let v = json["session_start_times"] as? [String: Double] { sessionStartTimes = v }
        if let v = json["session_packs"] as? [String: Any] { sessionPacks = v }
        if let v = json["subagent_sessions"] as? [String: Double] { subagentSessions = v }
        if let v = json["agent_sessions"] as? [String] { agentSessions = Set(v) }
        if let v = json["pending_subagent_pack"] as? [String: Any] { pendingSubagentPack = v }
        if let v = json["rotation_index"] as? Int { rotationIndex = v }
    }

    func save() {
        let dict: [String: Any] = [
            "last_active": lastActive,
            "last_stop_time": lastStopTime,
            "last_played": lastPlayed,
            "prompt_timestamps": promptTimestamps,
            "prompt_start_times": promptStartTimes,
            "session_start_times": sessionStartTimes,
            "session_packs": sessionPacks,
            "subagent_sessions": subagentSessions,
            "agent_sessions": Array(agentSessions),
            "pending_subagent_pack": pendingSubagentPack,
            "rotation_index": rotationIndex
        ]
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: []) {
            try? data.write(to: URL(fileURLWithPath: filePath))
        }
        dirty = false
    }

    func getSessionPackName(_ sessionId: String) -> String? {
        guard let entry = sessionPacks[sessionId] else { return nil }
        if let dict = entry as? [String: Any] { return dict["pack"] as? String }
        if let str = entry as? String { return str }
        return nil
    }

    func setSessionPack(_ sessionId: String, pack: String) {
        sessionPacks[sessionId] = ["pack": pack, "last_used": Date().timeIntervalSince1970] as [String: Any]
        dirty = true
    }
}

// MARK: - Audio Engine

class AudioPlayer {
    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var useSoundEffectsDevice: Bool = true
    private var volume: Float = 0.5

    func configure(useSoundEffects: Bool, volume: Float) {
        self.useSoundEffectsDevice = useSoundEffects
        self.volume = volume
    }

    func play(file path: String) {
        stop()
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return }
        guard let audioFile = try? AVAudioFile(forReading: url) else { return }

        let eng = AVAudioEngine()
        let player = AVAudioPlayerNode()
        eng.attach(player)

        if useSoundEffectsDevice, let deviceID = systemOutputDeviceID(),
           let audioUnit = eng.outputNode.audioUnit {
            var devID = deviceID
            AudioUnitSetProperty(audioUnit,
                                 kAudioOutputUnitProperty_CurrentDevice,
                                 kAudioUnitScope_Global, 0,
                                 &devID, UInt32(MemoryLayout<AudioDeviceID>.size))
        }

        let format = audioFile.processingFormat
        eng.connect(player, to: eng.mainMixerNode, format: format)
        eng.mainMixerNode.outputVolume = volume

        guard (try? eng.start()) != nil else { return }

        player.scheduleFile(audioFile, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                self?.engine?.stop()
                self?.engine = nil
                self?.playerNode = nil
            }
        }
        player.play()

        self.engine = eng
        self.playerNode = player
    }

    func stop() {
        playerNode?.stop()
        engine?.stop()
        engine = nil
        playerNode = nil
    }

    private func systemOutputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }
}

// MARK: - Pack Manifest

struct SoundEntry {
    let file: String
    let label: String
    let icon: String?
}

class PackManager {
    private let workDir: String
    private var manifests: [String: [String: Any]] = [:]

    init(workDir: String) {
        self.workDir = workDir
    }

    func loadManifest(pack: String) -> [String: Any]? {
        if let cached = manifests[pack] { return cached }
        let packDir = (workDir as NSString).appendingPathComponent("packs/\(pack)")
        for name in ["openpeon.json", "manifest.json"] {
            let path = (packDir as NSString).appendingPathComponent(name)
            if let data = FileManager.default.contents(atPath: path),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                manifests[pack] = json
                return json
            }
        }
        return nil
    }

    func clearCache() {
        manifests.removeAll()
    }

    func packExists(_ pack: String) -> Bool {
        let path = (workDir as NSString).appendingPathComponent("packs/\(pack)")
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    func listPacks() -> [(name: String, displayName: String, soundCount: Int)] {
        let packsDir = (workDir as NSString).appendingPathComponent("packs")
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: packsDir) else { return [] }
        var result: [(name: String, displayName: String, soundCount: Int)] = []
        for name in contents.sorted() {
            let packPath = (packsDir as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: packPath, isDirectory: &isDir), isDir.boolValue else { continue }
            guard name != ".DS_Store" else { continue }
            var displayName = name
            var soundCount = 0
            if let manifest = loadManifest(pack: name) {
                if let dn = manifest["display_name"] as? String { displayName = dn }
                if let cats = manifest["categories"] as? [String: Any] {
                    var seen = Set<String>()
                    for (_, catData) in cats {
                        if let cd = catData as? [String: Any],
                           let sounds = cd["sounds"] as? [[String: Any]] {
                            for s in sounds {
                                if let f = s["file"] as? String { seen.insert(f) }
                            }
                        }
                    }
                    soundCount = seen.count
                }
            }
            result.append((name: name, displayName: displayName, soundCount: soundCount))
        }
        return result
    }

    func listCategories(pack: String) -> [String] {
        guard let manifest = loadManifest(pack: pack),
              let cats = manifest["categories"] as? [String: Any] else { return [] }
        return cats.keys.sorted()
    }

    func pickSound(pack: String, category: String, lastPlayed: String?) -> (path: String, file: String, iconPath: String?)? {
        guard let manifest = loadManifest(pack: pack) else { return nil }
        guard let cats = manifest["categories"] as? [String: Any],
              let catData = cats[category] as? [String: Any],
              let sounds = catData["sounds"] as? [[String: Any]],
              !sounds.isEmpty else { return nil }

        let packDir = (workDir as NSString).appendingPathComponent("packs/\(pack)")
        let packRoot = (packDir as NSString).standardizingPath + "/"

        var candidates = sounds
        if sounds.count > 1, let lp = lastPlayed {
            candidates = sounds.filter { ($0["file"] as? String) != lp }
            if candidates.isEmpty { candidates = sounds }
        }

        guard let pick = candidates.randomElement(),
              let fileRef = pick["file"] as? String else { return nil }

        let fullPath: String
        if fileRef.contains("/") {
            fullPath = ((packDir as NSString).appendingPathComponent(fileRef) as NSString).standardizingPath
        } else {
            fullPath = ((packDir as NSString).appendingPathComponent("sounds/\(fileRef)") as NSString).standardizingPath
        }
        guard fullPath.hasPrefix(packRoot) else { return nil }
        guard FileManager.default.fileExists(atPath: fullPath) else { return nil }

        var iconPath: String? = nil
        if let ic = pick["icon"] as? String { iconPath = ic }
        else if let catIcon = catData["icon"] as? String { iconPath = catIcon }
        else if let mIcon = manifest["icon"] as? String { iconPath = mIcon }
        else {
            let defaultIcon = (packDir as NSString).appendingPathComponent("icon.png")
            if FileManager.default.fileExists(atPath: defaultIcon) { iconPath = "icon.png" }
        }
        if let ic = iconPath {
            let resolved = ((packDir as NSString).appendingPathComponent(ic) as NSString).standardizingPath
            if resolved.hasPrefix(packRoot), FileManager.default.fileExists(atPath: resolved) {
                iconPath = resolved
            } else {
                iconPath = nil
            }
        }

        return (path: fullPath, file: fileRef, iconPath: iconPath)
    }
}

// MARK: - Notification Dispatcher

class NotificationDispatcher {
    private let workDir: String

    init(workDir: String) {
        self.workDir = workDir
    }

    func send(message: String, title: String, color: String, iconPath: String?,
              bundleId: String, idePid: String) {
        let overlayPath = (workDir as NSString).appendingPathComponent("scripts/mac-overlay.js")
        guard FileManager.default.fileExists(atPath: overlayPath) else {
            sendFallback(message: message, title: title)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let slotDir = "/tmp/workwork-popups"
            try? FileManager.default.createDirectory(atPath: slotDir,
                                                      withIntermediateDirectories: true)
            var slot = 0
            while slot < 5 {
                let slotPath = "\(slotDir)/slot-\(slot)"
                do {
                    try FileManager.default.createDirectory(atPath: slotPath,
                                                             withIntermediateDirectories: false)
                    break
                } catch {
                    slot += 1
                }
            }
            if slot >= 5 {
                if let contents = try? FileManager.default.contentsOfDirectory(atPath: slotDir) {
                    for item in contents where item.hasPrefix("slot-") {
                        let path = "\(slotDir)/\(item)"
                        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                           let mod = attrs[.modificationDate] as? Date,
                           Date().timeIntervalSince(mod) > 60 {
                            try? FileManager.default.removeItem(atPath: path)
                        }
                    }
                }
                slot = 0
                try? FileManager.default.createDirectory(atPath: "\(slotDir)/slot-0",
                                                          withIntermediateDirectories: true)
            }

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-l", "JavaScript", overlayPath,
                              message, color, iconPath ?? "", "\(slot)", "4",
                              bundleId, idePid]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            try? proc.run()
            proc.waitUntilExit()

            try? FileManager.default.removeItem(atPath: "\(slotDir)/slot-\(slot)")
        }
    }

    private func sendFallback(message: String, title: String) {
        DispatchQueue.global(qos: .utility).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e",
                "display notification \"\(message.replacingOccurrences(of: "\"", with: "\\\""))\" with title \"\(title.replacingOccurrences(of: "\"", with: "\\\""))\""]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            try? proc.run()
            proc.waitUntilExit()
        }
    }
}

// MARK: - Focus Detection

func terminalIsFocused(bundleId: String) -> Bool {
    guard let frontmost = NSWorkspace.shared.frontmostApplication else { return false }
    if !bundleId.isEmpty, frontmost.bundleIdentifier == bundleId { return true }
    let name = frontmost.localizedName ?? ""
    let terminals = ["Terminal", "iTerm2", "Warp", "Alacritty", "kitty", "WezTerm",
                     "Ghostty", "Cursor", "Code", "Windsurf", "Zed"]
    return terminals.contains(where: { name.contains($0) })
}

// MARK: - Glob matching

func globMatch(pattern: String, path: String) -> Bool {
    var regex = "^"
    for ch in pattern {
        switch ch {
        case "*": regex += "[^/]*"
        case "?": regex += "[^/]"
        case ".": regex += "\\."
        default: regex += String(ch)
        }
    }
    regex = regex.replacingOccurrences(of: "[^/]*[^/]*", with: ".*")
    regex += "$"
    return path.range(of: regex, options: .regularExpression) != nil
}

// MARK: - Event Processor

class EventProcessor {
    let workDir: String
    let configPath: String
    var config: DaemonConfig
    let state: DaemonState
    let audio: AudioPlayer
    let packs: PackManager
    let notifier: NotificationDispatcher

    init(workDir: String, configPath: String, statePath: String) {
        self.workDir = workDir
        self.configPath = configPath
        self.config = DaemonConfig.load(from: configPath)
        self.state = DaemonState(filePath: statePath)
        self.audio = AudioPlayer()
        self.packs = PackManager(workDir: workDir)
        self.notifier = NotificationDispatcher(workDir: workDir)
        audio.configure(useSoundEffects: config.useSoundEffectsDevice, volume: config.volume)
    }

    func reloadConfig(path: String) {
        config = DaemonConfig.load(from: path)
        audio.configure(useSoundEffects: config.useSoundEffectsDevice, volume: config.volume)
        packs.clearCache()
        log("Config reloaded")
    }

    // MARK: Process hook event — returns JSON response
    func processEvent(_ input: [String: Any]) -> [String: Any] {
        if let cli = input["cli"] as? String {
            return handleCLI(cli, input: input)
        }

        let paused = FileManager.default.fileExists(atPath: (workDir as NSString).appendingPathComponent(".paused"))

        guard config.enabled else {
            return ["ok": true, "skipped": "disabled"]
        }

        let event = input["hook_event_name"] as? String ?? input["event"] as? String ?? ""
        let sessionId = input["session_id"] as? String ?? ""
        let cwd = input["cwd"] as? String ?? ""
        let permMode = input["permission_mode"] as? String ?? ""
        let sessionSource = input["source"] as? String ?? ""
        let ntype = input["notification_type"] as? String ?? ""
        let bundleId = input["bundle_id"] as? String ?? ""
        let idePid = input["ide_pid"] as? String ?? ""
        let now = Date().timeIntervalSince1970

        // Agent detection
        if permMode == "delegate" {
            state.agentSessions.insert(sessionId)
            state.dirty = true
            saveStateIfDirty()
            return ["ok": true, "skipped": "agent"]
        }
        if state.agentSessions.contains(sessionId) {
            return ["ok": true, "skipped": "agent"]
        }

        // Session cleanup
        let cutoff = now - Double(config.sessionTTLDays) * 86400
        var cleanPacks: [String: Any] = [:]
        for (sid, packData) in state.sessionPacks {
            if let dict = packData as? [String: Any] {
                if (dict["last_used"] as? Double ?? 0) > cutoff {
                    var d = dict
                    if sid == sessionId { d["last_used"] = now }
                    cleanPacks[sid] = d
                }
            } else if sid == sessionId {
                cleanPacks[sid] = ["pack": packData, "last_used": now] as [String: Any]
            }
        }
        if cleanPacks.count != state.sessionPacks.count {
            state.sessionPacks = cleanPacks
            state.dirty = true
        }

        // Resolve active pack
        let activePack = resolveActivePack(event: event, sessionId: sessionId,
                                            cwd: cwd, source: sessionSource)

        // Track last active
        state.lastActive = [
            "session_id": sessionId, "pack": activePack,
            "timestamp": now, "event": event, "cwd": cwd
        ]
        state.dirty = true

        // Project name
        var project = (cwd as NSString).lastPathComponent
        if project.isEmpty { project = "claude" }
        project = project.replacingOccurrences(of: "[^a-zA-Z0-9 ._-]", with: "",
                                                options: .regularExpression)
        if project.isEmpty { project = "claude" }

        // Event routing
        var category = ""
        var status = ""
        var marker = ""
        var notify = false
        var notifyColor = ""
        var msg = ""

        switch event {
        case "SessionStart":
            if sessionSource == "compact" {
                saveStateIfDirty()
                return ["ok": true, "skipped": "compact"]
            }
            category = "session.start"
            status = "ready"

        case "UserPromptSubmit":
            status = "working"
            if config.categories["user.spam"] == true {
                var ts = state.promptTimestamps[sessionId] ?? []
                ts = ts.filter { now - $0 < config.annoyedWindowSeconds }
                ts.append(now)
                state.promptTimestamps[sessionId] = ts
                state.dirty = true
                if ts.count >= config.annoyedThreshold {
                    category = "user.spam"
                }
            }
            if category.isEmpty, config.categories["task.acknowledge"] == true {
                category = "task.acknowledge"
                status = "working"
            }
            if config.silentWindowSeconds > 0 {
                state.promptStartTimes[sessionId] = now
                state.dirty = true
            }

        case "Stop":
            category = "task.complete"
            if config.suppressSubagentComplete,
               state.subagentSessions[sessionId] != nil {
                saveStateIfDirty()
                return ["ok": true, "skipped": "subagent"]
            }
            var silent = false
            if config.silentWindowSeconds > 0,
               let startTime = state.promptStartTimes.removeValue(forKey: sessionId) {
                if (now - startTime) < config.silentWindowSeconds { silent = true }
                state.dirty = true
            }
            status = "done"
            if !silent {
                marker = "\u{25cf} "
                notify = true
                notifyColor = "blue"
                msg = "\(project)  \u{2014}  Task complete"
            } else {
                category = ""
            }

        case "Notification":
            if ntype == "permission_prompt" {
                status = "needs approval"
                marker = "\u{25cf} "
            } else if ntype == "idle_prompt" {
                status = "done"
                marker = "\u{25cf} "
                notify = true
                notifyColor = "yellow"
                msg = "\(project)  \u{2014}  Waiting for input"
            } else {
                saveStateIfDirty()
                return ["ok": true, "skipped": "unknown_notification"]
            }

        case "PermissionRequest":
            category = "input.required"
            status = "needs approval"
            marker = "\u{25cf} "
            notify = true
            notifyColor = "red"
            msg = "\(project)  \u{2014}  Permission needed"

        case "PostToolUseFailure":
            let toolName = input["tool_name"] as? String ?? ""
            let errorMsg = input["error"] as? String ?? ""
            if toolName == "Bash", !errorMsg.isEmpty {
                category = "task.error"
                status = "error"
            } else {
                saveStateIfDirty()
                return ["ok": true, "skipped": "non_bash_failure"]
            }

        case "SubagentStart":
            state.pendingSubagentPack = ["ts": now, "pack": activePack]
            state.dirty = true
            saveStateIfDirty()
            return ["ok": true, "skipped": "subagent_start"]

        case "PreCompact":
            category = "resource.limit"
            status = "working"

        case "SessionEnd":
            for key in [sessionId] {
                state.promptTimestamps.removeValue(forKey: key)
                state.promptStartTimes.removeValue(forKey: key)
                state.sessionStartTimes.removeValue(forKey: key)
                state.subagentSessions.removeValue(forKey: key)
                state.sessionPacks.removeValue(forKey: key)
            }
            state.agentSessions.remove(sessionId)
            state.dirty = true
            saveStateIfDirty()
            return ["ok": true, "skipped": "session_end"]

        default:
            return ["ok": true, "skipped": "unknown_event"]
        }

        // Debounce rapid Stop events
        if event == "Stop" {
            if now - state.lastStopTime < 5 {
                category = ""
                notify = false
            }
            state.lastStopTime = now
            state.dirty = true
        }

        // Session replay suppression (claude -c)
        if event == "SessionStart" {
            state.sessionStartTimes[sessionId] = now
            state.dirty = true
        } else if !category.isEmpty {
            if let startTime = state.sessionStartTimes[sessionId],
               now - startTime < 3 {
                category = ""
                notify = false
            }
        }

        // Check category enabled
        if !category.isEmpty, config.categories[category] != true {
            category = ""
        }

        // Pick and play sound
        var soundFile = ""
        var iconPath: String? = nil
        if !category.isEmpty, !paused {
            if let result = packs.pickSound(pack: activePack, category: category,
                                            lastPlayed: state.lastPlayed[category]) {
                soundFile = result.path
                state.lastPlayed[category] = result.file
                state.dirty = true
                iconPath = result.iconPath
                audio.play(file: soundFile)
            }
        }

        // Build tab title
        let title = "\(marker)\(project): \(status)"

        // Tab color (iTerm2 OSC 6)
        var tabColorEscapes = ""
        if config.tabColorEnabled, !status.isEmpty {
            let statusKey = status.replacingOccurrences(of: " ", with: "_")
            var colors = config.tabColorColors
            if let profileColors = config.tabColorProfiles[project] {
                for (k, v) in profileColors { colors[k] = v }
            }
            if let rgb = colors[statusKey], rgb.count >= 3 {
                tabColorEscapes = "\u{1b}]6;1;bg;red;brightness;\(rgb[0])\u{07}"
                    + "\u{1b}]6;1;bg;green;brightness;\(rgb[1])\u{07}"
                    + "\u{1b}]6;1;bg;blue;brightness;\(rgb[2])\u{07}"
            }
        }

        // Desktop notification (only when terminal not focused)
        if notify, !paused, config.desktopNotifications, !msg.isEmpty,
           !terminalIsFocused(bundleId: bundleId) {
            notifier.send(message: msg, title: title, color: notifyColor,
                         iconPath: iconPath ?? (workDir as NSString).appendingPathComponent("docs/peon-icon.png"),
                         bundleId: bundleId, idePid: idePid)
        }

        saveStateIfDirty()

        var response: [String: Any] = [
            "ok": true,
            "tab_title": "\u{1b}]0;\(title)\u{07}"
        ]
        if !tabColorEscapes.isEmpty {
            response["tab_color"] = tabColorEscapes
        }
        if paused, event == "SessionStart" {
            response["stderr"] = "workwork: sounds paused \u{2014} run 'workwork resume' to unpause"
        }
        return response
    }

    // MARK: Pack resolution
    private func resolveActivePack(event: String, sessionId: String,
                                    cwd: String, source: String) -> String {
        let defaultPack = config.defaultPack

        var pathRulePack: String? = nil
        for rule in config.pathRules {
            guard let pattern = rule["pattern"], let candidate = rule["pack"],
                  !cwd.isEmpty, !pattern.isEmpty, !candidate.isEmpty,
                  globMatch(pattern: pattern, path: cwd),
                  packs.packExists(candidate) else { continue }
            pathRulePack = candidate
            break
        }

        let rotationMode = config.packRotationMode
        let packRotation = config.packRotation

        if rotationMode == "session_override" || rotationMode == "agentskill" {
            if let existing = state.getSessionPackName(sessionId),
               packs.packExists(existing) {
                state.setSessionPack(sessionId, pack: existing)
                return existing
            }
            if let defEntry = state.sessionPacks["default"],
               let defDict = defEntry as? [String: Any],
               let defPack = defDict["pack"] as? String,
               packs.packExists(defPack) {
                return defPack
            }
            return pathRulePack ?? defaultPack

        } else if !packRotation.isEmpty,
                  (rotationMode == "random" || rotationMode == "round-robin") {
            if let prp = pathRulePack { return prp }

            if let existing = state.getSessionPackName(sessionId),
               packRotation.contains(existing) {
                return existing
            }

            var inherited = false
            var result = defaultPack
            if event == "SessionStart" {
                let lastSid = state.lastActive["session_id"] as? String ?? ""
                let lastTs = state.lastActive["timestamp"] as? Double ?? 0
                let lastEvt = state.lastActive["event"] as? String ?? ""
                let lastPack = state.lastActive["pack"] as? String ?? ""
                let now = Date().timeIntervalSince1970

                if source == "resume", packRotation.contains(lastPack) {
                    result = lastPack; inherited = true
                } else if !state.pendingSubagentPack.isEmpty,
                          let ts = state.pendingSubagentPack["ts"] as? Double,
                          now - ts < 30,
                          let parentPack = state.pendingSubagentPack["pack"] as? String,
                          packRotation.contains(parentPack) {
                    result = parentPack; inherited = true
                    state.subagentSessions[sessionId] = now
                    state.subagentSessions = state.subagentSessions.filter { now - $0.value < 300 }
                    state.dirty = true
                } else if !lastSid.isEmpty, lastSid != sessionId,
                          packRotation.contains(lastPack),
                          lastEvt != "Stop", lastEvt != "SessionEnd",
                          now - lastTs < 15 {
                    result = lastPack; inherited = true
                }
            }
            if !inherited {
                if rotationMode == "round-robin" {
                    let idx = state.rotationIndex % packRotation.count
                    result = packRotation[idx]
                    state.rotationIndex = idx + 1
                } else {
                    result = packRotation.randomElement() ?? defaultPack
                }
            }
            state.setSessionPack(sessionId, pack: result)
            return result

        } else {
            return pathRulePack ?? defaultPack
        }
    }

    // MARK: CLI handler — ALL commands in daemon
    private func handleCLI(_ cmd: String, input: [String: Any]) -> [String: Any] {
        let value = input["value"] as? String ?? ""
        let action = input["action"] as? String ?? ""
        let arg = input["arg"] as? String ?? ""
        let arg2 = input["arg2"] as? String ?? ""

        switch cmd {
        case "status":
            let paused = FileManager.default.fileExists(
                atPath: (workDir as NSString).appendingPathComponent(".paused"))
            let packList = packs.listPacks()
            let installed = packList.map { $0.name }.joined(separator: ", ")
            return [
                "ok": true,
                "text": """
                    workwork daemon: running
                    enabled: \(config.enabled)
                    paused: \(paused)
                    volume: \(config.volume)
                    pack: \(config.defaultPack)
                    rotation: \(config.packRotationMode) [\(config.packRotation.joined(separator: ", "))]
                    notifications: \(config.notificationStyle)
                    installed: \(installed)
                    """
            ]

        case "pause":
            FileManager.default.createFile(
                atPath: (workDir as NSString).appendingPathComponent(".paused"),
                contents: nil)
            return ["ok": true, "text": "workwork: sounds paused"]

        case "resume":
            try? FileManager.default.removeItem(
                atPath: (workDir as NSString).appendingPathComponent(".paused"))
            return ["ok": true, "text": "workwork: sounds resumed"]

        case "toggle":
            let pausedPath = (workDir as NSString).appendingPathComponent(".paused")
            if FileManager.default.fileExists(atPath: pausedPath) {
                try? FileManager.default.removeItem(atPath: pausedPath)
                return ["ok": true, "text": "workwork: sounds resumed"]
            } else {
                FileManager.default.createFile(atPath: pausedPath, contents: nil)
                return ["ok": true, "text": "workwork: sounds paused"]
            }

        case "volume":
            if !value.isEmpty, let v = Float(value) {
                let clamped = max(0, min(1, v))
                config.volume = clamped
                audio.configure(useSoundEffects: config.useSoundEffectsDevice, volume: clamped)
                let rounded = (Double(clamped) * 100).rounded() / 100
                DaemonConfig.writeKey("volume", value: rounded, configPath: configPath)
                return ["ok": true, "text": "volume: \(String(format: "%.2f", clamped))"]
            }
            return ["ok": true, "text": "volume: \(String(format: "%.2f", config.volume))"]

        case "preview":
            if value == "--list" {
                let cats = packs.listCategories(pack: config.defaultPack)
                if cats.isEmpty {
                    return ["ok": false, "text": "No categories found for \(config.defaultPack)"]
                }
                return ["ok": true, "text": "Categories for \(config.defaultPack):\n" + cats.map { "  \($0)" }.joined(separator: "\n")]
            }
            let cat = value.isEmpty ? "task.complete" : value
            let pack = config.defaultPack
            if let result = packs.pickSound(pack: pack, category: cat, lastPlayed: nil) {
                audio.play(file: result.path)
                return ["ok": true, "text": "Playing \(cat) from \(pack)"]
            }
            return ["ok": false, "text": "No sounds found for \(cat) in \(pack)"]

        case "packs":
            return handlePacksCLI(action: action, arg: arg, arg2: arg2)

        case "notifications":
            if value.isEmpty {
                return ["ok": true, "text": "notifications: \(config.notificationStyle)"]
            }
            switch value {
            case "on":
                config.desktopNotifications = true
                DaemonConfig.writeKey("desktop_notifications", value: true, configPath: configPath)
                return ["ok": true, "text": "notifications: on"]
            case "off":
                config.desktopNotifications = false
                DaemonConfig.writeKey("desktop_notifications", value: false, configPath: configPath)
                return ["ok": true, "text": "notifications: off"]
            case "overlay", "standard":
                config.desktopNotifications = true
                config.notificationStyle = value
                DaemonConfig.writeKey("desktop_notifications", value: true, configPath: configPath)
                DaemonConfig.writeKey("notification_style", value: value, configPath: configPath)
                return ["ok": true, "text": "notifications: \(value)"]
            default:
                return ["ok": false, "text": "Usage: workwork notifications [on|off|overlay|standard]"]
            }

        case "rotation":
            if value.isEmpty {
                return ["ok": true, "text": "rotation: \(config.packRotationMode)"]
            }
            let valid = ["random", "round-robin", "session_override", "agentskill"]
            if valid.contains(value) {
                config.packRotationMode = value
                DaemonConfig.writeKey("pack_rotation_mode", value: value, configPath: configPath)
                return ["ok": true, "text": "rotation: \(value)"]
            }
            return ["ok": false, "text": "Valid modes: \(valid.joined(separator: ", "))"]

        case "ping":
            return ["ok": true, "text": "pong"]

        default:
            return ["ok": false, "text": "Unknown command: \(cmd). Run 'workwork help' for usage."]
        }
    }

    // MARK: Packs sub-commands
    private func handlePacksCLI(action: String, arg: String, arg2: String) -> [String: Any] {
        switch action {
        case "list", "":
            let packList = packs.listPacks()
            if packList.isEmpty {
                return ["ok": true, "text": "No packs installed"]
            }
            var lines: [String] = []
            for p in packList {
                let active = p.name == config.defaultPack ? " *" : ""
                let inRotation = config.packRotation.contains(p.name) ? " [rotation]" : ""
                lines.append("  \(p.name) (\(p.displayName), \(p.soundCount) sounds)\(active)\(inRotation)")
            }
            return ["ok": true, "text": "Installed packs:\n" + lines.joined(separator: "\n")]

        case "use":
            guard !arg.isEmpty else {
                return ["ok": false, "text": "Usage: workwork packs use <name>"]
            }
            guard packs.packExists(arg) else {
                return ["ok": false, "text": "Pack '\(arg)' not found"]
            }
            config.defaultPack = arg
            DaemonConfig.writeKey("default_pack", value: arg, configPath: configPath)
            return ["ok": true, "text": "Active pack: \(arg)"]

        case "next":
            let packList = packs.listPacks().map { $0.name }
            guard packList.count > 1 else {
                return ["ok": false, "text": "Only one pack installed"]
            }
            let currentIdx = packList.firstIndex(of: config.defaultPack) ?? 0
            let nextIdx = (currentIdx + 1) % packList.count
            let nextPack = packList[nextIdx]
            config.defaultPack = nextPack
            DaemonConfig.writeKey("default_pack", value: nextPack, configPath: configPath)
            return ["ok": true, "text": "Active pack: \(nextPack)"]

        case "rotation":
            // Sub-sub-commands: add, remove, list
            switch arg {
            case "list", "":
                if config.packRotation.isEmpty {
                    return ["ok": true, "text": "Rotation list: (empty)"]
                }
                return ["ok": true, "text": "Rotation list: \(config.packRotation.joined(separator: ", "))"]

            case "add":
                guard !arg2.isEmpty else {
                    return ["ok": false, "text": "Usage: workwork packs rotation add <name>"]
                }
                guard packs.packExists(arg2) else {
                    return ["ok": false, "text": "Pack '\(arg2)' not found"]
                }
                var rotation = config.packRotation
                if !rotation.contains(arg2) {
                    rotation.append(arg2)
                    config.packRotation = rotation
                    DaemonConfig.writeKey("pack_rotation", value: rotation, configPath: configPath)
                }
                return ["ok": true, "text": "Rotation: \(rotation.joined(separator: ", "))"]

            case "remove":
                guard !arg2.isEmpty else {
                    return ["ok": false, "text": "Usage: workwork packs rotation remove <name>"]
                }
                var rotation = config.packRotation
                rotation.removeAll { $0 == arg2 }
                config.packRotation = rotation
                DaemonConfig.writeKey("pack_rotation", value: rotation, configPath: configPath)
                return ["ok": true, "text": "Rotation: \(rotation.isEmpty ? "(empty)" : rotation.joined(separator: ", "))"]

            default:
                return ["ok": false, "text": "Usage: workwork packs rotation [list|add|remove] [name]"]
            }

        default:
            return ["ok": false, "text": "Usage: workwork packs [list|use|next|rotation] [args]"]
        }
    }

    func saveStateIfDirty() {
        if state.dirty { state.save() }
    }

    func log(_ msg: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        fputs("[\(ts)] \(msg)\n", stderr)
    }
}

// MARK: - Socket Server

class SocketServer {
    let socketPath: String
    let processor: EventProcessor
    private var serverSocket: Int32 = -1
    private var readSource: DispatchSourceRead?
    let queue = DispatchQueue(label: "com.workwork.daemon.socket")

    init(socketPath: String, processor: EventProcessor) {
        self.socketPath = socketPath
        self.processor = processor
    }

    func start() throws {
        unlink(socketPath)

        serverSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            throw NSError(domain: "WorkWorkDaemon", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create socket"])
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathSize = MemoryLayout.size(ofValue: addr.sun_path)
        socketPath.withCString { ptr in
            withUnsafeMutablePointer(to: &addr) { addrPtr in
                let base = UnsafeMutableRawPointer(addrPtr)
                    .advanced(by: MemoryLayout.offset(of: \sockaddr_un.sun_path)!)
                    .assumingMemoryBound(to: CChar.self)
                strncpy(base, ptr, pathSize - 1)
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(serverSocket, sockPtr, addrLen)
            }
        }
        guard bindResult == 0 else {
            close(serverSocket)
            throw NSError(domain: "WorkWorkDaemon", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to bind: \(String(cString: strerror(errno)))"])
        }

        chmod(socketPath, 0o700)

        guard listen(serverSocket, 5) == 0 else {
            close(serverSocket)
            throw NSError(domain: "WorkWorkDaemon", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to listen"])
        }

        readSource = DispatchSource.makeReadSource(fileDescriptor: serverSocket, queue: queue)
        readSource?.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        readSource?.setCancelHandler { [weak self] in
            if let fd = self?.serverSocket, fd >= 0 { close(fd) }
        }
        readSource?.resume()

        processor.log("Listening on \(socketPath)")
    }

    private func acceptConnection() {
        var clientAddr = sockaddr_un()
        var clientLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let clientFd = withUnsafeMutablePointer(to: &clientAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                accept(serverSocket, sockPtr, &clientLen)
            }
        }
        guard clientFd >= 0 else { return }

        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(clientFd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(clientFd, &buf, buf.count)
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
            if data.contains(0x0A) { break }
        }

        var response: [String: Any] = ["ok": false, "error": "invalid input"]
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            DispatchQueue.main.sync {
                response = self.processor.processEvent(json)
            }
        }

        if let respData = try? JSONSerialization.data(withJSONObject: response, options: []) {
            var toSend = respData
            toSend.append(0x0A)
            _ = toSend.withUnsafeBytes { ptr in
                write(clientFd, ptr.baseAddress!, toSend.count)
            }
        }

        close(clientFd)
    }

    func stop() {
        readSource?.cancel()
        readSource = nil
        if serverSocket >= 0 {
            close(serverSocket)
            serverSocket = -1
        }
        unlink(socketPath)
    }
}

// MARK: - Config File Watcher

class ConfigWatcher {
    private var source: DispatchSourceFileSystemObject?
    private let path: String
    private let handler: () -> Void
    private let queue: DispatchQueue

    init(path: String, queue: DispatchQueue, handler: @escaping () -> Void) {
        self.path = path
        self.queue = queue
        self.handler = handler
    }

    func start() {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename],
            queue: queue
        )
        source?.setEventHandler { [weak self] in
            self?.handler()
        }
        source?.setCancelHandler {
            close(fd)
        }
        source?.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
    }
}

// MARK: - Periodic State Saver

class PeriodicSaver {
    private var timer: DispatchSourceTimer?
    private let handler: () -> Void

    init(interval: TimeInterval = 30, handler: @escaping () -> Void) {
        self.handler = handler
        timer = DispatchSource.makeTimerSource(queue: .main)
        timer?.schedule(deadline: .now() + interval, repeating: interval)
        timer?.setEventHandler { handler() }
        timer?.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        handler()
    }
}

// MARK: - Main

func main() {
    var socketPath: String? = nil
    var configPath: String? = nil
    var workDir: String? = nil

    var args = Array(CommandLine.arguments.dropFirst())
    while !args.isEmpty {
        let arg = args.removeFirst()
        switch arg {
        case "--socket":
            guard !args.isEmpty else { fputs("--socket requires a path\n", stderr); exit(1) }
            socketPath = args.removeFirst()
        case "--config":
            guard !args.isEmpty else { fputs("--config requires a path\n", stderr); exit(1) }
            configPath = args.removeFirst()
        case "--work-dir":
            guard !args.isEmpty else { fputs("--work-dir requires a path\n", stderr); exit(1) }
            workDir = args.removeFirst()
        case "--help", "-h":
            print("""
                workworkd — WorkWork daemon
                Usage: workworkd [--socket <path>] [--config <path>] [--work-dir <path>]
                """)
            exit(0)
        default:
            fputs("Unknown argument: \(arg)\n", stderr)
            exit(1)
        }
    }

    let resolvedWorkDir = workDir ?? {
        let binPath = CommandLine.arguments[0]
        let binDir = (binPath as NSString).deletingLastPathComponent
        let parent = (binDir as NSString).deletingLastPathComponent
        if FileManager.default.fileExists(atPath: (parent as NSString).appendingPathComponent("config.json")) {
            return parent
        }
        return NSHomeDirectory() + "/.claude/hooks/workwork"
    }()

    let resolvedSocket = socketPath ?? (resolvedWorkDir as NSString).appendingPathComponent(".workworkd.sock")
    let resolvedConfig = configPath ?? (resolvedWorkDir as NSString).appendingPathComponent("config.json")
    let statePath = (resolvedWorkDir as NSString).appendingPathComponent(".state.json")

    let processor = EventProcessor(workDir: resolvedWorkDir,
                                    configPath: resolvedConfig,
                                    statePath: statePath)
    let server = SocketServer(socketPath: resolvedSocket, processor: processor)

    let configWatcher = ConfigWatcher(path: resolvedConfig, queue: .main) {
        processor.reloadConfig(path: resolvedConfig)
    }
    configWatcher.start()

    let saver = PeriodicSaver(interval: 30) {
        processor.saveStateIfDirty()
    }

    let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    sigterm.setEventHandler {
        processor.log("SIGTERM received, shutting down")
        processor.saveStateIfDirty()
        saver.stop()
        configWatcher.stop()
        server.stop()
        exit(0)
    }
    sigterm.resume()
    signal(SIGTERM, SIG_IGN)

    let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigint.setEventHandler {
        processor.log("SIGINT received, shutting down")
        processor.saveStateIfDirty()
        saver.stop()
        configWatcher.stop()
        server.stop()
        exit(0)
    }
    sigint.resume()
    signal(SIGINT, SIG_IGN)

    do {
        try server.start()
    } catch {
        fputs("Failed to start: \(error.localizedDescription)\n", stderr)
        exit(1)
    }

    processor.log("WorkWorkDaemon started (work_dir=\(resolvedWorkDir))")

    dispatchMain()
}

main()
