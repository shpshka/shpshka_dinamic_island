import AppKit
import Carbon

struct BrowserReading {
    var connection: BrowserConnection
    var track: PlayerTrack?
    var canToggle = false
}

// Accessed only on the bridge's serial worker. Keep one tab reference, never tab history.
final class BrowserMediaReader: @unchecked Sendable {
    enum Action: String { case read, toggle, pause }
    private var connectedTo: pid_t?
    private var cachedAccess: BrowserConnection?
    private var tab: NSAppleEventDescriptor?
    private var token: String?

    private struct Page: Decodable {
        let key: String
        let title: String
        let artist: String
        let album: String
        let duration: Double?
        let artwork: String?
        let playing: Bool
        let canToggle: Bool

        var track: PlayerTrack {
            let url = artwork.flatMap(URL.init(string:))
            return PlayerTrack(title: title, artist: artist, lyrics: nil, isPlaying: playing, album: album,
                               duration: duration, identifier: key, artwork: url?.scheme == "https" ? url.map(ArtworkSource.url) : nil)
        }
    }

    func read(_ target: BrowserTarget, audible: Bool, authorize: Bool, action: Action) -> BrowserReading {
        if connectedTo != target.pid {
            connectedTo = target.pid
            cachedAccess = nil
            tab = nil
            token = nil
        }
        guard NSRunningApplication(processIdentifier: target.pid)?.bundleIdentifier == target.bundle else {
            tab = nil
            token = nil
            return .init(connection: .connected)
        }
        let event = PlayerEvent(target: .init(processIdentifier: target.pid))
        if cachedAccess == nil || authorize {
            let status = AEDeterminePermissionToAutomateTarget(event.target.aeDesc, typeWildCard, typeWildCard, authorize)
            switch status {
            case noErr: cachedAccess = .connected
            case OSStatus(errAEEventNotPermitted): cachedAccess = .denied
            default: cachedAccess = .needsPermission
            }
        }
        guard cachedAccess == .connected else { return .init(connection: cachedAccess ?? .needsPermission) }
        var paused: (tab: NSAppleEventDescriptor, page: Page)?
        if let tab, let token {
            // A saved descriptor can point at a different Safari tab after a reorder. The page token
            // is checked inside JavaScript before performing a transport command.
            if let page = try? inspect(tab, target, event, known: token, action: action) {
                if action != .read || page.playing || !audible {
                    self.token = page.key
                    return .init(connection: .connected, track: page.track, canToggle: page.canToggle)
                }
                paused = (tab, page)
            }
        }
        if action != .read {
            // Recover the display after a tab was replaced, without sending the action to a new one.
            return read(target, audible: audible, authorize: false, action: .read)
        }
        tab = nil
        token = nil
        guard audible else { return .init(connection: .connected) }

        do {
            var executed = false
            var restricted = false
            for window in try objects("cwin", within: .null(), using: event) {
                for candidate in try objects(target.isSafari ? "bTab" : "CrTb", within: window, using: event) {
                    do {
                        let page = try inspect(candidate, target, event, known: nil, action: .read)
                        executed = true
                        if let page, page.playing {
                            tab = candidate
                            token = page.key
                            return .init(connection: .connected, track: page.track, canToggle: page.canToggle)
                        }
                    } catch {
                        // Browsers also reject JavaScript in internal pages. Only offer the browser
                        // setting when no tab could execute the script.
                        restricted = true
                    }
                }
            }
            if let paused {
                tab = paused.tab
                token = paused.page.key
                return .init(connection: .connected, track: paused.page.track, canToggle: paused.page.canToggle)
            }
            if !executed && restricted { cachedAccess = .requiresJavaScript }
        } catch {
            if (error as NSError).code == Int(errAEEventNotPermitted) { cachedAccess = .denied }
        }
        return .init(connection: cachedAccess ?? .connected)
    }

