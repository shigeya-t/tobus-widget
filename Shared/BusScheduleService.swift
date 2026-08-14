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
    static func fetchTimetable(for route: RouteBlock) async throws -> [BusTime] {
        guard let rtmcd = route.timetableRTMCD, let pl = route.timetablePl else {
            return []
        }

        let key = "\(route.slst):\(pl):\(rtmcd)"
        if let cached = await cache.value(for: key) { return cached }

        let selectHTML = try await BusAPI.destinationSelectHTML(slst: route.slst, pl: pl, rtmcd: rtmcd)
        guard let params = TobusPageParser.parseStoppoleParams(html: selectHTML) else {
            await cache.store([], for: key)
            return []
        }

        let timetableHTML = try await BusAPI.timetableHTML(
            rtmcd: params.rtmcd, slst: params.slst, pl: params.pl, lrid: params.lrid, tgo: params.tgo
        )
        let times = try TobusPageParser.parseTimetable(html: timetableHTML)
        await cache.store(times, for: key)
        return times
    }
}

private actor ScheduleCache {
    private var entries: [String: (times: [BusTime], day: Date)] = [:]

    private var today: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TobusConfig.timeZone
        return calendar.startOfDay(for: Date())
    }

    func value(for key: String) -> [BusTime]? {
        guard let entry = entries[key], entry.day == today else { return nil }
        return entry.times
    }

    func store(_ times: [BusTime], for key: String) {
        entries[key] = (times, today)
    }
}
