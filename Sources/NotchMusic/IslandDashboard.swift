import AppKit
import Combine

enum IslandSection: Int, CaseIterable {
    case music, calendar, alerts, bluetooth
    var title: String {
        switch self {
        case .music: return "Музыка"
        case .calendar: return "Календарь"
        case .alerts: return "Уведомления"
        case .bluetooth: return "Bluetooth"
        }
    }
    var symbol: String {
        switch self {
        case .music: return "music.note"
        case .calendar: return "calendar"
        case .alerts: return "bell"
        case .bluetooth: return "antenna.radiowaves.left.and.right"
        }
    }
}

@MainActor
final class IslandFeatures {
    let alerts = IslandAlerts()
    private var accessoryMonitor: BluetoothDevices?
    var bluetooth: BluetoothDevices {
        if let accessoryMonitor { return accessoryMonitor }
        let monitor = BluetoothDevices()
        monitor.onConnectionChange = { [weak self] name, connected in
            self?.alerts.post(connected ? "Устройство подключено" : "Устройство отключено",
                              detail: name, symbol: "antenna.radiowaves.left.and.right")
        }
        accessoryMonitor = monitor
        return monitor
    }
    func start() {
        alerts.start()
        if BluetoothDevices.monitoringEnabled { bluetooth.startIfAuthorized() }
    }

    func stop() {
        accessoryMonitor?.stop()
        alerts.stop()
    }
}

