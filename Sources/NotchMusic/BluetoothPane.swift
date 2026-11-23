import AppKit
import Combine

@MainActor
final class BluetoothPane: NSView {
    private let devices: BluetoothDevices
    private let heading = NSTextField(labelWithString: "")
    private let settings = NSButton()
    private let message = NSTextField(wrappingLabelWithString: "")
    private let access = NSButton()
    private let list = NSScrollView()
    private let document = BluetoothRows()
    private var rows: [AccessoryRow] = []
    private var observation: AnyCancellable?
    private var settingsReturn: AnyCancellable?

    override var isFlipped: Bool { true }

    init(devices: BluetoothDevices) {
        self.devices = devices
        super.init(frame: .zero)
        appearance = NSAppearance(named: .darkAqua)
        heading.font = .systemFont(ofSize: 16, weight: .semibold)
        heading.textColor = .white
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Настройки Bluetooth")
        settings.imagePosition = .imageOnly
        settings.contentTintColor = .lightGray
        settings.isBordered = false
        settings.target = self
        settings.action = #selector(openSettings)
        settings.toolTip = "Настройки Bluetooth"
        settings.setAccessibilityLabel("Настройки Bluetooth")
        message.font = .systemFont(ofSize: 13)
        message.textColor = .init(white: 0.74, alpha: 1)
        message.alignment = .center
        message.maximumNumberOfLines = 3
        access.target = self
        access.action = #selector(accessAction)
        access.bezelStyle = .rounded
        access.font = .systemFont(ofSize: 12, weight: .semibold)
        list.drawsBackground = false
        list.hasHorizontalScroller = false
        list.hasVerticalScroller = true
        list.autohidesScrollers = true
        list.scrollerStyle = .overlay
        list.documentView = document
        for child in [heading, settings, list, message, access] { addSubview(child) }
        observation = devices.$availability.combineLatest(devices.$connected).sink { [weak self] state, items in
            self?.render(state, items)
        }
        settingsReturn = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didDeactivateApplicationNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak devices] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                if app?.bundleIdentifier == "com.apple.systempreferences" { devices?.startIfAuthorized() }
            }
        devices.startIfAuthorized()
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        devices.setBatteryPaneVisible(window != nil)
    }

    private func render(_ state: BluetoothDevices.Availability, _ items: [ConnectedAccessory]) {
        let visible = state == .ready && !items.isEmpty
        heading.stringValue = visible ? "Подключено · " + String(items.count) : "Bluetooth-устройства"
        settings.isHidden = false
        list.isHidden = !visible
        message.isHidden = visible
        access.isHidden = true
        if visible {
            while rows.count > items.count { rows.removeLast().removeFromSuperview() }
            for (index, item) in items.enumerated() {
                if index < rows.count {
                    rows[index].update(item)
                } else {
                    let row = AccessoryRow(item)
                    document.addSubview(row)
                    rows.append(row)
                }
            }
        } else {
            for row in rows { row.removeFromSuperview() }
            rows.removeAll()
            switch state {
            case .needsAccess:
                message.stringValue = "Разрешите доступ к Bluetooth, чтобы видеть подключённые устройства."
                access.title = "Разрешить доступ"
                access.isHidden = false
            case .denied:
                message.stringValue = "Доступ к Bluetooth отключён для shpshka app."
                access.title = "Настроить доступ"
                access.isHidden = false
            case .starting: message.stringValue = "Проверяем Bluetooth…"
            case .poweredOff: message.stringValue = "Bluetooth выключен"
            case .unavailable: message.stringValue = "Bluetooth недоступен на этом Mac"
            case .ready: message.stringValue = "Нет подключённых устройств"
            }
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let inset: CGFloat = 18
        let w = max(0, bounds.width - inset * 2)
        heading.frame = CGRect(x: inset, y: 7, width: max(0, w - 35), height: 24)
        settings.frame = CGRect(x: max(inset, bounds.width - inset - 30), y: 3, width: 30, height: 29)
        list.frame = CGRect(x: inset, y: 37, width: w, height: max(0, bounds.height - 43))
        let rowHeight: CGFloat = 39
        document.frame = CGRect(x: 0, y: 0, width: list.contentSize.width, height: CGFloat(rows.count) * rowHeight)
        for (index, row) in rows.enumerated() {
            row.frame = CGRect(x: 0, y: CGFloat(index) * rowHeight, width: document.bounds.width, height: rowHeight)
        }
        let mid = (bounds.height + 28) / 2
        message.frame = CGRect(x: inset, y: max(38, mid - (access.isHidden ? 12 : 35)), width: w, height: 38)
        let bw = min(w, max(120, access.fittingSize.width + 10))
        access.frame = CGRect(x: (bounds.width - bw) / 2, y: mid + 8, width: bw, height: 28)
    }

    @objc private func accessAction() {
        if devices.availability == .denied {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")!)
        } else {
            devices.requestAccess()
        }
    }

    @objc private func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!)
    }
}

