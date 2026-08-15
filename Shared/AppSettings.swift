import Foundation

extension Notification.Name {
    static let busPauseStateChanged = Notification.Name("com.example.TobusWidget.pauseStateChanged")
    /// ウィジェットの「今すぐ更新」は通信せず、Appに取得を依頼する（取得をAppに一本化しているため）。
    static let busManualRefreshRequested = Notification.Name("com.example.TobusWidget.manualRefreshRequested")
}

/// アプリとウィジェット拡張で共有する設定。サンドボックスのコンテナは別々のため、App Group 経由でやり取りする。
enum AppSettings {
    /// App Group は macOS では Team ID プレフィックスが必須のため、値を固定できない。
    /// ビルド設定 APP_GROUP_ID から Info.plist に埋め込んだものを読み取る。
    static let appGroupID: String = {
        Bundle.main.object(forInfoDictionaryKey: "AppGroupID") as? String ?? ""
    }()

    /// App Group が使えない場合は標準のドメインに退避する。
    /// アプリとウィジェットで値を共有できなくなるため、原因を追えるよう記録する。
    private static var defaults: UserDefaults {
        guard !appGroupID.isEmpty, let shared = UserDefaults(suiteName: appGroupID) else {
            busLogger.error("App Group を利用できません（AppGroupID=\(appGroupID, privacy: .public)）")
            return .standard
        }
        return shared
    }

    private enum Keys {
        static let isPaused = "isPaused"
        static let slst = "selectedSlst"
        static let ordinal = "selectedOrdinal"
        static func snapshot(_ routeID: String) -> String { "snapshot.\(routeID)" }
        static func routeIdentity(_ routeID: String) -> String { "routeIdentity.\(routeID)" }
        static func schedule(_ routeID: String) -> String { "schedule.\(routeID)" }
        static func scheduleKind(_ routeID: String) -> String { "scheduleKind.\(routeID)" }
    }

    /// 一時停止中は、アプリもウィジェットも定期的な取得を行わない。
    static var isPaused: Bool {
        get { defaults.bool(forKey: Keys.isPaused) }
        set { defaults.set(newValue, forKey: Keys.isPaused) }
    }

