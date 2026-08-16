import Foundation

/// 停留所名検索でヒットした、停留所グループ（クラスタ）。
/// 同名の停留所でも複数のりば（プラットフォーム）に分かれ、1クラスタに複数系統がまとまっている。
struct BusStopCluster: Identifiable, Hashable, Codable, Sendable {
    /// tobus.jp 内部の停留所グループID（`slst`）。検索結果ページの `<a class="func_stop" id="e965">` から取れる。
    let slst: Int
    let name: String
    var id: Int { slst }
}

/// 停留所クラスタ内の1系統×行き先（＝1のりば分の表示ブロック）。ウィジェットの設定はこの単位で保存する。
struct RouteBlock: Identifiable, Hashable, Codable, Sendable {
    let slst: Int
    /// ページ内での出現順。tobus.jp 側でのりばや系統が増減すれば変わるため、**識別には使わない**。
    /// ただし接近情報の引き当てには現在の並び順が必要なので、値としては保持する。
    let ordinal: Int
    let platformLabel: String
    let label: String
    let destination: String
    /// 時刻表ページへのリンクに含まれる `RTMCD` / `pl`。時刻表取得（[[BusScheduleService]]）に使う。
    /// tobus.jp 自身の系統コード・のりば番号なので、表示文字列より安定した識別材料でもある。
    let timetableRTMCD: Int?
    let timetablePl: Int?

    /// ウィジェット設定・スナップショット（`snapshot.<id>`）のキー。
    ///
    /// 初回は `"slst#ordinal"` だが、**以降は並び順が変わっても保存済みの値をそのまま持ち回る**。
    /// ここを現在の `ordinal` から都度組み立てると、並び順が変わったときにアプリが書くキーと
    /// ウィジェットが読むキーがずれ、ウィジェットが無言で空になる。
    /// 並び順が変わった系統の引き当ては [[BusDirectoryService]] の `routeBlock(id:)` が行う。
    let id: String

    var displayName: String {
        label.isEmpty && destination.isEmpty ? "系統未設定" : "\(label) \(destination)"
    }

    init(
        slst: Int, ordinal: Int, platformLabel: String, label: String, destination: String,
        timetableRTMCD: Int? = nil, timetablePl: Int? = nil, id: String? = nil
    ) {
        self.slst = slst
        self.ordinal = ordinal
        self.platformLabel = platformLabel
        self.label = label
        self.destination = destination
        self.timetableRTMCD = timetableRTMCD
        self.timetablePl = timetablePl
        self.id = id ?? "\(slst)#\(ordinal)"
    }

    /// id文字列から復元する（名称は空になるため、後でページを引き直して埋める）
    init?(id: String) {
        guard let hashIndex = id.lastIndex(of: "#"),
              let slst = Int(id[..<hashIndex]),
              let ordinal = Int(id[id.index(after: hashIndex)...])
        else { return nil }
        self.init(slst: slst, ordinal: ordinal, platformLabel: "", label: "", destination: "", id: id)
    }
}

/// 時刻表の1便分（時・分）。
struct BusTime: Comparable, Hashable, Codable, Sendable {
    let hour: Int
    let minute: Int

    static func < (lhs: BusTime, rhs: BusTime) -> Bool {
        (lhs.hour, lhs.minute) < (rhs.hour, rhs.minute)
    }

    /// 指定日の絶対時刻に変換する。`after` を渡すとそれより後の便だけを返す。
    static func dates(from times: [BusTime], on day: Date, after: Date? = nil) -> [Date] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TobusConfig.timeZone
        let dates = times.compactMap { $0.date(on: day, calendar: calendar) }
        guard let after else { return dates }
        return dates.filter { $0 > after }
    }

    /// 深夜便は24時を超える表記（例: 25時10分）があるため、日をまたぐ場合は繰り上げる。
    func date(on day: Date, calendar: Calendar) -> Date? {
        var components = calendar.dateComponents([.year, .month, .day], from: day)
        components.hour = hour % 24
        components.minute = minute
        components.second = 0
        guard let base = calendar.date(from: components) else { return nil }
        let extraDays = hour / 24
        guard extraDays > 0 else { return base }
        return calendar.date(byAdding: .day, value: extraDays, to: base)
    }
}

/// 接近状況の種類。実車が接近中は「◯◯行04分待」「◯◯行まもなく」のように分単位の実測値が
/// 表示されるが、実車情報が無い時間帯は定型文（バケット）だけが返る。
enum BusApproachKind: Equatable {
    /// 「◯◯行04分待」→ 4、「◯◯行まもなく」→ 0 のように、実車の接近表示から得られる「あとN分」。
    case estimatedMinutes(Int)
    /// 「５分以内に発車予定です。」
    case departingSoon
    /// 「ただいま定刻で運行しています。」
    case onSchedule
    /// 「ただいまの時間は接近情報をご案内できません。」
    /// ＝tobus.jp が案内そのものを行っていない状態。
    case unavailable
    /// 接近情報は案内されているが、まだ接近中のバスが1台も出ていない状態。
    /// 該当ブロックの表に「◯◯行NN分待」が1つも無く、バス表示のセルが空で返る。
    /// `unavailable` と混同すると、正常運行中なのに「案内できません」と出てしまう。
    case noBusApproaching
    /// 「本日は運休日です。」
    case suspended
    /// 解釈できなかった、または想定外の文言（生のテキストを保持）
    case other(String)

    init(statusText: String, estimatedMinutes: Int?) {
        if let estimatedMinutes {
            self = .estimatedMinutes(estimatedMinutes)
        } else if statusText.contains("運休") {
            self = .suspended
        } else if statusText.contains("以内に発車") {
            self = .departingSoon
        } else if statusText.contains("定刻") {
            self = .onSchedule
        } else if statusText.contains("ご案内できません") {
            self = .unavailable
        } else if statusText.isEmpty {
            self = .noBusApproaching
        } else {
            self = .other(statusText)
        }
    }
}

struct BusApproach: Equatable {
    let kind: BusApproachKind
    /// tobus.jpが返す生のバケット文言（表示にそのまま使えるようにしておく）
    let statusText: String
    /// 2台目以降の待ち時間（分、到着が早い順）。1台だけなら空。
    /// `kind` は1台目だけを表すので、後続はここから読む。
    var followingMinutes: [Int] = []
    /// 「本日は運休日です。」「本日は土曜ダイヤで運行しています。」など、状態を補足する注記
    let noteText: String?
    /// ページに表示されている「HH:mm 時点の情報」の時刻
    let observedAt: Date

    /// 通信エラーが続くと、取得済みのスナップショットがいつまでも表示され続けることがある。
    /// 一定時間（既定10分）以上更新されていない場合は「古いデータかもしれない」の目安として使う。
    func isStale(asOf now: Date = Date(), threshold: TimeInterval = 10 * 60) -> Bool {
        now.timeIntervalSince(observedAt) > threshold
    }
}
