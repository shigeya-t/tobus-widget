import WidgetKit
import SwiftUI
import AppIntents

struct BusEntry: TimelineEntry {
    let date: Date
    /// 未設定、または解決できなかった場合はnil。
    let routeID: String?
    let routeDisplayName: String?
    /// 系統ラベルのみ（例: "都０５－１"）。小サイズ表示で `stopName` が無い場合の短いフォールバックに使う。
    let routeLabel: String?
    /// 行き先のみ（例: "東京駅丸の内南口 行"）。小サイズでは `routeDisplayName` を丸ごと出すと
    /// 系統ラベルと合わさって長すぎるため、行き先だけを別の行に出せるよう分けて持つ。
    let routeDestination: String?
    let stopName: String?
    /// tobus.jpから取得した接近状況。取得できなかった場合はnil。
    let approach: BusApproach?
    /// 本日の残り定刻（無ければ翌日分）。
    let scheduled: [ScheduledDeparture]
    /// `scheduled` がどのダイヤ区分のものか（`平日` / `土曜` / `休日`）。判別できなければ nil。
    let scheduleKind: String?
    /// `scheduled` が翌日分か（本日分が尽きたとき）。区分は推定なので見出しで明示する。
    let scheduleIsNextDay: Bool
    /// 表示中の定刻に出てくる記号の凡例。
    let scheduleLegend: [TimetableMark]
    /// 一時停止中は通信せず、最後に取得した値をそのまま表示する
    let isPaused: Bool

    /// AppIntentsが保存済みエンティティを空文字で再解決してくることがあるため、
    /// nil だけでなく空文字も「無い」ものとして扱うヘルパー。
    private static func firstNonEmpty(_ candidates: String?...) -> String? {
        for candidate in candidates {
            if let candidate, !candidate.isEmpty { return candidate }
        }
        return nil
    }

    /// ウィジェットのヘッダーに使う、系統を表す短いラベル（例: "都０５－１"）。
    var shortRouteLabel: String? {
        Self.firstNonEmpty(routeLabel)
    }

    /// ウィジェットのヘッダーに使う、なるべく短い停留所名（無ければ系統の表示名全体にフォールバック）。
    var shortHeaderText: String {
        Self.firstNonEmpty(stopName, routeDisplayName) ?? "都バス"
    }

    /// 小サイズのヘッダーで、系統ラベルとは別の行に出す行き先。
    /// バス停名が無いときは `shortHeaderText` が系統の表示名（＝行き先を含む）に化けるため、
    /// 二重に出さないよう nil にする。
    var shortDestination: String? {
        guard Self.firstNonEmpty(stopName) != nil else { return nil }
        return Self.firstNonEmpty(routeDestination)
    }

    static func placeholder(_ date: Date = Date()) -> BusEntry {
        BusEntry(date: date, routeID: nil, routeDisplayName: nil, routeLabel: nil, routeDestination: nil, stopName: nil, approach: nil, scheduled: [], scheduleKind: nil, scheduleIsNextDay: false, scheduleLegend: [], isPaused: false)
    }
}

