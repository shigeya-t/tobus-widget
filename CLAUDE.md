# 新規クローン直後のセットアップ

`TobusWidget.xcodeproj` / `Info.plist` / `*.entitlements` は `project.yml` から生成され、
`.gitignore` によりリポジトリに含まれていない。**クローン直後や `project.yml` を編集した後は
`xcodegen generate` が必要**で、忘れると `xcodebuild` はプロジェクトが無いという分かりにくい
失敗をする（`brew install xcodegen`）。

初回ビルドは SwiftSoup を取りに行くのでネットワークが要る。
`xcodebuild -resolvePackageDependencies -project TobusWidget.xcodeproj -scheme TobusWidget`
で事前解決だけ行うこともできる。

ここまで済んだら `./scripts/deploy-local.sh`（後述）へ。GUI でビルドする場合は README の
「ビルドと導入」に従うこと。

# ビルドについて（重要）

## 1. 必ず署名付きでビルドすること

このプロジェクトをローカルでビルドして `/Applications/TobusWidget.app` へ配置する
（＝実際にウィジェットを動かして確認する）場合は、**必ず Team ID 付きで署名すること。**
（`.app` のファイル名は ASCII のまま。日本語にするとウィジェット拡張が起動できなくなる。
詳細は「開発中に踏んだ既知の落とし穴」の濁点の項を参照。表示名だけは日本語で「都バス接近情報」）
`CODE_SIGNING_REQUIRED=NO` / `CODE_SIGN_IDENTITY=""` などの無署名ビルドは
コンパイルが通るかの確認にしか使わないこと。

理由: AppIntents（`SelectBusStopIntent` など、ウィジェットの設定パネル）は署名に Team ID が必要で、
無署名や Team ID なしの adhoc 署名だと `Unable to get teamId` となり、ウィジェットが情報を更新できず
プレースホルダのまま止まる。

## 2. `CONFIGURATION_BUILD_DIR` を独自パスに上書きしないこと（既知の問題）

SwiftPM 成果物（`SwiftSoup.swiftmodule`）のコピーとモジュール探索のタイミングがずれ、
`error: unable to resolve module dependency: 'SwiftSoup'` で失敗する
（理由の詳細は README「ビルドと導入」の注記）。

ここに書き足す価値があるのは、**リトライでは直らない**という点。同一コマンドを2〜3回試しても、
DerivedData を完全に消しても再発することを確認済み。指定せず標準の DerivedData 配下に
ビルドすれば通るので、成果物が要る場合はビルド後にコピーする（`scripts/deploy-local.sh` がそうしている）。

## ビルド・テスト・配置

よく使う手順は `scripts/` にまとめてある。**手順を間違えると症状が分かりにくい**
（無署名だとウィジェットが更新されない、拡張プロセスを落とし忘れると古いコードが動き続ける）ため、
手で組み立てず基本はこれを使う。

```sh
./scripts/test.sh              # 単体テスト（-v で xcodebuild の全出力）
./scripts/deploy-local.sh      # ビルドして ~/Applications へ配置し直し、起動する
./scripts/deploy-local.sh /Applications   # 配置先を変える
```

Team ID は環境ごとに異なる個人情報なのでリポジトリには書かず、手元の「Apple Development」
証明書の OU から自動で引いている（`scripts/_common.sh`）。証明書が複数ある環境では
`DEVELOPMENT_TEAM=XXXXXXXXXX ./scripts/deploy-local.sh` のように明示する。

`deploy-local.sh` は配置後に `TeamIdentifier` を検査し、`not set`（＝無署名）なら失敗で止まる。
AppIntents は署名の Team ID が無いと解決できず、**ウィジェットがプレースホルダのまま止まる**ため。

自分で `xcodebuild` を組み立てる場合は `CONFIGURATION_BUILD_DIR` を指定しないこと（前述の理由）。
無署名でコンパイルの通過だけ見たいときは次のとおり（`/Applications/` へは配置しない）。

```sh
xcodebuild -project TobusWidget.xcodeproj -scheme TobusWidget \
  -configuration Debug -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build
```

起動しただけではウィジェットは画面に出ない。通知センターまたはデスクトップの
「ウィジェットを編集」から追加する（README の「ビルドと導入」参照）。

## テストの構成

