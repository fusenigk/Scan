// Test report: 2026-09-30_12-02_Scanner-Details-Dialog.md
import XCTest
@testable import Scan

@MainActor
final class ScannerDetailsTests: XCTestCase {
    private let s1500 = ScannerIdentity(name: "ScanSnap S1500", manufacturer: "Fujitsu", model: "ScanSnap S1500", serialNumber: "A1B2C3", connectionKind: .usb, usbDeviceID: USBDeviceID(vendorID: 0x04c5, productID: 0x11a2), locationID: 0x0120_0000)

    private func section(_ title: String, in details: ScannerDetails) -> ScannerDetailSection? { details.sections.first { $0.title == title } }
    private func value(_ label: String, in section: ScannerDetailSection?) -> String? { section?.rows.first { $0.label == label }?.value }

    func testIdentitySectionListsUSBIdentifiers() {
        let identity = section("Identity", in: ScannerDetails(identity: s1500))
        XCTAssertEqual(value("Serial Number", in: identity), "A1B2C3")
        XCTAssertEqual(value("USB Vendor ID", in: identity), "0x04c5")
        XCTAssertEqual(value("USB Product ID", in: identity), "0x11a2")
        XCTAssertEqual(value("USB Location ID", in: identity), "0x01200000")
        XCTAssertEqual(value("Scan Identifier", in: identity), s1500.id)
    }

    func testMissingSerialNumberIsShownAsDash() {
        let identity = ScannerIdentity(name: "Scanner", manufacturer: "Acme", model: "X", serialNumber: "", connectionKind: .imageCapture, usbDeviceID: nil, locationID: nil, persistentID: "P-1")
        let rows = section("Identity", in: ScannerDetails(identity: identity))
        XCTAssertEqual(value("Serial Number", in: rows), "—")
        XCTAssertEqual(value("Persistent ID", in: rows), "P-1")
        XCTAssertNil(value("USB Vendor ID", in: rows))
    }

    func testUnsupportedScannerOnlyShowsIdentityAndDriver() {
        let details = ScannerDetails(identity: s1500)
        XCTAssertEqual(details.sections.map(\.title), ["Identity", "Driver"])
        XCTAssertEqual(value("Driver", in: section("Driver", in: details)), "No driver – discovered, unsupported")
    }

    func testCapabilitiesAndFeaturesAreRendered() {
        let capabilities = ScannerCapabilities(sources: [.flatbed, .adfFront], colorModes: [.color, .gray], resolutionsDPI: [600, 150, 300], resolutionsBySource: [.adfFront: [150, 300]], outputFormats: [.pdf, .png], scanArea: .init(width: 8.5, height: 14, unit: "in"), supportsDuplex: false, supportsScannerBuffering: true)
        let details = ScannerDetails(identity: s1500, driverName: "Test", capabilities: capabilities)
        let caps = section("Capabilities", in: details)
        XCTAssertEqual(value("Sources", in: caps), "Flatbed, ADF Front")
        XCTAssertEqual(value("Resolutions", in: caps), "150, 300, 600 dpi")
        XCTAssertEqual(value("Resolutions (ADF Front)", in: caps), "150, 300 dpi")
        XCTAssertNil(value("Resolutions (Flatbed)", in: caps))
        XCTAssertEqual(value("Output Formats", in: caps), "PDF, PNG")
        XCTAssertEqual(value("Scan Area", in: caps)?.hasSuffix(" in"), true)
        let features = section("Features", in: details)
        XCTAssertEqual(value("Duplex", in: features), "No")
        XCTAssertEqual(value("Scanner Buffering", in: features), "Yes")
        XCTAssertNil(value("Deskew", in: features), "software processing is not a scanner feature")
    }

    func testUnsupportedReasonAppearsAsLimitation() {
        let capabilities = ScannerCapabilities(sources: [], colorModes: [], resolutionsDPI: [], supportsDuplex: false, unsupportedReason: "Firmware missing")
        let details = ScannerDetails(identity: s1500, driverName: "Test", capabilities: capabilities)
        XCTAssertEqual(value("Limitation", in: section("Driver", in: details)), "Firmware missing")
        XCTAssertEqual(value("Sources", in: section("Capabilities", in: details)), "—")
    }

    func testRegistryDetailsForLiveS1500Driver() throws {
        let details = ScannerDriverRegistry.live.details(for: s1500)
        XCTAssertEqual(details.driverName, FujitsuScanSnapS1500Driver().name)
        XCTAssertEqual(details.modelProfileName, FujitsuScanSnapModelProfile.s1500.name)
        XCTAssertEqual(details.capabilities, FujitsuScanSnapModelProfile.s1500.capabilities)
        let button = try XCTUnwrap(section("Hardware Button", in: details))
        XCTAssertEqual(value("Scan Button", in: button), FujitsuScanSnapModelProfile.s1500.hardwareButtonSupport.label)
    }

    func testRegistryDetailsForUnknownDeviceHaveNoDriver() {
        let unknown = ScannerIdentity(name: "Mystery", manufacturer: "Fujitsu", model: "Mystery", serialNumber: nil, connectionKind: .usb, usbDeviceID: USBDeviceID(vendorID: 0x04c5, productID: 0xffff), locationID: nil)
        let details = ScannerDriverRegistry.live.details(for: unknown, usbRegistryProperties: ["bcdDevice": "256 (0x100)"])
        XCTAssertNil(details.driverName)
        XCTAssertNil(details.capabilities)
        XCTAssertEqual(details.sections.map(\.title), ["Identity", "Driver", "USB Registry"])
    }

    func testUSBRegistrySectionIsSortedNaturally() {
        let details = ScannerDetails(identity: s1500, usbRegistryProperties: ["idVendor": "1", "USB Product Name": "S1500", "bcdDevice": "2"])
        XCTAssertEqual(section("USB Registry", in: details)?.rows.map(\.label), ["bcdDevice", "idVendor", "USB Product Name"])
    }

    func testRegistryScalarRenderingSkipsCollections() {
        let rendered = USBDeviceEnumerator.renderScalarProperties([
            "USB Product Name": "ScanSnap S1500",
            "idVendor": NSNumber(value: 1221),
            "Built-In": kCFBooleanTrue as Any,
            "IOCFPlugInTypes": ["a": "b"]
        ])
        XCTAssertEqual(rendered["USB Product Name"], "ScanSnap S1500")
        XCTAssertEqual(rendered["idVendor"], "1221 (0x4c5)")
        XCTAssertEqual(rendered["Built-In"], "Yes")
        XCTAssertNil(rendered["IOCFPlugInTypes"])
    }

    func testPlainTextContainsEverySection() {
        let details = ScannerDriverRegistry.live.details(for: s1500)
        let text = details.plainText
        XCTAssertTrue(text.hasPrefix("ScanSnap S1500\n"))
        for section in details.sections { XCTAssertTrue(text.contains("[\(section.title)]"), section.title) }
        XCTAssertTrue(text.contains("Serial Number: A1B2C3"))
    }

    func testDetailsIdentifierMatchesScanner() {
        XCTAssertEqual(ScannerDetails(identity: s1500).id, s1500.id)
    }
}
