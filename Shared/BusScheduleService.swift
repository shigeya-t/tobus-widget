import Foundation

/// 静的時刻表（「定刻」）の取得。
///
/// 車両接近情報ページ内の「時刻表」リンクを2段階たどって取得する
/// （行き先選択ページ → 実際の時刻表ページ）。時刻表は日をまたがない限り変わらないため、
/// 系統ごとに1日1回だけ取得すれば十分。
enum BusScheduleService {
    private static let cache = ScheduleCache()

    /// 指定した系統の、本日のダイヤ区分における時刻表を取得する。
    /// 時刻表リンクの情報（`timetableRTMCD` / `timetablePl`）を持たない系統では取得できない。
    static func fetchTimetable(for route: RouteBlock) async throws -> ParsedTimetable {
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
            let parsed = try TobusPageParser.parseTimetable(html: selectHTML)
            if parsed.times.isEmpty {
                busLogger.error("行き先選択・時刻表のどちらとしても読めません（slst=\(route.slst, privacy: .public), pl=\(pl, privacy: .public), RTMCD=\(rtmcd, privacy: .public)）")
            }
            await cache.store(parsed, for: key)
            return parsed
        }

        let timetableHTML = try await BusAPI.timetableHTML(
            rtmcd: params.rtmcd, slst: params.slst, pl: params.pl, lrid: params.lrid, tgo: params.tgo
        )
        let parsed = try TobusPageParser.parseTimetable(html: timetableHTML)
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
