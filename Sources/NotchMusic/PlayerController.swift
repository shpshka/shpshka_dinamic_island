import AppKit
import Carbon
import Combine

enum MusicSource: String, CaseIterable {
    case music, spotify

    var displayName: String { self == .music ? "Apple Music" : "Spotify" }
    var bundleID: String { self == .music ? "com.apple.Music" : "com.spotify.client" }

    fileprivate var runningPID: pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first { !$0.isTerminated }?.processIdentifier
    }
}

struct PlayerTrack: Equatable {
    var title: String
    var artist: String
    var lyrics: String?
    var isPlaying: Bool
    var album: String
    var duration: Double?
    var identifier: String? = nil
    var artwork: ArtworkSource? = nil
}

enum PlayerStatus: Equatable {
    case notRunning, needsPermission, denied, ready, unavailable
}

private struct Reading {
    let source: MusicSource
    let status: PlayerStatus
    var track: PlayerTrack? = nil
}

// The codes below come from Music.sdef and Spotify.sdef. Address events to a
// running PID so a player quitting between detection and delivery stays closed.
func fourChar(_ literal: StaticString) -> OSType {
    precondition(literal.utf8CodeUnitCount == 4)
    return literal.withUTF8Buffer { $0.reduce(0) { ($0 << 8) | OSType($1) } }
}

struct PlayerEvent {
    let target: NSAppleEventDescriptor

    func firstArtwork(of track: NSAppleEventDescriptor) throws -> ArtworkSource? {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(.init(typeCode: fourChar("cArt")), forKeyword: AEKeyword(keyAEDesiredClass))
        record.setDescriptor(.init(enumCode: OSType(formAbsolutePosition)), forKeyword: AEKeyword(keyAEKeyForm))
        record.setDescriptor(.init(int32: 1), forKeyword: AEKeyword(keyAEKeyData))
        record.setDescriptor(track, forKeyword: AEKeyword(keyAEContainer))
        guard let specifier = record.coerce(toDescriptorType: typeObjectSpecifier),
              let value = try property("pRaw", of: specifier) else { return nil }
        return ArtworkSource.embedded(value.data)
    }

    func property(_ code: StaticString, of container: NSAppleEventDescriptor = .null()) throws -> NSAppleEventDescriptor? {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(.init(typeCode: typeProperty), forKeyword: AEKeyword(keyAEDesiredClass))
        record.setDescriptor(.init(enumCode: OSType(formPropertyID)), forKeyword: AEKeyword(keyAEKeyForm))
        record.setDescriptor(.init(typeCode: fourChar(code)), forKeyword: AEKeyword(keyAEKeyData))
        record.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
        guard let specifier = record.coerce(toDescriptorType: typeObjectSpecifier) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(errAECoercionFail))
        }
        return try send(kAECoreSuite, kAEGetData, object: specifier)
    }

    @discardableResult
    func send(_ domain: OSType, _ action: OSType, object: NSAppleEventDescriptor? = nil,
              parameters: [AEKeyword: NSAppleEventDescriptor] = [:]) throws -> NSAppleEventDescriptor? {
        let event = NSAppleEventDescriptor(eventClass: domain, eventID: action, targetDescriptor: target,
                                           returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        if let object { event.setParam(object, forKeyword: AEKeyword(keyDirectObject)) }
        for (key, value) in parameters { event.setParam(value, forKeyword: key) }
        let noPrompt = NSAppleEventDescriptor.SendOptions(rawValue: UInt(kAEDoNotPromptForUserConsent))
        let reply = try event.sendEvent(options: [.waitForReply, .neverInteract, noPrompt], timeout: 2)
        if let error = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber)), error.int32Value != 0 {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(error.int32Value))
        }
        guard let value = reply.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)),
              value.descriptorType != typeNull,
              !(value.descriptorType == typeType && value.typeCodeValue == cMissingValue) else { return nil }
        return value
    }
}

private enum PlayerAction {
    case authorize, previous, playPause, pause, next

    var commandCode: OSType? {
        switch self {
        case .authorize: return nil
        case .previous: return fourChar("Prev")
        case .playPause: return fourChar("PlPs")
        case .pause: return fourChar("Paus")
        case .next: return fourChar("Next")
        }
    }
}

// All access to the bridge is serialized on PlayerController's background queue.
private final class PlayerBridge: @unchecked Sendable {
    private var permissions: [MusicSource: (pid: pid_t, status: PlayerStatus)] = [:]
    private var cachedTracks: [MusicSource: (pid: pid_t, id: String, track: PlayerTrack)] = [:]

    func resetPermissions() { permissions.removeAll() }

