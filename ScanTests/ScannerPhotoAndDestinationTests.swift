// Test report: 2026-09-30_12-02_Scanner-Details-Dialog.md
import AppKit
import XCTest
@testable import Scan

@MainActor
final class ScannerPhotoAndDestinationTests: XCTestCase {
    private func usbIdentity(_ productID: UInt16) -> ScannerIdentity {
        ScannerIdentity(name: "Scanner", manufacturer: "Fujitsu", model: "Scanner", serialNumber: nil, connectionKind: .usb, usbDeviceID: USBDeviceID(vendorID: 0x04c5, productID: productID), locationID: nil)
    }

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ScanTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func isolatedDefaults() -> UserDefaults {
        let suite = "ScanTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return UserDefaults(suiteName: suite)!
    }

    // MARK: Photo catalog

    func testBundledPhotosExistForS1500AndIX500Family() {
        XCTAssertEqual(ScannerPhotoCatalog.bundledPhoto(for: usbIdentity(0x11a2))?.caption, "ScanSnap S1500")
        XCTAssertEqual(ScannerPhotoCatalog.bundledPhoto(for: usbIdentity(0x132b))?.caption, "ScanSnap iX500")
        XCTAssertEqual(ScannerPhotoCatalog.bundledPhoto(for: usbIdentity(0x13f3))?.caption, "ScanSnap iX500", "iX500EE shares the iX500 housing")
        XCTAssertNil(ScannerPhotoCatalog.bundledPhoto(for: usbIdentity(0x1632)), "No freely licensed iX1600 photo is bundled")
    }

    func testEveryBundledPhotoIsInTheAssetCatalogAndCredited() {
        for photo in ScannerPhotoCatalog.bundled.values {
            XCTAssertNotNil(NSImage(named: photo.assetName), photo.assetName)
            XCTAssertFalse(photo.credit.isEmpty)
            XCTAssertTrue(photo.license.hasPrefix("CC BY"), photo.license)
            XCTAssertEqual(photo.sourceURL.host(), "commons.wikimedia.org")
        }
    }

    func testPhotoKeyIsPerModelForUSBAndSanitizedOtherwise() {
        XCTAssertEqual(ScannerPhotoCatalog.photoKey(for: usbIdentity(0x11a2)), "usb-04c5-11a2")
        let imageCapture = ScannerIdentity(name: "Canon", manufacturer: "Canon", model: "LiDE", serialNumber: nil, connectionKind: .imageCapture, usbDeviceID: nil, locationID: nil, persistentID: "A/B C")
        let key = ScannerPhotoCatalog.photoKey(for: imageCapture)
        XCTAssertTrue(key.hasPrefix("device-"))
        XCTAssertFalse(key.contains("/")); XCTAssertFalse(key.contains(" "))
    }

    func testCustomPhotoCanBeStoredAndRemoved() throws {
        let folder = try temporaryFolder()
        let store = ScannerPhotoStore(folder: folder.appendingPathComponent("Photos"))
        let identity = usbIdentity(0x1632)
        XCTAssertNil(store.customPhoto(for: identity))

        let image = NSImage(size: NSSize(width: 4, height: 3), flipped: false) { rect in NSColor.red.setFill(); rect.fill(); return true }
        let source = folder.appendingPathComponent("photo.png")
        try NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: source)

        try store.setCustomPhoto(from: source, for: identity)
        try FileManager.default.removeItem(at: source)
        XCTAssertNotNil(store.customPhoto(for: identity), "The photo is copied, so the original may vanish")
        store.removeCustomPhoto(for: identity)
        XCTAssertNil(store.customPhoto(for: identity))
    }

    func testCustomPhotoRejectsNonImages() throws {
        let folder = try temporaryFolder()
        let source = folder.appendingPathComponent("notes.txt")
        try Data("not an image".utf8).write(to: source)
        XCTAssertThrowsError(try ScannerPhotoStore(folder: folder).setCustomPhoto(from: source, for: usbIdentity(0x1632)))
    }

    // MARK: Destination folder

    func testDestinationSurvivesAReloadFromDefaults() throws {
        let defaults = isolatedDefaults()
        let folder = try temporaryFolder()
        try DestinationFolderStore(defaults: defaults).save(folder)

        // A fresh store stands in for the next app launch.
        let restored = try XCTUnwrap(DestinationFolderStore(defaults: defaults).restore())
        XCTAssertEqual(restored.standardizedFileURL.resolvingSymlinksInPath(), folder.standardizedFileURL.resolvingSymlinksInPath())
        XCTAssertEqual(DestinationFolderStore(defaults: defaults).savedPath, folder.path)
    }

    func testDestinationResetFallsBackToNothingSaved() throws {
        let defaults = isolatedDefaults()
        let store = DestinationFolderStore(defaults: defaults)
        try store.save(try temporaryFolder())
        store.reset()
        XCTAssertNil(store.restore())
        XCTAssertNil(store.savedPath)
    }

    func testDefaultDestinationIsScansInDocuments() {
        XCTAssertEqual(DestinationFolderStore.defaultFolder.lastPathComponent, "Scans")
        XCTAssertEqual(DestinationFolderStore.defaultFolder.deletingLastPathComponent(), FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0])
    }
}
