import XCTest

/// `BusDirectoryService.resolve` の多段引き当て。
///
/// tobus.jp 側で系統の並び順が変わったときに、保存済みウィジェットが別系統を指してしまわないかを見る。
/// 実地では tobus.jp が実際に並びを変えないと発火しない経路なので、ここで担保する。
final class RouteResolutionTests: XCTestCase {

    /// 実際の勝どき橋南詰（slst=325）の並びを模したブロック列。
    private func blocks(_ specs: [(ordinal: Int, label: String, dest: String, rtmcd: Int?, pl: Int?)]) -> [RouteBlock] {
        specs.map {
            RouteBlock(
                slst: 325, ordinal: $0.ordinal, platformLabel: "のりば",
                label: $0.label, destination: $0.dest,
                timetableRTMCD: $0.rtmcd, timetablePl: $0.pl
            )
        }
    }

    private var sample: [RouteBlock] {
        blocks([
            (0, "都０３", "四谷駅 行", 183, 1),
            (1, "都０４", "東京駅丸の内南口 行", 41, 1),
            (2, "都０５－１", "東京駅丸の内南口 行", 184, 1),
            (3, "都０５－１出入", "東京駅丸の内南口 行", 185, 1),
            (4, "都０５－２", "東京駅丸の内南口 行", 186, 1),
            (5, "業１０", "新橋 行", 40, 1),
        ])
    }

    private func identity(
        label: String, dest: String, platform: String = "のりば", rtmcd: Int?, pl: Int?
    ) -> AppSettings.RouteIdentity {
        AppSettings.RouteIdentity(
            label: label, destination: dest, platformLabel: platform,
            timetableRTMCD: rtmcd, timetablePl: pl
        )
    }

    // MARK: - 段階④（フォールバック）

    /// 識別情報がまだ無い初回は、id に埋まっている ordinal で引き当てる。
    func testFallsBackToOrdinalWhenNoIdentitySaved() throws {
        let match = try XCTUnwrap(
            BusDirectoryService.resolve(id: "325#5", ordinal: 5, identity: nil, in: sample)
        )
        XCTAssertEqual(match.label, "業１０")
        XCTAssertEqual(match.destination, "新橋 行")
    }

    /// ordinal が範囲外なら引き当てられない（黙って別系統を返さない）。
    func testReturnsNilWhenOrdinalOutOfRange() {
        XCTAssertNil(BusDirectoryService.resolve(id: "325#99", ordinal: 99, identity: nil, in: sample))
    }

    // MARK: - 段階①（RTMCD＋pl）

    /// 並び順が変わっても、RTMCD＋pl が一致する系統を追跡できる。
    /// これがこの仕組みの主目的。
    func testTracksRouteByRTMCDWhenOrderChanged() throws {
        // 先頭にのりばが1つ増え、業１０が 5 → 6 にずれた状況
        var shifted = blocks([(0, "都０６", "新橋 行", 900, 2)])
        shifted += sample.map {
            RouteBlock(
                slst: $0.slst, ordinal: $0.ordinal + 1, platformLabel: $0.platformLabel,
                label: $0.label, destination: $0.destination,
                timetableRTMCD: $0.timetableRTMCD, timetablePl: $0.timetablePl
            )
        }

        let saved = identity(label: "業１０", dest: "新橋 行", rtmcd: 40, pl: 1)
        let match = try XCTUnwrap(
            BusDirectoryService.resolve(id: "325#5", ordinal: 5, identity: saved, in: shifted)
        )

        XCTAssertEqual(match.label, "業１０", "並び順がずれても同じ系統を指し続ける")
        XCTAssertEqual(match.ordinal, 6, "接近情報を引くための ordinal は現在の並びに更新される")
        XCTAssertEqual(match.id, "325#5", "保存済みのキーは変えない（スナップショットのキーがずれるため）")
    }

    /// 系統名の表記が変わっても RTMCD＋pl で追跡できる。
    func testTracksRouteByRTMCDWhenLabelRenamed() throws {
        let renamed = blocks([
            (0, "都０３", "四谷駅 行", 183, 1),
            (1, "業１０系統", "新橋駅 行", 40, 1),
        ])
        let saved = identity(label: "業１０", dest: "新橋 行", rtmcd: 40, pl: 1)
        let match = try XCTUnwrap(
            BusDirectoryService.resolve(id: "325#5", ordinal: 5, identity: saved, in: renamed)
        )
        XCTAssertEqual(match.label, "業１０系統")
    }