    func forget(_ source: MusicSource) {
        permissions.removeValue(forKey: source)
        cachedTracks.removeValue(forKey: source)
    }

    func read(_ source: MusicSource, pid: pid_t, action: PlayerAction? = nil) -> Reading {
        let event = PlayerEvent(target: .init(processIdentifier: pid))
        do {
            let cached = permissions[source]
            if cached?.pid != pid || action == .authorize {
                let result = AEDeterminePermissionToAutomateTarget(event.target.aeDesc, typeWildCard, typeWildCard,
                                                                   action == .authorize)
                guard result == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(result)) }
                permissions[source] = (pid, .ready)
            } else if let cached, cached.status != .ready {
                return Reading(source: source, status: cached.status)
            }
            if let code = action?.commandCode {
                try event.send(source == .music ? fourChar("hook") : fourChar("spfy"), code)
            }
            let playing = try event.property("pPlS")?.enumCodeValue == fourChar("kPSP")
            let current: NSAppleEventDescriptor?
            do { current = try event.property("pTrk") }
            catch let error as NSError where [Int(errAENoSuchObject), Int(errAEIllegalIndex)].contains(error.code) {
                current = nil
            }
            guard let current else {
                cachedTracks.removeValue(forKey: source)
                return Reading(source: source, status: .ready)
            }

            let idCode: StaticString = source == .music ? "pPIS" : "ID  "
            let id = try? event.property(idCode, of: current)?.stringValue
            if let id, !id.isEmpty, let cached = cachedTracks[source], cached.pid == pid, cached.id == id {
                var track = cached.track
                track.isPlaying = playing
                return Reading(source: source, status: .ready, track: track)
            }
            guard let title = try event.property("pnam", of: current)?.stringValue, !title.isEmpty else {
                return Reading(source: source, status: .ready)
            }
            let artist = (try? event.property("pArt", of: current)?.stringValue) ?? ""
            let album = (try? event.property("pAlb", of: current)?.stringValue) ?? ""
            let rawDuration = try? event.property("pDur", of: current)?.doubleValue
            // Spotify returns milliseconds in practice. Music returns seconds.
            let duration = rawDuration.map { $0 / (source == .spotify ? 1000 : 1) }.flatMap { $0 > 0 ? $0 : nil }
            let lyrics = source == .music ? try? event.property("pLyr", of: current)?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines) : nil
            let artwork: ArtworkSource?
            if source == .music {
                artwork = try? event.firstArtwork(of: current)
            } else if let address = try? event.property("aUrl", of: current)?.stringValue,
                      let url = URL(string: address) {
                artwork = .url(url)
            } else {
                artwork = nil
            }
            let track = PlayerTrack(title: title, artist: artist, lyrics: lyrics?.isEmpty == false ? lyrics : nil,
                                    isPlaying: playing, album: album, duration: duration, identifier: id,
                                    artwork: artwork)
            if let id { cachedTracks[source] = (pid, id, track) }
            return Reading(source: source, status: .ready, track: track)
        } catch {
            let status: PlayerStatus
            switch (error as NSError).code {
            case Int(errAEEventNotPermitted): status = .denied
            case Int(errAEEventWouldRequireUserConsent): status = .needsPermission
            case Int(procNotFound): status = .notRunning
            default: status = .unavailable
            }
            if status == .denied || status == .needsPermission { permissions[source] = (pid, status) }
            return Reading(source: source, status: status)
        }
    }
}

@MainActor
final class PlayerController: ObservableObject {
    @Published private(set) var source: MusicSource
    @Published private(set) var track: PlayerTrack?
    @Published private(set) var status: PlayerStatus = .notRunning
    @Published private var audioSession: SystemAudioSession?

    private var external: SystemAudioSession? {
        guard let audioSession, nativeSource(of: audioSession) == nil else { return nil }
        return audioSession
    }

    var sourceName: String { external?.appName ?? source.displayName }
    var canPlayPause: Bool { external?.canPlayPause ?? (status == .ready && track != nil) }
    var canSkipPrevious: Bool { external == nil && status == .ready && track != nil }
    var canSkipNext: Bool { canSkipPrevious }
    var canOpenPlayer: Bool { external != nil || source.runningPID != nil }

    var connectTitle: String? {
        if let external {
            switch external.connection {
            case .needsPermission: return "Подключить браузер"
            case .denied: return "Настройки доступа"
            case .requiresJavaScript: return "Настроить браузер"
            default: return nil
            }
        }
        switch status {
        case .needsPermission: return "Подключить"
        case .denied: return "Настройки доступа"
        case .unavailable: return "Повторить"
        default: return nil
        }
    }

