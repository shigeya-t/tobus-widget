import Foundation

/// 停留所検索・系統一覧の取得。設定パネルの選択肢に使う。
/// 車両接近情報ページ（`slst`単位）は「その停留所の全のりば・全系統の一覧」と
/// 「各系統の現在の接近状況」を同時に返すため、[[BusLocationService]] と同じキャッシュ済みページを共有する。
enum BusDirectoryService {
    /// 停留所名称検索（部分一致）。空文字では検索しない。
    static func searchStops(query text: String) async throws -> [BusStopCluster] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let html = try await BusAPI.searchStopsHTML(query: trimmed)
        return try TobusPageParser.parseStopSearch(html: html)
    }

    /// 指定した停留所クラスタに属する系統（のりば×行き先）一覧。
    static func fetchRouteBlocks(slst: Int) async throws -> [RouteBlock] {
        let page = try await TobusPageService.fetchPage(slst: slst)
        return page.blocks.map {
            RouteBlock(
                slst: slst, ordinal: $0.ordinal, platformLabel: $0.platformLabel,
                label: $0.label, destination: $0.destination,
                timetableRTMCD: $0.timetableRTMCD, timetablePl: $0.timetablePl
            )
        }
    }

    /// idから系統を復元する（名称を埋めるためにページを引き直す）。
    ///
    /// id に埋まっている `ordinal` はページ内の並び順にすぎず、tobus.jp 側でのりばや系統が
    /// 増減すると別の系統を指してしまう。そのため保存済みの識別情報（[[AppSettings]] の
    /// `RouteIdentity`）を使って多段で引き当て、`ordinal` は最後の手段としてのみ使う。
    ///
    /// 返す `RouteBlock` の `id` は**要求されたものをそのまま**にする。ここで現在の並び順から
    /// 組み立て直すと、アプリが書くスナップショットのキーとウィジェットが読むキーがずれる。
    static func routeBlock(id: String) async -> RouteBlock? {
        guard let partial = RouteBlock(id: id) else {
            busLogger.error("RouteBlock id を解析できません: \(id, privacy: .public)")
            return nil
        }
        let blocks: [RouteBlock]
        do {
            blocks = try await fetchRouteBlocks(slst: partial.slst)
        } catch {
            busLogger.error("fetchRouteBlocks(slst: \(partial.slst, privacy: .public)) に失敗: \(String(describing: error), privacy: .public)")
            return nil
        }
        guard let match = resolve(id: id, ordinal: partial.ordinal, in: blocks) else {
            busLogger.error("id=\(id, privacy: .public) に一致する系統が見つかりません（全\(blocks.count, privacy: .public)件）")
            return nil
        }
        if match.ordinal != partial.ordinal {
            busLogger.debug("id=\(id, privacy: .public) の並び順が変わっています（ordinal \(partial.ordinal, privacy: .public) → \(match.ordinal, privacy: .public)）")
        }
        // 次回の引き当てに備えて最新の手がかりを控え直す。
        // 初回（まだ識別情報が無く ordinal で引き当てたとき）はここで初めて保存される。
        AppSettings.saveRouteIdentity(match)
        return match
    }

    /// 保存済みの識別情報で系統を引き当てる。見つけたブロックには要求された `id` を持たせて返す。
    private static func resolve(id: String, ordinal: Int, in blocks: [RouteBlock]) -> RouteBlock? {
        func adopt(_ block: RouteBlock) -> RouteBlock {
            RouteBlock(
                slst: block.slst, ordinal: block.ordinal, platformLabel: block.platformLabel,
                label: block.label, destination: block.destination,
                timetableRTMCD: block.timetableRTMCD, timetablePl: block.timetablePl,
                id: id
            )
        }

        if let saved = AppSettings.routeIdentity(routeID: id) {
            // ① 時刻表リンクの RTMCD（系統コード）＋ pl（のりば番号）。
            //    tobus.jp 内部のコードなので、表示文言が変わっても追随できる。
            //    ただし時刻表リンクを持たない系統では nil になるため万能ではない。
            if let rtmcd = saved.timetableRTMCD, let pl = saved.timetablePl,
               let hit = blocks.first(where: { $0.timetableRTMCD == rtmcd && $0.timetablePl == pl }) {
                return adopt(hit)
            }
            // ② 系統名＋行き先＋のりば。①が使えない系統向け。
            if let hit = blocks.first(where: {
                $0.label == saved.label && $0.destination == saved.destination
                    && $0.platformLabel == saved.platformLabel
            }) {
                return adopt(hit)
            }
            // ③ のりば表記だけが変わった場合に備え、系統名＋行き先まで緩める。
            if let hit = blocks.first(where: {
                $0.label == saved.label && $0.destination == saved.destination
            }) {
                return adopt(hit)
            }
        }

        // ④ 並び順。識別情報がまだ無い初回と、①〜③が空振りしたときのフォールバック。
        return blocks.first { $0.ordinal == ordinal }.map(adopt)
    }

    /// 保存済みの `slst` から停留所名だけを復元する（再検索なしでメニューバー表示を復元するため）。
    static func stopName(slst: Int) async -> String? {
        guard let page = try? await TobusPageService.fetchPage(slst: slst) else { return nil }
        return page.stopName.isEmpty ? nil : page.stopName
    }
}

/// 車両接近情報ページの取得結果を短時間キャッシュする。
/// サーバー側のエッジキャッシュが60秒のため、それよりわずかに短い50秒にしている。
/// 同じ停留所の複数系統（＝複数ウィジェット）が同じ更新サイクルで参照しても、
/// 実際のHTTPリクエストは1回にまとまる（[[PageCache]] で取得中のタスクを共有している）。
///
/// なお、このキャッシュはプロセス内に閉じている。アプリとウィジェット拡張は別プロセスなので
/// 共有されないが、拡張は通信しない設計（App Group のスナップショットを読むだけ）なので問題にならない。
enum TobusPageService {
    private static let cache = PageCache()

    static func fetchPage(slst: Int) async throws -> ParsedStopPage {
        try await cache.page(for: slst)
    }
}

/// キャッシュ判定と取得を1つのactor内で完結させ、取得中のリクエストを後続と共有する（single-flight）。
/// 「キャッシュを見る」「無ければ取る」を呼び出し側で分けて書くと、その間の `await` で
/// 他タスクが割り込み、全員がキャッシュミスして同時に同じページを取りに行ってしまう
/// （複数ウィジェットの更新契機は揃うため、実際に起きる）。
private actor PageCache {
    private enum Entry {
        case ready(page: ParsedStopPage, at: Date)
        case inFlight(Task<ParsedStopPage, Error>)
    }

    private var entries: [Int: Entry] = [:]
    private let lifetime: TimeInterval = 50

    func page(for slst: Int) async throws -> ParsedStopPage {
        switch entries[slst] {
        case .ready(let page, let at) where Date().timeIntervalSince(at) < lifetime:
            return page
        case .inFlight(let task):
            // 取得中の結果に相乗りする。呼び出し側のキャンセルが他の待ち手に波及しないよう、
            // 構造化された子タスクではなく独立した `Task` を共有している。
            return try await task.value
        case .ready, .none:
            break
        }

        let task = Task {
            let html = try await BusAPI.stopPageHTML(slst: slst)
            return try TobusPageParser.parseStopPage(html: html, slst: slst)
        }
        entries[slst] = .inFlight(task)
        do {
            let page = try await task.value
            entries[slst] = .ready(page: page, at: Date())
            return page
        } catch {
            // 失敗は残さない。残すと次の呼び出しまで再試行できなくなる。
            entries[slst] = nil
            throw error
        }
    }
}
