import Combine
import CoreBluetooth
import Foundation

final class QuboBulbManager: NSObject, ObservableObject {
    enum RadioState: Equatable {
        case idle
        case preparing
        case ready
        case poweredOff
        case unauthorized
        case unsupported
        case failed(String)

        var title: String {
            switch self {
            case .idle: return "Ready to scan"
            case .preparing: return "Preparing Bluetooth…"
            case .ready: return "Bluetooth ready"
            case .poweredOff: return "Bluetooth is off"
            case .unauthorized: return "Bluetooth access denied"
            case .unsupported: return "Bluetooth is unavailable"
            case .failed(let message): return message
            }
        }
    }

    @Published private(set) var bulbs: [QuboBulbSnapshot] = []
    @Published private(set) var radioState: RadioState = .idle
    @Published private(set) var isScanning = false

    private let quboService = CBUUID(string: "00DD")
    private let modelCharacteristic = CBUUID(string: "DD01")
    private let lightStateCharacteristic = CBUUID(string: "DD02")
    private let deviceStateCharacteristic = CBUUID(string: "DD03")
    private let mirroredStateCharacteristic = CBUUID(string: "DD04")

    private var central: CBCentralManager?
    private var shouldScan = false
    private var peripheralsByHardwareID: [String: CBPeripheral] = [:]
    private var hardwareIDByPeripheralID: [UUID: String] = [:]
    private var connectingPeripheralIDs = Set<UUID>()
    private var staleTimer: Timer?

    func startScanning() {
        shouldScan = true
        radioState = .preparing

        if central == nil {
            central = CBCentralManager(
                delegate: self,
                queue: .main,
                options: [CBCentralManagerOptionShowPowerAlertKey: true]
            )
        } else {
            beginScanIfPossible()
        }
    }

    func stopScanning() {
        shouldScan = false
        central?.stopScan()
        isScanning = false
        staleTimer?.invalidate()
        staleTimer = nil

        for peripheral in peripheralsByHardwareID.values where peripheral.state != .disconnected {
            central?.cancelPeripheralConnection(peripheral)
        }
    }

    func restartScanning() {
        stopScanning()
        bulbs.removeAll()
        peripheralsByHardwareID.removeAll()
        hardwareIDByPeripheralID.removeAll()
        connectingPeripheralIDs.removeAll()
        startScanning()
    }

    private func beginScanIfPossible() {
        guard shouldScan, let central else { return }
        guard central.state == .poweredOn else {
            updateRadioState(for: central.state)
            return
        }

        central.stopScan()
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
        radioState = .ready
        isScanning = true
        startStaleTimer()
    }