`TobusWidgetTests` は**ホストアプリを立てない**単体テスト（`Shared` のソースを直接取り込む構成）。
`TobusWidget` をテストホストにすると常駐アプリが起動して初回取得の通信が走るため、あえてそうしている。
したがってテストは通信せず、`AppSettings`（UserDefaults）にも触らない。

対象は「壊れても気づきにくい」ところに絞ってある。

- `TobusPageParserTests` — 実ページのHTML（`Tests/Fixtures/`、勝どき橋南詰）に対する解析。
  tobus.jp は公式APIではないので、先方のHTML構造が変わったことに気づく手段がここしか無い。
  フィクスチャを更新するときは `curl 'https://tobus.jp/blsys/navi?VCD=csrst&ECD=NEXT&LCD=&func=fap&method=msn&slst=325'`
  で取り直し、期待値（系統数・分待の値）も併せて直すこと。
  期待値は**取得時点のスナップショット**であって「いつでもこうなる」値ではない
- `RouteResolutionTests` — `BusDirectoryService.resolve` の多段引き当て。
  tobus.jp 側の並び順が実際に変わらないと再現できない経路なので、ここでしか担保できない
- `TimetableParsingTests` — 行き先選択ページと、時刻表が直接返るページの両方
- `BusTimeTests` — 定刻の日またぎ・深夜便（25時表記）の変換

## データソース（tobus.jp）固有の注意

エンドポイント一覧・仕様・利用条件は README「データソースについて」にある。ここには
**コードを触るときに効く注意点だけ**を書く。

- パース処理は `Shared/TobusPageParser.swift`（SwiftSoup使用）に集約している。
  tobus.jp側のHTML構造が変わった場合はここだけを見直せばよい
- **`URLSession.shared` を使ってはいけない。`JSESSIONID` を持ち回ると時刻表が壊れる。**
  応答に `JSESSIONID` が付くため、Cookieを自動保存する `URLSession.shared` だと全リクエストが
  同一セッションに乗る。時刻表は「行き先選択」→「時刻表本体」の2段階で、サーバーが
  セッションに選択状態を持つため、**複数系統を並行取得すると互いの選択を上書きし合い、
  別系統の時刻表が返る**。`BusAPI` は Cookie を保持しない専用セッションを使っている。

  2026-08-16に実際に踏んだ症状: 都０３・都０５－１・都０５－２（いずれも同じのりば）の定刻が
  すべて都０５－１のものになっていた。**エラーは出ず、値がもっともらしいので気づきにくい。**
  疑ったら `curl` で切り分ける（Cookieを共有した並行リクエストだけが誤る）。

  ```sh
  # 正しい: Cookieを送らない並行リクエスト → それぞれ正しい系統が返る
  for r in 23 184 181; do ( curl -s "https://tobus.jp/blsys/navi?VCD=cresultttbl&ECD=show&RTMCD=$r&slst=325&bs=325&pl=1&lrid=2&tgo=2" | grep -o '<title>[^ ]*' ) & done; wait
  ```
- サーバー側60秒 / アプリ内 `TobusPageService` 50秒のキャッシュ段構成
- 定刻（`Shared/BusScheduleService.swift`）は原則「行き先選択」ページ→「時刻表本体」ページの
  2段階フェッチだが、**行き先が1つしかない系統では1段階目で時刻表そのものが返る**。
  この場合ページに `func_stoppole` が無く `parseStoppoleParams` が nil になるので、
  2段階目には進まず、取得済みのHTMLをそのまま `parseTimetable` に通すこと。
  ここで諦めると、**エラーも出ないまま定刻だけが空になる**（勝どき橋南詰の業１０で実際に踏んだ）。
  見分け方は応答サイズが分かりやすい。

  ```sh
  # 行き先が複数（行き先選択ページ・約17KB・func_stoppole あり）
  curl -s 'https://tobus.jp/blsys/navi?LCD=&VCD=SelectDest&ECD=SelectDest&slst=325&pl=1&RTMCD=184' | grep -c func_stoppole
  # 行き先が1つ（時刻表ページが直接返る・約159KB・func_stoppole なし）
  curl -s 'https://tobus.jp/blsys/navi?LCD=&VCD=SelectDest&ECD=SelectDest&slst=325&pl=1&RTMCD=40' | grep -c func_stoppole
  ```

  どちらの経路も `TimetableParsingTests` がフィクスチャで固定している