    private func objects(_ kind: StaticString, within parent: NSAppleEventDescriptor,
                         using event: PlayerEvent) throws -> [NSAppleEventDescriptor] {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(.init(typeCode: fourChar(kind)), forKeyword: AEKeyword(keyAEDesiredClass))
        record.setDescriptor(.init(enumCode: OSType(formAbsolutePosition)), forKeyword: AEKeyword(keyAEKeyForm))
        var all = OSType(kAEAll)
        guard let ordinal = NSAppleEventDescriptor(descriptorType: typeAbsoluteOrdinal, bytes: &all, length: MemoryLayout<OSType>.size) else { return [] }
        record.setDescriptor(ordinal, forKeyword: AEKeyword(keyAEKeyData))
        record.setDescriptor(parent, forKeyword: AEKeyword(keyAEContainer))
        guard let specifier = record.coerce(toDescriptorType: typeObjectSpecifier),
              let items = try event.send(kAECoreSuite, kAEGetData, object: specifier) else { return [] }
        if items.descriptorType == typeObjectSpecifier { return [items] }
        guard items.numberOfItems > 0 else { return [] }
        return (1...items.numberOfItems).compactMap { items.atIndex($0) }
    }

    private func inspect(_ tab: NSAppleEventDescriptor, _ target: BrowserTarget, _ event: PlayerEvent,
                         known: String?, action: Action) throws -> Page? {
        let key = String(decoding: try JSONEncoder().encode(known), as: UTF8.self)
        let code = NSAppleEventDescriptor(string: "((known, action) => {" + Self.script + "})(" + key + ", '" + action.rawValue + "')")
        let reply: NSAppleEventDescriptor?
        if target.isSafari {
            reply = try event.send(fourChar("sfri"), fourChar("dojs"), object: code,
                                   parameters: [fourChar("dcnm"): tab])
        } else {
            reply = try event.send(fourChar("CrSu"), fourChar("ExJa"), object: tab,
                                   parameters: [fourChar("JvSc"): code])
        }
        guard let json = reply?.stringValue, !json.isEmpty else { return nil }
        return try JSONDecoder().decode(Page.self, from: Data(json.utf8))
    }

    // Return media-session fields only after verifying playback. Unknown or paused tabs return
    // an empty string, and the app never receives their titles, URLs, or page contents.
    static let script = #"""
        const items = Array.from(document.querySelectorAll('video, audio'));
        const playing = items.find(e => !e.paused && !e.ended && !e.muted && e.volume > 0);
        const element = playing || (known && items.find(e => !e.ended && e.readyState >= 1));
        const session = navigator.mediaSession;
        const active = Boolean(playing || (!items.length && session?.playbackState === 'playing'));
        if (!active && !known) return '';
        const metadata = session?.metadata;
        const title = (metadata?.title || document.title || '').trim().slice(0, 1024);
        if (!title) return '';
        const artist = (metadata?.artist || '').trim().slice(0, 1024);
        const key = JSON.stringify([performance.timeOrigin, title, artist]);
        if (known && key !== known) return '';
        if (!active && !element && session?.playbackState !== 'paused') return '';
        if (element && action === 'pause' && playing) element.pause();
        if (element && action === 'toggle') {
            if (element.paused) { const pending = element.play(); pending?.catch(() => {}); }
            else element.pause();
        }
        const cover = Array.from(metadata?.artwork || [])
            .filter(a => typeof a.src === 'string' && a.src.startsWith('https://') && a.src.length <= 8192)
            .sort((a, b) => Math.abs((parseInt(a.sizes) || 200) - 180) - Math.abs((parseInt(b.sizes) || 200) - 180))[0];
        const duration = element?.duration;
        return JSON.stringify({ key, title, artist, album: (metadata?.album || '').slice(0, 1024),
            duration: Number.isFinite(duration) && duration > 0 ? duration : null, artwork: cover?.src || null,
            playing: element ? !element.paused && !element.ended : active, canToggle: Boolean(element) });
        """#
}
