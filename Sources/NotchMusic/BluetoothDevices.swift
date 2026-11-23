import AppKit
import Combine
import CoreBluetooth
import IOBluetooth

struct ConnectedAccessory: Equatable {
    let id: String
    let name: String
    let symbol: String
    let lowEnergy: Bool
    var battery: AccessoryBattery?
}

@MainActor
final class BluetoothDevices: NSObject, ObservableObject {
    enum Availability { case needsAccess, denied, starting, poweredOff, unavailable, ready }

    @Published private(set) var availability: Availability = .needsAccess
    @Published private(set) var connected: [ConnectedAccessory] = []
    var onConnectionChange: ((_ name: String, _ connected: Bool) -> Void)?

    private var central: CBCentralManager?
    private var connections: IOBluetoothUserNotification?
    private var disconnections: [String: IOBluetoothUserNotification] = [:]
    private var discoveredUnpaired: [String: IOBluetoothDevice] = [:]
    private var classic: [String: ConnectedAccessory] = [:]
    private var lowEnergy: [ConnectedAccessory] = []
    private var baseline = false
    private var refreshTimer: Timer?
    private var batteryPaneVisible = false
    private var batteries: [String: AccessoryBattery] = [:]
    private var batteryReadInFlight = false
    private var batteryReadRevision: Int?
    private var batteryReadTime: TimeInterval?
    private var connectionRevision = 0

    // macOS requires specific GATT services when retrieving existing system connections.
    private lazy var services = ["180F", "180A", "1812", "184E", "1850"].map { CBUUID(string: $0) }

    static var monitoringEnabled: Bool { UserDefaults.standard.bool(forKey: "observeConnectedBluetooth") }

    func startIfAuthorized() {
        switch CBManager.authorization {
        case .allowedAlways:
            if !Self.monitoringEnabled { UserDefaults.standard.set(true, forKey: "observeConnectedBluetooth") }
            if central == nil { startCentral() }
            else if central?.state == .poweredOn { refresh() }
        case .notDetermined: setAvailability(.needsAccess)
        case .denied, .restricted:
            stopObservation()
            setAvailability(.denied)
        @unknown default: setAvailability(.unavailable)
        }
    }

    func requestAccess() {
        UserDefaults.standard.set(true, forKey: "observeConnectedBluetooth")
        guard CBManager.authorization == .notDetermined else { startIfAuthorized(); return }
        startCentral()
    }

    private func startCentral() {
        guard central == nil else { return }
        setAvailability(.starting)
        central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    func stop() {
        stopObservation()
        central?.delegate = nil
        central = nil
    }

    func setBatteryPaneVisible(_ visible: Bool) {
        batteryPaneVisible = visible
        if visible { refreshBatteriesIfNeeded() }
    }

    private func refreshBatteriesIfNeeded() {
        guard batteryPaneVisible, !batteryReadInFlight, !connected.isEmpty,
              availability == .ready, CBManager.authorization == .allowedAlways else { return }
        let devices = connected
        let now = ProcessInfo.processInfo.systemUptime
        let revision = connectionRevision
        if let batteryReadTime, now - batteryReadTime < (batteryReadRevision == revision ? 60 : 5) { return }
        batteryReadInFlight = true
        batteryReadRevision = revision
        batteryReadTime = now
        Task { [weak self] in
            let levels = await Task.detached(priority: .utility) { AccessoryBatteryReader.read(for: devices) }.value
            guard let self else { return }
            self.batteryReadInFlight = false
            guard revision == self.connectionRevision, self.availability == .ready,
                  self.batteries != levels else { return }
            self.batteries = levels
            var updated = self.connected
            for index in updated.indices { updated[index].battery = levels[updated[index].id] }
            self.connected = updated
        }
    }

    private func setAvailability(_ value: Availability) {
        if availability != value { availability = value }
    }

    private func stopObservation() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        connections?.unregister()
        connections = nil
        for subscription in disconnections.values { subscription.unregister() }
        disconnections.removeAll()
        discoveredUnpaired.removeAll()
        classic.removeAll()
        lowEnergy.removeAll()
        batteries.removeAll()
        batteryReadTime = nil
        connectionRevision += 1
        baseline = false
        if !connected.isEmpty { connected = [] }
    }

