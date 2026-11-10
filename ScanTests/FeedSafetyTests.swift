import Foundation
import XCTest
@testable import Scan

/// Multifeed detection, the pre-scan sensor check and the decoding of
/// `GET HW STATUS`, driven through `FujitsuScriptedTransport`.
final class FeedSafetyTests: XCTestCase {
    private let identity = FujitsuCommandTranscriptTests.identity(productID: 0x132b)
    private let wrapperPrefix = "W 43" + String(repeating: "00", count: 0x12)

    private func makeDevice(_ transport: FujitsuScriptedTransport, feed: ScannerFeedSettings) -> FujitsuScanSnapDevice {
        let device = FujitsuScanSnapIX500Driver().makeDevice(identity: identity, transport: transport) as! FujitsuScanSnapDevice
        device.feedSettingsProvider = { _ in feed }
        return device
    }

    private func scan(_ device: FujitsuScanSnapDevice) async throws -> Int {
        var options = ScanOptions(acquisition: AcquisitionSettings(source: .adfFront, colorMode: .color, resolutionDPI: 300))
        options.export.jpegQuality = 0.82
        var pages = 0
        let stream = try await device.startScan(options: options)
        for try await _ in stream { pages += 1 }
        return pages
    }

    /// The payload written after the double-feed MODE SELECT (page 0x38).
    private func doubleFeedPayload(in transcript: [String]) -> String? {
        transcript.first { $0.hasPrefix("W 0000000038") }
    }

    func testUltrasonicDetectionEnablesThicknessSensing() async throws {
        let transport = FujitsuScriptedTransport(identity: identity, pixelWidth: 2550, pixelHeight: 8, sheets: 1)
        let device = makeDevice(transport, feed: ScannerFeedSettings(multifeedDetection: .ultrasonic))
        try await device.open()
        _ = try await scan(device)
        await device.close()
        XCTAssertEqual(doubleFeedPayload(in: transport.transcript), "W 000000003806900000000000")
    }

    func testEachMultifeedModeMapsToSANEBits() {
        XCTAssertEqual(MultifeedDetection.scannerDefault.modePageFlags, 0x00)
        XCTAssertEqual(MultifeedDetection.off.modePageFlags, 0x80)
        XCTAssertEqual(MultifeedDetection.ultrasonic.modePageFlags, 0x90)
        XCTAssertEqual(MultifeedDetection.length.modePageFlags, 0x88)
        XCTAssertEqual(MultifeedDetection.ultrasonicAndLength.modePageFlags, 0x98)
    }

    func testSensorCheckRefusesToFeedWithOpenCover() async throws {
        let transport = FujitsuScriptedTransport(identity: identity, pixelWidth: 2550, pixelHeight: 8, sheets: 1)
        transport.reportsCoverOpen = true
        let device = makeDevice(transport, feed: ScannerFeedSettings())
        try await device.open()
        do {
            _ = try await scan(device)
            XCTFail("An open cover must stop the scan")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("cover is open"), error.localizedDescription)
        }
        await device.close()
        XCTAssertFalse(transport.transcript.contains { $0.hasPrefix(wrapperPrefix + "3101") }, "No sheet may be fed")
    }

    func testSensorCheckReportsLeftoverErrorCode() async throws {
        let transport = FujitsuScriptedTransport(identity: identity, pixelWidth: 2550, pixelHeight: 8, sheets: 1)
        transport.reportedErrorCode = 0x55
        let device = makeDevice(transport, feed: ScannerFeedSettings())
        try await device.open()
        do {
            _ = try await scan(device)
            XCTFail("A pending error code must stop the scan")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("0x55"), error.localizedDescription)
        }
        await device.close()
    }

    func testSensorCheckCanBeTurnedOff() async throws {
        let transport = FujitsuScriptedTransport(identity: identity, pixelWidth: 2550, pixelHeight: 8, sheets: 1)
        transport.reportedErrorCode = 0x55
        let device = makeDevice(transport, feed: ScannerFeedSettings(checksSensorsBeforeScan: false))
        try await device.open()
        let pages = try await scan(device)
        await device.close()
        XCTAssertEqual(pages, 1)
    }

    func testHardwareStatusDecoding() {
        let clear = FujitsuHardwareStatus(bytes: [0, 0, 0, 0x00, 0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertTrue(clear.hopperHasPaper)
        XCTAssertNil(clear.blockingProblem)

        let jammed = FujitsuHardwareStatus(bytes: [0, 0, 0, 0x80, 0, 0, 0x01, 0x12, 0, 0, 0, 0])
        XCTAssertFalse(jammed.hopperHasPaper)
        XCTAssertTrue(jammed.doubleFeed)
        XCTAssertEqual(jammed.errorCode, 0x12)
        XCTAssertNotNil(jammed.blockingProblem)

        let short = FujitsuHardwareStatus(bytes: [0, 0])
        XCTAssertNil(short.blockingProblem)
    }

    func testFeedSettingsDefaultsAndDecodingOfOlderData() throws {
        let defaults = ScannerFeedSettings()
        XCTAssertEqual(defaults.multifeedDetection, .ultrasonic)
        XCTAssertTrue(defaults.checksSensorsBeforeScan)
        let decoded = try JSONDecoder().decode(ScannerFeedSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded, defaults)
    }
}
