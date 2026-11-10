import AppKit
import CoreText
import XCTest
@testable import Scan

/// AI page orientation (`TextOrientationDetector`) and the post-scan
/// progress steps shown in place of the Scan button.
final class TextOrientationTests: XCTestCase {
    func testReadingAngleMapsToTheRotationThatUndoesIt() {
        XCTAssertEqual(TextOrientationDetector.correction(forReadingAngle: 0), 0)
        XCTAssertEqual(TextOrientationDetector.correction(forReadingAngle: 3), 0)
        XCTAssertEqual(TextOrientationDetector.correction(forReadingAngle: 90), 270)
        XCTAssertEqual(TextOrientationDetector.correction(forReadingAngle: 178), 180)
        XCTAssertEqual(TextOrientationDetector.correction(forReadingAngle: -180), 180)
        XCTAssertEqual(TextOrientationDetector.correction(forReadingAngle: -90), 90)
    }

    func testBestRotationNeedsEnoughTextAndAClearMajority() {
        XCTAssertEqual(TextOrientationDetector.bestRotation(votes: [180: 300, 0: 20]), 180)
        XCTAssertNil(TextOrientationDetector.bestRotation(votes: [0: 5]), "too little text")
        XCTAssertNil(TextOrientationDetector.bestRotation(votes: [0: 100, 90: 90]), "no majority")
        XCTAssertNil(TextOrientationDetector.bestRotation(votes: [:]))
    }

    /// A rendered text page, turned by each candidate rotation, is turned
    /// back upright by the detector's answer.
    func testDetectorUndoesEachRotationOfATextPage() throws {
        let page = try XCTUnwrap(Self.textPage())
        for applied in [0, 90, 180, 270] {
            let input = try XCTUnwrap(ScanImageProcessor.rotate(page, degrees: applied))
            let fix = try XCTUnwrap(TextOrientationDetector.uprightRotation(for: input), "applied \(applied)")
            XCTAssertEqual((applied + fix) % 360, 0, "applied \(applied), detector \(fix)")
        }
    }

    func testABlankPageIsLeftToTheLandscapeRule() throws {
        let width = 850, height = 1100
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(.white); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        XCTAssertNil(TextOrientationDetector.uprightRotation(for: try XCTUnwrap(context.makeImage())))
    }

    func testOlderProfilesDecodeWithAIOrientationOff() throws {
        let decoded = try JSONDecoder().decode(ImageProcessingSettings.self, from: Data(#"{"autoRotate":true}"#.utf8))
        XCTAssertTrue(decoded.autoRotate)
        XCTAssertFalse(decoded.aiOrientation)
    }

    func testExportStepsBecomeProgressDescriptions() {
        let start = Date()
        let reading = PostScanActivity.step(.readingText(page: 2, of: 3), startedAt: start)
        XCTAssertEqual(reading.detail, "Page 2 of 3 · Vision OCR")
        XCTAssertEqual(reading.fraction ?? -1, 1.0 / 3.0, accuracy: 0.001)
        XCTAssertNil(PostScanActivity.step(.proposingName, startedAt: start).fraction, "the model reports no progress")
        XCTAssertEqual(PostScanActivity.step(.writingPage(page: 1, of: 4, recognizingText: true), startedAt: start).title, "Recognizing text (OCR)")
        XCTAssertNil(PostScanActivity.ocrmypdf(file: 1, of: 1, name: "a.pdf", language: "German", startedAt: start).fraction)
        XCTAssertEqual(PostScanActivity.ocrmypdf(file: 2, of: 2, name: "b.pdf", language: "German", startedAt: start).fraction, 0.5)
    }

    /// A letter-sized page with several lines of large black text.
    private static func textPage() -> CGImage? {
        let width = 1275, height = 1650
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(.white); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica" as CFString, 44, nil)
        let lines = ["Rechnung Nummer 2026-1042", "Telekom Deutschland GmbH", "Bitte überweisen Sie den Betrag", "bis zum 31. Oktober 2026 auf das", "unten genannte Konto. Vielen Dank.", "Mit freundlichen Grüßen"]
        for (index, line) in lines.enumerated() {
            let attributed = CFAttributedStringCreate(nil, line as CFString, [kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor.black] as CFDictionary)!
            context.textPosition = CGPoint(x: 100, y: height - 200 - index * 110)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }
        return context.makeImage()
    }
}