@MainActor
final class IslandDashboard: NSView {
    private let player: PlayerController
    private let island: IslandPresentation
    private let artwork: TrackArtwork
    private let lyrics: LyricsLookup
    private let features: IslandFeatures
    private var selected: IslandSection?
    private var page: NSView?
    private var buttons: [NSButton] = []
    private let pin = NSButton()
    private let rule = NSBox()
    static let navigationHeight: CGFloat = 42

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(player: PlayerController, island: IslandPresentation, artwork: TrackArtwork, lyrics: LyricsLookup, features: IslandFeatures) {
        self.player = player; self.island = island; self.artwork = artwork; self.lyrics = lyrics; self.features = features
        super.init(frame: .zero)
        appearance = NSAppearance(named: .darkAqua)
        rule.boxType = .separator
        addSubview(rule)
        addSubview(pin)
        pin.isBordered = false
        pin.target = self
        pin.action = #selector(togglePin)
        for section in IslandSection.allCases {
            let button = NSButton(title: section.title, target: self, action: #selector(selectPage(_:)))
            button.image = NSImage(systemSymbolName: section.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
            button.imagePosition = .imageAbove
            button.isBordered = false
            button.font = .systemFont(ofSize: 9, weight: .medium)
            button.toolTip = section.title
            button.setAccessibilityLabel(section.title)
            button.tag = section.rawValue
            buttons.append(button)
            addSubview(button)
        }
        update()
    }
    required init?(coder: NSCoder) { nil }

    func update() {
        let section = island.section
        if selected != section {
            clearPage()
            let next: NSView
            switch section {
            case .music: next = ExpandedIslandView(player: player, island: island, artwork: artwork, lyrics: lyrics)
            case .calendar: next = CalendarPane(frame: .zero)
            case .alerts: next = AlertsPane(alerts: features.alerts)
            case .bluetooth: next = BluetoothPane(devices: features.bluetooth)
            }
            page = next
            selected = section
            addSubview(next, positioned: .below, relativeTo: rule)
            for (index, button) in buttons.enumerated() {
                let active = index == section.rawValue
                let ink = NSColor(white: active ? 1 : 0.60, alpha: 1)
                button.contentTintColor = ink
                button.attributedTitle = NSAttributedString(string: IslandSection.allCases[index].title,
                    attributes: [.foregroundColor: ink, .font: NSFont.systemFont(ofSize: 9, weight: active ? .bold : .regular)])
                button.setAccessibilityValue(active ? 1 : 0)
            }
        } else { (page as? ExpandedIslandView)?.update() }
        pin.isHidden = section == .music
        pin.image = NSImage(systemSymbolName: island.isPinned ? "pin.fill" : "pin", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        pin.toolTip = island.isPinned ? "Открепить остров" : "Закрепить остров открытым"
        pin.setAccessibilityLabel(pin.toolTip)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = bounds.width, band = island.notchSize.height
        let navY = bounds.height - Self.navigationHeight
        rule.frame = CGRect(x: 18, y: navY, width: max(0, width - 36), height: 1)
        let segment = max(0, width - 18) / CGFloat(buttons.count)
        for (index, button) in buttons.enumerated() {
            button.frame = CGRect(x: 9 + CGFloat(index) * segment, y: navY + 2, width: segment, height: 34)
        }
        let wing = (width - island.notchSize.width) / 2
        pin.frame = CGRect(x: (wing - 30) / 2, y: (band - 24) / 2, width: 30, height: 24)
        let top = selected == .music ? 0 : band
        page?.frame = CGRect(x: 0, y: top, width: width, height: max(0, navY - top))
    }

    private func clearPage() {
        (page as? ExpandedIslandView)?.close()
        page?.removeFromSuperview()
        page = nil
    }
    func close() { clearPage() }
    @objc private func selectPage(_ sender: NSButton) {
        if let section = IslandSection(rawValue: sender.tag) { island.section = section }
    }
    @objc private func togglePin() { island.isPinned.toggle() }
}

@MainActor
private final class AlertsPane: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let alerts: IslandAlerts
    private let toggle = NSButton(checkboxWithTitle: "Баннеры приложений macOS", target: nil, action: nil)
    private let grant = NSButton(title: "Дать доступ", target: nil, action: nil)
    private let clear = NSButton(title: "Очистить", target: nil, action: nil)
    private let list = NSScrollView()
    private var rows: [IslandNotice] = []
    private let empty = NSTextField(wrappingLabelWithString: "")
    private var observation: AnyCancellable?
    override var isFlipped: Bool { true }

    init(alerts: IslandAlerts) {
        self.alerts = alerts
        super.init(frame: .zero)
        for view in [toggle, grant, clear, list, empty] { addSubview(view) }
        toggle.font = .systemFont(ofSize: 12, weight: .semibold)
        toggle.toolTip = "Показывать доступные баннеры из Центра уведомлений в острове"
        toggle.target = self; toggle.action = #selector(toggleBanners)
        grant.target = self; grant.action = #selector(request)
        clear.target = self; clear.action = #selector(clearHistory)
        for b in [grant, clear] { b.bezelStyle = .rounded; b.controlSize = .small }
        empty.textColor = .secondaryLabelColor
        empty.alignment = .center
        empty.font = .systemFont(ofSize: 12)
        empty.maximumNumberOfLines = 4
        list.drawsBackground = false; list.hasVerticalScroller = true; list.autohidesScrollers = true
        alerts.refreshPermission()
        observation = alerts.objectWillChange.sink { [weak self] in DispatchQueue.main.async { self?.render() } }
        render()
    }
    required init?(coder: NSCoder) { nil }

    private func render() {
        let notices = alerts.notices
        toggle.state = alerts.mirrorsBanners ? .on : .off
        grant.isHidden = !alerts.mirrorsBanners || alerts.hasAccess
        clear.isHidden = notices.isEmpty
        list.isHidden = notices.isEmpty
        empty.isHidden = !notices.isEmpty
        empty.stringValue = grant.isHidden ? "Здесь появятся новые уведомления острова." :
            "Разрешите универсальный доступ для shpshka app в настройках macOS, чтобы видеть баннеры приложений."
        if rows != notices {
            rows = notices
            if notices.isEmpty {
                list.documentView = nil
            } else {
                let table = (list.documentView as? NSTableView) ?? makeTable()
                table.noteNumberOfRowsChanged()
                table.enumerateAvailableRowViews { row, index in
                    guard notices.indices.contains(index), let cell = row.view(atColumn: 0) as? NoticeRow else { return }
                    cell.show(notices[index])
                }
                table.scrollRowToVisible(0)
            }
        }
        needsLayout = true
    }

    private func makeTable() -> NSTableView {
        let table = NSTableView(frame: list.bounds)
        let column = NSTableColumn(identifier: .init("notice"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.style = .plain
        table.rowSizeStyle = .custom
        table.rowHeight = 48
        table.headerView = nil
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.intercellSpacing = .zero
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("Уведомления острова")
        list.documentView = table
        return table
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("notice")
        if let view = tableView.makeView(withIdentifier: id, owner: self) as? NoticeRow {
            view.show(rows[row])
            return view
        }
        let view = NoticeRow(rows[row])
        view.identifier = id
        return view
    }
    override func layout() {
        super.layout()
        let width = max(0, bounds.width - 36)
        toggle.frame = CGRect(x: 18, y: 8, width: max(0, width - 94), height: 24)
        grant.frame = CGRect(x: bounds.width - 109, y: 8, width: 92, height: 24)
        let reserved: CGFloat = !grant.isHidden && !clear.isHidden ? 58 : 37
        clear.frame = CGRect(x: bounds.width - 99, y: grant.isHidden ? 8 : 32, width: 82, height: 24)
        list.frame = CGRect(x: 18, y: reserved, width: width, height: max(0, bounds.height - reserved - 7))
        empty.frame = CGRect(x: 35, y: bounds.height / 2 - 16, width: max(0, bounds.width - 70), height: 64)
        if let table = list.documentView as? NSTableView {
            table.setFrameSize(CGSize(width: list.contentSize.width, height: table.frame.height))
            table.tableColumns.first?.width = list.contentSize.width
        }
    }
    @objc private func toggleBanners() { alerts.setMirroring(toggle.state == .on); render() }
    @objc private func request() { alerts.requestAccess() }
    @objc private func clearHistory() { alerts.clear() }
}

@MainActor
final class NoticeRow: NSView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let time = NSTextField(labelWithString: "")
    override var isFlipped: Bool { true }
    init(_ notice: IslandNotice) {
        super.init(frame: .zero)
        icon.contentTintColor = .lightGray
        for v in [icon, title, detail, time] { addSubview(v) }
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        detail.font = .systemFont(ofSize: 11)
        time.font = .systemFont(ofSize: 10)
        detail.textColor = .lightGray; time.textColor = .lightGray
        title.textColor = .white
        for field in [title, detail] { field.lineBreakMode = .byTruncatingTail }
        time.alignment = .right
        show(notice)
    }
    required init?(coder: NSCoder) { nil }
    func show(_ notice: IslandNotice) {
        icon.image = NSImage(systemSymbolName: notice.symbol, accessibilityDescription: nil)
        title.stringValue = notice.title
        title.toolTip = notice.title
        detail.stringValue = notice.detail
        detail.toolTip = notice.detail
        time.stringValue = notice.date.formatted(date: .omitted, time: .shortened)
    }
    override func layout() {
        super.layout()
        icon.frame = CGRect(x: 2, y: 9, width: 24, height: 25)
        title.frame = CGRect(x: 33, y: 5, width: max(0, bounds.width - 93), height: 18)
        detail.frame = CGRect(x: 33, y: 24, width: max(0, bounds.width - 38), height: 17)
        time.frame = CGRect(x: max(0, bounds.width - 55), y: 6, width: 54, height: 16)
    }
}