    var statusDetail: String {
        if let external {
            switch external.connection {
            case .needsPermission: return "Подключите браузер, чтобы видеть трек."
            case .denied: return "Разрешите управление браузером в разделе «Автоматизация»."
            case .requiresJavaScript: return "Для чтения трека нужен доступ к медиаплееру вкладки."
            case .connected, .unsupported:
                return external.isAudible ? "Приложение воспроизводит звук" : "Пауза"
            }
        }
        switch status {
        case .notRunning: return "Здесь появится текущий трек"
        case .needsPermission: return "Разрешите острову управлять " + source.displayName + "."
        case .denied: return "Разрешите управление в разделе «Автоматизация»."
        case .ready: return track == nil ? "Выберите трек в плеере" : source.displayName
        case .unavailable: return source.displayName + " не отвечает."
        }
    }

    private let queue = DispatchQueue(label: "NotchMusic.playerAutomation", qos: .utility)
    private let bridge = PlayerBridge()
    private lazy var system = SystemNowPlaying { [weak self] session in self?.audioChanged(session) }
    private var timer: Timer?
    private var subscriptions: Set<AnyCancellable> = []
    private var revision = 0
    private var refreshing = false
    private var stopped = false
    private var pendingActions = 0
    private var lastPlaying: MusicSource?
    private var announcements: [MusicSource: PlayerTrack] = [:]
    private var readings: [MusicSource: Reading] = [:]

