import Foundation
import SwiftSoup

struct ParsedStopPage {
    let slst: Int
    let stopName: String
    let observedAt: Date
    let blocks: [ParsedBlock]
}

struct ParsedBlock {
    let ordinal: Int
    let platformLabel: String
    let label: String
    let destination: String
    let statusText: String
    let estimatedMinutes: Int?
    /// 2台目以降の待ち時間（分、到着が早い順）。1台だけなら空。
    let followingMinutes: [Int]
    let noteText: String?
    let timetableRTMCD: Int?
    let timetablePl: Int?
}

/// 時刻表ページの解析結果。
struct ParsedTimetable {
    let times: [BusTime]
    /// ページ自身が申告している当日のダイヤ区分（`平日` / `土曜` / `休日`）。読み取れなければ nil。
    /// 表のIDがそのままこの文字列になっており、`times` はこの区分の表から取っている。
    let scheduleKind: String?

    static let empty = ParsedTimetable(times: [], scheduleKind: nil)
}

/// 「行き先選択」ページの `onclick="func_stoppole(...)"` から取れる、時刻表ページ本体を
/// 取得するために必要なパラメータ一式。
struct StoppoleParams {
    let rtmcd: Int
    let slst: Int
    let pl: Int
    let lrid: Int
    let tgo: Int
}

/// tobus.jp（都バス運行情報サービス）の車両接近情報ページをHTML解析する。
/// 公式のデータ形式（JSON/XML）は提供されていないため、SwiftSoupでHTMLを直接パースする。
///
/// 車両接近情報の表（`table.appListTbl`）には少なくとも2つのレイアウトがある。
/// - 実車が接近中: 停留所を並べた帯状の表で、対応する `td.busLabel` に
///   「東京駅丸の内南口行04分待」「深川車庫前行まもなく」のような実テキストが入る
///   （`td.busIcon` に同じ位置でバスのアイコン画像が入る）
/// - 実車情報が無い/定型メッセージのみ: `td.stopNotes` に
///   「ただいま定刻で運行しています。」等の文言が入る
enum TobusPageParser {
    /// 停留所名称検索結果ページから、ヒットした停留所クラスタを取り出す。
    /// 検索結果テーブルは停留所ごとに `rowspan` でまとまっているが、
    /// `a.func_stop`（停留所名リンク、`id="e<slst>"`）だけを拾えば重複なく一覧化できる。
    static func parseStopSearch(html: String) throws -> [BusStopCluster] {
        let doc = try SwiftSoup.parse(html)
        var seen = Set<Int>()
        var results: [BusStopCluster] = []
        for anchor in try doc.select("a.func_stop").array() {
            let idAttr = try anchor.attr("id") // 例: "e965"
            guard idAttr.hasPrefix("e"), let slst = Int(idAttr.dropFirst()) else { continue }
            guard seen.insert(slst).inserted else { continue }
            results.append(BusStopCluster(slst: slst, name: try anchor.text()))
        }
        return results
    }

    /// 車両接近情報ページ（`slst` 指定）を、のりば×系統のブロック単位に分解する。
    static func parseStopPage(html: String, slst: Int, now: Date = Date()) throws -> ParsedStopPage {
        let doc = try SwiftSoup.parse(html)

        let stopName = ownText(firstOf: try doc.select("h2.titleAppResult2"))
        let observedAt = try parseObservedAt(doc: doc, now: now)

        var blocks: [ParsedBlock] = []
        var ordinal = 0
        for platformDiv in try doc.select("div.appResultBody").array() {
            let platformLabel = try text(firstOf: platformDiv.select("h3.titleAppResult3"))
            for dl in try platformDiv.select("dl.boxNoriba02").array() {
                let label = try text(firstOf: dl.select("dt"))
                let destination = try text(firstOf: dl.select("dd.stopName"))
                guard let table = try dl.nextElementSibling(), table.hasClass("appListTbl") else { continue }

                let (statusText, estimatedMinutes, followingMinutes) = try Self.approachInfo(inTable: table)
                let containerText = try table.parent()?.text() ?? ""
                let noteText = Self.note(fromContainerText: containerText)
                let (timetableRTMCD, timetablePl) = Self.timetableLinkParams(dl: dl)

                blocks.append(ParsedBlock(
                    ordinal: ordinal,
                    platformLabel: platformLabel,
                    label: label,
                    destination: destination,
                    statusText: statusText,
                    estimatedMinutes: estimatedMinutes,
                    followingMinutes: followingMinutes,
                    noteText: noteText,
                    timetableRTMCD: timetableRTMCD,
                    timetablePl: timetablePl
                ))
                ordinal += 1
            }
        }

        return ParsedStopPage(slst: slst, stopName: stopName, observedAt: observedAt, blocks: blocks)
    }

    /// 系統ブロックの接近状況本文を取り出す。
    /// 実車が接近中のレイアウトを優先し、無ければ定型メッセージのレイアウトにフォールバックする。
    ///
    /// 表は停留所を左方向に並べた帯（`◎当停留所 ←1つ前 ←2つ前 …`）で、`td.busLabel` は
    /// その位置に対応する。したがってセルの並び＝停留所に近い順＝到着が早い順になる。
    /// 同じ系統に複数台が接近していることがあるため、先頭だけでなく全台分を返す。
    private static func approachInfo(
        inTable table: Element
    ) throws -> (statusText: String, estimatedMinutes: Int?, followingMinutes: [Int]) {
        var labels: [String] = []
        for cell in try table.select("td.busLabel").array() {
            let cellText = try cell.text().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cellText.isEmpty else { continue }
            labels.append(cellText)
        }

        if let first = labels.first {
            let following = labels.dropFirst().compactMap { Self.minutes(fromBusLabel: $0) }
            return (first, Self.minutes(fromBusLabel: first), following)
        }

        let stopNotesText = try text(firstOf: table.select("td.stopNotes"))
        return (stopNotesText, nil, [])
    }

