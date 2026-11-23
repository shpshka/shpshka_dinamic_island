import AppKit
import ServiceManagement

@main
@MainActor
enum NotchMusicApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let player = PlayerController()
    private lazy var panel = IslandPanelController(player: player)
    private var statusItem: NSStatusItem?
    private var copyItem: NSMenuItem?
    private var loginItem: NSMenuItem?
    private var pinnedItem: NSMenuItem?
    private var sleepMenuItem: NSMenuItem?
    private var cancelSleepItem: NSMenuItem?
    private var sleepTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "shpshka app")
        item.button?.toolTip = "shpshka app"
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        addItem("Раскрыть остров", #selector(expand), to: menu)
        item.menu = menu
        statusItem = item
        panel.start()
        if CommandLine.arguments.contains("--enable-login"), SMAppService.mainApp.status == .notRegistered {
            changeLoginItem(enable: true)
        }
    }

    private func populateStatusMenu(_ menu: NSMenu) {
        let sections = NSMenu()
        for section in IslandSection.allCases {
            let item = addItem(section.title, #selector(openSection(_:)), to: sections)
            item.tag = section.rawValue
        }
        let sectionMenu = NSMenuItem(title: "Разделы острова", action: nil, keyEquivalent: "")
        sectionMenu.submenu = sections
        menu.addItem(sectionMenu)
        pinnedItem = addItem("Оставить остров раскрытым", #selector(togglePin), to: menu)
        copyItem = addItem("Скопировать название трека", #selector(copyTrack), to: menu)
        let sleep = NSMenuItem(title: "Таймер сна", action: nil, keyEquivalent: "")
        let intervals = NSMenu()
        intervals.autoenablesItems = false
        for minutes in [15, 30, 60] {
            let option = addItem("Пауза через \(minutes) мин", #selector(schedulePause(_:)), to: intervals)
            option.tag = minutes
        }
        intervals.addItem(.separator())
        cancelSleepItem = addItem("Отменить таймер", #selector(cancelSleep), to: intervals)
        sleep.submenu = intervals
        menu.addItem(sleep)
        sleepMenuItem = sleep
        loginItem = addItem("Запускать при входе", #selector(toggleLoginItem), to: menu)
        addItem("Открыть Карты", #selector(openMaps), to: menu)
        menu.addItem(.separator())
        addItem("Завершить shpshka app", #selector(quit), to: menu, key: "q")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel.showExpanded()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        cancelSleep()
        panel.stop()
        player.stop()
    }

    @discardableResult
    private func addItem(_ title: String, _ action: Selector, to menu: NSMenu, key: String = "") -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if pinnedItem == nil { populateStatusMenu(menu) }
        let loginStatus = SMAppService.mainApp.status
        loginItem?.state = loginStatus == .enabled ? .on : (loginStatus == .requiresApproval ? .mixed : .off)
        copyItem?.isEnabled = player.track != nil
        pinnedItem?.state = panel.island.isPinned ? .on : .off
        cancelSleepItem?.isEnabled = sleepTimer != nil
        if let deadline = sleepTimer?.fireDate {
            sleepMenuItem?.title = "Таймер сна · до " + deadline.formatted(date: .omitted, time: .shortened)
        } else { sleepMenuItem?.title = "Таймер сна" }
    }

    @objc private func toggleLoginItem() {
        let service = SMAppService.mainApp
        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        } else {
            changeLoginItem(enable: service.status != .enabled)
        }
    }

    private func changeLoginItem(enable: Bool) {
        do {
            if enable { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            if enable && SMAppService.mainApp.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Не удалось изменить запуск при входе"
            alert.runModal()
        }
    }

    @objc private func openSection(_ sender: NSMenuItem) {
        panel.showExpanded(section: IslandSection(rawValue: sender.tag))
    }
    @objc private func expand() { panel.showExpanded() }
    @objc private func togglePin() { panel.island.isPinned.toggle() }

    @objc private func schedulePause(_ sender: NSMenuItem) {
        cancelSleep()
        let timer = Timer(timeInterval: TimeInterval(sender.tag * 60), repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.sleepTimer = nil
                if let self, self.player.canPlayPause, self.player.track?.isPlaying == true {
                    self.player.pauseIfPlaying()
                    self.panel.features.alerts.post("Таймер сна", detail: "Время прослушивания истекло", symbol: "moon.fill")
                }
            }
        }
        sleepTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func cancelSleep() {
        sleepTimer?.invalidate()
        sleepTimer = nil
    }

    @objc private func copyTrack() {
        guard let track = player.track else { return }
        let text = [track.artist, track.title].filter { !$0.isEmpty }.joined(separator: " — ")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func openMaps() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Maps") else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