@MainActor private final class BluetoothRows: NSView {
    override var isFlipped: Bool { true }
}

@MainActor private final class AccessoryRow: NSView {
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let transport = NSTextField(labelWithString: "")
    private let charge = NSTextField(labelWithString: "")
    private let batteryIcon = NSImageView()
    private let line = NSBox()
    private var accessory: ConnectedAccessory?

    init(_ item: ConnectedAccessory) {
        super.init(frame: .zero)
        icon.contentTintColor = .init(white: 0.8, alpha: 1)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.textColor = .white
        name.lineBreakMode = .byTruncatingTail
        transport.font = .systemFont(ofSize: 10)
        transport.textColor = .lightGray
        charge.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        charge.alignment = .right
        batteryIcon.contentTintColor = .secondaryLabelColor
        line.boxType = .separator
        for child in [icon, name, transport, charge, batteryIcon, line] { addSubview(child) }
        update(item)
    }

    func update(_ item: ConnectedAccessory) {
        guard accessory != item else { return }
        let previous = accessory
        accessory = item
        if previous?.symbol != item.symbol {
            icon.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)
        }
        if previous?.name != item.name {
            name.stringValue = item.name
            name.toolTip = item.name
        }
        if previous?.lowEnergy != item.lowEnergy {
            transport.stringValue = item.lowEnergy ? "Bluetooth LE" : "Bluetooth"
        }
        guard previous == nil || previous?.battery != item.battery else { return }
        charge.stringValue = item.battery?.label(expanded: false) ?? "Заряд —"
        charge.textColor = item.battery == nil ? .secondaryLabelColor : .white
        charge.toolTip = item.battery.map { "Заряд: " + $0.label(expanded: true) } ?? "Нет данных о заряде"
        charge.setAccessibilityLabel(charge.toolTip)
        if let battery = item.battery, let main = battery.main,
           battery.left == nil, battery.right == nil, battery.chargingCase == nil {
            let step = Int((Double(main) / 25).rounded()) * 25
            batteryIcon.image = NSImage(systemSymbolName: "battery.\(step)percent", accessibilityDescription: nil)
        } else { batteryIcon.image = nil }
        batteryIcon.toolTip = charge.toolTip
        batteryIcon.isHidden = batteryIcon.image == nil
        needsLayout = true
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        let w = bounds.width
        let chargeWidth = min(max(0, w - 66), charge.fittingSize.width + 2)
        let chargeX = max(0, w - 3 - chargeWidth)
        let iconX = chargeX - (batteryIcon.isHidden ? 0 : 21)
        let nameWidth = max(0, iconX - 38)
        icon.frame = CGRect(x: 0, y: 9, width: 21, height: 21)
        name.frame = CGRect(x: 30, y: 4, width: nameWidth, height: 18)
        transport.frame = CGRect(x: 30, y: 21, width: nameWidth, height: 14)
        batteryIcon.frame = CGRect(x: iconX, y: 12, width: 18, height: 15)
        charge.frame = CGRect(x: chargeX, y: 11, width: chargeWidth, height: 18)
        line.frame = CGRect(x: 30, y: bounds.height - 1, width: max(0, w - 30), height: 1)
    }
}