    // MARK: - 段階②③（系統名＋行き先）

    /// 時刻表リンクを持たない系統（RTMCD/pl が nil）は、系統名＋行き先で引き当てる。
    func testTracksRouteByNameWhenTimetableLinkMissing() throws {
        let withoutLink = blocks([
            (0, "都０３", "四谷駅 行", nil, nil),
            (1, "業１０", "新橋 行", nil, nil),
        ])
        let saved = identity(label: "業１０", dest: "新橋 行", rtmcd: nil, pl: nil)
        let match = try XCTUnwrap(
            BusDirectoryService.resolve(id: "325#5", ordinal: 5, identity: saved, in: withoutLink)
        )
        XCTAssertEqual(match.ordinal, 1)
        XCTAssertEqual(match.id, "325#5")
    }

    /// のりば表記だけが変わった場合は段階③まで緩めて引き当てる。
    func testTracksRouteWhenOnlyPlatformLabelChanged() throws {
        let moved = blocks([(0, "業１０", "新橋 行", nil, nil)]).map {
            RouteBlock(
                slst: $0.slst, ordinal: $0.ordinal, platformLabel: "Ａのりば",
                label: $0.label, destination: $0.destination,
                timetableRTMCD: nil, timetablePl: nil
            )
        }
        let saved = identity(label: "業１０", dest: "新橋 行", platform: "のりば", rtmcd: nil, pl: nil)
        let match = try XCTUnwrap(
            BusDirectoryService.resolve(id: "325#5", ordinal: 5, identity: saved, in: moved)
        )
        XCTAssertEqual(match.platformLabel, "Ａのりば")
    }

    /// 同名・同行き先が複数のりばにある場合は、のりば表記まで一致する方を選ぶ。
    func testPrefersMatchingPlatformAmongDuplicates() throws {
        let duplicated = [
            RouteBlock(slst: 325, ordinal: 0, platformLabel: "Ａのりば",
                       label: "業１０", destination: "新橋 行", timetableRTMCD: nil, timetablePl: nil),
            RouteBlock(slst: 325, ordinal: 1, platformLabel: "Ｂのりば",
                       label: "業１０", destination: "新橋 行", timetableRTMCD: nil, timetablePl: nil),
        ]
        let saved = identity(label: "業１０", dest: "新橋 行", platform: "Ｂのりば", rtmcd: nil, pl: nil)
        let match = try XCTUnwrap(
            BusDirectoryService.resolve(id: "325#0", ordinal: 0, identity: saved, in: duplicated)
        )
        XCTAssertEqual(match.ordinal, 1, "ordinal が一致する方ではなく、のりばが一致する方を選ぶ")
    }

    // MARK: - 優先順位

    /// 保存済みの系統が消えた場合は、ordinal のフォールバックに落ちる。
    /// （消えたまま nil を返すと、ウィジェットが復帰不能になるため）
    func testFallsBackToOrdinalWhenSavedRouteDisappeared() throws {
        let saved = identity(label: "存在しない系統", dest: "どこか 行", rtmcd: 9999, pl: 9)
        let match = try XCTUnwrap(
            BusDirectoryService.resolve(id: "325#2", ordinal: 2, identity: saved, in: sample)
        )
        XCTAssertEqual(match.ordinal, 2)
    }

    // MARK: - id の安定性

    /// id は "slst#ordinal" として解釈でき、往復しても壊れない。
    func testRouteBlockIDRoundTrip() throws {
        let restored = try XCTUnwrap(RouteBlock(id: "325#5"))
        XCTAssertEqual(restored.slst, 325)
        XCTAssertEqual(restored.ordinal, 5)
        XCTAssertEqual(restored.id, "325#5")
    }

    func testRouteBlockIDDefaultsToSlstAndOrdinal() {
        let route = RouteBlock(slst: 325, ordinal: 5, platformLabel: "", label: "", destination: "")
        XCTAssertEqual(route.id, "325#5")
    }
}