    init() {
        source = MusicSource.allCases.first { $0.runningPID != nil } ?? .music
        let center = DistributedNotificationCenter.default()
        for (name, player) in [("com.apple.Music.playerInfo", MusicSource.music),
                               ("com.spotify.client.PlaybackStateChanged", MusicSource.spotify)] {
            center.publisher(for: .init(name)).receive(on: DispatchQueue.main).sink { [weak self] note in
                self?.playbackNotice(note, from: player)
            }.store(in: &subscriptions)
        }
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.publisher(for: NSWorkspace.didLaunchApplicationNotification)
            .merge(with: workspace.publisher(for: NSWorkspace.didTerminateApplicationNotification))
            .receive(on: DispatchQueue.main).sink { [weak self] note in
                guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                self.system.applicationsDidChange()
                guard let native = MusicSource.allCases.first(where: { $0.bundleID == app.bundleIdentifier }) else { return }
                self.queue.async { [bridge = self.bridge] in bridge.forget(native) }
                self.announcements[native] = nil
                self.readings[native] = nil
                self.revision += 1
                self.refresh()
            }.store(in: &subscriptions)
        workspace.publisher(for: NSWorkspace.didDeactivateApplicationNotification)
            .receive(on: DispatchQueue.main).sink { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == "com.apple.systempreferences", let self else { return }
                self.queue.async { [bridge = self.bridge] in bridge.resetPermissions() }
                self.refresh()
            }.store(in: &subscriptions)

        workspace.publisher(for: NSWorkspace.didWakeNotification).receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.system.applicationsDidChange()
            self?.refresh()
        }.store(in: &subscriptions)
        system.start()
        refresh()
    }

    // A native player can change state without broadcasting. Keep its watchdog only
    // while a native player is a candidate; workspace events handle the first launch.
    private func setNativeWatchdog(_ needed: Bool) {
        guard needed != (timer != nil) else { return }
        if needed {
            let timer = Timer(timeInterval: 12, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            timer.tolerance = 2
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    deinit { timer?.invalidate() }

    func stop() {
        stopped = true
        subscriptions.removeAll()
        system.stop()
        setNativeWatchdog(false)
    }

    private func nativeSource(of session: SystemAudioSession?) -> MusicSource? {
        MusicSource.allCases.first { $0.bundleID == session?.bundleID }
    }

    private func audioChanged(_ session: SystemAudioSession?) {
        guard audioSession != session else { return }
        let switched = audioSession?.bundleID != session?.bundleID
        audioSession = session
        if switched { revision += 1 }
        if let external {
            setNativeWatchdog(false)
            if track != external.track { track = external.track }
            if status != .ready { status = .ready }
        } else if switched {
            if let native = nativeSource(of: session) {
                apply(readings[native] ?? Reading(source: native, status: .unavailable))
            } else {
                selectReading()
            }
            refresh()
        }
    }

    private func playbackNotice(_ note: Notification, from native: MusicSource) {
        guard let info = note.userInfo, native.runningPID != nil else { return }
        let state = (info["Player State"] as? String)?.lowercased()
        if state == "stopped" {
            announcements[native] = nil
        } else if let title = info["Name"] as? String, !title.isEmpty {
            let id = info["Track ID"] as? String ?? info["PersistentID"] as? String
            let artist = info["Artist"] as? String ?? ""
            let album = info["Album"] as? String ?? ""
            let same = announcements[native].flatMap { old in
                old.title == title && old.artist == artist && old.album == album ? old : nil
            }
            // Both desktop apps announce total track time in milliseconds.
            let ms = (info["Duration"] ?? info["Total Time"]) as? NSNumber
            var announced = PlayerTrack(title: title, artist: artist, lyrics: nil, isPlaying: state == "playing",
                                        album: album, duration: ms.map { $0.doubleValue / 1000 } ?? same?.duration)
            announced.identifier = id ?? same?.identifier
            if let urlText = info["Cover Art URL"] as? String, let url = URL(string: urlText) {
                announced.artwork = .url(url)
            } else { announced.artwork = same?.artwork }
            announcements[native] = announced
        } else if state == "paused" || state == "playing" {
            announcements[native]?.isPlaying = state == "playing"
        }
        if state == "playing" { lastPlaying = native }
        refresh()
    }

    func refresh() {
        guard !stopped, external == nil, !refreshing, pendingActions == 0 else { return }
        let preferred = nativeSource(of: audioSession)
        let candidates = preferred.map { [$0] } ?? MusicSource.allCases
        let running = candidates.compactMap { player in player.runningPID.map { (player, $0) } }
        setNativeWatchdog(!running.isEmpty)
        guard !running.isEmpty else {
            apply(Reading(source: source, status: .notRunning))
            return
        }
        let startRevision = revision
        refreshing = true
        queue.async { [bridge, weak self] in
            let snapshot = running.map { bridge.read($0.0, pid: $0.1) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.refreshing = false
                guard self.revision == startRevision else { self.refresh(); return }
                for reading in snapshot { self.readings[reading.source] = reading }
                self.selectReading()
            }
        }
    }

    private func selectReading() {
        guard external == nil else { return }
        if let native = nativeSource(of: audioSession) {
            apply(readings[native] ?? Reading(source: native, status: .unavailable))
            return
        }
        let recent = lastPlaying ?? source
        func rank(_ reading: Reading) -> Int {
            let track = resolvedTrack(reading)
            let activity = track?.isPlaying == true ? 3 : (track != nil ? 2 : (reading.status == .ready ? 1 : 0))
            return activity * 2 + (reading.source == recent ? 1 : 0)
        }
        let running = readings.values.filter { $0.source.runningPID != nil }
        apply(running.max { rank($0) < rank($1) } ?? Reading(source: source, status: .notRunning))
    }

    private func resolvedTrack(_ reading: Reading) -> PlayerTrack? {
        guard reading.status != .notRunning else { return nil }
        let announced = announcements[reading.source]
        guard var native = reading.track else {
            return reading.status == .ready ? nil : announced
        }
        if native.artwork == nil, native.title == announced?.title, native.artist == announced?.artist {
            native.artwork = announced?.artwork
        }
        return native
    }

    func connect() {
        if external != nil { system.connect(); return }
        guard pendingActions == 0, let pid = source.runningPID else { return }
        perform(.authorize, pid: pid, showSettingsIfDenied: status == .denied)
    }

    func openPlayer() {
        let id = external?.bundleID ?? source.bundleID
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    func previous() { if canSkipPrevious { control(.previous) } }
    func playPause() {
        guard canPlayPause else { return }
        if external != nil { system.playPause() } else { control(.playPause) }
    }
    func next() { if canSkipNext { control(.next) } }

    func pauseIfPlaying() {
        guard canPlayPause, track?.isPlaying == true else { return }
        if external != nil { system.pause() } else { control(.pause) }
    }

    private func control(_ action: PlayerAction) {
        guard external == nil, status == .ready, let pid = source.runningPID else { refresh(); return }
        perform(action, pid: pid)
    }

    private func perform(_ action: PlayerAction, pid: pid_t, showSettingsIfDenied: Bool = false) {
        let selected = source
        revision += 1
        let actionRevision = revision
        pendingActions += 1
        queue.async { [bridge, weak self] in
            let reading = bridge.read(selected, pid: pid, action: action)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pendingActions -= 1
                guard self.revision == actionRevision, self.external == nil else { self.refresh(); return }
                self.readings[selected] = reading
                self.apply(reading)
                if showSettingsIfDenied && reading.status == .denied,
                   let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    private func apply(_ reading: Reading) {
        let newTrack = resolvedTrack(reading)
        if source != reading.source { source = reading.source }
        if status != reading.status { status = reading.status }
        if track != newTrack { track = newTrack }
    }
}
