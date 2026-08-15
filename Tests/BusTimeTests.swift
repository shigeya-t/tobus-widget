import XCTest

/// 時刻表（時刻のみ）から「これから来る便」を絶対時刻へ変換する処理。
/// アプリとウィジェット拡張の双方が同じ並びを出す必要があるため `BusTime.upcoming` に集約している。
final class BusTimeTests: XCTestCase {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TobusConfig.timeZone
        return calendar
    }

    private func date(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return calendar.date(from: components)!
    }

    private let timetable = [
        BusTime(hour: 6, minute: 40),
        BusTime(hour: 12, minute: 0),
        BusTime(hour: 23, minute: 50),
    ]

    /// 現在時刻より後の便だけを、時刻順に返す。
    func testReturnsOnlyRemainingBusesToday() {
        let now = date(8, 15, 10, 0)
        let result = BusTime.upcoming(from: timetable, now: now)
        XCTAssertEqual(result, [date(8, 15, 12, 0), date(8, 15, 23, 50)])
    }

    /// 本日分が尽きていれば翌日分に切り替える（深夜に見たとき空にならないように）。
    func testFallsBackToTomorrowWhenTodayIsExhausted() {
        let now = date(8, 15, 23, 55)
        let result = BusTime.upcoming(from: timetable, now: now)
        XCTAssertEqual(result, [date(8, 16, 6, 40), date(8, 16, 12, 0), date(8, 16, 23, 50)])
    }

    /// 月をまたぐ場合も翌日として扱えること。
    func testFallsBackAcrossMonthBoundary() {
        let now = date(8, 31, 23, 55)
        let result = BusTime.upcoming(from: timetable, now: now)
        XCTAssertEqual(result.first, date(9, 1, 6, 40))
    }

    /// ちょうど同時刻の便は「これから来る」に含めない（既に発車しているため）。
    func testExcludesBusAtExactlyNow() {
        let now = date(8, 15, 12, 0)
        let result = BusTime.upcoming(from: timetable, now: now)
        XCTAssertEqual(result, [date(8, 15, 23, 50)])
    }

    /// 深夜便は24時を超える表記（25:10 など）で返るため、翌日へ繰り上げる。
    func testHandlesAfterMidnightNotation() {
        let lateNight = [BusTime(hour: 25, minute: 10)]
        let result = BusTime.upcoming(from: lateNight, now: date(8, 15, 20, 0))
        XCTAssertEqual(result, [date(8, 16, 1, 10)], "25:10 は翌日の 01:10")
    }

    func testReturnsEmptyForEmptyTimetable() {
        XCTAssertEqual(BusTime.upcoming(from: [], now: date(8, 15, 10, 0)), [])
    }
}
