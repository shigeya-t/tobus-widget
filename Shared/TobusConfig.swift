import Foundation

enum TobusConfig {
    static let timeZone = TimeZone(identifier: "Asia/Tokyo")!
    static let unconfiguredStopName = "バス停未設定"

    /// 定刻の見出し。
    /// 本日分は tobus.jp の申告どおりの区分を「定刻（土曜ダイヤ）」のように添える。
    /// 翌日分に切り替わったときは、**推定した区分であることが分かるように**「翌 平日ダイヤ」と出す。
    static func scheduleHeading(kind: String?, isNextDay: Bool = false) -> String {
        guard let kind, !kind.isEmpty else { return isNextDay ? "翌日の定刻" : "定刻" }
        return isNextDay ? "翌 \(kind)ダイヤ" : "定刻（\(kind)ダイヤ）"
    }

    /// 指定日のダイヤ区分を曜日から推定する（月〜金→平日、土→土曜、日→休日）。
    ///
    /// **ページの申告がある日にはこれを使ってはいけない。** tobus.jp は実際の運行区分を
    /// 「本日は〇曜ダイヤ」と「乗車予定日のダイヤ」（翌日から最大7日）で教えており、
    /// 暦とは一致しない（2026-08-15の土曜は、お盆のため多くの系統が休日ダイヤだった）。
    /// 申告が無い日（取得日から8日目以降など）のフォールバックで、祝日も判定していない。
    /// 外れうる値なので、表示側は必ず区分名を添えて判断できるようにすること。
    static func estimatedScheduleKind(on date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        switch calendar.component(.weekday, from: date) {
        case 1: return "休日"
        case 7: return "土曜"
        default: return "平日"
        }
    }

    /// `Asia/Tokyo` の暦日を `yyyy-MM-dd` にする。時刻表の取得日・乗車予定日のキーに使う。
    static func calendarDayString(from date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// 指定時刻の次の0時（Asia/Tokyo）。ウィジェットが日をまたいでもアプリなしで定刻を切り替えるために使う。
    static func startOfNextCalendarDay(after date: Date) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let start = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: 1, to: start)
    }
}
