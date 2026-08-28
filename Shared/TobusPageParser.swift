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
///
/// ページには平日・土曜・休日の3つの表がすべて含まれているため、全部を保持する。
/// 本日どれを使うかはページ自身が申告してくるが（`todayKind`）、**翌日どれになるかは
/// ページからは分からない**ため、翌日分を出すときは呼び出し側が区分を決めて選ぶ
/// （[[TobusConfig]] の `estimatedScheduleKind(on:)`）。
struct UpcomingSchedule: Equatable {
    let departures: [ScheduledDeparture]
    let kind: String?
    let isNextDay: Bool

    var dates: [Date] { departures.map(\.date) }
}

struct ParsedTimetable: Equatable {
    /// ダイヤ区分（`平日` / `土曜` / `休日`）ごとの時刻表。
    let tables: [String: [BusTime]]
    /// ページが「本日は〇曜ダイヤで運行しております」と申告している区分。読み取れなければ nil。
    let todayKind: String?
    /// ページの「記号説明」。記号が無い系統では空。
    let legend: [TimetableMark]

    static let empty = ParsedTimetable(tables: [:], todayKind: nil, legend: [])

    init(tables: [String: [BusTime]], todayKind: String?, legend: [TimetableMark] = []) {
        self.tables = tables
        self.todayKind = todayKind
        self.legend = legend
    }

    /// 本日のダイヤ区分の時刻表。
    var todayTimes: [BusTime] {
        guard let todayKind else { return [] }
        return tables[todayKind] ?? []
    }

    func times(kind: String?) -> [BusTime] {
        guard let kind else { return [] }
        return tables[kind] ?? []
    }

    /// 表示に使う「これから来る定刻」。
    ///
    /// 本日分が残っていればそれを返す。尽きていれば翌日の始発から返すが、そのとき
    /// **今日と同じ表を使い回してはいけない**（日曜→月曜のようにダイヤ区分が変わる）。
    /// 翌日の区分はページから分からないので曜日から推定し、推定であることを
    /// `isNextDay` と `kind` で呼び出し側に伝える（見出しに区分名を出して判断できるようにする）。
    func upcoming(now: Date = Date()) -> UpcomingSchedule {
        let remaining = BusTime.departures(from: todayTimes, on: now, after: now)
        if !remaining.isEmpty {
            return UpcomingSchedule(departures: remaining, kind: todayKind, isNextDay: false)
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TobusConfig.timeZone
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) else {
            return UpcomingSchedule(departures: [], kind: todayKind, isNextDay: false)
        }
        let kind = TobusConfig.estimatedScheduleKind(on: tomorrow)
        return UpcomingSchedule(
            departures: BusTime.departures(from: times(kind: kind), on: tomorrow),
            kind: kind,
            isNextDay: true
        )
    }

    /// 表示中の定刻に出てくる記号だけの凡例。ウィジェットなど幅が無い面向け。
    /// 無印は系統の行き先そのものなので含めない（時刻にも記号が付いていない）。
    func legend(appearingIn departures: [ScheduledDeparture]) -> [TimetableMark] {
        let used = Set(departures.compactMap(\.mark).filter { !$0.isEmpty })
        return legend.filter { used.contains($0.symbol) }
    }
}

