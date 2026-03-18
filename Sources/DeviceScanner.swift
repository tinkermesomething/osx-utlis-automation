import Foundation
import IOKit
import IOKit.usb
import IOKit.hid
import IOBluetooth

// MARK: - Discovered devices

struct DiscoveredUSBDevice {
    let name:      String
    let vendorID:  Int
    let productID: Int
}

struct DiscoveredBluetoothDevice {
    let name:    String
    let address: String  // "XX:XX:XX:XX:XX:XX" — stable hardware ID
}

// MARK: - DeviceScanner

/// One-shot synchronous device enumeration for the user module wizard.
/// All methods are safe to call on the main thread — IOKit enumeration is fast.
enum DeviceScanner {

    // MARK: - USB

    /// Returns currently connected non-Apple USB devices (excludes hubs, internal devices).
    static func connectedUSBDevices() -> [DiscoveredUSBDevice] {
        var results: [DiscoveredUSBDevice] = []

        let matching = IOServiceMatching(kIOUSBHostDeviceClassName) as NSMutableDictionary
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == kIOReturnSuccess else {
            return results
        }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != IO_OBJECT_NULL {
            defer { IOObjectRelease(service); service = IOIteratorNext(iterator) }

            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == kIOReturnSuccess,
                  let dict = props?.takeRetainedValue() as? [String: Any] else { continue }

            guard let vendorID  = dict[kUSBVendorID]  as? Int,
                  let productID = dict[kUSBProductID] as? Int else { continue }

            // Skip Apple-internal devices (keyboards, trackpads, cameras, hubs)
            guard vendorID != 0x05AC else { continue }

            // kUSBProductString == "USB Product Name" — one lookup is sufficient
            let name = (dict[kUSBProductString] as? String) ?? "Unknown USB Device"

            results.append(DiscoveredUSBDevice(name: name, vendorID: vendorID, productID: productID))
        }

        // Deduplicate by VID+PID (same model connected twice shows once in picker)
        var seen = Set<String>()
        return results.filter { seen.insert("\($0.vendorID)-\($0.productID)").inserted }
    }

    // MARK: - Bluetooth

    /// Returns all paired Bluetooth devices (classic + LE).
    static func pairedBluetoothDevices() -> [DiscoveredBluetoothDevice] {
        guard let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else { return [] }
        return paired.compactMap { device in
            guard let address = device.addressString, !address.isEmpty else { return nil }
            let name = device.name ?? device.addressString ?? address
            return DiscoveredBluetoothDevice(name: name, address: address)
        }
    }

    // MARK: - Thunderbolt

    /// Thunderbolt device enumeration returns port-level IOPCIDevice entries only.
    /// No user-friendly device names are available via public API.
    /// The wizard skips the device picker for Thunderbolt — this method is reserved
    /// for future use when device-level naming becomes possible.
    static func connectedThunderboltDevices() -> [(registryID: UInt64, label: String)] {
        var results: [(UInt64, String)] = []

        let matching = IOServiceMatching("IOPCIDevice") as NSMutableDictionary
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == kIOReturnSuccess else {
            return results
        }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != IO_OBJECT_NULL {
            defer { IOObjectRelease(service); service = IOIteratorNext(iterator) }

            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == kIOReturnSuccess,
                  let dict = props?.takeRetainedValue() as? [String: Any] else { continue }

            // IOPCITunnelled = true marks Thunderbolt-connected PCIe endpoints
            guard dict["IOPCITunnelled"] as? Bool == true else { continue }

            var regID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &regID)
            let label = (dict["IOName"] as? String) ?? "Thunderbolt Device"
            results.append((regID, label))
        }

        return results
    }
}
