import SwiftUI
import WidgetKit
import AppIntents

@main
struct TobusWidgetApp: App {
    @StateObject private var model = ArrivalModel()

    var body: some Scene {
        // メニューバー常駐。ここから定期的にウィジェットを更新するため、
        // ウィジェット単体では更新されない macOS の制約を回避できる。
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Label(model.menuBarTitle, systemImage: model.isPaused ? "bus" : "bus.fill")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class ArrivalModel: ObservableObject {
    /// 常駐中の取得間隔。サーバー側のエッジキャッシュ（60秒）より短くしても意味がない。
    private static let refreshInterval: TimeInterval = 60

    @Published var stopSearchText: String = ""
    @Published var stopResults: [BusStopCluster] = []
    /// tobus.jpの検索仕様（ひらがな・カタカナは2文字以上）を満たさない場合の案内文。
    @Published var searchHint: String?
    @Published var selectedStop: BusStopCluster? {
        didSet {
            guard selectedStop != oldValue else { return }
            // 停留所が変わったら、前の停留所に属する表示状態をすべて捨てる。
            // `approach` を残すとメニューの表示条件（`approach` を `selectedRoute` より優先する）により、
            // 新しい停留所を選んだのに前の系統の「約N分後」が出続ける。
            // 系統一覧の取得には通信が要るので、この空白期間は必ず発生する。
            routeBlocks = []
            selectedRoute = nil
            approach = nil
            scheduled = []
            scheduleKind = nil
            scheduleIsNextDay = false
            scheduleLegend = []
            errorText = nil
            selectionGeneration += 1
            if let stop = selectedStop {
                Task { await routeChanged(slst: stop.slst, generation: selectionGeneration) }
            }
        }
    }
    @Published var routeBlocks: [RouteBlock] = []

    /// 系統ピッカー用の選択。`RouteBlock` は `id` 込みで `Hashable` だが、
    /// 復元した `selectedRoute` は**保存済みの安定ID**を持つ一方、`routeBlocks` の要素は
    /// **現在の並び順から作られたID**を持つ。並びがずれた直後は同じ系統でもIDが食い違い、
    /// `selectedRoute` をそのままタグに使うとピッカーが未選択に見える。
    /// 安定IDは保存のためだけのものなので、画面上の突き合わせは並び順で行う。
    var selectedRouteOrdinal: Int? {
        get { selectedRoute?.ordinal }
        set { selectedRoute = newValue.flatMap { ordinal in routeBlocks.first { $0.ordinal == ordinal } } }
    }
    @Published var selectedRoute: RouteBlock? {
        didSet {
            guard selectedRoute != oldValue else { return }
            // 系統が変わったら定刻も捨てる。取得は非同期なうえ、読み取りに失敗した回は
            // 「前回値を残す」扱いになるため、消さないと**前の系統の定刻が新しい系統の
            // 接近情報の下に出続ける**（恒久的に読めないページなら消えない）。
            // 停留所を変えたときと同じ扱いに揃える。
            scheduled = []
            scheduleKind = nil
            scheduleIsNextDay = false
            scheduleLegend = []
            saveSelection()
            selectionGeneration += 1
            Task { await refresh(generation: selectionGeneration) }
        }
    }

    @Published var approach: BusApproach?
    /// 本日の残り定刻（時刻順）。
    @Published var scheduled: [ScheduledDeparture] = []
    /// `scheduled` がどのダイヤ区分のものか（`平日` / `土曜` / `休日`）。判別できなければ nil。
    @Published var scheduleKind: String?
    /// `scheduled` が翌日分か（本日分が尽きたとき）。
    @Published var scheduleIsNextDay = false
    /// 時刻表ページの記号説明。記号が無い系統では空。
    @Published var scheduleLegend: [TimetableMark] = []
    @Published var errorText: String?
    /// 一時停止中は定期取得を行わない。設定は次回起動にも引き継ぐ。
    @Published private(set) var isPaused: Bool

    private var timer: Timer?
    private var selectionGeneration = 0
    private var searchGeneration = 0
    private var didRestoreSelection = false

    init() {
        isPaused = AppSettings.isPaused
        observePauseChangesFromWidget()
        observeManualRefreshRequestsFromWidget()
        Task { await restoreSelectionIfNeeded() }
        if !isPaused {
            startTimer()
            // メニューバー側の選択が無くても、配置済みウィジェットの分は取得する。
            Task { await refresh(force: true) }
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    /// 前回選択していた停留所・系統を、再検索なしで復元する。
    private func restoreSelectionIfNeeded() async {
        guard !didRestoreSelection else { return }
        didRestoreSelection = true
        let saved = loadSelection()
        guard saved.slst != 0 else { return }
        guard let name = await BusDirectoryService.stopName(slst: saved.slst) else { return }
        selectedStop = BusStopCluster(slst: saved.slst, name: name)
    }

    func performSearch() async {
        let text = stopSearchText.trimmingCharacters(in: .whitespaces)
        busLogger.debug("performSearch: text=\(text, privacy: .public)")
        guard !text.isEmpty else {
            stopResults = []
            searchHint = nil
            return
        }
        // tobus.jp自体の検索仕様: ひらがな・カタカナ1文字だけだとエラーになる（漢字は1文字でも可）。
        // 事前に弾いておくことで、無駄なリクエストとサーバー側のエラーページ表示を避ける。
        guard !Self.isSingleKanaCharacter(text) else {
            stopResults = []
            searchHint = "ひらがな・カタカナは2文字以上入力してください"
            return
        }
        searchHint = nil

        // 検索中に入力が変わった場合、後から遅れて届いた古い検索結果で
        // 新しい結果を上書きしないようにする（非同期処理の順序が入れ替わることがあるため）。
        searchGeneration += 1
        let generation = searchGeneration
        do {
            let results = try await BusDirectoryService.searchStops(query: text)
            guard generation == searchGeneration else { return }
            stopResults = results
            busLogger.debug("performSearch: \(self.stopResults.count, privacy: .public) 件")
        } catch {
            guard generation == searchGeneration else { return }
            // 入力のたびに前の検索がキャンセルされる（`.task(id:)`）。キャンセルは失敗ではないうえ、
            // 後続タスクはデバウンス中でまだ世代を進めていないため上の world チェックを素通りする。
            // ここで弾かないと、打鍵のたびに誤ったエラーが一瞬表示される。
            guard !Self.isCancellation(error) else { return }
            busLogger.error("performSearch failed: \(String(describing: error), privacy: .public)")
            stopResults = []
            // 黙って空にすると「ヒットなし」と区別がつかず、通信断に気づけない。
            searchHint = "検索できませんでした（\(error.localizedDescription)）"
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        return (error as? URLError)?.code == .cancelled
    }

    private func observePauseChangesFromWidget() {
        DistributedNotificationCenter.default().addObserver(
            forName: .busPauseStateChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.syncPauseState() }
        }
    }

    private func observeManualRefreshRequestsFromWidget() {
        DistributedNotificationCenter.default().addObserver(
            forName: .busManualRefreshRequested,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refresh(force: true) }
        }
    }

    private func syncPauseState() {
        let shared = AppSettings.isPaused
        guard shared != isPaused else { return }
        if shared {
            pause(propagate: false)
        } else {
            resume(propagate: false)
        }
    }

    /// メニューバーに出す短い文字列
    var menuBarTitle: String {
        if isPaused { return "停止中" }
        guard let approach else { return "--" }
        switch approach.kind {
        case .estimatedMinutes(let m): return m <= 0 ? "まもなく" : "約\(m)分"
        case .departingSoon: return "まもなく発車"
        case .onSchedule: return "定刻運行"
        case .unavailable: return "--"
        case .noBusApproaching: return "接近なし"
        case .suspended: return "運休"
        case .other: return "--"
        }
    }

    func pause(propagate: Bool = true) {
        isPaused = true
        timer?.invalidate()
        timer = nil
        if propagate {
            AppSettings.isPaused = true
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    func resume(propagate: Bool = true) {
        isPaused = false
        if propagate {
            AppSettings.isPaused = false
        }
        startTimer()
        Task { await refresh(force: true) }
    }

    private func routeChanged(slst: Int, generation: Int) async {
        let fetched: [RouteBlock]
        do {
            fetched = try await BusDirectoryService.fetchRouteBlocks(slst: slst)
        } catch {
            // 空配列で黙ると「系統を選んでください」と区別がつかず、通信断に気づけない。
            busLogger.error("slst=\(slst, privacy: .public) の系統一覧取得に失敗: \(String(describing: error), privacy: .public)")
            guard generation == selectionGeneration, selectedStop?.slst == slst else { return }
            errorText = error.localizedDescription
            return
        }
        guard generation == selectionGeneration, selectedStop?.slst == slst else { return }
        routeBlocks = fetched
        errorText = nil

        // 保存済みの選択を復元してよいのは、同じ停留所に戻ってきたときだけ。
        // 別の停留所では ordinal は単なるページ内の並び順なので、前の停留所のN番目に
        // 相当する無関係な系統を選んでしまう。
        //
        // 同じ停留所でも ordinal 直当てでは足りない。tobus.jp 側でのりばや系統が増えると
        // 並び順がずれ、保存した「N番目」が別系統になる。ウィジェットと同じ多段引き当て
        // （RTMCD → 系統名+行き先 → ordinal）を使う。手がかりは `saveSelection()` が
        // `routeIdentity` として書いてある。
        let saved = loadSelection()
        var restored: RouteBlock?
        if saved.slst == slst {
            // 保存済みIDをそのまま使う。無いのは旧バージョンからの移行時だけで、
            // そのときに限り ordinal から組み立てる（以降は安定IDが保存される）。
            let id = saved.routeID ?? "\(slst)#\(saved.ordinal)"
            restored = BusDirectoryService.resolve(
                id: id,
                ordinal: saved.ordinal,
                identity: AppSettings.routeIdentity(routeID: id),
                in: fetched
            )
        }
        selectedRoute = restored ?? fetched.first
    }

    /// - Parameters:
    ///   - force: 一時停止中でも取得する（「今すぐ更新」など明示操作のとき）
    ///   - generation: 取得開始時点の選択世代。省略時は現在の選択に追従する。
    func refresh(force: Bool = false, generation: Int? = nil) async {
        guard force || !isPaused else { return }

        // メニューバー自身の選択（あれば）を取得する。
        if let route = selectedRoute {
            let generation = generation ?? selectionGeneration

            func isCurrent() -> Bool {
                generation == selectionGeneration && selectedRoute == route
            }

            do {
                let result = try await BusLocationService.fetchApproach(for: route)
                AppSettings.saveSnapshot(result, routeID: route.id)
                guard isCurrent() else { return }
                approach = result
                errorText = nil
            } catch {
                guard isCurrent() else { return }
                errorText = error.localizedDescription
            }

            // 時刻表は1日1回取得できれば十分なため（BusScheduleService側で日次キャッシュ済み）、
            // 60秒ごとの本処理内で呼んでもコストは小さい。
            //
            // 読み取れなかった場合は例外になるので、この節ごと飛ばして前回の表示を保つ
            // （接近情報の失敗時と同じ扱い）。時刻表を持たない系統は空が返るので、
            // その場合は `scheduled` が空になり定刻の行が消える。
            if let timetable = try? await BusScheduleService.fetchTimetable(for: route) {
                AppSettings.saveSchedule(timetable, routeID: route.id)
                guard isCurrent() else { return }
                let upcoming = timetable.upcoming()
                scheduled = upcoming.departures
                scheduleKind = upcoming.kind
                scheduleIsNextDay = upcoming.isNextDay
                scheduleLegend = timetable.legend
            }
        }

        // 取得はここに一本化しているため、メニューバーの選択が無い／異なる系統を表示している
        // ウィジェットの分もあわせて取得しておく（ウィジェット側は通信しない）。
        // メニューバー側が未選択でも、配置済みウィジェットの取得は独立して行う。
        await refreshWidgetOnlyApproaches(excluding: selectedRoute?.id)

        // 配置済みウィジェットを更新する。
        // WidgetKit は自前のタイムライン要求をほとんど実行しないため、ここが実質の更新契機になる。
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func refreshWidgetOnlyApproaches(excluding excludedID: String?) async {
        let routes = await widgetConfiguredRoutes().filter { $0.id != excludedID }
        busLogger.debug("widget-only routes to refresh: \(routes.map(\.id), privacy: .public)")
        guard !routes.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for route in routes {
                group.addTask {
                    do {
                        let result = try await BusLocationService.fetchApproach(for: route)
                        AppSettings.saveSnapshot(result, routeID: route.id)
                        busLogger.debug("saved snapshot for \(route.id, privacy: .public): \(String(describing: result.kind), privacy: .public)")
                    } catch {
                        busLogger.error("\(route.id, privacy: .public) の接近状況取得に失敗: \(String(describing: error), privacy: .public)")
                    }
                    if let timetable = try? await BusScheduleService.fetchTimetable(for: route) {
                        AppSettings.saveSchedule(timetable, routeID: route.id)
                    }
                }
            }
        }
    }

    /// tobus.jpの検索仕様: 「ひらがな又はカタカナで検索する場合は、２文字以上を入力して下さい」
    /// （漢字は1文字でも検索可能）。停留所名称検索ページ自身のJS（`wordCheck`）と同じ判定。
    static func isSingleKanaCharacter(_ text: String) -> Bool {
        guard text.count == 1, let scalar = text.unicodeScalars.first else { return false }
        let hiragana: ClosedRange<UInt32> = 0x3041...0x3096
        let katakana: ClosedRange<UInt32> = 0x30A1...0x30F6
        return hiragana.contains(scalar.value) || katakana.contains(scalar.value)
    }

    /// 配置中の各ウィジェットが表示している系統（重複なし）。
    private func widgetConfiguredRoutes() async -> [RouteBlock] {
        let infos: [WidgetInfo]
        do {
            infos = try await withCheckedThrowingContinuation { continuation in
                WidgetCenter.shared.getCurrentConfigurations { continuation.resume(with: $0) }
            }
        } catch {
            busLogger.error("getCurrentConfigurations に失敗: \(String(describing: error), privacy: .public)")
            return []
        }
        busLogger.debug("getCurrentConfigurations: \(infos.count, privacy: .public) 件")

        var seen = Set<String>()
        var routes: [RouteBlock] = []
        for info in infos {
            // `info.configuration` は `Intents.INIntent?` 型で、AppIntentsベースの
            // `SelectBusStopIntent` へは決してキャストできない（`as?` は常にnilになる）。
            // AppIntents用の専用アクセサを使う必要がある。
            guard let intent = info.widgetConfigurationIntent(of: SelectBusStopIntent.self) else {
                busLogger.error("widgetConfigurationIntent(of:) が nil")
                continue
            }
            guard let route = await intent.resolvedRoute() else {
                busLogger.error("resolvedRoute() が nil（stop=\(intent.stop?.id ?? "nil", privacy: .public), route=\(intent.route?.id ?? "nil", privacy: .public)）")
                continue
            }
            if seen.insert(route.id).inserted {
                routes.append(route)
            }
        }
        return routes
    }

    // MARK: - 選択の保存

    private func saveSelection() {
        guard let route = selectedRoute else { return }
        AppSettings.selectedSlst = route.slst
        AppSettings.selectedOrdinal = route.ordinal
        // 復元のキーはこの安定IDを使う（現在の並び順から組み立て直さない）。
        AppSettings.selectedRouteID = route.id
        // ウィジェット設定と同じ系統をメニューバーでも選んでいる場合に、
        // 並び順が変わったときの引き当て手がかりを最新に保つ。
        AppSettings.saveRouteIdentity(route)
    }

    private func loadSelection() -> (slst: Int, ordinal: Int, routeID: String?) {
        (AppSettings.selectedSlst, AppSettings.selectedOrdinal, AppSettings.selectedRouteID)
    }
}

struct MenuContent: View {
    @ObservedObject var model: ArrivalModel
    @FocusState private var searchFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            search
            if model.selectedStop != nil {
                Divider()
                routePicker
                Divider()
                status
                scheduleRow
            }
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 340, alignment: .leading)
        // MenuBarExtra(.window) はポップオーバー表示後にSwiftUI側のコンテンツの高さが変わっても
        // ウィンドウが追従して自動リサイズされないことがある（検索候補が後から出現する場合など）。
        // fixedSize を明示することで、コンテンツサイズの変化のたびに正しく再計算・反映させる。
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            // MenuBarExtra(.window) はポップオーバーを開いてもウィンドウが必ずしも
            // キーウィンドウにならず、TextFieldがキー入力を受け取れないことがある。
            // 明示的にアプリをアクティブ化し、検索欄にフォーカスを当てる。
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                searchFieldFocused = true
            }
        }
        .task(id: model.stopSearchText) {
            busLogger.debug("search .task fired, id=\(model.stopSearchText, privacy: .public)")
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else {
                busLogger.debug("search .task cancelled")
                return
            }
            await model.performSearch()
        }
    }

    private var search: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("バス停").foregroundStyle(.secondary).font(.caption)
            TextField("バス停名で検索（例: 東京駅）", text: $model.stopSearchText)
                .textFieldStyle(.roundedBorder)
                .focused($searchFieldFocused)

            if let hint = model.searchHint {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            // 新しい検索候補が出ている間は、紛らわしいので選択中のバス停名は隠す
            // （候補リストの一部に見えてしまうため）。
            if let stop = model.selectedStop, model.stopResults.isEmpty {
                HStack(spacing: 4) {
                    Text("選択中:").foregroundStyle(.secondary)
                    Text(stop.name).font(.callout.bold())
                    Spacer()
                }
            }

            if !model.stopResults.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(model.stopResults) { cluster in
                            Button {
                                model.selectedStop = cluster
                                model.stopSearchText = ""
                                model.stopResults = []
                            } label: {
                                Text(cluster.name)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 100)
            }
        }
    }

