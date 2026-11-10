import AppKit
import XCTest
@testable import Scan

/// Records the text it is asked about and answers with a fixed name.
private final class StubNameSuggester: DocumentNameSuggesting, @unchecked Sendable {
    var reply: String?
    private(set) var texts: [String] = []
    init(reply: String?) { self.reply = reply }
    func suggestName(forText text: String) async -> String? { texts.append(text); return reply }
}

@MainActor
final class DocumentNameTests: XCTestCase {
    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("NameTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func isolatedDefaults() -> UserDefaults {
        let suite = "NameTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return UserDefaults(suiteName: suite)!
    }

    /// A scanned page showing `lines` as an image.
    private func frame(lines: [String], pageIndex: Int = 1) throws -> PageFrame {
        let size = NSSize(width: 1240, height: 1754)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.white.setFill(); rect.fill()
            for (index, line) in lines.enumerated() {
                (line as NSString).draw(at: NSPoint(x: 80, y: 1600 - CGFloat(index) * 90), withAttributes: [.font: NSFont.systemFont(ofSize: 48), .foregroundColor: NSColor.black])
            }
            return true
        }
        let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let data = try XCTUnwrap(NSBitmapImageRep(cgImage: cgImage).representation(using: .jpeg, properties: [.compressionFactor: 0.9]))
        return PageFrame(pageIndex: pageIndex, side: .front, pixelFormat: .jpeg, width: cgImage.width, height: cgImage.height, resolutionDPI: 150, data: data)
    }

    private func options(template: String, mode: ScanExportMode = .combinedPDF) -> ScanOptions {
        ScanOptions(export: ExportSettings(outputFormat: .pdf, sizePreset: .custom, outputDPI: 150, exportMode: mode, filenameTemplate: template))
    }

    // MARK: Template

    func testDefaultTemplateIsDateTimeName() {
        XCTAssertEqual(ExportSettings().filenameTemplate, "{date}-{time}-{name}")
    }

    func testNameTokenIsFilledFromRecognizedText() async throws {
        let stub = StubNameSuggester(reply: "Telekom Rechnung Oktober")
        let result = try await ScanOutputWriter(nameSuggester: stub).write(frames: [try frame(lines: ["Telekom Deutschland GmbH", "Rechnung Oktober 2026"])], options: options(template: "{date}-{time}-{name}"), destinationFolder: try temporaryFolder(), ocrLanguage: .german)
        let name = result.outputURLs[0].deletingPathExtension().lastPathComponent
        XCTAssertNotNil(name.wholeMatch(of: /\d{4}-\d{2}-\d{2}-\d{2}-\d{2}-\d{2}-Telekom Rechnung Oktober/), name)
        XCTAssertEqual(stub.texts.count, 1, "one proposal per batch")
        XCTAssertTrue(stub.texts[0].contains("Telekom"), "the suggester sees the OCR text: \(stub.texts[0])")
        XCTAssertTrue(stub.texts[0].contains("Rechnung"), stub.texts[0])
    }

    func testTemplateWithoutNameTokenNeverAsksTheModel() async throws {
        let stub = StubNameSuggester(reply: "Unused")
        let result = try await ScanOutputWriter(nameSuggester: stub).write(frames: [try frame(lines: ["Hallo"])], options: options(template: "Scan-{date}-{page}"), destinationFolder: try temporaryFolder())
        XCTAssertTrue(stub.texts.isEmpty)
        XCTAssertTrue(result.outputURLs[0].lastPathComponent.hasSuffix("-batch.pdf"), result.outputURLs[0].lastPathComponent)
    }

    func testMissingProposalFallsBackToScan() async throws {
        let folder = try temporaryFolder()
        for writer in [ScanOutputWriter(nameSuggester: StubNameSuggester(reply: nil)), ScanOutputWriter(nameSuggester: nil)] {
            let result = try await writer.write(frames: [try frame(lines: ["Hallo"])], options: options(template: "X-{name}"), destinationFolder: folder)
            XCTAssertTrue(result.outputURLs[0].lastPathComponent.hasPrefix("X-Scan"), result.outputURLs[0].lastPathComponent)
        }
    }

    func testSeparateFilesShareTheBatchNameAndStayUnique() async throws {
        let stub = StubNameSuggester(reply: "Vertrag")
        let frames = [try frame(lines: ["Vertrag Seite 1"], pageIndex: 1), try frame(lines: ["Vertrag Seite 2"], pageIndex: 2)]
        let result = try await ScanOutputWriter(nameSuggester: stub).write(frames: frames, options: options(template: "{name}", mode: .separateFiles), destinationFolder: try temporaryFolder())
        XCTAssertEqual(result.outputURLs.map(\.lastPathComponent), ["Vertrag.pdf", "Vertrag-2.pdf"])
        XCTAssertEqual(stub.texts.count, 1)
    }

    // MARK: Cleaning the model's reply

    func testSanitizeStripsDecorationAndUnsafeCharacters() {
        XCTAssertEqual(DocumentName.sanitize("Rechnung_Oktober_2026"), "Rechnung Oktober 2026")
        XCTAssertEqual(DocumentName.sanitize("\"Telekom Rechnung.pdf\"\n\nDas ist ein guter Name."), "Telekom Rechnung")
        XCTAssertEqual(DocumentName.sanitize("Dateiname: Finanzamt / Mahnung: Umsatzsteuer"), "Finanzamt Mahnung Umsatzsteuer")
        XCTAssertEqual(DocumentName.sanitize("  „ERGO   Wohngebäudeversicherung“. "), "ERGO Wohngebäudeversicherung")
        XCTAssertNil(DocumentName.sanitize(" \n \"\" "))
    }

    func testSanitizeLimitsLengthAtAWordBoundary() throws {
        let name = try XCTUnwrap(DocumentName.sanitize(Array(repeating: "Wohngebäudeversicherung", count: 8).joined(separator: " ")))
        XCTAssertLessThanOrEqual(name.count, DocumentName.maximumLength)
        XCTAssertTrue(name.hasSuffix("Wohngebäudeversicherung"), "no word is cut in half: \(name)")
    }

    func testExcerptDropsEmptyLinesAndIsCapped() {
        XCTAssertEqual(DocumentName.excerpt("  Zeile 1 \n\n\n Zeile 2\n"), "Zeile 1\nZeile 2")
        XCTAssertEqual(DocumentName.excerpt(String(repeating: "a", count: 5000)).count, 2000)
        XCTAssertEqual(DocumentName.excerpt(" \n "), "")
    }

    // MARK: Saved profiles

    func testSavedProfilesOnThePreviousDefaultMoveToTheNewOneOnce() {
        let defaults = isolatedDefaults()
        var old = ScanProfile(name: "Old", options: ScanOptions()); old.options.export.filenameTemplate = "Scan-{date}-{page}"
        var custom = ScanProfile(name: "Custom", options: ScanOptions()); custom.options.export.filenameTemplate = "Beleg-{date}"
        ScanProfileStore(defaults: defaults).save([old, custom])

        XCTAssertEqual(ScanProfileStore(defaults: defaults).load().map(\.options.export.filenameTemplate), ["{date}-{time}-{name}", "Beleg-{date}"])

        // Going back to the old template afterwards is the user's choice and is kept.
        ScanProfileStore(defaults: defaults).save([old, custom])
        XCTAssertEqual(ScanProfileStore(defaults: defaults).load().map(\.options.export.filenameTemplate), ["Scan-{date}-{page}", "Beleg-{date}"])
    }

    // MARK: On-device model

    /// End-to-end with Apple Intelligence on this Mac; nothing is sent anywhere.
    func testOnDeviceModelProposesAUsableName() async throws {
        if let reason = FoundationModelNameSuggester.unavailableReason { throw XCTSkip(reason) }
        let text = "Telekom Deutschland GmbH\nLandgrabenweg 151, 53227 Bonn\nMobilfunk-Rechnung\nRechnungsnummer 123456789\nKundennummer 4711\nRechnungsmonat Oktober 2026\nRechnungsbetrag 39,95 EUR"
        let proposal = await FoundationModelNameSuggester().suggestName(forText: text)
        let name = try XCTUnwrap(proposal)
        print("On-device model proposed: \(name)")
        XCTAssertLessThanOrEqual(name.count, DocumentName.maximumLength)
        XCTAssertNil(name.rangeOfCharacter(from: CharacterSet(charactersIn: "/:\\?%*|\"<>_\n")), name)
        XCTAssertTrue(name.localizedCaseInsensitiveContains("Rechnung") || name.localizedCaseInsensitiveContains("Telekom"), name)
    }

    func testOnDeviceModelIsNotAskedAboutEmptyText() async {
        let name = await FoundationModelNameSuggester().suggestName(forText: " \n ")
        XCTAssertNil(name)
    }
}
