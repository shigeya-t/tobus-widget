import XCTest

/// 時刻表の2段階フェッチ（行き先選択ページ → 時刻表ページ）の入口の判定。
///
/// tobus.jp は**行き先が1つしかない系統では行き先選択を挟まず、時刻表そのものを返す**。
/// このときページに `func_stoppole` が無いため、2段階目に進めない。
/// かつて `parseStoppoleParams` が nil のとき空配列を返していて、
/// 該当系統（勝どき橋南詰の業１０など）の定刻が黙って出ないままになっていた。
///
/// フィクスチャはいずれも勝どき橋南詰（slst=325）で 2026-08-14〜15 に取得したもの。
/// `timetable_direct_gyo10.html` が**休日ダイヤ**を申告しているのは、
/// 取得日が土曜だったうえに**お盆の週**で、多くの系統が休日ダイヤで運行していたため
/// （同じ停留所でも系統ごとに区分は異なり、325#1 は土曜ダイヤだった）。
/// テストはHTMLに埋め込まれた申告を読むだけなので実行日には依存しないが、
/// 期待値の「休日」を暦から導けるものと誤解しないこと。
final class TimetableParsingTests: XCTestCase {

    private func date(_ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TobusConfig.timeZone
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour) = (2026, month, day, 12)
        return calendar.date(from: c)!
    }

    private func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: name, withExtension: "html"),
            "フィクスチャ \(name).html がテストバンドルに入っていません"
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - 行き先が複数ある系統（2段階フェッチ）

    /// 都０５－１（RTMCD=184）は行き先選択ページが返り、2段階目のパラメータが取れる。
    func testParsesStoppoleParamsFromDestinationSelectPage() throws {
        let params = try XCTUnwrap(
            TobusPageParser.parseStoppoleParams(html: try fixture("destination_select_to05"))
        )
        XCTAssertEqual(params.rtmcd, 184)
        XCTAssertEqual(params.slst, 325)
        XCTAssertEqual(params.pl, 1)
        XCTAssertEqual(params.lrid, 2)
        XCTAssertEqual(params.tgo, 2)
    }

    // MARK: - 行き先が1つの系統（時刻表が直接返る）

    /// 業１０（RTMCD=40）は行き先選択を挟まないため `func_stoppole` が無い。
    /// ここで諦めると定刻が永遠に取れない。
    func testDestinationSelectIsSkippedForSingleDestinationRoute() throws {
        XCTAssertNil(
            TobusPageParser.parseStoppoleParams(html: try fixture("timetable_direct_gyo10")),
            "行き先選択を挟まない系統では func_stoppole は現れない"
        )
    }

    /// その同じHTMLは、時刻表としてはそのまま読める。
    /// `BusScheduleService` はこれを頼りにフォールバックしている。
    func testSameHTMLParsesDirectlyAsTimetable() throws {
        let parsed = try TobusPageParser.parseTimetable(html: try fixture("timetable_direct_gyo10"))
        let times = parsed.todayTimes
        XCTAssertFalse(times.isEmpty, "業１０の定刻が取れていない")
        XCTAssertEqual(times, times.sorted(), "時刻順に並んでいる")

        let hours = Set(times.map(\.hour))
        XCTAssertTrue(hours.allSatisfy { (0...29).contains($0) }, "時が範囲外: \(hours.sorted())")
        XCTAssertTrue(times.allSatisfy { (0...59).contains($0.minute) }, "分が範囲外")
        XCTAssertTrue(
            times.contains(BusTime(hour: 20, minute: 16, mark: "ﾛ")),
            "行き先記号付き（ﾛ16）の便も読む。落とすと終バスが空になり翌日ダイヤへ誤切替する"
        )
        XCTAssertEqual(
            parsed.legend.map(\.caption),
            ["【無印】新橋行", "【ﾛ】銀座六丁目経由新橋行"],
            "ページの記号説明を凡例として保持する"
        )
    }

    /// ページ自身の「本日は〇曜ダイヤ」の申告に従って表を選ぶ（こちらで祝日判定はしない）。
    /// フィクスチャは休日ダイヤと申告しているので、平日の表とは異なる結果になるはず。
    func testUsesScheduleTableDeclaredByPage() throws {
        let html = try fixture("timetable_direct_gyo10")
        let fetchedAt = date(8, 16)
        let parsed = try TobusPageParser.parseTimetable(html: html, now: fetchedAt)

        XCTAssertTrue(html.contains("getElementById('休日')"), "フィクスチャは休日ダイヤを申告している")
        XCTAssertEqual(parsed.todayKind, "休日", "ページの申告どおりの区分を返す")
        XCTAssertEqual(parsed.fetchedOnDay, "2026-08-16")
        XCTAssertFalse(parsed.todayTimes.isEmpty)
        XCTAssertEqual(
            Set(parsed.tables.keys), ["平日", "土曜", "休日"],
            "翌日分を出すために3区分すべて保持する"
        )
        XCTAssertNotEqual(
            parsed.tables["平日"], parsed.tables["休日"],
            "区分ごとに別の時刻表であること（使い回すと翌日の始発を誤る）"
        )
        XCTAssertEqual(parsed.upcomingKinds["2026-08-16"], "休日")
        XCTAssertEqual(parsed.upcomingKinds["2026-08-17"], "平日")
        XCTAssertEqual(parsed.upcomingKinds["2026-08-22"], "土曜")
        XCTAssertEqual(parsed.upcomingKinds.count, 7)
    }

    /// 実ページ（土曜）と同じく、乗車予定日の一覧が翌日始まりでも読める。
    func testParsesUpcomingKindsStartingTheNextDay() throws {
        let html = """
        <p>本日は、<a onclick="document.getElementById('土曜').scrollIntoView();">土曜ダイヤ</a>で運行しております。</p>
        <div id="dianame">
          <table><tr>
            <td id="td_0">8/30(日)</td><td>:</td>
            <td><a onclick="document.getElementById('休日').scrollIntoView();">休日ダイヤ</a></td>
          </tr></table>
          <table><tr>
            <td id="td_1">8/31(月)</td><td>:</td>
            <td><a onclick="document.getElementById('平日').scrollIntoView();">平日ダイヤ</a></td>
          </tr></table>
        </div>
        <table id="土曜"><tr><th>6</th><td>30</td></tr></table>
        """
        let parsed = try TobusPageParser.parseTimetable(html: html, now: date(8, 29))
        XCTAssertEqual(parsed.todayKind, "土曜")
        XCTAssertEqual(parsed.fetchedOnDay, "2026-08-29")
        XCTAssertNil(parsed.upcomingKinds["2026-08-29"], "本日は乗車予定日一覧に含まれない")
        XCTAssertEqual(parsed.upcomingKinds["2026-08-30"], "休日")
        XCTAssertEqual(parsed.upcomingKinds["2026-08-31"], "平日")
    }

    /// 年をまたぐ乗車予定日（12/31 取得で 1/1）は翌年にする。
    func testUpcomingKindAcrossNewYearUsesNextYear() throws {
        let html = """
        <p>本日は、<a onclick="document.getElementById('平日').scrollIntoView();">平日ダイヤ</a>で運行しております。</p>
        <div id="dianame">
          <table><tr>
            <td id="td_0">1/1(金)</td><td>:</td>
            <td><a onclick="document.getElementById('休日').scrollIntoView();">休日ダイヤ</a></td>
          </tr></table>
        </div>
        <table id="平日"><tr><th>6</th><td>00</td></tr></table>
        """
        let parsed = try TobusPageParser.parseTimetable(html: html, now: date(12, 31))
        XCTAssertEqual(parsed.upcomingKinds["2027-01-01"], "休日")
        XCTAssertNil(parsed.upcomingKinds["2026-01-01"])
    }

    /// 時刻表として読めないページ（HTTP 200 で返るエラーページなど）は、表が空の結果になる。
    /// この「表が空」がキャッシュ・保存をスキップする判定条件になっているので固定しておく。
    /// 空をキャッシュすると日付が変わるまで、空を保存すると次の成功まで定刻が消える。
    func testUnparsablePageYieldsEmptyTables() throws {
        let notATimetable = "<html><body><h1>ただいまアクセスが集中しています</h1></body></html>"
        let parsed = try TobusPageParser.parseTimetable(html: notATimetable)
        XCTAssertTrue(parsed.tables.isEmpty)
        XCTAssertNil(parsed.todayKind)
        XCTAssertTrue(parsed.upcoming(now: Date()).dates.isEmpty)
    }

    /// 空が渡るのは「その系統に時刻表が無い」ときだけなので、保存済みの値は**削除する**。
    /// 残すと、時刻表リンクを失った系統の古い表が消えず、別の日のダイヤとして表示され続ける。
    /// 取得の失敗は `BusScheduleError` として投げられ、ここまで来ない（呼び出し側が前回値を保つ）。
    func testSaveScheduleRemovesStoredValueWhenTimetableIsEmpty() throws {
        let routeID = "test-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removeObject(forKey: "schedule.\(routeID)") }

        let good = ParsedTimetable(tables: ["平日": [BusTime(hour: 6, minute: 50)]], todayKind: "平日")
        AppSettings.saveSchedule(good, routeID: routeID)
        XCTAssertEqual(AppSettings.schedule(routeID: routeID), good)

        AppSettings.saveSchedule(.empty, routeID: routeID)
        XCTAssertNil(
            AppSettings.schedule(routeID: routeID),
            "時刻表が無い系統の古い値は残さない"
        )
    }

    /// 行き先記号付きの分（都０５－２の「ｱ06」＝有明一丁目行など）も定刻として数える。
    /// `Int("ｱ06")` は nil なので、これを落とすと 22〜23 時台が空になり、
    /// 本日分が残っているのに翌日ダイヤへ切り替わる。
    func testReadsMinutesPrefixedWithDestinationMark() throws {
        let html = """
        <dl><dt class="icon4">記号説明</dt><dd><ul>
          <li>【無印】　東京ビッグサイト行</li>
          <li>【ｱ】　有明一丁目行</li>
        </ul></dd></dl>
        <p>本日は、<a onclick="document.getElementById('平日').scrollIntoView();">平日ダイヤ</a>で運行しております。</p>
        <table id="平日">
          <tr><th>20</th><td><span></span>51</td></tr>
          <tr><th>22</th><td><span>ｱ</span>06</td><td><span>ｱ</span>21</td><td><span>ｱ</span>41</td></tr>
          <tr><th>23</th><td><span>ｱ</span>06</td></tr>
        </table>
        """
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TobusConfig.timeZone
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour, c.minute) = (2026, 8, 25, 22, 9)
        let now = calendar.date(from: c)!
        let parsed = try TobusPageParser.parseTimetable(html: html, now: now)
        XCTAssertEqual(parsed.todayTimes, [
            BusTime(hour: 20, minute: 51),
            BusTime(hour: 22, minute: 6, mark: "ｱ"),
            BusTime(hour: 22, minute: 21, mark: "ｱ"),
            BusTime(hour: 22, minute: 41, mark: "ｱ"),
            BusTime(hour: 23, minute: 6, mark: "ｱ"),
        ])
        XCTAssertEqual(
            parsed.legend,
            [TimetableMark(symbol: "", label: "東京ビッグサイト行"), TimetableMark(symbol: "ｱ", label: "有明一丁目行")]
        )

        let upcoming = parsed.upcoming(now: now)
        XCTAssertFalse(upcoming.isNextDay, "22時台が残っているのに翌日へ切り替えてはいけない")
        XCTAssertEqual(upcoming.kind, "平日")
        XCTAssertEqual(calendar.component(.hour, from: upcoming.dates[0]), 22)
        XCTAssertEqual(calendar.component(.minute, from: upcoming.dates[0]), 21)
        XCTAssertEqual(upcoming.departures[0].mark, "ｱ")
        XCTAssertEqual(
            parsed.legend(appearingIn: upcoming.departures).map(\.caption),
            ["【ｱ】有明一丁目行"],
            "残っている便の記号だけを凡例として出す"
        )

        (c.year, c.month, c.day, c.hour, c.minute) = (2026, 8, 25, 20, 40)
        let evening = parsed.upcoming(now: calendar.date(from: c)!).departures
        XCTAssertNil(evening[0].mark, "20:51 は無印")
        XCTAssertEqual(
            parsed.legend(appearingIn: Array(evening.prefix(1))).map(\.caption),
            [],
            "無印だけの枠では凡例を出さない（行き先は系統名に既にある）"
        )
        XCTAssertEqual(
            parsed.legend(appearingIn: Array(evening.prefix(3))).map(\.caption),
            ["【ｱ】有明一丁目行"],
            "無印と混在していても記号付きの凡例だけ出す"
        )
    }

    /// 記号・凡例を足す前に保存したJSONも読める（再取得までの間、定刻が消えないように）。
    func testDecodesScheduleSavedBeforeLegendAndMarks() throws {
        let json = #"{"tables":{"平日":[{"hour":6,"minute":50}]},"todayKind":"平日"}"#
        let parsed = try JSONDecoder().decode(ParsedTimetable.self, from: Data(json.utf8))
        XCTAssertEqual(parsed.legend, [])
        XCTAssertEqual(parsed.fetchedOnDay, nil)
        XCTAssertEqual(parsed.upcomingKinds, [:])
        XCTAssertEqual(parsed.todayTimes, [BusTime(hour: 6, minute: 50)])
        XCTAssertNil(parsed.todayTimes.first?.mark)
    }

    /// 見出しはダイヤ区分が分かるときだけ添える。
    func testScheduleHeadingIncludesKindWhenKnown() {
        XCTAssertEqual(TobusConfig.scheduleHeading(kind: "土曜"), "定刻（土曜ダイヤ）")
        XCTAssertEqual(TobusConfig.scheduleHeading(kind: "休日"), "定刻（休日ダイヤ）")
        XCTAssertEqual(TobusConfig.scheduleHeading(kind: nil), "定刻")
        XCTAssertEqual(TobusConfig.scheduleHeading(kind: ""), "定刻", "空文字は「値あり」として扱わない")
    }
}