struct Provider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> BusEntry {
        BusEntry.placeholder()
    }

    func snapshot(for configuration: SelectBusStopIntent, in context: Context) async -> BusEntry {
        buildEntry(configuration: configuration, now: Date())
    }

    func timeline(for configuration: SelectBusStopIntent, in context: Context) async -> Timeline<BusEntry> {
        let now = Date()
        let today = buildEntry(configuration: configuration, now: now)
        // WidgetKit は macOS ではタイムライン要求をほとんど実行せず、エントリ日付の切り替えも
        // 当てにならない。翌日0時のエントリは保険で載せ、表示側は TimelineView で毎分載せ直す。
        var entries = [today]
        if let midnight = TobusConfig.startOfNextCalendarDay(after: now) {
            entries.append(buildEntry(configuration: configuration, now: midnight))
        }
        return Timeline(entries: entries, policy: .after(reloadDate(for: today, now: now)))
    }

    /// 接近状況を取り直すタイミング。tobus.jp側のエッジキャッシュが60秒のため、それより短くしても意味は薄い。
    private func reloadDate(for entry: BusEntry, now: Date) -> Date {
        guard entry.routeID != nil else { return now.addingTimeInterval(10 * 60) }
        // 一時停止中は自発的な更新要求を出さない（リロードボタンで明示的に更新する）
        if entry.isPaused { return now.addingTimeInterval(60 * 60) }

        let interval: TimeInterval
        switch entry.approach?.kind {
        case .estimatedMinutes(let m):
            interval = m <= 2 ? 30 : 60
        case .departingSoon:
            interval = 45
        case .onSchedule:
            interval = 90
        case .unavailable, .other:
            interval = 120
        case .noBusApproaching:
            // 案内は生きていて、いつバスが現れてもおかしくないので短めに見る。
            interval = 60
        case .suspended:
            interval = 30 * 60
        case .none:
            // 取得失敗。一時的な通信エラーの可能性があるため長く空けない。
            interval = 60
        }
        return now.addingTimeInterval(interval)
    }

    /// ウィジェット拡張はWidgetKitの実行時間制限が厳しく、ここで通信すると間に合わず
    /// 古いタイムラインが表示され続けることがある。系統の解決に `configuration.resolvedRoute()`
    /// （tobus.jpへの通信を伴う）は使わず、ウィジェット設定に保存済みの値だけで組み立てる。
    ///
    /// 接近状況・定刻はAppがApp Group経由で共有するスナップショットを読むだけで、ここでは通信しない
    /// （メニューバーアプリとウィジェット拡張が別々に同じ問い合わせをする重複を避けるため）。
    /// 通信しない以上、一時停止中かどうかで組み立て方を変える必要はなく、`isPaused` は表示にのみ使う。
    private func buildEntry(configuration: SelectBusStopIntent, now: Date) -> BusEntry {
        let routeID = configuration.route?.id
        let routeName = configuration.route?.name
        let timetable = routeID.flatMap { AppSettings.schedule(routeID: $0) }
        let upcoming = timetable?.upcoming(now: now)
        return BusEntry(
            date: now,
            routeID: routeID,
            routeDisplayName: routeName,
            routeLabel: Self.firstWord(of: routeName),
            routeDestination: Self.dropFirstWord(of: routeName),
            stopName: configuration.stop?.name,
            approach: routeID.flatMap { AppSettings.snapshot(routeID: $0) },
            scheduled: upcoming?.departures ?? [],
            scheduleKind: upcoming?.kind,
            scheduleIsNextDay: upcoming?.isNextDay ?? false,
            scheduleLegend: timetable?.legend ?? [],
            isPaused: AppSettings.isPaused
        )
    }

    /// "都０５－１ 東京駅丸の内南口 行" のような表示名から系統ラベル部分だけを取り出す。
    private static func firstWord(of text: String?) -> String? {
        guard let text else { return nil }
        return text.split(separator: " ").first.map(String.init)
    }

    /// 同じ表示名から、系統ラベルを除いた残り（＝行き先）を取り出す。
    /// 系統ラベルしか無い表示名では nil。
    private static func dropFirstWord(of text: String?) -> String? {
        guard let text else { return nil }
        let parts = text.split(separator: " ", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let rest = parts[1].trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? nil : rest
    }
}

