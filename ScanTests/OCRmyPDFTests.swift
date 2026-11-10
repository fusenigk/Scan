// Test report: 2026-09-30_12-14_OCR-Sprache-und-ocrmypdf.md
import AppKit
import PDFKit
import XCTest
@testable import Scan

@MainActor
final class OCRmyPDFTests: XCTestCase {
    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("OCRTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func isolatedDefaults() -> UserDefaults {
        let suite = "OCRTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return UserDefaults(suiteName: suite)!
    }

    /// Writes an executable shell script named `ocrmypdf` that stands in for the real tool.
    private func fakeOCRmyPDF(in folder: URL, body: String) throws -> OCRmyPDFRunner {
        let url = folder.appendingPathComponent("ocrmypdf")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return OCRmyPDFRunner(executableURL: url)
    }

    /// A one-page PDF showing `text` as an image, i.e. without a text layer.
    private func imagePDF(text: String, at url: URL) throws {
        let image = NSImage(size: NSSize(width: 1240, height: 400), flipped: false) { rect in
            NSColor.white.setFill(); rect.fill()
            (text as NSString).draw(at: NSPoint(x: 60, y: 160), withAttributes: [.font: NSFont.systemFont(ofSize: 72, weight: .regular), .foregroundColor: NSColor.black])
            return true
        }
        let document = PDFDocument()
        document.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
        XCTAssertTrue(document.write(to: url))
    }

    // MARK: Settings

    func testDefaultsAreGermanWithOCREnabled() {
        let settings = OCRSettingsStore(defaults: isolatedDefaults()).load()
        XCTAssertEqual(settings.language, .german)
        XCTAssertTrue(settings.runOCRmyPDF)
    }

    func testSettingsSurviveReload() {
        let defaults = isolatedDefaults()
        OCRSettingsStore(defaults: defaults).save(OCRSettings(language: .polish, runOCRmyPDF: false))
        XCTAssertEqual(OCRSettingsStore(defaults: defaults).load(), OCRSettings(language: .polish, runOCRmyPDF: false))
    }

    func testLanguageCodesForBothEngines() {
        XCTAssertEqual(OCRLanguage.german.tesseractCode, "deu")
        XCTAssertEqual(OCRLanguage.german.visionCode, "de-DE")
        XCTAssertEqual(OCRLanguage.english.tesseractCode, "eng")
        XCTAssertEqual(Set(OCRLanguage.allCases.map(\.tesseractCode)).count, OCRLanguage.allCases.count, "codes are unique")
    }

    // MARK: Runner

    func testArgumentsUseTesseractLanguageAndSkipExistingText() {
        let args = OCRmyPDFRunner.arguments(input: URL(fileURLWithPath: "/tmp/in.pdf"), output: URL(fileURLWithPath: "/tmp/out.pdf"), language: .german)
        XCTAssertEqual(args, ["--language", "deu", "--skip-text", "--output-type", "pdf", "/tmp/in.pdf", "/tmp/out.pdf"])
    }

    func testLocateFindsExecutableInGivenDirectoryOrPath() throws {
        let folder = try temporaryFolder()
        XCTAssertNil(OCRmyPDFRunner.locate(in: [folder.path], environment: [:]))
        _ = try fakeOCRmyPDF(in: folder, body: "exit 0")
        XCTAssertEqual(OCRmyPDFRunner.locate(in: [folder.path], environment: [:])?.executableURL.path, folder.appendingPathComponent("ocrmypdf").path)
        XCTAssertNotNil(OCRmyPDFRunner.locate(in: [], environment: ["PATH": "/nonexistent:\(folder.path)"]), "falls back to PATH")
    }

    func testChildEnvironmentPutsHomebrewOnPath() {
        let runner = OCRmyPDFRunner(executableURL: URL(fileURLWithPath: "/custom/bin/ocrmypdf"))
        let path = runner.environment(base: ["PATH": "/usr/bin", "HOME": "/Users/x"])["PATH"] ?? ""
        XCTAssertTrue(path.hasPrefix("/custom/bin:"))
        XCTAssertTrue(path.contains("/opt/homebrew/bin"))
        XCTAssertEqual(runner.environment(base: ["HOME": "/Users/x"])["HOME"], "/Users/x")
    }

    func testProcessReplacesPDFOnSuccessAndIgnoresOtherFiles() async throws {
        let folder = try temporaryFolder()
        let argsLog = folder.appendingPathComponent("args.txt")
        // Copy the input with a marker appended, the way ocrmypdf writes its output.
        let runner = try fakeOCRmyPDF(in: folder, body: "echo \"$@\" > '\(argsLog.path)'\nfor last; do :; done\neval in=\\${$(($#-1))}\ncat \"$in\" > \"$last\"; printf OCR >> \"$last\"")
        let pdf = folder.appendingPathComponent("Scan.pdf"); try Data("PDF".utf8).write(to: pdf)
        let jpeg = folder.appendingPathComponent("Scan.jpg"); try Data("JPG".utf8).write(to: jpeg)

        let processed = try await runner.process([pdf, jpeg], language: .german)

        XCTAssertEqual(processed, [pdf])
        XCTAssertEqual(try String(contentsOf: pdf, encoding: .utf8), "PDFOCR")
        XCTAssertEqual(try String(contentsOf: jpeg, encoding: .utf8), "JPG")
        XCTAssertTrue(try String(contentsOf: argsLog, encoding: .utf8).hasPrefix("--language deu --skip-text"))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.contains("-ocr-") }
        XCTAssertTrue(leftovers.isEmpty, "temporary output is cleaned up")
    }

    func testFailureKeepsOriginalAndReportsStderr() async throws {
        let folder = try temporaryFolder()
        let runner = try fakeOCRmyPDF(in: folder, body: "echo 'MissingDependencyError: tesseract' >&2\nexit 3")
        let pdf = folder.appendingPathComponent("Scan.pdf"); try Data("PDF".utf8).write(to: pdf)

        do {
            try await runner.process([pdf], language: .german)
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("MissingDependencyError"), error.localizedDescription)
        }
        XCTAssertEqual(try String(contentsOf: pdf, encoding: .utf8), "PDF")
    }

    /// End-to-end with the installed ocrmypdf: an image-only PDF gains a German text layer.
    func testRealOCRmyPDFAddsTextLayer() async throws {
        guard let runner = OCRmyPDFRunner.locate() else { throw XCTSkip("ocrmypdf is not installed") }
        let pdf = try temporaryFolder().appendingPathComponent("Rechnung.pdf")
        try imagePDF(text: "Rechnung Größe", at: pdf)
        XCTAssertEqual(PDFDocument(url: pdf)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "", "", "starts without text")

        try await runner.process([pdf], language: .german)

        let text = try XCTUnwrap(PDFDocument(url: pdf)?.string)
        XCTAssertTrue(text.contains("Rechnung"), text)
        XCTAssertTrue(text.contains("Größe"), "German umlauts need the deu model: \(text)")
    }
}
