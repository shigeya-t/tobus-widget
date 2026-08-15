import Foundation

enum TobusConfig {
    static let timeZone = TimeZone(identifier: "Asia/Tokyo")!
    static let unconfiguredStopName = "バス停未設定"

    /// 定刻の見出し。当日のダイヤ区分が分かっていれば「定刻（土曜ダイヤ）」のように添える。
    /// 区分は tobus.jp の時刻表ページが申告している `平日` / `土曜` / `休日`。
    static func scheduleHeading(kind: String?) -> String {
        guard let kind, !kind.isEmpty else { return "定刻" }
        return "定刻（\(kind)ダイヤ）"
    }
}
