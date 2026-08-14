import XCTest

/// `TobusPageParser` を実ページのHTMLで検証する。
///
/// tobus.jp は公式APIではなくHTML画面をそのまま解析しているため、
/// 先方の構造変更に気づく手段がここしか無い。フィクスチャは
/// `Tests/Fixtures/stop325.html`（勝どき橋南詰、2026-08-14 21時ごろ取得）。
final class TobusPageParserTests: XCTestCase {

    private func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: name, withExtension: "html"),
            "フィクスチャ \(name).html がテストバンドルに入っていません"
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func parsedPage() throws -> ParsedStopPage {
        try TobusPageParser.parseStopPage(html: try fixture("stop325"), slst: 325)
    }

    func testParsesStopName() throws {
        XCTAssertEqual(try parsedPage().stopName, "勝どき橋南詰")
    }

    /// のりば2つ・系統15ブロック。ordinal は 0 から連番で振られる。
    func testParsesAllBlocksWithSequentialOrdinals() throws {
        let blocks = try parsedPage().blocks
        XCTAssertEqual(blocks.count, 15)
        XCTAssertEqual(blocks.map(\.ordinal), Array(0..<15))
    }

    func testParsesLabelsAndDestinations() throws {
        let blocks = try parsedPage().blocks
        XCTAssertEqual(blocks[0].label, "都０３")
        XCTAssertEqual(blocks[0].destination, "四谷駅 行")
        XCTAssertEqual(blocks[2].label, "都０５－１")
        XCTAssertEqual(blocks[2].destination, "東京駅丸の内南口 行")
        XCTAssertEqual(blocks[5].label, "業１０")
        XCTAssertEqual(blocks[5].destination, "新橋 行")
    }

    /// 時刻表リンクの RTMCD / pl は系統の追跡キーにも使うため、確実に取れている必要がある。
    func testParsesTimetableLinkParameters() throws {
        let blocks = try parsedPage().blocks
        XCTAssertEqual(blocks[5].timetableRTMCD, 40)
        XCTAssertEqual(blocks[5].timetablePl, 1)
        XCTAssertEqual(blocks[2].timetableRTMCD, 184)
    }

    /// 接近中のバスがいる系統は「◯◯行NN分待」から分数を取る。
    func testParsesEstimatedMinutes() throws {
        let blocks = try parsedPage().blocks
        XCTAssertEqual(blocks[2].estimatedMinutes, 8, "都０５－１ 東京駅丸の内南口行08分待")
        XCTAssertEqual(blocks[4].estimatedMinutes, 6, "都０５－２ 東京駅丸の内南口行06分待")
        XCTAssertEqual(blocks[0].estimatedMinutes, 10, "都０３ 四谷駅行10分待")
    }

    /// 接近中のバスがいない系統は、テーブルにバス表示が無く statusText が空で返る。
    /// これは取得失敗でも案内停止でもないので、`unavailable` と区別されなければならない。
    func testBlocksWithoutApproachingBusYieldEmptyStatus() throws {
        let block = try XCTUnwrap(try parsedPage().blocks[5])
        XCTAssertNil(block.estimatedMinutes)
        XCTAssertTrue(block.statusText.isEmpty, "業１０には接近中のバスがいない")

        let kind = BusApproachKind(statusText: block.statusText, estimatedMinutes: block.estimatedMinutes)
        XCTAssertEqual(kind, .noBusApproaching)
    }

    /// 複数台が接近している場合でも、直近の1台の分数を採る。
    func testTakesNearestBusWhenMultipleApproaching() throws {
        let blocks = try parsedPage().blocks
        XCTAssertEqual(blocks[9].estimatedMinutes, 6, "晴海埠頭行は06分待と13分待の2台")
    }

    func testParsesObservedAt() throws {
        let page = try parsedPage()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TobusConfig.timeZone
        let components = calendar.dateComponents([.hour, .minute], from: page.observedAt)
        XCTAssertNotNil(components.hour)
        XCTAssertNotNil(components.minute)
    }
}

/// 文言から状態への分類。tobus.jp の定型文が変わると表示が崩れるため固定しておく。
final class BusApproachKindTests: XCTestCase {

    func testClassifiesEstimatedMinutes() {
        XCTAssertEqual(BusApproachKind(statusText: "新橋行05分待", estimatedMinutes: 5), .estimatedMinutes(5))
    }

    func testClassifiesSuspendedBeforeOtherText() {
        XCTAssertEqual(BusApproachKind(statusText: "本日は運休日です。", estimatedMinutes: nil), .suspended)
    }

    func testClassifiesDepartingSoon() {
        XCTAssertEqual(BusApproachKind(statusText: "５分以内に発車予定です。", estimatedMinutes: nil), .departingSoon)
    }

    func testClassifiesOnSchedule() {
        XCTAssertEqual(BusApproachKind(statusText: "ただいま定刻で運行しています。", estimatedMinutes: nil), .onSchedule)
    }

    /// 「案内できない」と「接近中のバスがいない」は別物。混同すると
    /// 正常運行中なのに「接近情報を案内できません」と表示される。
    func testDistinguishesUnavailableFromNoBusApproaching() {
        XCTAssertEqual(
            BusApproachKind(statusText: "ただいまの時間は接近情報をご案内できません。", estimatedMinutes: nil),
            .unavailable
        )
        XCTAssertEqual(BusApproachKind(statusText: "", estimatedMinutes: nil), .noBusApproaching)
    }

    func testKeepsUnknownTextAsOther() {
        XCTAssertEqual(
            BusApproachKind(statusText: "想定外のお知らせ", estimatedMinutes: nil),
            .other("想定外のお知らせ")
        )
    }

    /// 分数が取れていれば、文言に関わらず分数を優先する。
    func testEstimatedMinutesWinsOverText() {
        XCTAssertEqual(
            BusApproachKind(statusText: "ただいま定刻で運行しています。", estimatedMinutes: 3),
            .estimatedMinutes(3)
        )
    }
}
