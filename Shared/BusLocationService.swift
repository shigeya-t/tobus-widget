import Foundation

enum BusLocationService {
    /// 指定した系統ブロックの現在の接近状況を取得する。
    /// 実体は停留所ページ（`slst`単位）の取得で、同じ停留所の他系統と同じキャッシュを共有する。
    static func fetchApproach(for route: RouteBlock) async throws -> BusApproach {
        let page = try await TobusPageService.fetchPage(slst: route.slst)
        guard let block = page.blocks.first(where: { $0.ordinal == route.ordinal }) else {
            // ページの並びが変わった等でブロックが見つからない場合。取得自体は成功しているので
            // エラーにはせず、不明として返す。ただし静かに劣化するとウィジェットが
            // 「案内できません」のまま止まる原因になるため、必ず記録に残す。
            busLogger.error("slst=\(route.slst, privacy: .public) のページに ordinal=\(route.ordinal, privacy: .public) が見つかりません（全\(page.blocks.count, privacy: .public)件）")
            return BusApproach(
                kind: .unavailable,
                statusText: "この系統は現在ページに見つかりません",
                noteText: nil,
                observedAt: page.observedAt
            )
        }
        let kind = BusApproachKind(statusText: block.statusText, estimatedMinutes: block.estimatedMinutes)
        busLogger.debug("fetchApproach \(route.id, privacy: .public): \(String(describing: kind), privacy: .public)（\(block.statusText, privacy: .public)）")
        return BusApproach(
            kind: kind,
            statusText: block.statusText,
            noteText: block.noteText,
            observedAt: page.observedAt
        )
    }
}
