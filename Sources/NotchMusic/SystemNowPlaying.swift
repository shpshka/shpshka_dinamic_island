import AppKit
import Carbon
import CoreAudio

enum BrowserConnection: Equatable {
    case unsupported, needsPermission, denied, requiresJavaScript, connected
}

struct SystemAudioSession: Equatable {
    let bundleID: String
    let appName: String
    var track: PlayerTrack?
    let isBrowser: Bool
    var isAudible: Bool
    var canPlayPause: Bool = false
    var connection: BrowserConnection = .unsupported
}

private struct AudioOwner: Equatable {
    let bundle: String
    let name: String
    let browser: BrowserTarget?
}

struct BrowserTarget: Equatable {
    let bundle: String
    let pid: pid_t
    var isSafari: Bool { bundle == "com.apple.Safari" }
}

@MainActor
final class SystemNowPlaying {
    private let onChange: (SystemAudioSession?) -> Void
    private let worker = DispatchQueue(label: "NotchMusic.browserMedia", qos: .utility)
    private let browser = BrowserMediaReader()
    private var active: AudioOwner?
    private var previous: Set<String> = []
    private var lastSession: SystemAudioSession?
    private var outputListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var listListener: AudioObjectPropertyListenerBlock?
    private var processIDs: [AudioObjectID] = []
    private var audibleIDs: [AudioObjectID]?
    private var needsProcessList = true
    private var updateScheduled = false
    private var lastListRead = -Double.infinity
    private var hardwareCheck: Timer?
    private var poll: DispatchWorkItem?
    private var generation = 0
    private var reading = false
    private var lastBrowser: AudioOwner?
    private var observing = false

    init(onChange: @escaping (SystemAudioSession?) -> Void) { self.onChange = onChange }

