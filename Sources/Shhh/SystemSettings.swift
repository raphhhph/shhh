import AppKit

/// `Joe --system …`: a short, safe list of Mac settings by voice, so "study mode" or "turn the
/// volume down" works without opening System Settings. Each one is a plain AppleScript or
/// built-in command; nothing here needs admin rights, and none of it is open-ended.
///
///     Joe --system volume <0–100> | mute | unmute
///     Joe --system brightness up|down [steps]
///     Joe --system dark on|off
///     Joe --system wifi on|off
///     Joe --system focus on|off           runs the user's "Joe Focus On/Off" shortcut
///     Joe --system dnd on|off             same as focus
///     Joe --system study on|off           focus, mute, a little dimmer, dark mode
///     Joe --system downtime on|off        wind-down: "Joe Downtime On/Off" shortcut (or focus), quiet,
///                                         dim, dark, and quits distracting apps
///     Joe --system battery | storage      a one-line status
enum SystemSettings {
    static func run(_ args: [String]) -> String {
        let words = args.map { $0.lowercased() }
        let on = words.dropFirst().first.map { ["on", "true", "start", "yes"].contains($0) } ?? true
        switch words.first {
        case "volume":
            guard let level = words.dropFirst().first.flatMap(Int.init) else { return "Say it as: volume <0–100>." }
            let value = max(0, min(level, 100))
            return script("set volume output volume \(value) without output muted") ? "Volume \(value)%" : "Couldn't set the volume."
        case "mute": return script("set volume with output muted") ? "Muted" : "Couldn't mute."
        case "unmute": return script("set volume without output muted") ? "Sound on" : "Couldn't unmute."
        case "brightness":
            let up = words.dropFirst().first != "down"
            let steps = max(1, min(words.dropFirst(2).first.flatMap(Int.init) ?? 2, 16))
            return brightness(up: up, steps: steps) ? "Brightness \(up ? "up" : "down")" : "Couldn't change the brightness (Joe needs Accessibility)."
        case "dark", "darkmode":
            return script("tell application \"System Events\" to tell appearance preferences to set dark mode to \(on)")
                ? (on ? "Dark mode on" : "Light mode on") : "Couldn't change the appearance."
        case "wifi", "wi-fi":
            let device = wifiDevice() ?? "en0"
            return shell("/usr/sbin/networksetup", ["-setairportpower", device, on ? "on" : "off"]) != nil
                ? "Wi-Fi \(on ? "on" : "off")" : "Couldn't change Wi-Fi."
        case "focus", "dnd":
            return focus(on)
        case "study":
            var done = [focus(on)]
            done.append(run([on ? "mute" : "unmute"]))
            if on { done.append(run(["brightness", "down", "2"])) }
            done.append(run(["dark", on ? "on" : "off"]))
            return (on ? "Study mode on: " : "Study mode off: ") + done.joined(separator: " · ")
        case "downtime":
            var done = [shortcut(on ? "Joe Downtime On" : "Joe Downtime Off") ?? focus(on)]
            done.append(run([on ? "mute" : "unmute"]))
            done.append(run(["brightness", on ? "down" : "up", "4"]))
            done.append(run(["dark", on ? "on" : "off"]))
            if on {
                let quit = quitDistractions()
                if !quit.isEmpty { done.append("closed " + quit.joined(separator: ", ")) }
            }
            return (on ? "Downtime on: " : "Downtime off: ") + done.joined(separator: " · ")
        case "battery":
            let text = shell("/usr/bin/pmset", ["-g", "batt"]) ?? ""
            let line = text.components(separatedBy: "\n").first { $0.contains("%") } ?? ""
            let parts = line.components(separatedBy: "\t").last?.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
            return parts.isEmpty ? "No battery found." : "Battery " + parts.prefix(3).joined(separator: ", ")
        case "storage", "disk":
            let home = URL(fileURLWithPath: NSHomeDirectory())
            guard let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]),
                  let free = values.volumeAvailableCapacityForImportantUsage, let total = values.volumeTotalCapacity
            else { return "Couldn't read the disk." }
            let gb = { (bytes: Int64) in String(format: "%.0f GB", Double(bytes) / 1e9) }
            return "\(gb(free)) free of \(gb(Int64(total)))"
        default:
            return "Say it as: volume <0–100>, mute, unmute, brightness up|down, dark on|off, wifi on|off, focus on|off, study on|off, downtime on|off, battery, storage."
        }
    }

    /// Focus has no public switch, so it goes through a shortcut the user makes once in the
    /// Shortcuts app ("Joe Focus On": Set Focus → Do Not Disturb → On; "Joe Focus Off" likewise).
    private static func focus(_ on: Bool) -> String {
        let name = on ? "Joe Focus On" : "Joe Focus Off"
        let list = shell("/usr/bin/shortcuts", ["list"]) ?? ""
        guard list.components(separatedBy: "\n").contains(name) else {
            return "Focus: make a shortcut called “\(name)” in Shortcuts (Set Focus → Do Not Disturb → \(on ? "On" : "Off")) and I'll use it."
        }
        return shell("/usr/bin/shortcuts", ["run", name]) != nil ? "Focus \(on ? "on" : "off")" : "Couldn't run “\(name)”."
    }

    /// Runs a shortcut if the user has one by that name; nil when there's none.
    private static func shortcut(_ name: String) -> String? {
        let list = shell("/usr/bin/shortcuts", ["list"]) ?? ""
        guard list.components(separatedBy: "\n").contains(name) else { return nil }
        return shell("/usr/bin/shortcuts", ["run", name]) != nil ? name : "Couldn't run “\(name)”."
    }

    /// Games, video and social apps, asked politely to quit (they can save first). Browsers and
    /// anything for school stay open.
    private static let distractions = ["Steam", "Discord", "Minecraft", "Roblox", "TikTok", "Netflix", "YouTube",
                                       "Instagram", "Twitch", "Epic Games Launcher", "Battle.net", "League of Legends"]
    private static func quitDistractions() -> [String] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard let name = app.localizedName, distractions.contains(name), app.terminate() else { return nil }
            return name
        }
    }

    /// The brightness keys (144 up, 145 down), pressed through System Events.
    private static func brightness(up: Bool, steps: Int) -> Bool {
        script("tell application \"System Events\"\nrepeat \(steps) times\nkey code \(up ? 144 : 145)\nend repeat\nend tell")
    }

    private static func wifiDevice() -> String? {
        let text = shell("/usr/sbin/networksetup", ["-listallhardwareports"]) ?? ""
        let lines = text.components(separatedBy: "\n")
        guard let i = lines.firstIndex(where: { $0.contains("Wi-Fi") || $0.contains("AirPort") }), i + 1 < lines.count,
              lines[i + 1].hasPrefix("Device: ") else { return nil }
        return String(lines[i + 1].dropFirst("Device: ".count))
    }

    @discardableResult
    private static func script(_ source: String) -> Bool {
        var error: NSDictionary?
        _ = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil
    }

    private static func shell(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}
