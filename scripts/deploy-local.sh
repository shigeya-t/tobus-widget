#!/bin/bash
#
# 署名付きでビルドし、配置済みのアプリを入れ替えて起動し直す。
# ビルドしただけでは配置済みウィジェットに反映されないため、動作確認のたびにこれを使う。
#
#   ./scripts/deploy-local.sh                    # ~/Applications へ配置
#   ./scripts/deploy-local.sh /Applications      # 配置先を指定
#   DEVELOPMENT_TEAM=XXXXXXXXXX ./scripts/deploy-local.sh
#
# 手順を間違えやすい点をここに閉じ込めている:
#   - アプリの終了は表示名が日本語で紛らわしいため bundle ID で指定する
#   - ウィジェット拡張のプロセスも落とさないと古いコードが動き続ける
#   - 入れ替え後は LaunchServices に再登録しないと拡張を起動できないことがある

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

DEST="${1:-$HOME/Applications}"
TARGET="$DEST/$APP_NAME"

echo "==> ビルド"
run_xcodebuild build >/dev/null || die "ビルドに失敗しました。詳細は xcodebuild を直接実行して確認してください。"

APP=$(built_app_path)
[[ -n "$APP" ]] || die "$APP_NAME が DerivedData に見つかりません。"
echo "    $APP"

echo "==> 実行中のプロセスを終了"
# まだ配置されていない環境では何も落とすものが無いので、失敗は無視する。
osascript -e "tell application id \"$BUNDLE_ID\" to quit" 2>/dev/null || true
pkill -f "MacOS/TobusWidget$" 2>/dev/null || true
pkill -f "TobusWidgetExtension" 2>/dev/null || true
sleep 1

echo "==> 配置: $TARGET"
mkdir -p "$DEST"
rm -rf "$TARGET"
cp -R "$APP" "$DEST/"

# 古いパスの登録が残っていると拡張の解決に失敗することがあるので明示的に登録し直す。
"$LSREGISTER" -f -R -trusted "$TARGET"

echo "==> 署名の確認"
TEAM_LINE=$(codesign -dv "$TARGET/Contents/PlugIns/TobusWidgetExtension.appex" 2>&1 \
  | grep TeamIdentifier || true)
echo "    ${TEAM_LINE:-TeamIdentifier が読めません}"
if [[ "$TEAM_LINE" == *"not set"* ]]; then
  # AppIntents は署名の Team ID が無いと解決できず、ウィジェットが更新されなくなる。
  die "無署名のビルドが配置されました。ウィジェットは動きません。"
fi

open "$TARGET"
echo "==> 完了。ウィジェット未配置なら「ウィジェットを編集」から追加してください。"
