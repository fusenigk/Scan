import XCTest
@testable import Scan

extension ScanStatisticsStore {
    /// A store in a fresh temporary file, so tests never touch the app's history.
    static var temporaryForTests: ScanStatisticsStore {
        ScanStatisticsStore(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("ScanStatistics-\(UUID().uuidString).json"),
            defaults: UserDefaults(suiteName: "ScanStatisticsTests-\(UUID().uuidString)")!
        )
    }
}

/// History store and the figures of the Statistics topic.
final class ScanStatisticsTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        calendar.firstWeekday = 2
        return calendar
    }()

    private func date(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = calendar.timeZone
        return formatter.date(from: text + "T12:00:00+02:00")!
    }

    private let ix500 = "USB-0x04c5/0x132b-unknown-1245184"

    private var records: [ScanRecord] {
        [
            ScanRecord(date: date("2026-10-20"), scannerID: ix500, kind: .scan, pages: 4, blankPages: 1, duration: 20),
            ScanRecord(date: date("2026-10-20"), scannerID: ix500, kind: .export, pages: 3, files: 1, bytes: 3_000_000),
            ScanRecord(date: date("2026-10-19"), scannerID: ix500, kind: .scan, pages: 10, duration: 40),
            ScanRecord(date: date("2026-10-19"), scannerID: ix500, kind: .export, pages: 10, files: 2, bytes: 1_000_000),
            ScanRecord(date: date("2026-10-02"), scannerID: ix500, kind: .scan, pages: 2, duration: 10),
            ScanRecord(date: date("2026-03-15"), scannerID: ix500, kind: .scan, pages: 6, duration: 30),
            ScanRecord(date: date("2025-12-24"), scannerID: ix500, kind: .scan, pages: 1, duration: 5),
            ScanRecord(date: date("2026-10-20"), scannerID: ix500, kind: .scan, outcome: .failed),
            ScanRecord(date: date("2026-10-20"), scannerID: "USB-other", kind: .scan, pages: 50, duration: 60)
        ]
    }

    func testPeriodsCountScansPagesAndFilesPerScanner() {
        let stats = ScanStatistics(records: records, scannerID: ix500, now: date("2026-10-20"), calendar: calendar)
        XCTAssertEqual(stats.today, ScanStatistics.Period(scans: 1, pages: 4, files: 1))
        XCTAssertEqual(stats.thisWeek, ScanStatistics.Period(scans: 2, pages: 14, files: 3), "Monday 19 and Tuesday 20 October")
        XCTAssertEqual(stats.thisMonth, ScanStatistics.Period(scans: 3, pages: 16, files: 3))
        XCTAssertEqual(stats.thisYear, ScanStatistics.Period(scans: 4, pages: 22, files: 3))
        XCTAssertEqual(stats.total, ScanStatistics.Period(scans: 5, pages: 23, files: 3))
    }

    func testFurtherFigures() {
        let stats = ScanStatistics(records: records, scannerID: ix500, now: date("2026-10-20"), calendar: calendar)
        XCTAssertEqual(stats.failedScans, 1)
        XCTAssertEqual(stats.completedScans, 5)
        XCTAssertEqual(stats.blankPagesRemoved, 1)
        XCTAssertEqual(stats.largestScanPages, 10)
        XCTAssertEqual(stats.averagePagesPerScan ?? 0, 23.0 / 5.0, accuracy: 0.001)
        XCTAssertEqual(stats.pagesPerMinute ?? 0, 23.0 / (105.0 / 60.0), accuracy: 0.001)
        XCTAssertEqual(stats.bytesWritten, 4_000_000)
        XCTAssertEqual(stats.averageFileSize, 4_000_000 / 3)
        XCTAssertEqual(stats.busiestDay?.pages, 10)
        XCTAssertEqual(stats.pagesPerMonth.count, 12)
        XCTAssertEqual(stats.pagesPerMonth.last?.pages, 16)
        XCTAssertEqual(stats.pagesPerMonth.first?.pages, 0, "November 2025")
    }

    func testAllScannersIncludesEveryScanner() {
        let stats = ScanStatistics(records: records, scannerID: nil, now: date("2026-10-20"), calendar: calendar)
        XCTAssertEqual(stats.today.pages, 54)
    }

    func testStoreAppendsAndHonoursTheRecordingSwitch() {
        let store = ScanStatisticsStore.temporaryForTests
        defer { try? FileManager.default.removeItem(at: store.fileURL) }
        XCTAssertTrue(store.isRecording)
        store.append(records[0])
        XCTAssertEqual(store.load(), [records[0]])
        store.isRecording = false
        store.append(records[1])
        XCTAssertEqual(store.load().count, 1, "nothing is recorded while switched off")
    }
}

/// Geometry and shading of the GitHub-style activity grid.
final class ScanActivityLayoutTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        calendar.firstWeekday = 2
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }()

    private func day(_ month: Int, _ day: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: month, day: day))! }

    func testWeeksCoverTheYearStartingOnMonday() {
        let layout = ScanActivityLayout(year: 2026, pagesByDay: [:], calendar: calendar)
        XCTAssertTrue(layout.weeks.allSatisfy { $0.count == 7 })
        XCTAssertEqual(layout.weeks.flatMap { $0 }.compactMap { $0 }.count, 365)
        // 1 January 2026 is a Thursday: Monday to Wednesday of the first week are empty.
        XCTAssertNil(layout.weeks[0][2])
        XCTAssertEqual(layout.weeks[0][3], day(1, 1))
        XCTAssertEqual(layout.monthLabel(forWeek: 0), "Jan")
        XCTAssertEqual(layout.weekdaySymbol(0), "M")
    }

    func testLevelsSplitTheBusiestDayIntoQuarters() {
        let layout = ScanActivityLayout(year: 2026, pagesByDay: [day(10, 20): 100, day(10, 19): 10, day(3, 1): 0, calendar.date(from: DateComponents(year: 2025, month: 12, day: 24))!: 500], calendar: calendar)
        XCTAssertEqual(layout.totalPages, 110, "other years are ignored")
        XCTAssertEqual(layout.activeDays, 2)
        XCTAssertEqual(layout.level(for: 0), 0)
        XCTAssertEqual(layout.level(for: 10), 1)
        XCTAssertEqual(layout.level(for: 60), 3)
        XCTAssertEqual(layout.level(for: 100), 4)
    }
}
