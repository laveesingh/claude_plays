import Combine
import CoreBluetooth
import Foundation

/// A deliberately manual BLE client. Nothing scans or connects until the user
/// taps the matching control in the Bulbs tab.
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
            case .idle: return "Bluetooth idle"
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

    var hasActiveRead: Bool {
        bulbs.contains { $0.connectionPhase == .connecting || $0.connectionPhase == .reading }
    }

    private let quboService = CBUUID(string: "00DD")
    private let modelCharacteristic = CBUUID(string: "DD01")
    private let lightStateCharacteristic = CBUUID(string: "DD02")
    private let deviceStateCharacteristic = CBUUID(string: "DD03")
    private let mirroredStateCharacteristic = CBUUID(string: "DD04")

    private var central: CBCentralManager?
    private var scanRequested = false
    private var peripheralsByHardwareID: [String: CBPeripheral] = [:]
    private var hardwareIDByPeripheralID: [UUID: String] = [:]
    private var pendingReads: [UUID: Set<CBUUID>] = [:]
    private var readTimeouts: [UUID: DispatchWorkItem] = [:]

    func startScanning() {
        guard !isScanning, !hasActiveRead else { return }
        scanRequested = true

        if central == nil {
            radioState = .preparing
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
        scanRequested = false
        central?.stopScan()
        isScanning = false
    }

    func clearResults() {
        stopAllActivity()
        bulbs.removeAll()
        peripheralsByHardwareID.removeAll()
        hardwareIDByPeripheralID.removeAll()
    }

    func readDetails(for hardwareID: String) {
        guard !isScanning, !hasActiveRead,
              let central,
              let peripheral = peripheralsByHardwareID[hardwareID] else { return }

        peripheral.delegate = self
        hardwareIDByPeripheralID[peripheral.identifier] = hardwareID
        mutateBulb(hardwareID: hardwareID) {
            $0.connectionPhase = .connecting
            $0.errorMessage = nil
        }

        switch peripheral.state {
        case .connected:
            discoverDetails(on: peripheral)
        case .disconnected:
            central.connect(peripheral)
        case .connecting:
            break
        case .disconnecting:
            mutateBulb(hardwareID: hardwareID) {
                $0.connectionPhase = .failed
                $0.errorMessage = "The bulb is disconnecting. Try Read details again."
            }
        @unknown default:
            break
        }
    }

    func cancelRead(for hardwareID: String) {
        guard let peripheral = peripheralsByHardwareID[hardwareID] else { return }
        finishRead(on: peripheral, phase: .disconnected, error: nil)
    }

    /// Used only when leaving the page or clearing results. It prevents Sapiod
    /// from holding bulb connections while the utility is not visible.
    func stopAllActivity() {
        stopScanning()
        for workItem in readTimeouts.values { workItem.cancel() }
        readTimeouts.removeAll()
        pendingReads.removeAll()
        for (hardwareID, peripheral) in peripheralsByHardwareID where peripheral.state != .disconnected {
            mutateBulb(hardwareID: hardwareID) {
                $0.connectionPhase = .disconnected
                $0.errorMessage = nil
            }
            central?.cancelPeripheralConnection(peripheral)
        }
    }

    private func beginScanIfPossible() {
        guard scanRequested, let central else { return }
        guard central.state == .poweredOn else {
            updateRadioState(for: central.state)
            return
        }

        // One callback per peripheral per manual scan. Repeated RSSI broadcasts
        // must not drive continuous SwiftUI updates.
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        radioState = .ready
        isScanning = true
    }

    private func discoverDetails(on peripheral: CBPeripheral) {
        guard let hardwareID = hardwareIDByPeripheralID[peripheral.identifier] else { return }
        mutateBulb(hardwareID: hardwareID) { $0.connectionPhase = .reading }
        peripheral.discoverServices([quboService])
        scheduleReadTimeout(for: peripheral)
    }

    private func scheduleReadTimeout(for peripheral: CBPeripheral) {
        readTimeouts[peripheral.identifier]?.cancel()
        let workItem = DispatchWorkItem { [weak self, weak peripheral] in
            guard let self, let peripheral else { return }
            self.finishRead(
                on: peripheral,
                phase: .failed,
                error: "The bulb did not finish the read within 8 seconds."
            )
        }
        readTimeouts[peripheral.identifier] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: workItem)
    }

    private func finishRead(
        on peripheral: CBPeripheral,
        phase: QuboConnectionPhase,
        error: String?
    ) {
        readTimeouts.removeValue(forKey: peripheral.identifier)?.cancel()
        pendingReads.removeValue(forKey: peripheral.identifier)
        if let hardwareID = hardwareIDByPeripheralID[peripheral.identifier] {
            mutateBulb(hardwareID: hardwareID) {
                $0.connectionPhase = phase
                $0.errorMessage = error
            }
        }
        if peripheral.state != .disconnected {
            central?.cancelPeripheralConnection(peripheral)
        }
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
        if central.state == .poweredOn, scanRequested { beginScanIfPossible() }
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

        if let index = bulbs.firstIndex(where: { $0.id == hardwareID }) {
            var bulb = bulbs[index]
            bulb.advertisement = advertisement
            bulb.rssi = RSSI.intValue
            bulb.lastSeen = Date()
            bulbs[index] = bulb
        } else {
            bulbs.append(QuboBulbSnapshot(
                advertisement: advertisement,
                rssi: RSSI.intValue,
                lastSeen: Date()
            ))
            bulbs.sort { $0.id < $1.id }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        discoverDetails(on: peripheral)
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        finishRead(
            on: peripheral,
            phase: .failed,
            error: error?.localizedDescription ?? "Could not connect over Bluetooth."
        )
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        guard let error,
              let hardwareID = hardwareIDByPeripheralID[peripheral.identifier] else { return }
        mutateBulb(hardwareID: hardwareID) {
            $0.connectionPhase = .failed
            $0.errorMessage = error.localizedDescription
        }
    }
}

extension QuboBulbManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            finishRead(on: peripheral, phase: .failed, error: error.localizedDescription)
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == quboService }) else {
            finishRead(
                on: peripheral,
                phase: .failed,
                error: "The Qubo data service was not found."
            )
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
        if let error {
            finishRead(on: peripheral, phase: .failed, error: error.localizedDescription)
            return
        }

        let readable = (service.characteristics ?? []).filter { $0.properties.contains(.read) }
        guard !readable.isEmpty else {
            finishRead(on: peripheral, phase: .failed, error: "No readable Qubo details were found.")
            return
        }

        pendingReads[peripheral.identifier] = Set(readable.map(\.uuid))
        for characteristic in readable {
            peripheral.readValue(for: characteristic)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard let hardwareID = hardwareIDByPeripheralID[peripheral.identifier] else { return }
        if let error {
            finishRead(on: peripheral, phase: .failed, error: error.localizedDescription)
            return
        }

        if let value = text(from: characteristic) {
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
            }
        }

        pendingReads[peripheral.identifier]?.remove(characteristic.uuid)
        if pendingReads[peripheral.identifier]?.isEmpty == true {
            finishRead(on: peripheral, phase: .ready, error: nil)
        }
    }
}
