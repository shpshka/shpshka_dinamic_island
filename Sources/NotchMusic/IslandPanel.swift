import AppKit
import Combine
import QuartzCore

@MainActor
final class IslandPresentation {
    fileprivate(set) var isExpanded = false
    var isPinned = false {
        didSet { if isPinned != oldValue { pinDidChange?() } }
    }
    var section: IslandSection = .music {
        didSet { if section != oldValue { layoutDidChange?() } }
    }
    var showsLyrics = false {
        didSet {
            if showsLyrics != oldValue { layoutDidChange?() }
        }
    }
    fileprivate(set) var notchSize = CGSize(width: 88, height: 24)
    fileprivate var layoutDidChange: (() -> Void)?
    fileprivate var pinDidChange: (() -> Void)?

    var collapsedSize: CGSize { CGSize(width: notchSize.width + 60, height: notchSize.height) }
    var expandedSize: CGSize {
        let bodyHeight: CGFloat = section == .music ? (showsLyrics ? 305 : 145) : 245
        return CGSize(width: max(360, collapsedSize.width), height: notchSize.height + bodyHeight + IslandDashboard.navigationHeight)
    }
}

private final class NotchWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect  // This window intentionally occupies the menu bar.
    }
}

@MainActor
final class IslandPanelController: NSObject {
    let island = IslandPresentation()
    private let player: PlayerController
    private var panel: NotchWindow?
    private var backdrop: CompactIslandView?
    private var controls: IslandDashboard?
    let features = IslandFeatures()
    private var noticeRow: NoticeRow?
    private var noticeTimeout: DispatchWorkItem?
    private var idleSize: CGSize {
        noticeRow == nil ? island.collapsedSize : CGSize(width: max(340, island.collapsedSize.width), height: island.notchSize.height + 50)
    }
    private let artwork = TrackArtwork()
    private lazy var lyrics = LyricsLookup()
    private var artworkChanges: AnyCancellable?
    private var artworkTask: Task<Void, Never>?
    private var anchor = CGPoint.zero
    private var hoverWork: DispatchWorkItem?
    private var resizeWork: DispatchWorkItem?
    private var menuDepth = 0
    private var openedFromMenuUntil = Date.distantPast

    init(player: PlayerController) {
        self.player = player
        super.init()
    }

