import Foundation

/// 静的時刻表（「定刻」）の取得。
///
/// 車両接近情報ページ内の「時刻表」リンクを2段階たどって取得する
/// （行き先選択ページ → 実際の時刻表ページ）。時刻表は日をまたがない限り変わらないため、
/// 系統ごとに1日1回だけ取得すれば十分。
/// 時刻表として読み取れなかった（HTTP 200 で返るエラーページなど）。
/// 「その系統に時刻表が無い」（`ParsedTimetable.empty`）とは区別する。前者は前回値を残すべきで、
/// 後者は本当に空なので表示を消すべきという、逆の扱いになるため。
enum BusScheduleError: LocalizedError {
    case unreadableTimetable(slst: Int, pl: Int, rtmcd: Int)

    var errorDescription: String? {
        switch self {
        case .unreadableTimetable(let slst, let pl, let rtmcd):
            return "時刻表を読み取れませんでした（slst=\(slst), pl=\(pl), RTMCD=\(rtmcd)）"
        }
    }
}

enum BusScheduleService {
    private static let cache = ScheduleCache()

    /// 指定した系統の、本日のダイヤ区分における時刻表を取得する。
    /// 時刻表リンクの情報（`timetableRTMCD` / `timetablePl`）を持たない系統では取得できない。
    static func fetchTimetable(for route: RouteBlock) async throws -> ParsedTimetable {
        // 時刻表リンクを持たない系統。取得の失敗ではなく「時刻表が無い」ので、
        // エラーにせず空を返す（呼び出し側は定刻の表示を消してよい）。
        guard let rtmcd = route.timetableRTMCD, let pl = route.timetablePl else {
            return .empty
        }

        let key = "\(route.slst):\(pl):\(rtmcd)"
        if let cached = await cache.value(for: key) { return cached }

        let selectHTML = try await BusAPI.destinationSelectHTML(slst: route.slst, pl: pl, rtmcd: rtmcd)
        guard let params = TobusPageParser.parseStoppoleParams(html: selectHTML) else {
            // 行き先が1つしかない系統では、tobus.jp は行き先選択を挟まず時刻表そのものを返す
            // （例: 勝どき橋南詰の業１０）。この場合 `func_stoppole` が無いので、
            // 2段階目に進まず、いま取得したHTMLをそのまま時刻表として読む。
            return try await store(
                TobusPageParser.parseTimetable(html: selectHTML),
                for: key, slst: route.slst, pl: pl, rtmcd: rtmcd
            )
        }

        let timetableHTML = try await BusAPI.timetableHTML(
            rtmcd: params.rtmcd, slst: params.slst, pl: params.pl, lrid: params.lrid, tgo: params.tgo
        )
        return try await store(
            TobusPageParser.parseTimetable(html: timetableHTML),
            for: key, slst: route.slst, pl: pl, rtmcd: rtmcd
        )
    }

    /// 表が1つも取れなかったときは、キャッシュせずエラーにする。
    ///
    /// キャッシュは日付でしか失効しないため、HTTP 200 で返るエラーページを一度掴むと
    /// **その日いっぱい定刻が空のまま**になる。また空を返してしまうと、呼び出し側は
    /// 「時刻表が無い系統」と区別できず、メニューバーの定刻を消してしまう。
    /// エラーにしておけば呼び出し側は前回値を保てる（接近情報の失敗時と同じ扱いになる）。
    private static func store(
        _ parsed: ParsedTimetable, for key: String, slst: Int, pl: Int, rtmcd: Int
    ) async throws -> ParsedTimetable {
        guard !parsed.tables.isEmpty else {
            busLogger.error("時刻表を読み取れません（slst=\(slst, privacy: .public), pl=\(pl, privacy: .public), RTMCD=\(rtmcd, privacy: .public)）")
            throw BusScheduleError.unreadableTimetable(slst: slst, pl: pl, rtmcd: rtmcd)
        }
        await cache.store(parsed, for: key)
        return parsed
    }
}

private actor ScheduleCache {
    private var entries: [String: (timetable: ParsedTimetable, day: Date)] = [:]

    private var today: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TobusConfig.timeZone
        return calendar.startOfDay(for: Date())
    }

    func value(for key: String) -> ParsedTimetable? {
        guard let entry = entries[key], entry.day == today else { return nil }
        return entry.timetable
    }

    func store(_ timetable: ParsedTimetable, for key: String) {
        entries[key] = (timetable, today)
    }
}
