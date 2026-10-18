// MIT License
// Copyright (c) 2021-2026 LinearMouse

@testable import LinearMouse
import XCTest

final class MChoseBatteryTests: XCTestCase {
    /// A reply captured from an A7X Ultra on its 2.4 GHz dongle at 98 %.
    private let a7xUltraReply: [UInt8] = [
        0x11, 0xF9, 0xC8, 0xC7, 0xEE, 0xBF, 0xE1, 0xFA, 0xFC, 0xFF, 0xF6, 0xA4, 0xFF, 0x9D,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF
    ]

    func testParsesStatusReply() {
        XCTAssertEqual(
            MChoseBattery.parseStatus(a7xUltraReply),
            .init(vendorID: 0x3837, productID: 0x4011, isConnected: true, batteryLevel: 98, isCharging: false)
        )
    }

    func testOtherModelsReadBatteryAtDocumentedOffset() {
        var reply = a7xUltraReply
        reply[4] = 0x20 ^ 0xFF
        reply[5] = 0x10 ^ 0xFF
        XCTAssertEqual(MChoseBattery.parseStatus(reply)?.batteryLevel, 91)
    }

    func testIgnoresEmptyFrameBeforeMouseAnswers() {
        var reply = [UInt8](repeating: 0xFF, count: 21)
        reply[0] = 0x11
        reply[1] = 0xF9
        XCTAssertNil(MChoseBattery.parseStatus(reply))
    }

    func testIgnoresRepliesToOtherCommands() {
        var reply = a7xUltraReply
        reply[1] = 0x03 ^ 0xFF
        XCTAssertNil(MChoseBattery.parseStatus(reply))
        XCTAssertNil(MChoseBattery.parseStatus(Array(a7xUltraReply.prefix(8))))
    }

    func testStatusRequestIsInverted() {
        let request = MChoseBattery.statusRequest()
        XCTAssertEqual(request.count, 21)
        XCTAssertEqual(Array(request.prefix(3)), [0x11, 0xF9, 0xFF])
    }

    func testMatchesConfigurationInterfaceOnly() {
        XCTAssertTrue(MChoseBattery.isConfigurationInterface(vendorID: 0x3837, primaryUsagePage: 0xFF0B))
        XCTAssertTrue(MChoseBattery.isConfigurationInterface(vendorID: 0x5253, primaryUsagePage: 0xFF0B))
        XCTAssertFalse(MChoseBattery.isConfigurationInterface(vendorID: 0x3837, primaryUsagePage: 0x01))
        XCTAssertFalse(MChoseBattery.isConfigurationInterface(vendorID: 0x046D, primaryUsagePage: 0xFF0B))
    }
}