- 当日のダイヤ区分（平日/土曜/休日）はページ自身の
  「本日は、〇曜ダイヤで運行しております」というリンクのIDから判定しており、
  こちら側で祝日判定などは行っていない。ウィジェットの「定刻（土曜ダイヤ）」の表記も
  この値をそのまま出しているだけ（`TobusConfig.scheduleHeading(kind:)`）。
  **カレンダーから自前で導こうとしないこと。** ダイヤ区分は暦の曜日と一致せず、
  しかも**同じ停留所でも系統ごとに違う**。2026-08-15（土）に実際に観測した値:

  ```
  325#1  → 土曜ダイヤ
  325#0, 325#2, 325#4, 325#5, 325#7, 325#11, 325#12 → 休日ダイヤ
  ```

  お盆の週で、多くの系統が土曜でも休日ダイヤで運行していたため。
  「土曜なら土曜ダイヤ」でも「お盆は一律休日ダイヤ」でも間違いになる
- **翌日分だけは曜日から推定している。本日の区分にこれを流用しないこと。**
  本日分の定刻が尽きたあと、翌日の始発を出すために平日・土曜・休日の3表すべてを
  保持している（時刻表ページには元から3つとも入っているので追加の通信は不要）。
  翌日どの区分になるかはページからは分からないので `TobusConfig.estimatedScheduleKind(on:)`
  が曜日から推定するが、上記のとおり外れうる。そのため見出しを
  「定刻（休日ダイヤ）」→「翌 平日ダイヤ」と切り替え、**推定値だと画面で分かるようにしている**。

  ここを手抜きして「今日の表をそのまま翌日に使う」とどうなるかは実際に踏んだ:
  日曜の夜に月曜の始発が休日ダイヤの 07:01 と表示されていた（正しくは平日ダイヤの 06:50）。
  `TimetableSelectionTests` がこの切り替えを固定している

## 開発中に踏んだ既知の落とし穴（SwiftUI / WidgetKit / AppIntents）

このプロジェクトの開発中に実際にハマった、非自明なバグ・挙動。同種の実装をする際は要注意。

- **ウィジェットギャラリーのアプリ一覧（左サイドバー等）は `CFBundleDisplayName` を見ていない。**
  Spotlightのメタデータ（`kMDItemDisplayName`、`mdls <app>` で確認できる）を見ており、これは
  `.app` バンドルの**ファイル名そのもの**（拡張子を除いた部分）から来る。`Info.plist` の
  `CFBundleDisplayName` / `CFBundleName` をいくら日本語にしても（`Base.lproj/InfoPlist.strings`
  でローカライズしても）このサイドバーの表示は変わらない。
  実行ファイル名を直接決める `PRODUCT_NAME` を日本語にすると `CodeSign failed`
  （`code object is not signed at all`）でビルドが壊れる。`.app` バンドルの外側の名前だけを変える
  `WRAPPER_NAME: 都バス接近情報.app` なら署名は通り、一覧の表示も日本語になる——が、
  **今度はウィジェット拡張が起動できなくなるため、この方法は採用していない**（次項）。
  結論として `.app` のファイル名は ASCII（`TobusWidget.app`）のままにし、
  ギャラリー一覧が「TobusWidget」表示になることは受け入れている。
  `CFBundleDisplayName` / `CFBundleName` の日本語化はメニューバー等には効くので残してある
