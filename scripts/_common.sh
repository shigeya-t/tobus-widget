#!/bin/bash
# 各スクリプトから source して使う共通処理。単体では実行しない。

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$REPO_ROOT/TobusWidget.xcodeproj"
SCHEME="TobusWidget"
APP_NAME="TobusWidget.app"
BUNDLE_ID="com.example.TobusWidget"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

die() { echo "error: $*" >&2; exit 1; }

# Team ID は環境ごとに異なる個人情報なのでリポジトリには書かない。
# DEVELOPMENT_TEAM が指定されていればそれを使い、無ければ手元の
# 「Apple Development」証明書の OU から引く。
resolve_team_id() {
  if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
    echo "$DEVELOPMENT_TEAM"
    return
  fi

  local names
  names=$(security find-identity -v -p codesigning \
    | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p')

  [[ -n "$names" ]] || die "Apple Development 証明書が見つかりません。Xcode でサインインしてください。"

  if [[ $(wc -l <<<"$names") -gt 1 ]]; then
    echo "複数の証明書が見つかりました。DEVELOPMENT_TEAM=<Team ID> を指定してください:" >&2
    echo "$names" >&2
    exit 1
  fi

  local team
  team=$(security find-certificate -c "$names" -p \
    | openssl x509 -noout -subject \
    | sed -n 's/.*OU *= *\([A-Z0-9]*\).*/\1/p')

  [[ -n "$team" ]] || die "証明書から Team ID を取得できませんでした: $names"
  echo "$team"
}

# 署名付きの xcodebuild。CONFIGURATION_BUILD_DIR は指定しない
# （SwiftPM 成果物のコピーとモジュール探索がずれて SwiftSoup の解決に失敗するため。
#   詳細は CLAUDE.md「ビルドについて」）。
run_xcodebuild() {
  local team
  team=$(resolve_team_id)
  xcodebuild "$@" \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination 'platform=macOS' \
    -allowProvisioningUpdates \
    CODE_SIGN_STYLE=Automatic \
    CODE_SIGN_IDENTITY="Apple Development" \
    DEVELOPMENT_TEAM="$team"
}

# DerivedData に生成された .app を探す。
built_app_path() {
  find ~/Library/Developer/Xcode/DerivedData -maxdepth 1 -iname "TobusWidget-*" \
    -exec find {}/Build/Products/Debug -maxdepth 1 -name "$APP_NAME" \; 2>/dev/null | head -1
}
