import XCTest

/// 時刻表から「これから来る便」を選ぶ処理。
///
/// 本日分が尽きたら翌日の始発を出すが、**今日と同じダイヤ区分の表を使い回してはいけない**
/// （日曜→月曜のように区分が変わる）。翌日の区分は「乗車予定日のダイヤ」にあればそれを使い、
/// 無ければ曜日から推定する。推定のときは見出しで区分名を出す。
final class TimetableSelectionTests: XCTestCase {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TobusConfig.timeZone
        return calendar
    }

    private func date(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour, c.minute) = (2026, month, day, hour, minute)
        return calendar.date(from: c)!
    }

    /// 都０５－２の実際の値を模したもの（休日は 07:01 始発、平日は 06:50 始発）。
    /// 取得日を日曜にして、「本日は休日ダイヤ」がその日にだけ効くようにする。
    private let timetable = ParsedTimetable(
        tables: [
            "平日": [BusTime(hour: 6, minute: 50), BusTime(hour: 7, minute: 2), BusTime(hour: 20, minute: 0)],
            "土曜": [BusTime(hour: 6, minute: 30), BusTime(hour: 20, minute: 30)],
            "休日": [BusTime(hour: 7, minute: 1), BusTime(hour: 7, minute: 16), BusTime(hour: 21, minute: 0)],
        ],
        todayKind: "休日",
        fetchedOnDay: "2026-08-16"
    )

    // MARK: - 本日分が残っている場合

    func testReturnsRemainingTimesOfTodayKind() {
        // 2026-08-16 は日曜。ページの申告どおり休日ダイヤ。
        let result = timetable.upcoming(now: date(8, 16, 7, 5))
        XCTAssertEqual(result.dates, [date(8, 16, 7, 16), date(8, 16, 21, 0)])
        XCTAssertEqual(result.kind, "休日")
        XCTAssertFalse(result.isNextDay)
    }

    func testExcludesBusAtExactlyNow() {
        let result = timetable.upcoming(now: date(8, 16, 7, 16))
        XCTAssertEqual(result.dates, [date(8, 16, 21, 0)], "同時刻の便は既に発車している")
    }

    // MARK: - 本日分が尽きた場合（翌日のダイヤ区分に切り替える）

    /// 日曜の夜に見たら、翌日は月曜なので**平日ダイヤ**の始発を出す。
    /// 休日ダイヤの 07:01 をそのまま出すのが以前のバグだった。
    func testSwitchesToNextDayKindWhenTodayIsExhausted() {
        let result = timetable.upcoming(now: date(8, 16, 21, 30))
        XCTAssertEqual(result.kind, "平日")
        XCTAssertTrue(result.isNextDay)
        XCTAssertEqual(result.dates.first, date(8, 17, 6, 50), "月曜の始発は平日ダイヤの 06:50")
        XCTAssertNotEqual(result.dates.first, date(8, 17, 7, 1), "休日ダイヤを使い回してはいけない")
    }

    /// 金曜の夜なら翌日は土曜ダイヤ。
    func testUsesSaturdayKindOnFridayNight() {
        let result = timetable.upcoming(now: date(8, 14, 23, 30))
        XCTAssertEqual(result.kind, "土曜")
        XCTAssertEqual(result.dates.first, date(8, 15, 6, 30))
    }

    /// 土曜の夜なら翌日は休日ダイヤ。
    func testUsesHolidayKindOnSaturdayNight() {
        let result = timetable.upcoming(now: date(8, 15, 23, 30))
        XCTAssertEqual(result.kind, "休日")
        XCTAssertEqual(result.dates.first, date(8, 16, 7, 1))
    }

    /// 月をまたぐ場合も翌日として扱う。
    func testCrossesMonthBoundary() {
        let result = timetable.upcoming(now: date(8, 31, 23, 30)) // 月曜の夜 → 火曜
        XCTAssertEqual(result.dates.first, date(9, 1, 6, 50))
    }

    func testReturnsEmptyWhenNoTables() {
        let result = ParsedTimetable.empty.upcoming(now: date(8, 16, 12, 0))
        XCTAssertTrue(result.dates.isEmpty)
    }

    // MARK: - 取得日をまたいだあと（ウィジェットは通信せず保存済みの表を読む）

    /// 金曜に取った表の `todayKind` は平日のまま。土曜朝にそれを今日へ適用してはいけない。
    func testDoesNotKeepWeekdayKindOnSaturdayAfterFridayFetch() {
        let friday = ParsedTimetable(
            tables: timetable.tables,
            todayKind: "平日",
            fetchedOnDay: "2026-08-28",
            upcomingKinds: ["2026-08-29": "土曜", "2026-08-30": "休日"]
        )
        let result = friday.upcoming(now: date(8, 29, 6, 0))
        XCTAssertEqual(result.kind, "土曜")
        XCTAssertFalse(result.isNextDay)
        XCTAssertEqual(result.dates.first, date(8, 29, 6, 30))
        XCTAssertNotEqual(result.kind, "平日", "金曜の本日申告を土曜に残してはいけない")
    }

    /// 乗車予定日の表が無い古い保存でも、取得日が過ぎていれば曜日から推定する。
    func testEstimatesKindWhenFetchDayHasPassedAndForecastIsMissing() {
        let friday = ParsedTimetable(
            tables: timetable.tables,
            todayKind: "平日",
            fetchedOnDay: "2026-08-28"
        )
        let result = friday.upcoming(now: date(8, 29, 6, 0))
        XCTAssertEqual(result.kind, "土曜")
        XCTAssertFalse(result.isNextDay)
    }

    /// 取得日も乗車予定日も無い古い JSON。todayKind を今日に適用すると金曜の平日が残るので、
    /// 曜日推定する（見出しに区分名が出る）。
    func testLegacyJSONWithoutFetchDayDoesNotKeepWeekdayKindOnSaturday() {
        let legacy = ParsedTimetable(tables: timetable.tables, todayKind: "平日")
        let result = legacy.upcoming(now: date(8, 29, 6, 0))
        XCTAssertEqual(result.kind, "土曜", "取得日不明の平日申告を土曜に適用しない")
        XCTAssertFalse(result.isNextDay)
    }

    /// 土曜に取った表を日曜朝に読む。todayKind は土曜のままなので、乗車予定日の申告を使う。
    func testDoesNotKeepSaturdayKindOnSundayAfterSaturdayFetch() {
        let saturday = ParsedTimetable(
            tables: timetable.tables,
            todayKind: "土曜",
            fetchedOnDay: "2026-08-29",
            upcomingKinds: ["2026-08-30": "休日"]
        )
        let result = saturday.upcoming(now: date(8, 30, 13, 0))
        XCTAssertEqual(result.kind, "休日")
        XCTAssertFalse(result.isNextDay)
        XCTAssertEqual(result.dates.first, date(8, 30, 21, 0))
        XCTAssertNotEqual(result.kind, "土曜", "土曜の本日申告を日曜に残してはいけない")
    }

    /// お盆の金曜。推定なら翌日は土曜ダイヤだが、ページは休日と申告している。
    func testFridayNightUsesForecastKindNotWeekdayEstimate() {
        let friday = ParsedTimetable(
            tables: timetable.tables,
            todayKind: "平日",
            fetchedOnDay: "2026-08-14",
            upcomingKinds: ["2026-08-15": "休日"]
        )
        let result = friday.upcoming(now: date(8, 14, 23, 30))
        XCTAssertEqual(result.kind, "休日", "推定の土曜ダイヤよりページの申告を使う")
        XCTAssertTrue(result.isNextDay)
        XCTAssertEqual(result.dates.first, date(8, 15, 7, 1))
    }

    // MARK: - 深夜便

    /// 24時を超える表記（25:10）は翌日の 01:10 として扱う。
    func testHandlesAfterMidnightNotation() {
        let lateNight = ParsedTimetable(
            tables: ["休日": [BusTime(hour: 25, minute: 10)]],
            todayKind: "休日",
            fetchedOnDay: "2026-08-16"
        )
        let result = lateNight.upcoming(now: date(8, 16, 20, 0))
        XCTAssertEqual(result.dates, [date(8, 17, 1, 10)])
        XCTAssertFalse(result.isNextDay, "本日のダイヤの便なので翌日扱いにはしない")
    }
}