- **`.app` のファイル名に濁点付きの文字（バ など）を入れると、ウィジェット拡張が起動できなくなる。**
  症状は**ウィジェットが中身のない空の枠になる**こと。ビルドもコード署名も正常で、アプリ本体は動き、
  `busLogger` にもエラーは出ない（拡張が起動していないので当然）。原因は次のログでしか分からない。

  ```sh
  /usr/bin/log show --predicate 'eventMessage contains "TobusWidget"' --last 10m --style compact \
    | grep -E "not found in LS database|Unknown extension process|Reload success"
  ```

  ```
  Launch failed with error: ... Extension `com.example.TobusWidget.Widget`,
  URL `file:///Users/<user>/Applications/%E9%83%BD%E3%83%8F%E3%82%99%E3%82%B9....app/...`
  not found in LS database
  → chronod: Reload failed ... "Unknown extension process"
  ```

  理由: 「バ」は分解可能な文字で、**LaunchServices は NFC（`バ` = `e3 83 90`）、
  PluginKit は NFD（`ハ`+`゙` = `e3 83 8f e3 82 99`）** でパスを保持する。ExtensionKit は
  PluginKit から得た URL を LS で引くため、この文字列比較が一致せず拡張を起動できない。
  APFS は正規化を区別しないのでファイル自体は開けてしまい、`ls` では気づけない。
  確認するなら次の2つのバイト列を突き合わせる。

  ```sh
  cd ~/Applications && ls -d *.app | xxd            # LS/ディスク側（NFC）
  pluginkit -m -v -i com.example.TobusWidget.Widget | xxd  # PluginKit側（NFD）
  ```

  **効かなかった対処**（2026-08-14 に一通り試した）: `lsregister -f -R -trusted` での再登録、
  `lsregister -u` してからの再登録（バンドル削除の前・後どちらの順序でも）、`killall chronod`、
  ウィジェットの削除→再追加、`mv` でディスク上の名前を NFD にする試み（APFS が NFC に戻す）、
  `build/` や DerivedData に残っていた同一バンドルIDの重複登録の解除。
  一度だけ復旧したことがあるが再現せず、**運用でごまかせる問題ではない**と判断した。
  `project.yml` から `WRAPPER_NAME` を外して ASCII 名に戻すのが唯一の確実な解決
- `.app` のファイル名が ASCII に戻ったので、`osascript` の**名前指定**（`tell application "TobusWidget"`）は
  再び使えるはずだが、`CFBundleDisplayName` が日本語のままで紛らわしいため、
  **bundle ID 指定**（`tell application id "com.example.TobusWidget"`）に統一している
- **`WidgetInfo.configuration` は `Intents.INIntent?` 型**（`AppIntents.WidgetConfigurationIntent`
  ではない）。`info.configuration as? SelectBusStopIntent` は**常にnilになる**
  （コンパイラが "always fails" と警告するが、上流の参考実装にも同じ警告があったため
  最初は無害な誤検知だと誤判断してしまった＝実際は本物のバグだった）。
  正しくは `info.widgetConfigurationIntent(of: SelectBusStopIntent.self)`（macOS 14+）を使う。
  `App/TobusWidgetApp.swift` の `widgetConfiguredRoutes()` 参照
- **ウィジェット拡張の `Provider.buildEntry()` から通信するAPIを呼んではいけない。**
  WidgetKitは拡張の実行時間を厳しく制限しており、通信が間に合わないと処理が止まり、
  古いタイムラインが表示され続ける（エラーにもならず、症状に気づきにくい）。
  当初 `configuration.resolvedRoute()`（`BusDirectoryService` 経由でtobus.jpに問い合わせる）を
  ウィジェット側からも呼んでいたが、これが原因で系統ラベル等が更新されない不具合が起きた。
  ウィジェット側は `configuration.route?.id` / `.name` など、**AppIntentsが保存済みの値だけ**を使い、
  実データはApp Group経由のスナップショット（`AppSettings`）からのみ読むこと
- **`EntityQuery.entities(for:)` は名前を空文字で返してはいけない。**
  AppIntentsはウィジェットの保存済み設定を（再検証などのタイミングで）この関数経由で
  再解決することがあり、ここで空文字を返すと保存済みの表示名が空文字で**上書き**されてしまう。
  `BusStopClusterQuery.entities(for:)` は当初 `name: ""` を返していたためこの不具合を踏んだ。
  実名を引き直すよう修正したが、**引き直しに失敗したときのフォールバックにも同じ罠がある**。
  `?? ""` のように空文字で埋めると通信エラーのたびに同じ上書きが起きるため、
  実名を引けなかった識別子は**エンティティを返さず落とす**こと（返さなければ上書き自体が起きない）。
  `Shared/SelectBusStopIntent.swift` の `BusStopClusterQuery` / `RouteBlockQuery` はどちらもこの方針
- **`RouteBlock.id` は保存済みの値を持ち回ること。現在の並び順から組み立て直してはいけない。**
  tobus.jp のページには系統ブロック単位の安定したIDが無く、`id` は初回選択時の
  `"slst#ordinal"`（`ordinal` はページ内の出現順）でしかない。のりばや系統が増減すれば
  並び順は変わるため、`ordinal` を識別に使うと保存済みウィジェットが黙って別系統を表示する。
  対策として `BusDirectoryService.routeBlock(id:)` が
  ①`RTMCD`＋`pl` ②系統名＋行き先＋のりば ③系統名＋行き先 ④`ordinal`
  の順で引き当て、手がかりは `AppSettings.saveRouteIdentity` に控えている。
  このとき**返す `RouteBlock` の `id` は要求されたものに固定する**（`RouteBlock.id` を
  保存プロパティにしているのはこのため）。現在の `ordinal` から組み立て直すと、
  アプリが書くスナップショットのキー（`snapshot.<id>`）とウィジェットが読むキーがずれ、
  ウィジェットがエラーも出さずに空になる
- **`??` は空文字を「値あり」として扱う。** 上記の空文字混入と組み合わさると、
  `a ?? b ?? c` の `a` が `Some("")` の場合そこで止まり `b`/`c` に落ちない。
  フォールバックチェーンを書くときは `nil` だけでなく空文字も明示的にスキップすること
  （`BusEntry.shortHeaderText` 等）
- **`MenuBarExtra(.menuBarExtraStyle: .window)` はポップオーバーを開いても自動的に
  キーウィンドウにならず、`TextField` がキーボード入力を受け取れないことがある。**
  `.onAppear` で `NSApp.activate(ignoringOtherApps: true)` を呼び、`@FocusState` で
  明示的にフォーカスを当てる必要がある（`App/TobusWidgetApp.swift` の `MenuContent`）
- **同じポップオーバーは、表示後にSwiftUI側のコンテンツの高さが変わってもウィンドウが
  自動リサイズされないことがある**（検索候補が後から出現する場合など、`Text` は空文字を
  含む要素が新たに増える）。`.fixedSize(horizontal: false, vertical: true)` を明示することで解決した
- **`swiftc -typecheck` 単体での警告は、実際の `xcodebuild` と必ずしも一致しない**
  （上記の `WidgetInfo.configuration` の件は両方で同じ警告が出ていたので本物のバグだったが、
  逆に無害な警告もありうる）。疑わしい警告は放置せず、実際のSDKの `.swiftinterface`
  （`grep` で `WidgetKit.swiftmodule` 等を探す）で型定義を直接確認するのが確実

## ログの確認

```sh
log stream --predicate 'subsystem beginswith "com.example.TobusWidget"' --level debug
```

`project.yml` の `bundleIdPrefix` / `PRODUCT_BUNDLE_IDENTIFIER` を変更した場合は、
subsystem もそれに合わせて読み替えること（`Shared/BusAPI.swift` の `busLogger` は
`Bundle.main.bundleIdentifier` を使っている）。アプリ／ウィジェット拡張どちらのログもまとめて見える。

主なログ行:
- `API request: <query>` — tobus.jpへの実リクエスト（ウィジェット拡張からこれが出ていたら
  「ウィジェット拡張は通信しない」の設計が崩れている兆候なので要調査）
- `getCurrentConfigurations: N 件` / `widget-only routes to refresh: [...]` — アプリが検出した
  配置済みウィジェットの系統一覧（`App/TobusWidgetApp.swift`）
- `fetchApproach <routeID>: <kind>（<ページ上の文言>）` — 実際に解釈した接近状況。
  ウィジェットの表示が想像と違うときに、tobus.jp の文言とこちらの分類のどちらがずれているか切り分けられる
- `saved snapshot for <routeID>: ...` — 系統ごとの接近状況スナップショット保存完了
- `id=... の並び順が変わっています（ordinal N → M）` — tobus.jp 側で系統の並びが変わり、
  保存済みの識別情報で引き当て直したことを示す（この行が出ずに表示が別系統になっていたら引き当ての不具合）
- `resolvedRoute() が nil` / `slst=... に ordinal=... が見つかりません` などの `error` レベルの行は、
  ウィジェット設定の復元や系統解決に失敗していることを示す
- `... の停留所名を引けませんでした（空文字での上書きを避けるため候補から除外）` — 通信エラー等で
  `EntityQuery` が候補を落とした。ウィジェット設定が消えたように見えるときはこれを疑う

`log stream` はリアルタイム監視用。過去ログを見たい場合は `log show` だが、
`busLogger.debug(...)` の内容は既定では永続化されない（`--level debug` を付けても
`log show` では拾えないことがある）ため、再現条件を作ってから `log stream` で待ち構えること。