    private func startStaleTimer() {
        staleTimer?.invalidate()
        staleTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.removeStaleDisconnectedBulbs()
        }
    }

    private func removeStaleDisconnectedBulbs(now: Date = Date()) {
        let staleIDs = bulbs.compactMap { bulb -> String? in
            guard now.timeIntervalSince(bulb.lastSeen) > 12 else { return nil }
            let peripheral = peripheralsByHardwareID[bulb.id]
            return peripheral?.state == .connected || peripheral?.state == .connecting ? nil : bulb.id
        }
        guard !staleIDs.isEmpty else { return }
        bulbs.removeAll { staleIDs.contains($0.id) }
    }

    private func updateRadioState(for state: CBManagerState) {
        switch state {
        case .unknown, .resetting: radioState = .preparing
        case .unsupported: radioState = .unsupported
        case .unauthorized: radioState = .unauthorized
        case .poweredOff: radioState = .poweredOff
        case .poweredOn: radioState = .ready
        @unknown default: radioState = .failed("Unknown Bluetooth state")
        }
        if state != .poweredOn { isScanning = false }
    }

    private func mutateBulb(hardwareID: String, _ change: (inout QuboBulbSnapshot) -> Void) {
        guard let index = bulbs.firstIndex(where: { $0.id == hardwareID }) else { return }
        var bulb = bulbs[index]
        change(&bulb)
        bulbs[index] = bulb
        bulbs.sort { lhs, rhs in
            if lhs.state != rhs.state { return lhs.state == .needsSetup }
            return lhs.id < rhs.id
        }
    }

    private func text(from characteristic: CBCharacteristic) -> String? {
        guard let data = characteristic.value else { return nil }
        return String(data: data, encoding: .utf8)?
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension QuboBulbManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        updateRadioState(for: central.state)
        if central.state == .poweredOn { beginScanIfPossible() }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
            ?? peripheral.name
            ?? ""
        guard let advertisement = QuboAdvertisement.parse(localName: localName) else { return }

        let hardwareID = advertisement.hardwareID
        peripheralsByHardwareID[hardwareID] = peripheral
        hardwareIDByPeripheralID[peripheral.identifier] = hardwareID
        peripheral.delegate = self

        if let index = bulbs.firstIndex(where: { $0.id == hardwareID }) {
            var bulb = bulbs[index]
            bulb.advertisement = advertisement
            bulb.rssi = RSSI.intValue
            bulb.lastSeen = Date()
            bulb.errorMessage = nil
            bulbs[index] = bulb
        } else {
            bulbs.append(QuboBulbSnapshot(
                advertisement: advertisement,
                rssi: RSSI.intValue,
                lastSeen: Date()
            ))
        }

        switch peripheral.state {
        case .connected:
            mutateBulb(hardwareID: hardwareID) { $0.connectionPhase = .reading }
            peripheral.discoverServices([quboService])
        case .connecting:
            mutateBulb(hardwareID: hardwareID) { $0.connectionPhase = .connecting }
        case .disconnected:
            guard !connectingPeripheralIDs.contains(peripheral.identifier) else { return }
            connectingPeripheralIDs.insert(peripheral.identifier)
            mutateBulb(hardwareID: hardwareID) { $0.connectionPhase = .connecting }
            central.connect(peripheral)
        case .disconnecting:
            mutateBulb(hardwareID: hardwareID) { $0.connectionPhase = .disconnected }
        @unknown default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectingPeripheralIDs.remove(peripheral.identifier)
        guard let hardwareID = hardwareIDByPeripheralID[peripheral.identifier] else { return }
        mutateBulb(hardwareID: hardwareID) {
            $0.connectionPhase = .reading
            $0.errorMessage = nil
        }
        peripheral.discoverServices([quboService])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        connectingPeripheralIDs.remove(peripheral.identifier)
        guard let hardwareID = hardwareIDByPeripheralID[peripheral.identifier] else { return }
        mutateBulb(hardwareID: hardwareID) {
            $0.connectionPhase = .failed
            $0.errorMessage = error?.localizedDescription ?? "Could not connect over Bluetooth."
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        connectingPeripheralIDs.remove(peripheral.identifier)
        guard let hardwareID = hardwareIDByPeripheralID[peripheral.identifier] else { return }
        mutateBulb(hardwareID: hardwareID) {
            $0.connectionPhase = error == nil ? .disconnected : .failed
            $0.errorMessage = error?.localizedDescription
        }
    }
}

extension QuboBulbManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let hardwareID = hardwareIDByPeripheralID[peripheral.identifier] else { return }
        if let error {
            mutateBulb(hardwareID: hardwareID) {
                $0.connectionPhase = .failed
                $0.errorMessage = error.localizedDescription
            }
            return
        }

        guard let service = peripheral.services?.first(where: { $0.uuid == quboService }) else {
            mutateBulb(hardwareID: hardwareID) {
                $0.connectionPhase = .failed
                $0.errorMessage = "The Qubo data service was not found."
            }
            return
        }

        peripheral.discoverCharacteristics(
            [modelCharacteristic, lightStateCharacteristic, deviceStateCharacteristic, mirroredStateCharacteristic],
            for: service
        )
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard let hardwareID = hardwareIDByPeripheralID[peripheral.identifier] else { return }
        if let error {
            mutateBulb(hardwareID: hardwareID) {
                $0.connectionPhase = .failed
                $0.errorMessage = error.localizedDescription
            }
            return
        }

        let characteristics = service.characteristics ?? []
        for characteristic in characteristics {
            if characteristic.properties.contains(.read) {
                peripheral.readValue(for: characteristic)
            }
            if characteristic.properties.contains(.notify) {
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }

        mutateBulb(hardwareID: hardwareID) { $0.connectionPhase = .ready }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard let hardwareID = hardwareIDByPeripheralID[peripheral.identifier] else { return }
        if let error {
            mutateBulb(hardwareID: hardwareID) { $0.errorMessage = error.localizedDescription }
            return
        }
        guard let value = text(from: characteristic) else { return }

        mutateBulb(hardwareID: hardwareID) { bulb in
            switch characteristic.uuid {
            case modelCharacteristic:
                bulb.model = value
            case lightStateCharacteristic:
                bulb.rawLightState = value
            case deviceStateCharacteristic:
                bulb.rawState = value
            case mirroredStateCharacteristic:
                if bulb.rawLightState == nil { bulb.rawLightState = value }
            default:
                break
            }
            bulb.connectionPhase = .ready
        }
    }
}