    private func stateChanged() {
        guard let central else { return }
        switch central.state {
        case .poweredOn:
            setAvailability(.ready)
            if connections == nil {
                connections = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(classicConnected(_:device:)))
            }
            refresh()
            if refreshTimer == nil {
                // macOS has no system-wide BLE connection callback. This retrieves only already
                // connected peripherals. The controller never scans, pairs, or opens a connection.
                let timer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, let central = self.central, central.state == .poweredOn else { return }
                        self.refreshLowEnergy(central)
                    }
                }
                timer.tolerance = 4
                RunLoop.main.add(timer, forMode: .common)
                refreshTimer = timer
            }
        case .poweredOff:
            classic.removeAll()
            lowEnergy.removeAll()
            publish()
            stopObservation()
            setAvailability(.poweredOff)
        case .unauthorized: stopObservation(); setAvailability(.denied)
        case .unsupported: stopObservation(); setAvailability(.unavailable)
        case .unknown, .resetting: stopObservation(); setAvailability(.starting)
        @unknown default: stopObservation(); setAvailability(.unavailable)
        }
    }

    private func refresh() {
        guard let central, central.state == .poweredOn else { return }
        var devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        discoveredUnpaired = discoveredUnpaired.filter { $0.value.isConnected() }
        devices.append(contentsOf: discoveredUnpaired.values)
        var current: [String: ConnectedAccessory] = [:]
        for device in devices where device.isConnected() {
            guard let address = device.addressString, !address.isEmpty else { continue }
            current[address] = ConnectedAccessory(id: address, name: device.name ?? "Bluetooth-устройство",
                                                  symbol: Self.symbol(major: device.deviceClassMajor, minor: device.deviceClassMinor), lowEnergy: false)
            if disconnections[address] == nil {
                disconnections[address] = device.register(forDisconnectNotification: self, selector: #selector(classicDisconnected(_:device:)))
            }
        }
        for address in Set(disconnections.keys).subtracting(current.keys) {
            disconnections.removeValue(forKey: address)?.unregister()
        }
        let classicChanged = classic != current
        classic = current
        refreshLowEnergy(central, classicChanged: classicChanged)
    }

    private func refreshLowEnergy(_ central: CBCentralManager, classicChanged: Bool = false) {
        let devices = central.retrieveConnectedPeripherals(withServices: services).map { peripheral in
            ConnectedAccessory(id: peripheral.identifier.uuidString, name: peripheral.name ?? "Устройство Bluetooth LE",
                               symbol: "antenna.radiowaves.left.and.right", lowEnergy: true)
        }
        if baseline && !classicChanged && devices == lowEnergy {
            refreshBatteriesIfNeeded()
            return
        }
        lowEnergy = devices
        publish()
    }

    @objc nonisolated private func classicConnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        let address = device.isPaired() ? nil : device.addressString
        DispatchQueue.main.async { [weak self] in
            guard let self, self.availability == .ready else { return }
            if let address { self.discoveredUnpaired[address] = IOBluetoothDevice(addressString: address) }
            self.refresh()
        }
    }

    @objc nonisolated private func classicDisconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    private func publish() {
        var next = (Array(classic.values) + lowEnergy).sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        let old = connected
        let before = Set(old.map(\.id)), after = Set(next.map(\.id))
        if before != after {
            connectionRevision += 1
            batteries = batteries.filter { after.contains($0.key) }
        }
        for index in next.indices {
            next[index].battery = batteries[next[index].id]
        }
        if next != old { connected = next }
        refreshBatteriesIfNeeded()
        defer { baseline = true }
        guard baseline else { return }
        for device in old where !after.contains(device.id) { onConnectionChange?(device.name, false) }
        for device in next where !before.contains(device.id) { onConnectionChange?(device.name, true) }
    }

    private static func symbol(major: BluetoothDeviceClassMajor, minor: BluetoothDeviceClassMinor) -> String {
        switch major {
        case 1: return "desktopcomputer"
        case 2: return "iphone"
        case 4: return minor == 5 || minor == 10 ? "hifispeaker" : "headphones"
        case 5:
            if minor & 0x10 != 0 { return "keyboard" }
            if minor & 0x20 != 0 { return "computermouse" }
            return minor == 1 || minor == 2 ? "gamecontroller" : "dot.radiowaves.left.and.right"
        case 7: return "applewatch"
        default: return "antenna.radiowaves.left.and.right"
        }
    }
}

extension BluetoothDevices: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor [weak self] in
            guard let self, self.central === central else { return }
            self.stateChanged()
        }
    }
}