extension ParsedTimetable: Codable {
    enum CodingKeys: String, CodingKey { case tables, todayKind, legend }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tables = try c.decode([String: [BusTime]].self, forKey: .tables)
        todayKind = try c.decodeIfPresent(String.self, forKey: .todayKind)
        legend = try c.decodeIfPresent([TimetableMark].self, forKey: .legend) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(tables, forKey: .tables)
        try c.encodeIfPresent(todayKind, forKey: .todayKind)
        if !legend.isEmpty { try c.encode(legend, forKey: .legend) }
    }
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
                let (statusOverride, noteText) = Self.statusOverrideAndNote(fromParent: table.parent())
                // 接近中の実車があるときは分数を優先する。運休の上書きは表が空のときだけ。
                let resolvedStatus: String
                if estimatedMinutes == nil, statusText.isEmpty, let statusOverride {
                    resolvedStatus = statusOverride
                } else {
                    resolvedStatus = statusText
                }
                let (timetableRTMCD, timetablePl) = Self.timetableLinkParams(dl: dl)

                blocks.append(ParsedBlock(
                    ordinal: ordinal,
                    platformLabel: platformLabel,
                    label: label,
                    destination: destination,
                    statusText: resolvedStatus,
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

    /// 系統ブロックの表の外にある注記を取る。
    ///
    /// tobus.jp は「本日は運休日です。」を `td.stopNotes` ではなく、表の直後のテキストとして
    /// 置くことがある。一方、地震などの注意は同じ親の `dl.appNotes` テロップに入る。
    /// 親要素全体の `.text()` を見ると、テロップの「運休が発生する場合があります」まで
    /// 「本日は運休日です。」に潰してしまう（2026-08-23 に実ページで確認）。
    private static func statusOverrideAndNote(
        fromParent parent: Element?
    ) -> (statusOverride: String?, noteText: String?) {
        guard let parent else { return (nil, nil) }

        let isSuspended = parent.ownText().contains("本日は運休日")
        var scheduleNote: String?
        var disruptionNote: String?

        let items = (try? parent.select("dl.appNotes li").array()) ?? []
        for li in items {
            let text = (try? li.text()) ?? ""
            if text.contains("本日は運休日") {
                continue
            } else if text.contains("土曜ダイヤ") {
                scheduleNote = "本日は土曜ダイヤで運行しています。"
            } else if text.contains("休日ダイヤ") {
                scheduleNote = "本日は休日ダイヤで運行しています。"
            } else if text.contains("運休が発生する場合") {
                disruptionNote = "運休が発生する場合があります"
            }
        }

        // 本物の運休は状態として出す。備考の「運休が発生する場合」を運休日にしない。
        let noteText: String?
        if isSuspended {
            noteText = nil
        } else {
            noteText = disruptionNote ?? scheduleNote
        }
        let statusOverride = isSuspended ? "本日は運休日です。" : nil
        return (statusOverride, noteText)
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

        // ページには平日・土曜・休日の表がすべて入っている。翌日分を出すために全部拾っておく
        // （表のIDがそのままダイヤ区分の名前になっている）。
        var tables: [String: [BusTime]] = [:]
        for table in try doc.select("table[id]").array() {
            let kind = try table.attr("id")
            guard Self.scheduleKinds.contains(kind) else { continue }
            let times = try Self.times(inTable: table)
            guard !times.isEmpty else { continue }
            tables[kind] = times
        }

        return ParsedTimetable(
            tables: tables,
            todayKind: try todayScheduleTableId(doc: doc),
            legend: try parseLegend(doc: doc)
        )
    }

    /// 時刻表の表として想定しているID。これ以外のテーブル（案内文の枠など）は読み飛ばす。
    private static let scheduleKinds: Set<String> = ["平日", "土曜", "休日"]

    /// 「時」の見出し行＋分のセル、という構造から時刻を組み立てる。
    private static func times(inTable table: Element) throws -> [BusTime] {
        var times: [BusTime] = []
        for row in try table.select("tr").array() {
            guard let hourText = try row.select("th").first()?.text(),
                  let hour = Int(hourText.trimmingCharacters(in: .whitespaces))
            else { continue }
            for cell in try row.select("td").array() {
                guard let minute = minute(inTimetableCell: cell) else { continue }
                times.append(BusTime(hour: hour, minute: minute, mark: destinationMark(in: cell)))
            }
        }
        return times.sorted()
    }

    /// 時刻セルから分を取り出す。
    ///
    /// 行き先記号が付く便は `<td><span>ｱ</span>06</td>` となり、`text()` は「ｱ06」。
    /// これを `Int` にすると nil になり、終バスが記号付きの系統では夜に本日分が空になる。
    /// 数字だけを拾えば無印（`<span></span>51`）も記号付きも同じ扱いにできる。
    private static func minute(inTimetableCell cell: Element) -> Int? {
        let raw = (try? cell.text()) ?? cell.ownText()
        let digits = raw.filter { $0.isASCII && $0.isNumber }
        guard let minute = Int(digits), (0...59).contains(minute) else { return nil }
        return minute
    }

    /// セル先頭の `<span>ｱ</span>` から行き先記号を取る。空の span（無印）は nil。
    private static func destinationMark(in cell: Element) -> String? {
        let text = (try? cell.select("span").first()?.text())?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    /// 「記号説明」の `【ｱ】　有明一丁目行` を凡例として取り出す。
    private static func parseLegend(doc: Document) throws -> [TimetableMark] {
        var entries: [TimetableMark] = []
        for dt in try doc.select("dt.icon4").array() {
            guard try dt.text().contains("記号説明") else { continue }
            let items = try dt.parent()?.select("dd li").array() ?? []
            for li in items {
                let text = try li.text().trimmingCharacters(in: .whitespacesAndNewlines)
                guard let entry = legendEntry(from: text) else { continue }
                entries.append(entry)
            }
            break
        }
        return entries
    }

    private static func legendEntry(from text: String) -> TimetableMark? {
        guard let symbol = firstStringMatch(in: text, pattern: #"【([^】]+)】"#) else { return nil }
        let label = text.replacingOccurrences(
            of: #"【[^】]+】"#, with: "", options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return nil }
        return TimetableMark(symbol: symbol == "無印" ? "" : symbol, label: label)
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
