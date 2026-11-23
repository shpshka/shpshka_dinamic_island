import AppKit
@preconcurrency import ApplicationServices
import Combine

struct IslandNotice: Equatable {
    let title: String
    let detail: String
    let symbol: String
    let date: Date
}

@MainActor
final class IslandAlerts: ObservableObject {
    @Published private(set) var notices: [IslandNotice] = []
    @Published private(set) var mirrorsBanners = UserDefaults.standard.bool(forKey: "mirrorVisibleBanners")
    var onPost: ((IslandNotice) -> Void)?
    private var reader: BannerReader?
    private var workspaceObserver: NSObjectProtocol?
    var hasAccess: Bool { AXIsProcessTrusted() }

    func start() {
        guard mirrorsBanners else { return }
        if workspaceObserver == nil {
            workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.refreshPermission() } }
        }
        refreshPermission()
    }

    func setMirroring(_ enabled: Bool) {
        mirrorsBanners = enabled
        UserDefaults.standard.set(enabled, forKey: "mirrorVisibleBanners")
        if enabled {
            if !hasAccess { requestAccess() }
            start()
        } else { stop() }
    }

    func requestAccess() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func refreshPermission() {
        guard mirrorsBanners else { return }
        if !hasAccess {
            if reader != nil { reader?.stop(); reader = nil; objectWillChange.send() }
            return
        }
        if reader == nil {
            reader = BannerReader { [weak self] title, detail in
                self?.post(title, detail: detail, symbol: "bell.fill")
            }
            reader?.start()
            objectWillChange.send()
        }
    }

    func post(_ title: String, detail: String, symbol: String) {
        let notice = IslandNotice(title: String(title.prefix(160)), detail: String(detail.prefix(550)), symbol: symbol, date: Date())
        notices.insert(notice, at: 0)
        if notices.count > 25 { notices.removeLast(notices.count - 25) }
        onPost?(notice)
    }

    func clear() { notices.removeAll() }

    func stop() {
        reader?.stop()
        reader = nil
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
        workspaceObserver = nil
    }
}

/// Watches only the Notification Center process, after the user enables this integration.
/// Work runs off the UI thread, including when the system service is slow to reply.
private final class BannerReader: @unchecked Sendable {
    private static let bundleID = "com.apple.notificationcenterui"
    private let deliver: @MainActor (String, String) -> Void
    private var observer: AXObserver?
    private var pid: pid_t?
    private var watchers: [NSObjectProtocol] = []
    private let worker = DispatchQueue(label: "local.notchmusic.visible-banners", qos: .utility)
    // Coalesce bursts from the same AX subtree and bound outstanding work.
    private var roots: [AXUIElement] = []
    private var reading = false
    private var seen: [String: Date] = [:]
    private var generation = 0
    private static let bannerRoles: Set<String> = ["AXNotificationCenterBanner", "AXNotificationCenterAlert",
                                                    "AXNotificationCenterNotification",
                                                    "AXNotificationCenterAlertStack"]

    init(deliver: @escaping @MainActor (String, String) -> Void) { self.deliver = deliver }