struct TobusWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    var entry: Provider.Entry

    /// 補足情報（「〜時点」「定刻」）用。主役の「約〇分後」を目立たせるため、
    /// 最小の標準スタイル `.caption2` よりさらに小さくしたく、実寸で指定している。
    private static let footnoteFont = Font.system(size: 9)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            liveStatus
            Spacer(minLength: 0)
            observedAtLine
            scheduleFooter
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                if family == .systemSmall {
                    // 小サイズは横幅が狭く「系統＋行き先」を1行で入れると収まらないため、
                    // 系統ラベル・行き先・バス停名を行に分けて出す。
                    if let routeLabel = entry.shortRouteLabel {
                        Text(routeLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    if let destination = entry.shortDestination {
                        Text(destination)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    Text(entry.shortHeaderText)
                        .font(.caption.bold())
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                } else {
                    if let stopName = entry.stopName, !stopName.isEmpty {
                        Text(stopName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    Text(entry.routeDisplayName ?? entry.stopName ?? "都バス")
                        .font(.subheadline.bold())
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            Spacer(minLength: 0)
            if entry.routeID != nil {
                HStack(spacing: 8) {
                    Button(intent: TogglePauseIntent()) {
                        Image(systemName: entry.isPaused ? "play.fill" : "pause.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(entry.isPaused ? .orange : .secondary)

                    Button(intent: RefreshBusIntent(routeID: entry.routeID)) {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// 表示値がいつ時点のものかを示す。一時停止中は値が固定されるため特に重要。
    @ViewBuilder
    private var observedAtLine: some View {
        if let approach = entry.approach {
            HStack(spacing: 4) {
                if entry.isPaused {
                    Image(systemName: "pause.circle")
                        .foregroundStyle(.orange)
                } else if approach.isStale(asOf: entry.date) {
                    // 通信エラーが続くと古いスナップショットが表示され続けるため、目安として警告を出す。
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                Text("\(approach.observedAt, format: .dateTime.hour().minute()) 時点")
                if entry.isPaused {
                    Text("· 一時停止中")
                        .foregroundStyle(.orange)
                }
            }
            .font(Self.footnoteFont)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
    }

    @ViewBuilder
    private var scheduleFooter: some View {
        // エントリに焼き込んだ定刻は、WidgetKit がタイムラインを進めないと前日のダイヤのまま残る。
        // 保存済み時刻表から「今」の区分を毎分載せ直せば、アプリなしでも日付変更に追従できる。
        TimelineView(.everyMinute) { context in
            let live = resolvedSchedule(at: context.date)
            if !live.departures.isEmpty {
                let shown = Array(live.departures.prefix(family == .systemSmall ? 2 : 3))
                let usedMarks = Set(shown.compactMap(\.mark).filter { !$0.isEmpty })
                let captions = live.legend
                    .filter { usedMarks.contains($0.symbol) }
                    .map(\.caption)
                VStack(alignment: .leading, spacing: 1) {
                    Text(TobusConfig.scheduleHeading(kind: live.kind, isNextDay: live.isNextDay))
                        .font(Self.footnoteFont)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    HStack(spacing: 6) {
                        ForEach(Array(shown.enumerated()), id: \.offset) { _, dep in
                            HStack(spacing: 1) {
                                Text(dep.date, format: .dateTime.hour().minute())
                                    .monospacedDigit()
                                if let mark = dep.mark, !mark.isEmpty {
                                    Text(mark)
                                }
                            }
                            .font(Self.footnoteFont)
                            .foregroundStyle(.secondary)
                        }
                    }
                    if !captions.isEmpty {
                        Text(captions.joined(separator: " · "))
                            .font(Self.footnoteFont)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .minimumScaleFactor(0.7)
                    }
                }
            }
        }
    }

    /// タイムラインのスナップショットではなく、保存済み時刻表を `date` 時点で解釈した結果。
    private func resolvedSchedule(at date: Date) -> (departures: [ScheduledDeparture], kind: String?, isNextDay: Bool, legend: [TimetableMark]) {
        if let routeID = entry.routeID, let timetable = AppSettings.schedule(routeID: routeID) {
            let upcoming = timetable.upcoming(now: date)
            return (upcoming.departures, upcoming.kind, upcoming.isNextDay, timetable.legend)
        }
        return (entry.scheduled, entry.scheduleKind, entry.scheduleIsNextDay, entry.scheduleLegend)
    }

    @ViewBuilder
    private var liveStatus: some View {
        if entry.routeID == nil {
            Label("ウィジェットを編集してバス停・系統を選択", systemImage: "gearshape")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                statusBody
                followingBusesLine
                if let note = entry.approach?.noteText {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    /// 同じ系統に2台以上接近しているときの、2台目以降。
    /// 1台目を逃したときの判断に使えるよう、主役の数字のすぐ下に小さく添える。
    @ViewBuilder
    private var followingBusesLine: some View {
        let following = entry.approach?.followingMinutes ?? []
        if !following.isEmpty {
            // 小サイズは縦幅が厳しいので1台分だけ。中サイズは入るだけ並べる。
            let shown = family == .systemSmall ? Array(following.prefix(1)) : following
            Text("次 \(shown.map(Self.minutesText).joined(separator: "、"))")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private static func minutesText(_ minutes: Int) -> String {
        minutes <= 0 ? "まもなく" : "\(minutes)分後"
    }

    @ViewBuilder
    private var statusBody: some View {
        switch entry.approach?.kind {
        case .estimatedMinutes(let m):
            // 「まもなく到着」は今すぐ動く必要がある状態なので、分数表示と色で区別する
            // （江戸バス版と同じ配色: 到着＝緑）。
            Text(m <= 0 ? "まもなく到着" : "約\(m)分後")
                .font(.system(size: family == .systemSmall ? 23 : 35, weight: .semibold, design: .rounded))
                .foregroundStyle(m <= 0 ? Color.green : Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)

        case .departingSoon:
            statusText("まもなく発車", color: .green, systemImage: "bus.fill")

        case .onSchedule:
            statusText("定刻運行中", color: .primary, systemImage: "checkmark.circle")

        case .unavailable:
            Text("接近情報を案内できません")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

        case .noBusApproaching:
            // 運行情報自体は正常なので「案内できません」とは区別する。
            Text("接近中のバスなし")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

        case .suspended:
            statusText("本日は運休", color: .secondary, systemImage: "moon.zzz")

        case .other(let text):
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)

        case .none:
            if entry.isPaused {
                Label("一時停止中", systemImage: "pause.circle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            } else {
                Text("接近状況を取得できません")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func statusText(_ text: String, color: Color, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.title3.bold())
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}

struct TobusWidget: Widget {
    let kind: String = "TobusWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: SelectBusStopIntent.self, provider: Provider()) { entry in
            TobusWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("都バス接近情報")
        .description("選んだバス停・系統の車両接近情報を、都バス運行情報サービス（tobus.jp）から表示します。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
