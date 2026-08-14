# 都バス接近情報ウィジェット

東京都交通局「都営バス」のバス停への車両接近情報を表示する macOS ウィジェットです。
[江戸バス接近情報ウィジェット](https://github.com/shigeya-t/edobus-widget) と同じ構成
（WidgetKit ウィジェット + メニューバー常駐アプリ）で、公式サイト
[都バス運行情報サービス（tobus.jp）](https://tobus.jp/blsys/navi) が内部で使っている
HTML画面を取得し、クライアント側で解析（スクレイピング）して表示します。

## できること

- 通知センター / デスクトップに置ける WidgetKit ウィジェット（小・中サイズ）
- 都バス運行情報サービスの車両接近情報にもとづく状態表示（実車接近中は「約N分後」、
  実車情報が無い時間帯は定型文で表示）
- 本日の残り定刻（静的時刻表）をあわせて表示（中サイズウィジェット・メニューバー）
- バス停名で検索し、その停留所にある系統（のりば×行き先）から選択
  （ひらがな・カタカナ1文字だけの検索は、tobus.jpに問い合わせる前に案内を出して弾く）
- メニューバーに接近状況を常時表示（クリックでバス停・系統の切り替え）
- 一定時間（既定10分）更新できていない場合は、古いデータの可能性がある旨を警告表示
- APIキー等の登録は不要（公式サイトが誰でも使える形で公開している画面をそのまま利用）

### 表示される情報について

tobus.jpの車両接近情報ページには、系統ごとに次の2種類のレイアウトがあります。

- **実車が接近中**: `東京駅丸の内南口行04分待` / `深川車庫前行まもなく` のように、
  行き先と分単位の待ち時間（または「まもなく」）を含む実テキストが表示される
  （`td.busLabel`）。ここから分数を取り出し、「約N分後」として表示します
- **実車情報が無い/定型メッセージのみ**: 次のような定型文（バケット）だけが返る（`td.stopNotes`）

  | tobus.jpの文言 | 表示 |
  | --- | --- |
  | `ただいま定刻で運行しています。` | 定刻運行中 |
  | `５分以内に発車予定です。` | まもなく発車 |
  | `ただいまの時間は接近情報をご案内できません。` | 接近情報を案内できません |
  | `本日は運休日です。` | 本日は運休 |

どちらのレイアウトになるかは系統・時間帯によって変わるため、両方に対応しています
（`Shared/TobusPageParser.swift` の `approachInfo(inTable:)`）。

### 定刻（時刻表）について

車両接近情報ページの「時刻表」リンクを2段階たどって、静的時刻表を取得しています。

1. 「行き先選択」ページ（`VCD=SelectDest&ECD=SelectDest`）を取得し、実際の時刻表ページへの
   パラメータ（`onclick="func_stoppole(...)"`）を取り出す
2. 時刻表ページ（`VCD=cresultttbl&ECD=show`）を取得する

時刻表ページ自身が「本日は、〇曜ダイヤで運行しております」という文言と、対応する時刻表テーブルの
IDを教えてくれるため、こちらで祝日判定などを行う必要はありません（`Shared/TobusPageParser.swift`
の `parseTimetable` / `todayScheduleTableId`）。時刻表は日をまたがない限り変わらないため、
系統ごとに1日1回だけ取得します（`Shared/BusScheduleService.swift`）。

小ウィジェットでは、系統ラベル・バス停名の表示だけで十分スペースを使うため、定刻は表示していません
（中ウィジェット・メニューバーのみ）。

## 必要なもの

- macOS 14 以降
- Xcode 15 以降
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`）
- インターネット接続（初回ビルド時にSwift Package Manager経由で
  [SwiftSoup](https://github.com/scinfu/SwiftSoup)（HTML解析ライブラリ）を取得します）

## ビルドと導入

```sh
brew install xcodegen
xcodegen generate
open TobusWidget.xcodeproj
```

Xcode で以下を行ってください。

1. **Signing & Capabilities** で `TobusWidget` と `TobusWidgetExtension` の両ターゲットに自分の Team を設定する
   （無料の Personal Team で動作します）
2. スキーム `TobusWidget` を選んで実行（⌘R）する
   （Dock には出ず、メニューバーにバスのアイコンが常駐します）
3. メニューバーアイコンをクリックし、バス停名で検索して選び、系統を選ぶ
4. 通知センターまたはデスクトップで「ウィジェットを編集」から「都バス接近情報」を追加する
   （ウィジェットごとに個別のバス停・系統を選べます）

常時使う場合は、システム設定 →「一般」→「ログイン項目」に登録しておくと便利です。

バンドル ID は `com.example.TobusWidget`（プレースホルダ）です。自分の環境で使う場合は
`project.yml` の `bundleIdPrefix` と `PRODUCT_BUNDLE_IDENTIFIER` を書き換えてください。

App Group は、アプリとウィジェットの間で選択状態・一時停止フラグ・接近状況のスナップショットを
共有するために使っています。macOS では識別子に Team ID のプレフィックスが必須なため、
`project.yml` で `$(DEVELOPMENT_TEAM).com.example.TobusWidget` として組み立てています。
**`DEVELOPMENT_TEAM` を自分の Team ID にすれば、entitlement と実行時の参照先の両方に反映されます**
（コード側は Info.plist 経由で読み取るため、書き換え箇所はありません）。

> **署名について（重要）**
> アドホック署名（`CODE_SIGN_IDENTITY="-"`）ではビルドは通りますが、[江戸バス版と同様に](https://github.com/shigeya-t/edobus-widget#ビルドと導入)
> AppIntents の登録に Team ID が必要なため、ウィジェットの設定パネルが解決できず動作しません。
> 無料の Personal Team で構わないので、必ず Team を設定して署名してください。

> **`CONFIGURATION_BUILD_DIR` を指定したコマンドラインビルドについて**
> SwiftPM経由の依存（SwiftSoup）を使っているため、`CONFIGURATION_BUILD_DIR` を独自の場所に
> 上書きしてビルドすると、パッケージ成果物のコピー先とタイミングがずれ、
> `unable to resolve module dependency: 'SwiftSoup'` で失敗することがあります
> （Xcodeの新ビルドシステムとSwiftPMパッケージ成果物コピーの既知の相性問題）。
> コマンドラインでビルドする場合は `CONFIGURATION_BUILD_DIR` を指定せず、標準のDerivedDataに
> ビルドしてから、必要なら成果物をコピーしてください。

```sh
xcodebuild -project TobusWidget.xcodeproj -scheme TobusWidget \
  -configuration Debug -destination 'platform=macOS' \
  -allowProvisioningUpdates \
  CODE_SIGN_STYLE=Automatic \
  CODE_SIGN_IDENTITY="Apple Development" \
  DEVELOPMENT_TEAM=YOURTEAMID \
  build

# ビルド成果物はDerivedData配下に生成される。必要ならコピーする。
# .app のファイル名は TobusWidget.app。メニューバー等での表示名だけが「都バス接近情報」。
APP=$(find ~/Library/Developer/Xcode/DerivedData -maxdepth 1 -iname "TobusWidget-*" \
  -exec find {}/Build/Products/Debug -maxdepth 1 -name "TobusWidget.app" \; | head -1)
cp -R "$APP" /Applications/
open "/Applications/TobusWidget.app"
```

## バス停・系統の選び方

メニューバーのメニューでバス停名を検索すると、部分一致した停留所クラスタが候補に出ます
（tobus.jp自体が「ひらがな・カタカナは2文字以上、漢字は1文字から検索可」という制約を持つため、
アプリ側でもひらがな・カタカナ1文字だけの入力は通信前に弾いて案内を表示します）。
1つの停留所名（例:「東京駅丸の内北口」）には複数ののりば・複数の系統が属することが多いため、
バス停を選んだあとに系統（例:「東２２ 錦糸町駅前 行」）を選んでください。

ウィジェット側は右クリック →「ウィジェットを編集」で、同様にバス停・系統を選べます。
複数のウィジェットを置いて、それぞれ別のバス停・系統を表示することもできます。

## 更新のしくみ

**このアプリはメニューバーに常駐します。** 常駐をやめるとウィジェットはほぼ更新されません
（[江戸バス版](https://github.com/shigeya-t/edobus-widget#更新のしくみ)と同じ理由・同じ設計です）。

取得はメニューバーアプリに一本化しており、**ウィジェット拡張は自分では一切通信しません**
（`WidgetInfo` から系統IDを取り出す際も、AppIntentsが保存済みのウィジェット設定値だけを使い、
tobus.jpへは問い合わせません。WidgetKitはウィジェット拡張の実行時間を厳しく制限しており、
拡張側で通信すると間に合わず古いタイムラインが表示され続けることがあるための設計です）。
アプリが60秒ごとに、自分が表示している系統と、配置されている各ウィジェットが表示している系統
（`WidgetCenter.getCurrentConfigurations` で検出）の分をまとめて取得し、App Group 経由の
共有ストレージに保存します。ウィジェット側はその値を読むだけです。同じ停留所（`slst`）を指す
系統が複数あっても、そのページへのリクエストは短時間キャッシュ（50秒）により1回にまとまります。

定刻（静的時刻表）は日をまたがない限り変わらないため、系統ごとに1日1回だけ取得し
（`BusScheduleService` が日次キャッシュ）、その結果もApp Group経由でウィジェットへ共有します。

tobus.jp側のレスポンスヘッダーは `Cache-Control: max-age=60, s-maxage=60` を返しており、
60秒より高頻度で取得しても新しい情報は返りません。取得間隔を変えたい場合は
`App/TobusWidgetApp.swift` の `refreshInterval` を変更してください。

一定時間（既定10分、`BusApproach.isStale`）更新できていない場合は、メニューバー・ウィジェット
双方に⚠️アイコンで「古いデータの可能性」を表示します（一時停止中は対象外）。

### 一時停止

使わない時間帯は、メニューの「一時停止」でリクエストを完全に止められます。

- 定期取得を停止し、ウィジェットの更新も行いません
- 設定は次回起動にも引き継がれます
- 「今すぐ更新」は一時停止中でも取得します（明示操作のため）。ウィジェットのボタンから
  押した場合も、ウィジェット自身ではなくアプリに取得を依頼します（アプリの起動が必要です）

## データソースについて

このアプリは、東京都交通局が公開している
[都バス運行情報サービス（tobus.jp）](https://tobus.jp/blsys/navi) が内部で使っている
HTMLエンドポイントを直接利用しています。

| 用途 | エンドポイント |
| --- | --- |
| 停留所名称検索 | `navi?VCD=csrst&ECD=search&func=fap&method=msn&srtxt=<検索文字列>` |
| 車両接近情報（停留所単位、全のりば・全系統） | `navi?VCD=csrst&ECD=NEXT&func=fap&method=msn&slst=<停留所ID>` |
| 時刻表・行き先選択 | `navi?VCD=SelectDest&ECD=SelectDest&slst=<停留所ID>&pl=<のりば番号>&RTMCD=<系統コード>` |
| 時刻表本体 | `navi?VCD=cresultttbl&ECD=show&RTMCD=...&slst=...&bs=...&pl=...&lrid=...&tgo=...`（前段のページから取得したパラメータを使う） |

**注意点**

- tobus.jpは公式サイトですが、公式API・オープンデータとして提供されているわけではありません。
  ここで使っているHTML構造・URLパラメータは、公開画面の内部実装を調査して得たものです。
  提供側の都合で予告なく変更・停止される可能性があります
- 接続時にセッションCookie（`JSESSIONID`）が発行されますが、動作確認の結果、
  クエリパラメータだけで完結するステートレスなGETとして利用できています
  （セッションの継続や事前のログイン等は不要です）
- ページ側の免責事項（`navi?VCD=cresultapr&ECD=nc`）には、当局の許諾なく本サービス経由の情報を
  「利用者個人の私的使用の範囲外」で使用・第三者への提供をしてはならない旨の記載があります。
  このアプリを個人利用の範囲で使う分には問題ありませんが、配布・公開する場合は利用条件に
  十分ご注意ください
- 実車が接近中は「約N分後」の分単位表示、そうでない時間帯は定型文（定刻運行中／まもなく発車／
  接近情報案内不可／運休）をベースに表示します（詳細は「表示される情報について」を参照）

## 構成

```
project.yml               XcodeGen のプロジェクト定義（Info.plist と entitlements はここから生成）
Shared/
  TobusConfig.swift         タイムゾーン等の設定
  BusModels.swift           停留所クラスタ・系統ブロック・接近状況・時刻(BusTime)のドメインモデル
  BusAPI.swift               tobus.jpへのHTTP GETクライアント（HTML取得のみ）
  TobusPageParser.swift      SwiftSoupによるHTML解析（検索結果・車両接近情報・時刻表の各ページ）
  BusDirectoryService.swift  停留所検索・系統一覧の取得、ページの短時間キャッシュ
  BusLocationService.swift   系統ブロックの現在の接近状況への変換
  BusScheduleService.swift   定刻（静的時刻表）の取得、系統ごとの日次キャッシュ
  SelectBusStopIntent.swift  ウィジェット設定パネル（AppIntents、バス停→系統の順に選択）
  RefreshBusIntent.swift     ウィジェット上の更新・一時停止ボタン
  AppSettings.swift          App Group経由の共有設定・接近状況/定刻スナップショット
App/                       メニューバー常駐アプリ（ウィジェットの更新もここから行う）
WidgetExtension/           ウィジェット本体（通信は一切行わず、共有スナップショットを読むだけ）
```

`Info.plist` と `*.entitlements` は `project.yml` から生成されるため、リポジトリには含めていません。
設定を変えるときは `project.yml` を編集して `xcodegen generate` を実行してください。

## ライセンス

[MIT License](LICENSE)

ライセンスが及ぶのはこのリポジトリのコードだけです。都営バスの運行データ、および
都バス運行情報サービス（tobus.jp）に対する権利は一切含みません。データの利用可否については
提供元（東京都交通局）の免責事項・利用条件に従ってください。
