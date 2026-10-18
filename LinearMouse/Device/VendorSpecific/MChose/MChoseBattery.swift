// MIT License
// Copyright (c) 2021-2026 LinearMouse

import Foundation
import IOKit.hid

/// Reads the battery level of MCHOSE mice through their vendor configuration
/// interface. The protocol is documented by https://github.com/alexfrih/mchose-linux.
///
/// Requests and replies are feature reports. Every byte after the report ID is
/// inverted (XOR 0xFF). Reply byte 1 echoes the command so it can be matched.
enum MChoseBattery {
    static let vendorIDs: Set<Int> = [0x3837, 0x5253]
    static let configurationUsagePage = 0xFF0B

    private static let shortReportID: UInt8 = 0x11
    private static let shortReportLength = 21
    private static let statusCommand: UInt8 = 0x06
    private static let connectedFlag: UInt8 = 0b0000_1000

    struct Status: Equatable {
        let vendorID: Int
        let productID: Int
        let isConnected: Bool
        let batteryLevel: Int
        let isCharging: Bool
    }

    /// The A7X Ultra reports a value at offset 9 that never changes; its live
    /// battery level sits at offset 11. Other models use offset 9 as documented.
    private static let a7xUltraProductID = 0x4011

    private static func batteryOffset(productID: Int) -> Int {
        productID == a7xUltraProductID ? 11 : 9
    }

    static func isConfigurationInterface(vendorID: Int?, primaryUsagePage: Int?) -> Bool {
        guard let vendorID, let primaryUsagePage else {
            return false
        }
        return vendorIDs.contains(vendorID) && primaryUsagePage == configurationUsagePage
    }

    static func statusRequest() -> [UInt8] {
        var request = [UInt8](repeating: 0xFF, count: shortReportLength)
        request[0] = shortReportID
        request[1] = statusCommand ^ 0xFF
        return request
    }

    /// Parses a raw `0x11 0x06` reply. Returns nil for replies to other commands
    /// and for the empty frames the dongle sends before the mouse has answered.
    static func parseStatus(_ report: [UInt8]) -> Status? {
        guard report.count >= 14,
              report[0] == shortReportID,
              report[1] == statusCommand ^ 0xFF else {
            return nil
        }
        let payload = report[2...].map { $0 ^ 0xFF }
        let vendorID = Int(payload[0]) | Int(payload[1]) << 8
        guard vendorID != 0 else {
            return nil
        }
        let productID = Int(payload[2]) | Int(payload[3]) << 8
        let batteryLevel = Int(payload[batteryOffset(productID: productID)])
        guard (0 ... 100).contains(batteryLevel) else {
            return nil
        }
        return Status(
            vendorID: vendorID,
            productID: productID,
            isConnected: payload[8] & connectedFlag != 0,
            batteryLevel: batteryLevel,
            isCharging: payload[10] != 0
        )
    }

    /// The dongle stops relaying requests while the mouse sleeps, so the last
    /// reading is kept for as long as the dongle itself stays connected.
    private static let lastKnownLevelsLock = NSLock()
    private static var lastKnownLevels = [UInt64: Int]()

    /// Blocks while the dongle relays the request to the mouse. Call off the main thread.
    static func batteryLevel(from device: IOHIDDevice) -> Int? {
        var entryID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &entryID) == KERN_SUCCESS else {
            return readBatteryLevel(from: device)
        }

        let level = readBatteryLevel(from: device)
        lastKnownLevelsLock.lock()
        defer { lastKnownLevelsLock.unlock() }
        if let level {
            lastKnownLevels[entryID] = level
            return level
        }
        return lastKnownLevels[entryID]
    }

    /// Forgets readings from dongles that are no longer connected.
    static func retainLastKnownLevels(for devices: Set<IOHIDDevice>) {
        let entryIDs = Set(devices.compactMap { device -> UInt64? in
            var entryID: UInt64 = 0
            return IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &entryID) == KERN_SUCCESS
                ? entryID : nil
        })
        lastKnownLevelsLock.lock()
        defer { lastKnownLevelsLock.unlock() }
        lastKnownLevels = lastKnownLevels.filter { entryIDs.contains($0.key) }
    }

    private static func readBatteryLevel(from device: IOHIDDevice) -> Int? {
        guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            return nil
        }
        defer {
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }

        for _ in 0 ..< 3 {
            let request = statusRequest()
            guard IOHIDDeviceSetReport(
                device,
                kIOHIDReportTypeFeature,
                CFIndex(shortReportID),
                request,
                request.count
            ) == kIOReturnSuccess else {
                return nil
            }

            // The dongle answers with an empty frame until the mouse replies,
            // which takes roughly 100 ms over 2.4 GHz.
            for _ in 0 ..< 6 {
                Thread.sleep(forTimeInterval: 0.05)
                var report = [UInt8](repeating: 0, count: shortReportLength)
                var length = CFIndex(report.count)
                guard IOHIDDeviceGetReport(
                    device,
                    kIOHIDReportTypeFeature,
                    CFIndex(shortReportID),
                    &report,
                    &length
                ) == kIOReturnSuccess else {
                    continue
                }
                if let status = parseStatus(Array(report.prefix(length))) {
                    return status.isConnected ? status.batteryLevel : nil
                }
            }
        }

        return nil
    }
}