    func start() {
        guard panel == nil else { return }
        let window = NotchWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = true
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        let backdrop = CompactIslandView(player: player, artwork: artwork)
        backdrop.pointerChanged = { [weak self] in self?.updateHover() }
        window.contentView = backdrop
        self.backdrop = backdrop
        panel = window
        // One thumbnail serves both window sizes. Changes to playback alone do not reload it.
        artworkChanges = player.$track.map { $0?.artwork }.removeDuplicates().sink { [weak self] source in
            guard let self else { return }
            self.artworkTask?.cancel()
            if let source {
                self.artworkTask = Task { [artwork = self.artwork] in await artwork.load(source) }
            } else {
                self.artworkTask = nil
                self.artwork.clear()
            }
        }
        island.layoutDidChange = { [weak self] in self?.resizeForContent() }
        island.pinDidChange = { [weak self] in
            guard let self else { return }
            if self.island.isPinned { self.setExpanded(true) }
            self.controls?.update()
            self.updateHover()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(positionOnDisplay),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.screensDidWakeNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(positionOnDisplay),
                                                              name: name, object: nil)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(menuBegan),
                                               name: NSMenu.didBeginTrackingNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(menuEnded),
                                               name: NSMenu.didEndTrackingNotification, object: nil)
        features.alerts.onPost = { [weak self] notice in self?.preview(notice) }
        positionOnDisplay()
        features.start()
    }

    func stop() {
        hoverWork?.cancel()
        resizeWork?.cancel()
        features.alerts.onPost = nil
        features.stop()
        removePreview()
        island.layoutDidChange = nil
        island.pinDidChange = nil
        island.isPinned = false
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        artworkChanges?.cancel()
        artworkChanges = nil
        artworkTask?.cancel()
        artworkTask = nil
        discardControls()
        panel?.orderOut(nil)
        panel = nil
        backdrop = nil
        island.isExpanded = false
        island.showsLyrics = false
        menuDepth = 0
        openedFromMenuUntil = .distantPast
    }

    func showExpanded(section: IslandSection? = nil) {
        if panel == nil { start() }
        if let section { island.section = section }
        openedFromMenuUntil = Date().addingTimeInterval(3)
        setExpanded(true)
        updateHover()
    }

    private func preview(_ notice: IslandNotice) {
        // Keep the user's current page, menus and playback controls undisturbed.
        guard !island.isExpanded, menuDepth == 0, panel?.isVisible == true else { return }
        removePreview()
        let row = NoticeRow(notice)
        row.appearance = NSAppearance(named: .darkAqua)
        row.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(openAlerts)))
        noticeRow = row
        fitPanel(idleSize, fromExpanded: false, revealing: row)
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.island.isExpanded else { return }
            self.removePreview()
            self.fitPanel(self.island.collapsedSize, fromExpanded: false)
        }
        noticeTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    @objc private func openAlerts() { showExpanded(section: .alerts) }

    private func removePreview() {
        noticeTimeout?.cancel()
        noticeTimeout = nil
        noticeRow?.removeFromSuperview()
        noticeRow = nil
    }

    @objc private func positionOnDisplay() {
        guard let panel else { return }
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else {
            panel.orderOut(nil)
            return
        }
        let display = screen.frame
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
           screen.safeAreaInsets.top > 0, display.width > left.width + right.width {
            let width = display.width - left.width - right.width
            anchor = CGPoint(x: display.minX + left.width + width / 2, y: display.maxY)
            island.notchSize = CGSize(width: width, height: screen.safeAreaInsets.top)
        } else {
            anchor = CGPoint(x: display.midX, y: display.maxY)
            island.notchSize = CGSize(width: 88, height: 24)
        }
        backdrop?.update(notchSize: island.notchSize, expanded: island.isExpanded)
        fitPanel(island.isExpanded ? island.expandedSize : idleSize)
        controls?.needsLayout = true
        panel.ignoresMouseEvents = false
        panel.orderFrontRegardless()
        updateHover()
    }

    @objc private func menuBegan() {
        menuDepth += 1
        hoverWork?.cancel()
    }

    @objc private func menuEnded() {
        menuDepth = max(0, menuDepth - 1)
        updateHover()
    }

    private func frame(for size: CGSize) -> CGRect {
        CGRect(x: (anchor.x - size.width / 2).rounded(.down), y: anchor.y - size.height,
               width: size.width, height: size.height)
    }

    private func placeContent(of size: CGSize, in backdrop: CompactIslandView) {
        let rect = CGRect(x: backdrop.bounds.midX - size.width / 2, y: backdrop.bounds.maxY - size.height,
                          width: size.width, height: size.height)
        controls?.frame = rect
        noticeRow?.frame = CGRect(x: rect.minX + 18, y: rect.minY + 2, width: max(0, rect.width - 36), height: 46)
    }

    private func fitPanel(_ size: CGSize, fromExpanded: Bool? = nil, revealing content: NSView? = nil) {
        guard let panel, let backdrop else { return }
        resizeWork?.cancel()
        resizeWork = nil
        let oldSize = panel.frame.size
        let finalFrame = frame(for: size)
        let animated = fromExpanded != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let duration = animated ? 0.22 : 0.0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        // Keep the window anchored at the notch. Only the mask changes size between endpoints.
        let canvas = CGSize(width: max(oldSize.width, size.width), height: max(oldSize.height, size.height))
        let canvasFrame = animated ? frame(for: canvas) : finalFrame
        if panel.frame != canvasFrame { panel.setFrame(canvasFrame, display: false) }
        if animated {
            let finish = DispatchWorkItem { [weak self] in
                guard let self, let panel = self.panel, let backdrop = self.backdrop else { return }
                if panel.frame != finalFrame {
                    panel.setFrame(finalFrame, display: false)
                    self.placeContent(of: size, in: backdrop)
                    backdrop.layoutSubtreeIfNeeded()
                }
                self.resizeWork = nil
                panel.ignoresMouseEvents = false
                self.updateHover()
            }
            resizeWork = finish
            CATransaction.setCompletionBlock { DispatchQueue.main.async(execute: finish) }
        } else {
            panel.ignoresMouseEvents = false
        }
        backdrop.animateShape(from: oldSize, expanded: fromExpanded ?? island.isExpanded,
                              to: size, expanded: island.isExpanded, duration: duration)
        placeContent(of: size, in: backdrop)
        if let content {
            content.wantsLayer = true
            if animated {
                let fade = CAKeyframeAnimation(keyPath: "opacity")
                fade.values = [0, 0, 1]
                fade.keyTimes = [0, 0.35, 1]
                fade.duration = duration
                content.layer?.add(fade, forKey: "reveal")
            }
            backdrop.addSubview(content)
        }
        backdrop.layoutSubtreeIfNeeded()
    }

    private func pointerInside(_ size: CGSize) -> Bool {
        let rect = frame(for: size)
        let point = NSEvent.mouseLocation
        // Include the topmost screen edge, where the pointer naturally comes to rest.
        return point.x >= rect.minX && point.x < rect.maxX && point.y >= rect.minY && point.y <= rect.maxY
    }

    private func updateHover() {
        hoverWork?.cancel()
        guard let panel, panel.isVisible, menuDepth == 0, !island.isPinned else { return }
        let expanded = island.isExpanded
        let inside = pointerInside(expanded ? island.expandedSize : idleSize)
        guard inside != expanded else {
            if expanded { openedFromMenuUntil = .distantPast }
            return
        }
        let delay = inside ? 0.12 : max(0.35, openedFromMenuUntil.timeIntervalSinceNow)
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.menuDepth == 0, !self.island.isPinned else { return }
            let visibleSize = self.island.isExpanded ? self.island.expandedSize : self.idleSize
            if self.pointerInside(visibleSize) == inside {
                if inside, self.noticeRow != nil { self.island.section = .alerts }
                self.setExpanded(inside)
            }
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func setExpanded(_ expanded: Bool) {
        guard let panel, let backdrop, expanded != island.isExpanded else { return }
        hoverWork?.cancel()
        island.isExpanded = expanded
        backdrop.update(notchSize: island.notchSize, expanded: expanded)
        panel.ignoresMouseEvents = !expanded
        if expanded {
            removePreview()
            let controls = IslandDashboard(player: player, island: island, artwork: artwork, lyrics: lyrics, features: features)
            self.controls = controls
            fitPanel(island.expandedSize, fromExpanded: false, revealing: controls)
        } else {
            discardControls()
            island.showsLyrics = false
            island.section = .music
            fitPanel(island.collapsedSize, fromExpanded: true)
        }
    }

    private func discardControls() {
        controls?.close()
        controls?.removeFromSuperview()
        controls = nil
    }

    private func resizeForContent() {
        guard island.isExpanded else { return }
        controls?.update()
        fitPanel(island.expandedSize, fromExpanded: true)
    }
}
