import CoreBluetooth
import Foundation

/// Alerts the user once a connected Bluetooth accessory's battery drops to
/// 5% or below. Opt-in and OFF by default — starting CoreBluetooth triggers
/// a real system permission prompt, and nothing should ask for that
/// permission on behalf of a feature the user hasn't actually turned on.
///
/// Scoped to what iOS actually lets a third-party app read: the standard
/// BLE "Battery Service" (0x180F) GATT characteristic. That covers many
/// generic/fitness-tracker-style BLE earbuds, but NOT Apple's own
/// accessories — AirPods and Beats report battery through a private Apple
/// protocol that is never exposed to third-party apps — and not a classic-
/// Bluetooth-only headphone with no BLE battery service at all. There is no
/// public, App-Store-safe API that covers every Bluetooth headphone; this
/// is the best available without one.
@MainActor
final class BluetoothBatteryMonitorService: NSObject, ObservableObject {
    static let shared = BluetoothBatteryMonitorService()

    private static let enabledKey = "bluetoothBatteryMonitor.enabled"
    private static let lowBatteryThreshold = 5

    @Published var isEnabled: Bool = UserDefaults.standard.bool(forKey: BluetoothBatteryMonitorService.enabledKey) {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            isEnabled ? start() : stop()
        }
    }

    private var centralManager: CBCentralManager?
    private var monitoredPeripherals: [UUID: CBPeripheral] = [:]
    /// Peripherals already alerted on at-or-below `lowBatteryThreshold`, so a
    /// device sitting at (say) 3% doesn't re-trigger a toast on every single
    /// GATT notify tick — only once per low-battery period, clearing once it
    /// reads back above the threshold (a recharge) or disconnects.
    private var alertedBelowThreshold: Set<UUID> = []

    private static let batteryServiceUUID = CBUUID(string: "180F")
    private static let batteryLevelCharacteristicUUID = CBUUID(string: "2A19")

    private override init() {
        super.init()
    }

    func start() {
        guard isEnabled, centralManager == nil else { return }
        // Delivers delegate callbacks on the main queue, matching this
        // class's own @MainActor isolation.
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    func stop() {
        for peripheral in monitoredPeripherals.values {
            centralManager?.cancelPeripheralConnection(peripheral)
        }
        monitoredPeripherals.removeAll()
        alertedBelowThreshold.removeAll()
        centralManager = nil
    }

    /// Already-connected accessories only — no active scan, since by the
    /// time this runs the device is already paired/connected (for its own
    /// audio profile, if nothing else). Avoids the Location-permission
    /// implications an active `scanForPeripherals` call can carry on older
    /// iOS versions, and finds the device immediately rather than waiting
    /// on an advertisement to arrive.
    private func checkExistingConnections() {
        guard let centralManager, centralManager.state == .poweredOn else { return }
        let connected = centralManager.retrieveConnectedPeripherals(withServices: [Self.batteryServiceUUID])
        for peripheral in connected where monitoredPeripherals[peripheral.identifier] == nil {
            monitoredPeripherals[peripheral.identifier] = peripheral
            peripheral.delegate = self
            centralManager.connect(peripheral, options: nil)
        }
    }

    private func handleBatteryLevel(_ level: Int, for peripheral: CBPeripheral) {
        if level <= Self.lowBatteryThreshold {
            guard !alertedBelowThreshold.contains(peripheral.identifier) else { return }
            alertedBelowThreshold.insert(peripheral.identifier)
            let name = peripheral.name ?? "Your Bluetooth device"
            ToastCenter.shared.show(
                "\(name) is at \(level)% battery",
                category: .warning,
                icon: "battery.25",
                duration: 5
            )
        } else {
            alertedBelowThreshold.remove(peripheral.identifier)
        }
    }
}

extension BluetoothBatteryMonitorService: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            checkExistingConnections()
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.batteryServiceUUID])
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        monitoredPeripherals.removeValue(forKey: peripheral.identifier)
        alertedBelowThreshold.remove(peripheral.identifier)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        monitoredPeripherals.removeValue(forKey: peripheral.identifier)
    }
}

extension BluetoothBatteryMonitorService: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services where service.uuid == Self.batteryServiceUUID {
            peripheral.discoverCharacteristics([Self.batteryLevelCharacteristicUUID], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics else { return }
        for characteristic in characteristics where characteristic.uuid == Self.batteryLevelCharacteristicUUID {
            // Battery Level supports both read and (on most accessories)
            // notify — subscribe for live updates, and read once immediately
            // so a device already sitting at a low level is caught right
            // away rather than waiting for its next spontaneous notify.
            peripheral.setNotifyValue(true, for: characteristic)
            peripheral.readValue(for: characteristic)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.batteryLevelCharacteristicUUID,
              let data = characteristic.value, let level = data.first
        else { return }
        // Battery Level is defined as a single unsigned byte, 0-100.
        handleBatteryLevel(Int(level), for: peripheral)
    }
}
