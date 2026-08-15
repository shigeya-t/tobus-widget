# 新規クローン直後のセットアップ

`TobusWidget.xcodeproj` / `Info.plist` / `*.entitlements` は `project.yml` から生成する
ファイルで、`.gitignore` によりリポジトリには含まれていない。クローン直後は以下が必要。

```sh
# 1. XcodeGen が未インストールなら入れる
brew install xcodegen

# 2. project.yml からXcodeプロジェクト一式を生成する
#    （Info.plist / entitlements / .xcodeproj もこの時点で作られる）
xcodegen generate
```

`xcodegen generate` を実行しないと `xcodebuild` はプロジェクトファイルが無くて失敗するので、
このリポジトリで初めてビルドするときは必ず先に行うこと。`project.yml` を編集したときも
再実行が必要（README の「構成」参照）。

このプロジェクトはSwiftPM経由で [SwiftSoup](https://github.com/scinfu/SwiftSoup)（HTML解析）に
依存している。初回ビルド時にネットワーク経由でパッケージを取得するため、インターネット接続が必要。
`xcodebuild -resolvePackageDependencies -project TobusWidget.xcodeproj -scheme TobusWidget` で
事前解決だけ行うこともできる。

ここまで終えたら、下記の「署名付きビルドコマンド」に進む。Xcode.app から GUI でビルドする場合は
`open TobusWidget.xcodeproj` した上で、README の「Signing & Capabilities」の手順（両ターゲットに
自分の Team を設定）に従うこと。

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

このプロジェクトはSwiftPMパッケージ（SwiftSoup）に依存している。`CONFIGURATION_BUILD_DIR=build`
のようにビルド成果物の出力先を独自パスへ上書きすると、Xcodeの新ビルドシステムが
パッケージ成果物（`SwiftSoup.swiftmodule`）を依存先ターゲット（特に `TobusWidgetExtension`）へ
コピーするタイミングと、依存先ターゲットのSwiftモジュール探索タイミングがずれ、

```
error: unable to resolve module dependency: 'SwiftSoup'
```

で失敗することがある（Xcode 16 / Swift Explicit Modules まわりの既知の相性問題。SwiftSoup自体の
コンパイルは成功するが、それを利用する側のターゲットが見つけられない）。**同一のビルドコマンドを
2〜3回リトライしても直らないことを確認済み**（DerivedDataを完全に消してもTeamをそのままにしても
再発する）。`CONFIGURATION_BUILD_DIR` を指定せず、標準のDerivedData配下にビルドすれば問題なく
成功する。成果物が必要な場合は、ビルド後にDerivedDataから明示的にコピーする。

## 署名付きビルドコマンド

証明書名と Team ID は環境ごとに異なる個人情報なので、このファイル（公開リポジトリに含まれる想定）には書かない。
まず手元の証明書を確認する。

```sh
security find-identity -v -p codesigning
```

表示された証明書名から、次のコマンドで Team ID（OU）を確認できる。

```sh
security find-certificate -c "<証明書名>" -p | openssl x509 -noout -subject
```

それらを使ってビルドする（`CONFIGURATION_BUILD_DIR` は指定しない）。

```sh
xcodebuild -project TobusWidget.xcodeproj -scheme TobusWidget \
  -configuration Debug -destination 'platform=macOS' \
  -allowProvisioningUpdates \
  CODE_SIGN_STYLE=Automatic \
  CODE_SIGN_IDENTITY="Apple Development" \
  DEVELOPMENT_TEAM=<Team ID> \
  build
```

`CODE_SIGN_STYLE=Manual` + 個別の証明書名を指定する方法（[[江戸バス版]]と同じ流儀）でも動くが、
このプロジェクトではApp Groupのみで追加のプロビジョニングプロファイルが要らないため、
`Automatic` + `-allowProvisioningUpdates` の方が手数が少ない。

ビルド成果物はDerivedData配下（`~/Library/Developer/Xcode/DerivedData/TobusWidget-*/Build/Products/Debug/`）
に生成される。バンドル名は `TobusWidget.app`。実機確認用にコピーする場合は次のようにする。

```sh
APP=$(find ~/Library/Developer/Xcode/DerivedData -maxdepth 1 -iname "TobusWidget-*" \
  -exec find {}/Build/Products/Debug -maxdepth 1 -name "TobusWidget.app" \; | head -1)
cp -R "$APP" /path/to/destination/
```

## テスト

```sh
xcodebuild test -project TobusWidget.xcodeproj -scheme TobusWidget -destination 'platform=macOS' \
  -allowProvisioningUpdates CODE_SIGN_STYLE=Automatic \
  CODE_SIGN_IDENTITY="Apple Development" DEVELOPMENT_TEAM=<Team ID>
```

`TobusWidgetTests` は**ホストアプリを立てない**単体テスト（`Shared` のソースを直接取り込む構成）。
`TobusWidget` をテストホストにすると常駐アプリが起動して初回取得の通信が走るため、あえてそうしている。
したがってテストは通信せず、`AppSettings`（UserDefaults）にも触らない。

対象は「壊れても気づきにくい」2箇所に絞ってある。

- `TobusPageParserTests` — 実ページのHTML（`Tests/Fixtures/stop325.html`、勝どき橋南詰）に対する解析。
  tobus.jp は公式APIではないので、先方のHTML構造が変わったことに気づく手段がここしか無い。
  フィクスチャを更新するときは `curl 'https://tobus.jp/blsys/navi?VCD=csrst&ECD=NEXT&LCD=&func=fap&method=msn&slst=325'`
  で取り直し、期待値（系統数・分待の値）も併せて直すこと
- `RouteResolutionTests` — `BusDirectoryService.resolve` の多段引き当て。
  tobus.jp 側の並び順が実際に変わらないと再現できない経路なので、ここでしか担保できない

無署名でコンパイルの通過だけ確認したい場合（`/Applications/` へは配置しない）:

```sh
xcodebuild -project TobusWidget.xcodeproj -scheme TobusWidget \
  -configuration Debug -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  build
```

## 実機（ウィジェット）で確認する場合の反映手順

ビルドしただけでは配置済みのウィジェットには反映されない。実際に使っているコピーは
`/Applications/TobusWidget.app`（または `~/Applications/TobusWidget.app`）なので、
確認のたびに次の手順で入れ替える。アプリの起動/終了は表示名が日本語で紛らわしいため、
`osascript ... tell application "TobusWidget"` ではなく **bundle ID** で指定すること。

```sh
# 1. 実行中のプロセスを終了
osascript -e 'tell application id "com.example.TobusWidget" to quit'
pkill -f "MacOS/TobusWidget$"
pkill -f "TobusWidgetExtension"

# 2. 署名付きビルドを配置し直す（上記の$APPを使う）
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
rm -rf "/Applications/TobusWidget.app"
cp -R "$APP" /Applications/
# 古いパスの登録が残っていると混乱するので明示的に再登録する
"$LSREGISTER" -f -R -trusted "/Applications/TobusWidget.app"
open "/Applications/TobusWidget.app"
```

`codesign -dv "/Applications/TobusWidget.app/Contents/PlugIns/TobusWidgetExtension.appex"` の
`TeamIdentifier` が実際の Team ID になっていることを確認できる（`TeamIdentifier=not set` なら無署名ビルドが紛れ込んでいる）。

初回（まだ配置済みのアプリが存在しない環境）は `quit` / `pkill` は何もせず失敗するだけなので
無視してよい。また、起動しただけではウィジェットは画面に出ない。通知センターまたはデスクトップの
「ウィジェットを編集」から「都バス接近情報」を追加する必要がある（README の「ビルドと導入」参照）。

## データソース（tobus.jp）固有の注意

- APIキー等の登録は不要。江戸バス版と違い、起動直後からバス停検索・系統選択が使える
- tobus.jpは公式APIではなくHTMLスクレイピング。パース処理は `Shared/TobusPageParser.swift`
  （SwiftSoup使用）に集約している。tobus.jp側のHTML構造が変わった場合はここを見直す
- 主要エンドポイント（README「データソースについて」参照）はステートレスなGETで、
  `JSESSIONID` Cookieの継続は不要と確認済み（2026-08-14時点、`curl`で無Cookie検証済み）
- サーバー側エッジキャッシュが60秒（`Cache-Control: s-maxage=60`）。アプリ内キャッシュ
  （`TobusPageService`、50秒）もこれに合わせている
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
  URL `file:///Users/st/Applications/%E9%83%BD%E3%83%8F%E3%82%99%E3%82%B9....app/...`
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
