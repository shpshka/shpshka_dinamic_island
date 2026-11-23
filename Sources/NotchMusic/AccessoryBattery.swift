import Foundation
import IOKit

struct AccessoryBattery: Equatable {
    let main: Int?
    let left: Int?
    let right: Int?
    let chargingCase: Int?

    init?(main: Int? = nil, left: Int? = nil, right: Int? = nil, chargingCase: Int? = nil) {
        guard [main, left, right, chargingCase].contains(where: { $0 != nil }) else { return nil }
        self.main = main
        self.left = left
        self.right = right
        self.chargingCase = chargingCase
    }

    func label(expanded: Bool) -> String {
        var parts: [String] = []
        if left == nil, right == nil, let main { parts.append("\(main)%") }
        if let left { parts.append((expanded ? "Левый " : "Л ") + "\(left)%") }
        if let right { parts.append((expanded ? "Правый " : "П ") + "\(right)%") }
        if let chargingCase { parts.append((expanded ? "Футляр " : "К ") + "\(chargingCase)%") }
        return parts.joined(separator: " · ")
    }

    static func percentage(_ raw: Any?) -> Int? {
        let value: Int?
        if let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            value = Int(exactly: number.doubleValue)
        } else if let text = raw as? String {
            var digits = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if digits.last == "%" { digits.removeLast() }
            value = Int(digits.trimmingCharacters(in: .whitespaces))
        } else { return nil }
        guard let value, (0...100).contains(value) else { return nil }
        return value
    }
}

enum AccessoryBatteryReader {
    struct ReportDevice {
        let address: String?
        let name: String
        let battery: AccessoryBattery?
    }

    static func address(_ text: String?) -> String? {
        guard let text else { return nil }
        let compact = text.lowercased().filter { $0 != ":" && $0 != "-" }
        guard compact.utf8.count == 12, compact != "000000000000",
              compact.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        return compact
    }

    static func connectedReport(_ data: Data) -> [ReportDevice] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let radios = root["SPBluetoothDataType"] as? [[String: Any]] else { return [] }
        return radios.flatMap { radio in
            let devices = radio["device_connected"] as? [[String: [String: Any]]] ?? []
            return devices.flatMap { entry in
                entry.map { name, properties in
                    let battery = AccessoryBattery(main: AccessoryBattery.percentage(properties["device_batteryLevelMain"]),
                                                   left: AccessoryBattery.percentage(properties["device_batteryLevelLeft"]),
                                                   right: AccessoryBattery.percentage(properties["device_batteryLevelRight"]),
                                                   chargingCase: AccessoryBattery.percentage(properties["device_batteryLevelCase"]))
                    return ReportDevice(address: address(properties["device_address"] as? String), name: name, battery: battery)
                }
            }
        }
    }

    static func match(_ devices: [ConnectedAccessory], report: [ReportDevice], hid: [String: Int]) -> [String: AccessoryBattery] {
        var result: [String: AccessoryBattery] = [:]
        let classicAddresses = Set(devices.compactMap { address($0.id) })
        for device in devices {
            let mac = address(device.id)
            var found: ReportDevice?
            if let mac {
                found = report.first { $0.address == mac }
            } else if device.lowEnergy, devices.filter({ $0.name == device.name }).count == 1 {
                // CoreBluetooth exposes a UUID. Use the name only if it is unique on both sides
                // and the matching record does not belong to a known classic device.
                let matches = report.filter { $0.name == device.name }
                if matches.count == 1, matches[0].address.map(classicAddresses.contains) != true { found = matches[0] }
            }
            let hidLevel = (mac ?? found?.address).flatMap { hid[$0] }
            let battery = found?.battery
            result[device.id] = AccessoryBattery(main: battery?.main ?? hidLevel, left: battery?.left,
                                                 right: battery?.right, chargingCase: battery?.chargingCase)
        }
        return result
    }

    // An exact Bluetooth address is required before using any HID battery percentage.
    private static func hidLevels() -> [String: Int] {
        var result: [String: Int] = [:]
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleDeviceManagementHIDEventService"),
                                           &iterator) == KERN_SUCCESS else { return result }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            func property(_ name: String) -> AnyObject? {
                IORegistryEntryCreateCFProperty(service, name as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            guard let transport = property("Transport") as? String, transport.lowercased().contains("bluetooth"),
                  let level = AccessoryBattery.percentage(property("BatteryPercent")),
                  let mac = address(property("DeviceAddress") as? String) ?? address(property("SerialNumber") as? String)
            else { continue }
            result[mac] = level
        }
        return result
    }

    static func read(for devices: [ConnectedAccessory]) -> [String: AccessoryBattery] {
        let hid = hidLevels()
        let known = match(devices, report: [], hid: hid)
        // Audio accessories may also expose a HID percentage. The Bluetooth report can
        // include separate batteries for the earbuds and case.
        if known.count == devices.count, !devices.contains(where: { $0.symbol == "headphones" }) { return known }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["-json", "-timeout", "8", "SPBluetoothDataType"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return known }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return match(devices, report: connectedReport(data), hid: hid)
    }
}