    @MainActor func start() {
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            watchers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                if app?.bundleIdentifier == Self.bundleID { MainActor.assumeIsolated { self?.attach() } }
            })
        }
        attach()
    }

    @MainActor private func attach() {
        let target = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first?.processIdentifier
        guard pid != target || observer == nil else { return }
        detach()
        guard let target, AXIsProcessTrusted() else { return }
        var candidate: AXObserver?
        let callback: AXObserverCallback = { _, element, _, context in
            guard let context else { return }
            let reader = Unmanaged<BannerReader>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { reader.received(element) }
        }
        guard AXObserverCreate(target, callback, &candidate) == .success, let candidate else { return }
        let app = AXUIElementCreateApplication(target)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let notifications = [kAXWindowCreatedNotification, kAXCreatedNotification, kAXLayoutChangedNotification]
        let registered = notifications.map { AXObserverAddNotification(candidate, app, $0 as CFString, context) }
        guard registered.contains(.success) else { return }
        observer = candidate
        pid = target
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(candidate), .commonModes)
    }

    @MainActor private func detach() {
        generation += 1
        roots.removeAll()
        reading = false
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observer = nil
        pid = nil
        seen.removeAll()
    }

    @MainActor func stop() {
        detach()
        watchers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        watchers.removeAll()
    }

    @MainActor private func received(_ element: AXUIElement) {
        guard AXIsProcessTrusted(), pid != nil else { return }
        if !roots.contains(where: { CFEqual($0, element) }), roots.count < 8 { roots.append(element) }
        drain()
    }

    @MainActor private func drain() {
        guard !reading, !roots.isEmpty else { return }
        reading = true
        let batch = roots
        roots.removeAll(keepingCapacity: true)
        let version = generation
        worker.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            let hits = batch.flatMap(Self.visibleBanners)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == version else { return }
                self.reading = false
                let now = Date()
                self.seen = self.seen.filter { now.timeIntervalSince($0.value) < 45 }
                for hit in hits where self.seen[hit.key] == nil {
                    self.seen[hit.key] = now
                    self.deliver(hit.title, hit.detail)
                }
                self.drain()
            }
        }
    }

    private struct Hit { let key, title, detail: String }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func bannerText(_ item: AXUIElement) -> Hit? {
        let description = attribute(item, kAXDescriptionAttribute) as? String ?? ""
        var parts = description.components(separatedBy: ", ").filter { !$0.isEmpty }
        if parts.count <= 1 {
            var lines: [String] = []
            var stack = [(item, 0)]
            var visited = 0
            while let (child, depth) = stack.popLast(), visited < 28 {
                visited += 1
                if isHistory(child) || (attribute(child, kAXHiddenAttribute) as? Bool == true) { continue }
                if attribute(child, kAXRoleAttribute) as? String == kAXStaticTextRole,
                   let text = (attribute(child, kAXValueAttribute) as? String) ?? (attribute(child, kAXTitleAttribute) as? String),
                   !text.isEmpty, !lines.contains(text) {
                    lines.append(text)
                } else if depth < 4 {
                    stack += visibleChildren(child).prefix(12).reversed().map { ($0, depth + 1) }
                }
            }
            if !lines.isEmpty { parts = lines }
        }
        guard let heading = parts.first ?? attribute(item, kAXTitleAttribute) as? String, !heading.isEmpty else { return nil }
        let detail = parts.dropFirst().joined(separator: ", ")
        let id = attribute(item, kAXIdentifierAttribute) as? String
        return Hit(key: id.flatMap { $0.isEmpty ? nil : $0 } ?? (heading + detail), title: heading, detail: detail)
    }

    private static func isHistory(_ element: AXUIElement) -> Bool {
        (attribute(element, kAXIdentifierAttribute) as? String) == "AXNotificationListItems"
    }

    private static func visibleChildren(_ element: AXUIElement) -> [AXUIElement] {
        (attribute(element, kAXVisibleChildrenAttribute) as? [AXUIElement])
            ?? (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    private static func visibleBanners(in root: AXUIElement) -> [Hit] {
        AXUIElementSetMessagingTimeout(root, 0.25)
        // An app-wide layout event may represent opening Notification Center's history.
        // Scan the actual window/group delivered by AX, ignoring whole-application events.
        guard attribute(root, kAXRoleAttribute) as? String != kAXApplicationRole else { return [] }
        var ancestor = root
        for _ in 0..<10 {
            if isHistory(ancestor) { return [] }
            guard let parent = attribute(ancestor, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            ancestor = (parent as! AXUIElement)
        }
        var stack = [(root, 0)]
        var hits: [Hit] = []
        var legacyWindows: [AXUIElement] = []
        var visited = 0
        while let (item, depth) = stack.popLast(), visited < 96 {
            visited += 1
            if isHistory(item) || (attribute(item, kAXHiddenAttribute) as? Bool == true) { continue }
            let role = attribute(item, kAXSubroleAttribute) as? String ?? ""
            if role == "AXNotificationCenterBannerWindow" { legacyWindows.append(item) }
            if bannerRoles.contains(role) {
                if let result = bannerText(item) { hits.append(result); continue }
            }
            if depth < 7 {
                stack += visibleChildren(item).prefix(30).reversed().map { ($0, depth + 1) }
            }
        }
        return hits.isEmpty ? legacyWindows.compactMap(bannerText) : hits
    }
}