    /// 「東京駅丸の内南口行04分待」→ 4、「深川車庫前行まもなく」→ 0
    private static let minutesRegex = try! NSRegularExpression(pattern: #"(\d+)\s*分待"#)

    private static func minutes(fromBusLabel text: String) -> Int? {
        if text.contains("まもなく") { return 0 }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = minutesRegex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: text),
              let value = Int(text[valueRange])
        else { return nil }
        return value
    }

    /// `Elements` の先頭要素のテキストを取る。要素が無ければ空文字。
    private static func text(firstOf elements: Elements) throws -> String {
        guard let first = elements.first() else { return "" }
        return try first.text()
    }

    /// `Elements` の先頭要素の直接のテキストのみを取る（子要素のテキストは含めない）。要素が無ければ空文字。
    private static func ownText(firstOf elements: Elements) -> String {
        guard let first = elements.first() else { return "" }
        return first.ownText()
    }

    /// ページ上部の「HH:mm 時点の情報」から取得時刻を組み立てる。取れない場合は現在時刻にフォールバックする。
    private static func parseObservedAt(doc: Document, now: Date) throws -> Date {
        let text = try text(firstOf: doc.select("span.fc-ff0"))
        guard let colonIndex = text.firstIndex(of: ":"),
              let hour = Int(text[text.startIndex..<colonIndex]),
              let minute = Int(text[text.index(after: colonIndex)...])
        else { return now }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TobusConfig.timeZone
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = hour
        components.minute = minute
        components.second = 0
        return calendar.date(from: components) ?? now
    }

    private static func note(fromContainerText text: String) -> String? {
        if text.contains("運休") { return "本日は運休日です。" }
        if text.contains("土曜ダイヤ") { return "本日は土曜ダイヤで運行しています。" }
        if text.contains("休日ダイヤ") { return "本日は休日ダイヤで運行しています。" }
        return nil
    }

    /// `dd.linkBtn` 内の「時刻表」リンク（`navi?...VCD=SelectDest&...&slst=325&pl=1&RTMCD=23`）から
    /// `pl` と `RTMCD` を取り出す。
    private static func timetableLinkParams(dl: Element) -> (rtmcd: Int?, pl: Int?) {
        guard let href = try? dl.select("dd.linkBtn a").first()?.attr("href") else {
            return (nil, nil)
        }
        let pl = firstIntMatch(in: href, pattern: #"[?&]pl=(\d+)"#)
        let rtmcd = firstIntMatch(in: href, pattern: #"[?&]RTMCD=(\d+)"#)
        return (rtmcd, pl)
    }

    private static func firstIntMatch(in text: String, pattern: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return Int(text[range])
    }

    // MARK: - 時刻表

    /// 「行き先選択」ページ（`VCD=SelectDest&ECD=SelectDest`）から、実際の時刻表ページを取得するための
    /// パラメータを取り出す。`onclick="func_stoppole('23', '325', '1', '2', '2'); return false;"` の形式。
    static func parseStoppoleParams(html: String) -> StoppoleParams? {
        let pattern = #"func_stoppole\('(\d+)',\s*'(\d+)',\s*'(\d+)',\s*'(\d+)',\s*'(\d+)'\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              match.numberOfRanges > 5
        else { return nil }

        func intGroup(_ index: Int) -> Int? {
            guard let range = Range(match.range(at: index), in: html) else { return nil }
            return Int(html[range])
        }

        guard let rtmcd = intGroup(1), let slst = intGroup(2), let pl = intGroup(3),
              let lrid = intGroup(4), let tgo = intGroup(5)
        else { return nil }
        return StoppoleParams(rtmcd: rtmcd, slst: slst, pl: pl, lrid: lrid, tgo: tgo)
    }

    /// 時刻表ページ（`VCD=cresultttbl&ECD=show`）から、本日のダイヤ区分の便一覧を取り出す。
    /// ページ自身が「本日は、〇曜ダイヤで運行しております」という文言と、対応する表のIDを
    /// 教えてくれるため、自前で祝日判定などをする必要がない。
    static func parseTimetable(html: String) throws -> ParsedTimetable {
        let doc = try SwiftSoup.parse(html)

        guard let todayTableId = try todayScheduleTableId(doc: doc),
              let table = try doc.select("table[id=\(todayTableId)]").first()
        else { return .empty }

        var times: [BusTime] = []
        for row in try table.select("tr").array() {
            guard let hourText = try row.select("th").first()?.text(),
                  let hour = Int(hourText.trimmingCharacters(in: .whitespaces))
            else { continue }
            for cell in try row.select("td").array() {
                let text = try cell.text().trimmingCharacters(in: .whitespaces)
                guard let minute = Int(text) else { continue }
                times.append(BusTime(hour: hour, minute: minute))
            }
        }
        return ParsedTimetable(times: times.sorted(), scheduleKind: todayTableId)
    }

    /// 「本日は、<a onclick="document.getElementById('土曜').scrollIntoView();">土曜ダイヤ</a>で運行しております。」
    /// のリンクから、本日のダイヤに対応する表のIDを取り出す。
    private static func todayScheduleTableId(doc: Document) throws -> String? {
        for anchor in try doc.select("a").array() {
            let onclick = try anchor.attr("onclick")
            guard onclick.contains("getElementById") else { continue }
            guard let parentText = try anchor.parent()?.text(), parentText.hasPrefix("本日は") else { continue }
            if let id = firstStringMatch(in: onclick, pattern: #"getElementById\('([^']+)'\)"#) {
                return id
            }
        }
        return nil
    }

    private static func firstStringMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }
}