    @ViewBuilder
    private var routePicker: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                Text("系統").foregroundStyle(.secondary)
                Picker("", selection: $model.selectedRouteOrdinal) {
                    ForEach(model.routeBlocks) { route in
                        Text(route.displayName).tag(Optional(route.ordinal))
                    }
                }
                .labelsHidden()
            }
        }
    }

    @ViewBuilder
    private var scheduleRow: some View {
        if !model.scheduled.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(TobusConfig.scheduleHeading(kind: model.scheduleKind, isNextDay: model.scheduleIsNextDay))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    ForEach(Array(model.scheduled.prefix(4).enumerated()), id: \.offset) { _, dep in
                        labeledTime(dep)
                    }
                }
                if !model.scheduleLegend.isEmpty {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(model.scheduleLegend, id: \.viewID) { mark in
                            Text(mark.caption)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func labeledTime(_ dep: ScheduledDeparture) -> some View {
        HStack(spacing: 1) {
            Text(dep.date, format: .dateTime.hour().minute())
                .monospacedDigit()
            if let mark = dep.mark, !mark.isEmpty {
                Text(mark)
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        if let errorText = model.errorText {
            Label(errorText, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        } else if let approach = model.approach {
            VStack(alignment: .leading, spacing: 6) {
                arrivalText(approach)
                HStack(spacing: 4) {
                    Text("\(approach.observedAt, format: .dateTime.hour().minute()) 時点の情報")
                    if approach.isStale() {
                        Label("更新できていない可能性があります", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                if model.isPaused {
                    Label("一時停止中（自動更新なし）", systemImage: "pause.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        } else if model.isPaused {
            Label("一時停止中", systemImage: "pause.circle")
                .font(.callout)
                .foregroundStyle(.orange)
        } else if model.selectedRoute == nil {
            Text("系統を選んでください")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            ProgressView().controlSize(.small)
        }
    }

    @ViewBuilder
    private func arrivalText(_ approach: BusApproach) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            switch approach.kind {
            case .estimatedMinutes(let m):
                // 江戸バス版と同じ配色: 到着＝緑。分数が出ているうちは既定色のまま。
                Text(m <= 0 ? "まもなく到着" : "約\(m)分後")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .foregroundStyle(m <= 0 ? Color.green : Color.primary)
            case .departingSoon:
                Text("５分以内に発車予定")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .foregroundStyle(.green)
            case .onSchedule:
                Text("定刻で運行中")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
            case .unavailable:
                Text("接近情報を案内できません")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .noBusApproaching:
                // 運行情報自体は正常なので「案内できません」とは区別する。
                Text("接近中のバスはいません")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .suspended:
                Text("本日は運休日です")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            case .other(let text):
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // 同じ系統に2台以上接近しているときは、後続も出す（メニューは幅に余裕があるので全台）。
            if !approach.followingMinutes.isEmpty {
                let shown = approach.followingMinutes.map { $0 <= 0 ? "まもなく" : "\($0)分後" }
                Text("次 \(shown.joined(separator: "、"))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let note = approach.noteText {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Link(destination: URL(string: "https://tobus.jp/blsys/navi")!) {
                Label("都バス運行情報サービスで見る", systemImage: "map")
                    .font(.caption)
            }

            Text("データ提供: 東京都交通局（都バス運行情報サービス）。個人利用の範囲でご利用ください。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button(model.isPaused ? "再開" : "一時停止") {
                    if model.isPaused { model.resume() } else { model.pause() }
                }
                Button("今すぐ更新") {
                    Task { await model.refresh(force: true) }
                }
                Spacer()
                Button("終了") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .font(.caption)
        }
    }
}
