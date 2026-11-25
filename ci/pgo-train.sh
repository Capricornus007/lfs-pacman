#!/bin/bash
# PGO 訓練負載（v2.26 兩段式的中段）。用法: pgo-train.sh <pkgdir> <gcda 目錄>
# 原則：只收集、不判死 —— 任何訓練失敗都不影響構建（全程 || true + timeout 硬上限）。
#   1) 套件樹內有 check 目標就限時 15 分鐘跑 make check（glibc/gcc 全套要數小時，
#      硬切收「部分但真實」的 profile）；
#   2) pkg/ 內每個 ELF 執行檔 --help／--version 冒煙一輪，收基本熱點。
# 插樁二進位會把 .gcda 寫進 $pd（-fprofile-generate=$pd 編譯時已定路徑）。
set -uo pipefail
pdir=$1; pd=$2
cd "$pdir" || exit 0
[ -w "$pd" ] || exit 0

# 0) python 專屬訓練（v2.29）：CPython 官方 PGO 負載 -m test --pgo。
#    PKGBUILD 已廢除 --enable-optimizations（避免雙重插樁），外層 PGO 全權負責，
#    訓練負載由這裡補上 —— 用官方精選的 PGO 測試子集跑插樁直譯器。
python_bin=$(find src -maxdepth 2 -path '*/Python-*/python' -type f 2>/dev/null | sort | head -n1)
if [ -n "$python_bin" ] && [ -x "$python_bin" ]; then
  echo "train: python 專屬負載 -m test --pgo @ ${python_bin%/*}（≤15 分鐘）"
  ( cd "${python_bin%/*}" && timeout 900 ./python -m test --pgo >/dev/null 2>&1 ) || true
fi

# 1) 限時 make check（部分 profile 勝過沒有；-k 忽略單項測試失敗）
find src -maxdepth 5 -name Makefile 2>/dev/null | sort | while read -r mk; do
  grep -qE '^(check|test)[:( ]' "$mk" 2>/dev/null || continue
  d=$(dirname "$mk")
  echo "train: make check @ ${d#src/}（≤15 分鐘）"
  ( cd "$d" && timeout 900 make check -k >/dev/null 2>&1 ) || true
done

# 2) 冒煙：每個 ELF 執行檔跑 --help／--version（20 秒硬上限各）
# 除了安裝後的 pkg/，也跑 src/ —— libssh2/autoconf 等套件的 check 目標是
# shell 腳本、pkg/ 只有 .so／sh 腳本，只冒煙 pkg/ 會零 .gcda（repo
# shard3 #87 / lfs-pacman #111 實測）。src/ 下套件自己編的 ELF 執行檔
# （tests/、build tool 等）才是插樁過、能寫 gcda 的訓練標的。
for tree in pkg src; do
  find "$tree" -type f -perm -u+x 2>/dev/null | sort | while read -r f; do
    file -b "$f" 2>/dev/null | grep -q 'ELF.*executable' || continue
    timeout 20 "$f" --help    >/dev/null 2>&1 || true
    timeout 20 "$f" --version >/dev/null 2>&1 || true
  done
done

echo "train: 收到 $(find "$pd" -name '*.gcda' 2>/dev/null | wc -l) 個 .gcda"
exit 0
