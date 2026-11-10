// Test report: 2026-09-30_12-02_Scanner-Details-Dialog.md
import AppKit
import SwiftUI
import XCTest
@testable import Scan

@MainActor
final class ScannerDetailsViewTests: XCTestCase {
    private let s1500 = ScannerIdentity(name: "ScanSnap S1500", manufacturer: "Fujitsu", model: "ScanSnap S1500", serialNumber: "A1B2C3", connectionKind: .usb, usbDeviceID: USBDeviceID(vendorID: 0x04c5, productID: 0x11a2), locationID: 0x0120_0000)

    /// Presents the details sheet the way ContentView does and checks the
    /// user can resize it with the mouse.
    func testDetailsSheetIsResizable() async throws {
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 1000), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        let details = ScannerDriverRegistry.live.details(for: s1500)
        host.contentViewController = NSHostingController(rootView: Color.clear.frame(width: 1200, height: 1000).sheet(isPresented: .constant(true)) { ScannerDetailsView(details: details) })
        host.makeKeyAndOrderFront(nil)
        addTeardownBlock { @MainActor in host.attachedSheet.map { host.endSheet($0) }; host.close() }

        var sheet: NSWindow?
        for _ in 0..<50 where sheet == nil { try await Task.sleep(for: .milliseconds(100)); sheet = host.attachedSheet }
        let window = try XCTUnwrap(sheet, "The details sheet was not presented")
        XCTAssertTrue(window.styleMask.contains(.resizable), "Details sheet must be resizable with the mouse")
        XCTAssertLessThan(window.minSize.width, window.frame.width + 1)

        // Growing the sheet must be honoured rather than snapped back.
        let grown = NSSize(width: window.frame.width + 150, height: window.frame.height)
        window.setContentSize(grown)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(window.contentLayoutRect.width, grown.width, accuracy: 2)

        // Keep a rendering of the sheet for the test report.
        if let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("ScannerDetailsSheet.png"))
        }
    }
}
