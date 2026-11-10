// Test report: 2026-10-08_21-05_ocrmypdf-nicht-gefunden-App-Sandbox-Testreport.md
import XCTest
@testable import Scan

/// The Release build is sandboxed, and the sandbox hides Homebrew's prefix
/// unless Scan.entitlements names it. These tests read the entitlements file
/// from the source tree, since the unit tests themselves run unsandboxed.
final class SandboxEntitlementsTests: XCTestCase {
    private static let readOnlyExceptionKey = "com.apple.security.temporary-exception.files.absolute-path.read-only"
    /// Readable inside the App Sandbox without any exception.
    private static let systemDirectories = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    private func entitlements(file: StaticString = #filePath) throws -> [String: Any] {
        let url = URL(fileURLWithPath: "\(file)").deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Scan/Scan.entitlements")
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        return try XCTUnwrap(plist as? [String: Any])
    }

    func testAppSandboxStaysEnabled() throws {
        XCTAssertEqual(try entitlements()["com.apple.security.app-sandbox"] as? Bool, true)
    }

    func testEverySearchDirectoryIsReadableInTheSandbox() throws {
        let exceptions = try XCTUnwrap(try entitlements()[Self.readOnlyExceptionKey] as? [String], "no read-only exception in Scan.entitlements")
        for directory in OCRmyPDFRunner.searchDirectories where !Self.systemDirectories.contains(directory) {
            XCTAssertTrue(exceptions.contains { directory.hasPrefix($0) }, "\(directory) is searched for ocrmypdf but the sandbox cannot read it")
        }
    }

    /// `bin/ocrmypdf` is a symlink into the Cellar and starts a Python from
    /// there, so the exception has to cover the whole prefix, not just `bin`.
    func testExceptionsCoverWholePrefixes() throws {
        let exceptions = try XCTUnwrap(try entitlements()[Self.readOnlyExceptionKey] as? [String])
        XCTAssertTrue(exceptions.contains("/opt/homebrew/"), "\(exceptions)")
        XCTAssertTrue(exceptions.allSatisfy { $0.hasSuffix("/") }, "directory exceptions need a trailing slash: \(exceptions)")
        XCTAssertFalse(exceptions.contains { $0.hasSuffix("/bin/") }, "\(exceptions)")
    }

    func testExceptionsAreReadOnly() throws {
        let keys = try entitlements().keys
        XCTAssertFalse(keys.contains("com.apple.security.temporary-exception.files.absolute-path.read-write"))
        XCTAssertFalse(keys.contains("com.apple.security.temporary-exception.files.home-relative-path.read-write"))
    }
}