    func start() {
        guard !observing, #available(macOS 14.2, *) else { return }
        observing = true
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.scheduleUpdate(processListChanged: true) }
        }
        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener) == noErr {
            listListener = listener
        }
        // Some HAL clients omit running-output notifications when reusing an existing engine.
        // A coalescible check catches those changes without reading audio or starting helpers.
        let check = Timer(timeInterval: 4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateHardware() }
        }
        check.tolerance = 0.8
        RunLoop.main.add(check, forMode: .common)
        hardwareCheck = check
        updateHardware()
    }

    func stop() {
        observing = false
        hardwareCheck?.invalidate()
        hardwareCheck = nil
        generation += 1
        poll?.cancel()
        poll = nil
        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        if let listListener {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listListener)
        }
        listListener = nil
        address = Self.address(kAudioProcessPropertyIsRunningOutput)
        for (id, listener) in outputListeners {
            AudioObjectRemovePropertyListenerBlock(id, &address, .main, listener)
        }
        outputListeners.removeAll()
        processIDs.removeAll()
        audibleIDs = nil
        needsProcessList = true
        updateScheduled = false
        lastListRead = -.infinity
        active = nil
        lastBrowser = nil
        previous = []
        publish(nil)
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        .init(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    func applicationsDidChange() {
        // A browser or app owning an existing helper may have launched or quit.
        audibleIDs = nil
        scheduleUpdate(processListChanged: true)
    }

    private func scheduleUpdate(processListChanged: Bool) {
        guard observing else { return }
        if processListChanged { needsProcessList = true }
        guard !updateScheduled else { return }
        updateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.updateScheduled else { return }
            self.updateHardware()
        }
    }

    // Keep the HAL list and its subscriptions until the process topology changes.
    private func refreshProcessList() -> Bool {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        var bytes: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &bytes) == noErr else { return false }
        var ids = [AudioObjectID](repeating: 0, count: Int(bytes) / MemoryLayout<AudioObjectID>.size)
        if bytes > 0 {
            guard AudioObjectGetPropertyData(system, &address, 0, nil, &bytes, &ids) == noErr else { return false }
        }
        processIDs = ids.prefix(Int(bytes) / MemoryLayout<AudioObjectID>.size).sorted()
        let live = Set(processIDs)
        address = Self.address(kAudioProcessPropertyIsRunningOutput)
        for id in Set(outputListeners.keys).subtracting(live) {
            if let listener = outputListeners.removeValue(forKey: id) {
                AudioObjectRemovePropertyListenerBlock(id, &address, .main, listener)
            }
        }
        for id in live.subtracting(outputListeners.keys) {
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.scheduleUpdate(processListChanged: false) }
            }
            if AudioObjectAddPropertyListenerBlock(id, &address, .main, listener) == noErr { outputListeners[id] = listener }
        }
        return true
    }

    private func updateHardware() {
        guard observing else { return }
        updateScheduled = false
        let now = ProcessInfo.processInfo.systemUptime
        // Recover missed topology events and refresh owner mappings even for helpers
        // with a stable HAL ID. Unavailable list notifications retain the fast fallback.
        if needsProcessList || listListener == nil || now - lastListRead >= 30 {
            if refreshProcessList() {
                needsProcessList = false
                lastListRead = now
                audibleIDs = nil
            }
        }
        let playing = processIDs.filter { Self.integer($0, kAudioProcessPropertyIsRunningOutput) == 1 }
        guard playing != audibleIDs else { return }
        audibleIDs = playing
        let apps = playing.isEmpty ? [] : NSWorkspace.shared.runningApplications
        var owners: [AudioOwner] = []
        for id in playing {
            if let owner = Self.owner(id, apps: apps), !owners.contains(owner) { owners.append(owner) }
        }
        let newest = owners.filter { !previous.contains($0.bundle) }
        let front = newest.isEmpty ? nil : NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let chosen = newest.first { $0.bundle == front } ?? newest.last ?? owners.first { $0 == active } ?? owners.last
        previous = Set(owners.map(\.bundle))
        guard chosen != active else { return }
        generation += 1
        active = chosen
        poll?.cancel()
        if let chosen {
            lastBrowser = nil
            publish(SystemAudioSession(bundleID: chosen.bundle, appName: chosen.name,
                                       isBrowser: chosen.browser != nil, isAudible: true,
                                       connection: chosen.browser == nil ? .unsupported : .needsPermission))
            if chosen.browser != nil { readBrowser() }
        } else if lastBrowser != nil {
            readBrowser()
        } else {
            publish(nil)
        }
    }

    private static func integer(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var address = address(selector)
        var value: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : 0
    }

    private static func owner(_ id: AudioObjectID, apps: [NSRunningApplication]) -> AudioOwner? {
        var address = address(kAudioProcessPropertyBundleID)
        var raw: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout.size(ofValue: raw))
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &raw) == noErr else { return nil }
        let halBundle = raw?.takeRetainedValue() as String? ?? ""
        let pid = pid_t(bitPattern: integer(id, kAudioProcessPropertyPID))
        let process = NSRunningApplication(processIdentifier: pid)
        let bundle = halBundle.isEmpty ? process?.bundleIdentifier ?? "" : halBundle
        let browsertargets = ["com.apple.Safari", "com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac",
                              "com.vivaldi.Vivaldi", "org.chromium.Chromium"]
        // Chromium's render/audio helper bundle IDs start with their owning browser ID.
        // A shared WebKit process can serve multiple apps; identify Safari only after its tab confirms playback.
        if bundle == "com.apple.WebKit.GPU" {
            let safari = apps.first { $0.bundleIdentifier == "com.apple.Safari" }
            let target = safari.map { BrowserTarget(bundle: "com.apple.Safari", pid: $0.processIdentifier) }
            return AudioOwner(bundle: bundle, name: "WebKit", browser: target)
        }
        if let browserID = browsertargets.first(where: { bundle == $0 || bundle.hasPrefix($0 + ".helper") }),
           let app = apps.first(where: { $0.bundleIdentifier == browserID }) {
            return AudioOwner(bundle: browserID, name: app.localizedName ?? browserID,
                              browser: BrowserTarget(bundle: browserID, pid: app.processIdentifier))
        }
        // Other players may render audio in a helper embedded inside the real application.
        let path = process?.bundleURL?.standardizedFileURL.path
        let owner = apps.first { app in
            guard app.activationPolicy == .regular, let appURL = app.bundleURL else { return false }
            return app.bundleIdentifier == bundle || path?.hasPrefix(appURL.standardizedFileURL.path + "/") == true
        }
        guard let owner, let identifier = owner.bundleIdentifier else { return nil }
        return AudioOwner(bundle: identifier, name: owner.localizedName ?? identifier, browser: nil)
    }

    func connect() {
        guard let target = active?.browser ?? lastBrowser?.browser else { return }
        if lastSession?.connection == .denied {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                NSWorkspace.shared.open(url)
            }
        } else if lastSession?.connection == .requiresJavaScript {
            let alert = NSAlert()
            alert.messageText = "Доступ к музыке вкладки"
            alert.informativeText = target.isSafari
                ? "В Safari включите функции для веб-разработчиков в настройках «Дополнения». Затем в настройках разработчика включите «Разрешать JavaScript из событий Apple». После этого снова нажмите «Подключить»."
                : "В браузере откройте «Вид» → «Разработчикам» и включите «Разрешить JavaScript из событий Apple» (Allow JavaScript from Apple Events). После этого снова нажмите «Подключить»."
            alert.addButton(withTitle: "Понятно")
            alert.runModal()
        }
        readBrowser(authorize: true)
    }

    func playPause() {
        guard lastSession?.canPlayPause == true else { return }
        readBrowser(action: .toggle)
    }

    func pause() {
        guard lastSession?.canPlayPause == true, lastSession?.track?.isPlaying == true else { return }
        readBrowser(action: .pause)
    }

    private func readBrowser(authorize: Bool = false, action: BrowserMediaReader.Action = .read) {
        guard observing, let owner = active ?? lastBrowser, let target = owner.browser else { return }
        guard !reading || authorize || action != .read else { return }
        reading = true
        let revision = generation
        let audible = active != nil
        worker.async { [browser, weak self] in
            let result = browser.read(target, audible: audible, authorize: authorize, action: action)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.reading = false
                guard self.observing else { return }
                guard revision == self.generation else { self.readBrowser(); return }
                self.poll?.cancel()
                if !audible && result.track == nil {
                    self.lastBrowser = nil
                    self.publish(nil)
                    return
                }
                let verified = result.track != nil
                if verified { self.lastBrowser = owner }
                let name = verified && target.isSafari ? "Safari" : owner.name
                let item = SystemAudioSession(bundleID: verified ? target.bundle : owner.bundle, appName: name,
                                              track: result.track, isBrowser: true, isAudible: audible,
                                              canPlayPause: result.canToggle, connection: result.connection)
                self.publish(item)
                // Web pages update MediaSession in place. Read only the known tab on normal refreshes.
                if result.connection == .connected {
                    let work = DispatchWorkItem { [weak self] in self?.readBrowser() }
                    self.poll = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + (audible && verified ? 4 : 15), execute: work)
                }
            }
        }
    }

    private func publish(_ newValue: SystemAudioSession?) {
        guard newValue != lastSession else { return }
        lastSession = newValue
        onChange(newValue)
    }
}
