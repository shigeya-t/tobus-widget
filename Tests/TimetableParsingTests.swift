import XCTest

/// 時刻表の2段階フェッチ（行き先選択ページ → 時刻表ページ）の入口の判定。
///
/// tobus.jp は**行き先が1つしかない系統では行き先選択を挟まず、時刻表そのものを返す**。
/// このときページに `func_stoppole` が無いため、2段階目に進めない。
/// かつて `parseStoppoleParams` が nil のとき空配列を返していて、
/// 該当系統（勝どき橋南詰の業１０など）の定刻が黙って出ないままになっていた。
final class TimetableParsingTests: XCTestCase {

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
        let times = try TobusPageParser.parseTimetable(html: try fixture("timetable_direct_gyo10"))
        XCTAssertFalse(times.isEmpty, "業１０の定刻が取れていない")
        XCTAssertEqual(times, times.sorted(), "時刻順に並んでいる")

        let hours = Set(times.map(\.hour))
        XCTAssertTrue(hours.allSatisfy { (0...29).contains($0) }, "時が範囲外: \(hours.sorted())")
        XCTAssertTrue(times.allSatisfy { (0...59).contains($0.minute) }, "分が範囲外")
    }

    /// ページ自身の「本日は〇曜ダイヤ」の申告に従って表を選ぶ（こちらで祝日判定はしない）。
    /// フィクスチャは休日ダイヤと申告しているので、平日の表とは異なる結果になるはず。
    func testUsesScheduleTableDeclaredByPage() throws {
        let html = try fixture("timetable_direct_gyo10")
        let times = try TobusPageParser.parseTimetable(html: html)

        XCTAssertTrue(html.contains("getElementById('休日')"), "フィクスチャは休日ダイヤを申告している")
        // 休日ダイヤの表を読めていれば、平日にしか無い時間帯まで拾ってしまうことはない。
        XCTAssertFalse(times.isEmpty)
    }
}