    /// ウィジェットから切り替えたとき、常駐アプリ側にも伝える。
    /// App Group の設定変更は別プロセスに自動通知されないため、明示的に知らせる。
    static func notifyPauseStateChanged() {
        DistributedNotificationCenter.default().postNotificationName(
            .busPauseStateChanged,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    /// ウィジェットの「今すぐ更新」ボタンから、取得元であるAppに通知する。
    static func notifyManualRefreshRequested() {
        DistributedNotificationCenter.default().postNotificationName(
            .busManualRefreshRequested,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    // MARK: - メニューバー側で選んだ停留所・系統

    static var selectedSlst: Int {
        get { defaults.integer(forKey: Keys.slst) }
        set { defaults.set(newValue, forKey: Keys.slst) }
    }

    static var selectedOrdinal: Int {
        get { defaults.integer(forKey: Keys.ordinal) }
        set { defaults.set(newValue, forKey: Keys.ordinal) }
    }

    // MARK: - 最後に取得した接近状況

    /// 一時停止中は通信せずにこの値を表示する。取得時刻も一緒に持たせ、値が古いことが分かるようにする。
    struct Snapshot: Codable {
        enum Kind: String, Codable {
            case estimatedMinutes, departingSoon, onSchedule, unavailable, noBusApproaching, suspended, other
        }
        let kind: Kind
        let minutes: Int?
        /// 2台目以降の待ち時間。この項目が無い古い保存データも読めるよう省略可能にしている。
        let followingMinutes: [Int]?
        let statusText: String
        let noteText: String?
        let observedAt: Date

        init(_ approach: BusApproach) {
            statusText = approach.statusText
            followingMinutes = approach.followingMinutes.isEmpty ? nil : approach.followingMinutes
            noteText = approach.noteText
            observedAt = approach.observedAt
            switch approach.kind {
            case .estimatedMinutes(let m): kind = .estimatedMinutes; minutes = m
            case .departingSoon: kind = .departingSoon; minutes = nil
            case .onSchedule: kind = .onSchedule; minutes = nil
            case .unavailable: kind = .unavailable; minutes = nil
            case .noBusApproaching: kind = .noBusApproaching; minutes = nil
            case .suspended: kind = .suspended; minutes = nil
            case .other: kind = .other; minutes = nil
            }
        }

        var approach: BusApproach {
            let kindValue: BusApproachKind
            switch kind {
            case .estimatedMinutes: kindValue = .estimatedMinutes(minutes ?? 0)
            case .departingSoon: kindValue = .departingSoon
            case .onSchedule: kindValue = .onSchedule
            case .unavailable: kindValue = .unavailable
            case .noBusApproaching: kindValue = .noBusApproaching
            case .suspended: kindValue = .suspended
            case .other: kindValue = .other(statusText)
            }
            return BusApproach(
                kind: kindValue, statusText: statusText,
                followingMinutes: followingMinutes ?? [],
                noteText: noteText, observedAt: observedAt
            )
        }
    }

    static func saveSnapshot(_ approach: BusApproach, routeID: String) {
        guard let data = try? JSONEncoder().encode(Snapshot(approach)) else { return }
        defaults.set(data, forKey: Keys.snapshot(routeID))
    }

    static func snapshot(routeID: String) -> BusApproach? {
        guard let data = defaults.data(forKey: Keys.snapshot(routeID)) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data).approach
    }

    // MARK: - 系統の識別情報

    /// 保存済みウィジェットが指している系統を、ページ内の並び順（`ordinal`）に頼らず
    /// 言い当てるための手がかり。tobus.jp 側でのりばや系統が増減して並び順が変わっても
    /// 同じ系統を追跡できるよう、`RouteBlock.id` ごとに控えておく。
    struct RouteIdentity: Codable, Sendable {
        let label: String
        let destination: String
        let platformLabel: String
        /// tobus.jp 自身の系統コードとのりば番号。表示文字列より安定している。
        let timetableRTMCD: Int?
        let timetablePl: Int?
    }

    /// 系統を解決できたときに、次回の引き当て用として控え直す。
    /// 名前が空のブロック（id からの部分復元など）は手がかりにならないので保存しない。
    static func saveRouteIdentity(_ route: RouteBlock) {
        guard !route.label.isEmpty || !route.destination.isEmpty else { return }
        let identity = RouteIdentity(
            label: route.label, destination: route.destination, platformLabel: route.platformLabel,
            timetableRTMCD: route.timetableRTMCD, timetablePl: route.timetablePl
        )
        guard let data = try? JSONEncoder().encode(identity) else { return }
        defaults.set(data, forKey: Keys.routeIdentity(route.id))
    }

    static func routeIdentity(routeID: String) -> RouteIdentity? {
        guard let data = defaults.data(forKey: Keys.routeIdentity(routeID)) else { return nil }
        return try? JSONDecoder().decode(RouteIdentity.self, from: data)
    }

    // MARK: - 定刻（静的時刻表）

    /// 時刻表は日をまたがない限り変わらないため、ウィジェット拡張は自分では取得せず、
    /// Appが取得したものをここ経由で読むだけにする。
    ///
    /// ダイヤ区分は時刻の配列とは別のキーに入れている。`schedule.<id>` の中身を
    /// 構造体に変えると、保存済みの値が読めなくなって次の取得まで定刻が消えるため。
    static func saveSchedule(_ timetable: ParsedTimetable, routeID: String) {
        if let data = try? JSONEncoder().encode(timetable.times) {
            defaults.set(data, forKey: Keys.schedule(routeID))
        }
        if let kind = timetable.scheduleKind, !kind.isEmpty {
            defaults.set(kind, forKey: Keys.scheduleKind(routeID))
        } else {
            defaults.removeObject(forKey: Keys.scheduleKind(routeID))
        }
    }

    static func schedule(routeID: String) -> [BusTime]? {
        guard let data = defaults.data(forKey: Keys.schedule(routeID)) else { return nil }
        return try? JSONDecoder().decode([BusTime].self, from: data)
    }

    /// 保存済みの時刻表がどのダイヤ区分のものか（`平日` / `土曜` / `休日`）。
    static func scheduleKind(routeID: String) -> String? {
        guard let kind = defaults.string(forKey: Keys.scheduleKind(routeID)), !kind.isEmpty else { return nil }
        return kind
    }
}