/// ダイヤ区分の推定と見出し。
final class ScheduleKindTests: XCTestCase {

    private func date(_ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TobusConfig.timeZone
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour) = (2026, month, day, 12)
        return calendar.date(from: c)!
    }

    func testEstimatesKindFromWeekday() {
        XCTAssertEqual(TobusConfig.estimatedScheduleKind(on: date(8, 17)), "平日", "月曜")
        XCTAssertEqual(TobusConfig.estimatedScheduleKind(on: date(8, 21)), "平日", "金曜")
        XCTAssertEqual(TobusConfig.estimatedScheduleKind(on: date(8, 22)), "土曜")
        XCTAssertEqual(TobusConfig.estimatedScheduleKind(on: date(8, 23)), "休日", "日曜")
        XCTAssertEqual(TobusConfig.calendarDayString(from: date(8, 29)), "2026-08-29")
    }

    func testStartOfNextCalendarDayIsMidnightJST() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TobusConfig.timeZone
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour, c.minute) = (2026, 8, 29, 15, 30)
        let saturdayAfternoon = calendar.date(from: c)!
        let next = TobusConfig.startOfNextCalendarDay(after: saturdayAfternoon)
        XCTAssertEqual(TobusConfig.calendarDayString(from: next!), "2026-08-30")
        XCTAssertEqual(calendar.component(.hour, from: next!), 0)
        XCTAssertEqual(calendar.component(.minute, from: next!), 0)
    }

    /// 本日分は tobus.jp の申告どおり、翌日分は推定と分かる見出しにする。
    func testHeadingDistinguishesNextDay() {
        XCTAssertEqual(TobusConfig.scheduleHeading(kind: "休日"), "定刻（休日ダイヤ）")
        XCTAssertEqual(TobusConfig.scheduleHeading(kind: "平日", isNextDay: true), "翌 平日ダイヤ")
        XCTAssertEqual(TobusConfig.scheduleHeading(kind: nil), "定刻")
        XCTAssertEqual(TobusConfig.scheduleHeading(kind: "", isNextDay: true), "翌日の定刻")
    }
}
