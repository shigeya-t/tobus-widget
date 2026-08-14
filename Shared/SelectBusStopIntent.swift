import AppIntents

struct BusStopClusterEntity: AppEntity {
    let id: String
    let name: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "バス停" }
    static var defaultQuery = BusStopClusterQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    init(_ cluster: BusStopCluster) {
        self.id = String(cluster.slst)
        self.name = cluster.name
    }
}

/// 停留所は数千件あり事前一覧化はできないため、入力文字列で都度 tobus.jp を検索する
/// `EntityStringQuery` を使う（`suggestedEntities()` だけの静的候補は提供しない）。
struct BusStopClusterQuery: EntityStringQuery {
    /// AppIntentsが保存済み設定を再検証する際などに呼ばれる。名前を空文字で返すと
    /// ウィジェットの表示名がそのまま空になって上書きされてしまうため、必ず実名を引き直す。
    ///
    /// 通信エラー等で実名を引けなかったときは、空文字のエンティティを返さず**その識別子を落とす**。
    /// 空文字を返すと保存済みの表示名が確実に壊れるが、返さなければ上書き自体が起きないため。
    func entities(for identifiers: [String]) async throws -> [BusStopClusterEntity] {
        var results: [BusStopClusterEntity] = []
        for idString in identifiers {
            guard let slst = Int(idString) else { continue }
            guard let name = await BusDirectoryService.stopName(slst: slst) else {
                busLogger.error("slst=\(slst, privacy: .public) の停留所名を引けませんでした（空文字での上書きを避けるため候補から除外）")
                continue
            }
            results.append(BusStopClusterEntity(BusStopCluster(slst: slst, name: name)))
        }
        return results
    }

    func entities(matching string: String) async throws -> [BusStopClusterEntity] {
        let clusters = (try? await BusDirectoryService.searchStops(query: string)) ?? []
        return clusters.map(BusStopClusterEntity.init)
    }
}

struct RouteBlockEntity: AppEntity {
    let id: String
    let name: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "系統" }
    static var defaultQuery = RouteBlockQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    init(_ route: RouteBlock) {
        self.id = route.id
        self.name = route.displayName
    }
}

struct RouteBlockQuery: EntityQuery {
    /// 選択中の停留所に属する系統だけを候補に出すため、同じIntentの stop パラメータを参照する
    @IntentParameterDependency<SelectBusStopIntent>(\.$stop)
    var selection

    func entities(for identifiers: [String]) async throws -> [RouteBlockEntity] {
        var results: [RouteBlockEntity] = []
        for id in identifiers {
            if let route = await BusDirectoryService.routeBlock(id: id) {
                results.append(RouteBlockEntity(route))
            }
        }
        return results
    }

    func suggestedEntities() async throws -> [RouteBlockEntity] {
        guard let slstString = selection?.stop.id, let slst = Int(slstString) else { return [] }
        let blocks = (try? await BusDirectoryService.fetchRouteBlocks(slst: slst)) ?? []
        return blocks.map(RouteBlockEntity.init)
    }
}

struct SelectBusStopIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "バス停を選択" }
    static var description: IntentDescription {
        IntentDescription("接近状況を表示するバス停と系統を選びます。")
    }

    @Parameter(title: "バス停")
    var stop: BusStopClusterEntity?

    @Parameter(title: "系統")
    var route: RouteBlockEntity?

    init() {}

    init(stop: BusStopClusterEntity, route: RouteBlockEntity) {
        self.stop = stop
        self.route = route
    }

    /// 設定値を実際のデータ取得に使う形へ解決する。未設定なら nil。
    func resolvedRoute() async -> RouteBlock? {
        guard let route else { return nil }
        return await BusDirectoryService.routeBlock(id: route.id)
    }
}
