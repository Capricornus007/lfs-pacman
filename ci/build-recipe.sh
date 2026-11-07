#!/bin/sh
# feed-bot 用：在 archlinux 容器內逐配方構建（容器＝隔離，不污染任何系統；取代 chroot）
# 用法：build-recipe.sh <packages/下的目錄名>… ；失敗即紅（exit≠0）
set -e
SRC_GIT="https://github.com/Capricornus007/lfs-pacman.git"
SRC_DIR="$(dirname "$0")/../ci-sources-cache"
mkdir -p "$SRC_DIR"
fetch_source() { # $1=檔名 $2=md5 → 本地快取優先，缺就從盤上清單對應 URL 抓
  local f=$1 md5=$2 u
  if [ -s "$SRC_DIR/$f" ] && { [ -z "$md5" ] || [ "$(md5sum "$SRC_DIR/$f" | cut -d' ' -f1)" = "$md5" ]; }; then
    cp "$SRC_DIR/$f" .; return 0
  fi
  # URL 由配方 source=() 給出；CI 環境直連鏡像
  u="$3"
  [ -n "$u" ] || { echo "缺來源且無 URL：$f"; return 1; }
  curl -fL --retry 6 --retry-delay 4 -o "$f" "$u"
  if [ -n "$md5" ]; then
    echo "$md5  $f" | md5sum -c - || { echo "md5 不符：$f"; return 1; }
  fi
  cp "$f" "$SRC_DIR/$f"
}
fail=0
for p in "$@"; do
  echo "==================== $p ===================="
  cd "$(dirname "$0")/.."; cd "packages/$p" || { echo "無配方目錄 $p"; fail=1; continue; }
  su builder -c "cd '$PWD' && makepkg -fs --noconfirm --skipchecksums 2>&1 | tail -30" || { echo "FAIL: $p"; fail=1; continue; }
  echo "OK: $p"
  cd - >/dev/null
done
exit $fail
