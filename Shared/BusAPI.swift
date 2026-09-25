import Foundation
import os

let busLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "TobusWidget",
    category: "BusData"
)

enum BusAPIError: LocalizedError {
    case invalidURL
    case httpStatus(Int)
    case emptyResponse
    case undecodableResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "URLを組み立てられません"
        case .httpStatus(let code): return "サーバーがエラーを返しました（HTTP \(code)）"
        case .emptyResponse: return "サーバーの応答が空です"
        case .undecodableResponse: return "サーバーの応答をUTF-8として読めません"
        }
    }
}

/// 都バス運行情報サービス（tobus.jp）。
/// 公式API・オープンデータではなく、公式サイトが内部で使っているHTML画面をそのまま取得し、
/// クライアント側でHTML解析する（[[TobusPageParser]] 参照）。
///
/// `JSESSIONID` のCookieがレスポンスに付くが、動作確認の結果、リクエスト側では不要な
/// ステートレスなGETとして利用できる（セッションを継続する必要はない）。
enum BusAPI {
    static let host = "tobus.jp"
    static let path = "/blsys/navi"

    /// 追加データを待つ上限。`URLRequest(url:)` は既定で `timeoutInterval` = 60秒を持ち、
    /// セッション設定の `timeoutIntervalForRequest` より優先されるため、リクエスト側にも同じ値を設定する。
    private static let requestTimeout: TimeInterval = 15

    /// **Cookieを保持しない専用セッション。`URLSession.shared` を使ってはいけない。**
    ///
    /// tobus.jp は応答に `JSESSIONID` を付けてくる。`URLSession.shared` は Cookie を自動で
    /// 保存・送信するため、以降の全リクエストが同一セッションに乗る。時刻表は
    /// 「行き先選択」→「時刻表本体」の2段階で、サーバー側がセッションに選択状態を持つため、
    /// **複数系統を並行して取ると互いの選択を上書きし合い、別系統の時刻表が返る**
    /// （2026-08-16に都０３・都０５－１・都０５－２で再現。詳細は CLAUDE.md）。
    ///
    /// Cookieを送らなければリクエストごとに独立したセッションになり、この競合は起きない。
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // 既定（リクエスト60秒・リソース7日）のままだと、応答の遅い回が次の60秒周期に重なり、
        // single-flight で相乗りした待ち手ごと止まる。60秒周期の中で必ず決着させる。
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }()

    static func url(query: [String: String]) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url
    }

    /// サーバー側のエッジキャッシュが60秒（レスポンスの `Cache-Control: s-maxage=60`）のため、
    /// これより高頻度で取得しても新しい情報は返らない。
    static func fetchHTML(query: [String: String]) async throws -> String {
        guard let url = url(query: query) else { throw BusAPIError.invalidURL }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = requestTimeout
        busLogger.debug("API request: \(loggableDescription(of: query), privacy: .public)")
        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw BusAPIError.httpStatus(http.statusCode)
            }
            guard !data.isEmpty else { throw BusAPIError.emptyResponse }
            guard let html = String(data: data, encoding: .utf8) else {
                throw BusAPIError.undecodableResponse
            }
            return html
        } catch {
            busLogger.error("取得に失敗: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// 利用者が入力した検索語（`srtxt`）は行動範囲を推測できる個人情報なので、
    /// `.public` のログには値を残さず、キーだけを出す（検索語は `performSearch` 側で `.private` として記録する）。
    private static let privateQueryKeys: Set<String> = ["srtxt"]

    static func loggableDescription(of query: [String: String]) -> String {
        query
            .map { privateQueryKeys.contains($0.key) ? "\($0.key)=<private>" : "\($0.key)=\($0.value)" }
            .sorted()
            .joined(separator: "&")
    }

    /// 停留所名称検索（部分一致）。ひらがな・カタカナは2文字以上、漢字は1文字から検索できる。
    static func searchStopsHTML(query text: String) async throws -> String {
        try await fetchHTML(query: [
            "VCD": "csrst", "ECD": "search", "LCD": "",
            "func": "fap", "method": "msn",
            "slst": "", "slrsp": "", "srtxt": text,
        ])
    }

    /// 指定した停留所グループ（`slst`）の車両接近情報ページ。そのグループに属する全のりば・全系統がまとめて返る。
    static func stopPageHTML(slst: Int) async throws -> String {
        try await fetchHTML(query: [
            "VCD": "csrst", "ECD": "NEXT", "LCD": "",
            "func": "fap", "method": "msn",
            "slst": String(slst),
        ])
    }

    /// 時刻表の「行き先選択」ページ。時刻表本体を取得するための `onclick="func_stoppole(...)"` パラメータを含む。
    static func destinationSelectHTML(slst: Int, pl: Int, rtmcd: Int) async throws -> String {
        try await fetchHTML(query: [
            "LCD": "", "VCD": "SelectDest", "ECD": "SelectDest",
            "slst": String(slst), "pl": String(pl), "RTMCD": String(rtmcd),
        ])
    }

    /// 時刻表本体のページ。
    static func timetableHTML(rtmcd: Int, slst: Int, pl: Int, lrid: Int, tgo: Int) async throws -> String {
        try await fetchHTML(query: [
            "VCD": "cresultttbl", "ECD": "show",
            "RTMCD": String(rtmcd), "slst": String(slst), "bs": String(slst),
            "pl": String(pl), "lrid": String(lrid), "tgo": String(tgo),
        ])
    }
}
