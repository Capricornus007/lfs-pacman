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

# 1) 限時 make check（部分 profile 勝過沒有；-k 忽略單項測試失敗）
find src -maxdepth 5 -name Makefile 2>/dev/null | sort | while read -r mk; do
  grep -qE '^check[:( ]' "$mk" 2>/dev/null || continue
  d=$(dirname "$mk")
  echo "train: make check @ ${d#src/}（≤15 分鐘）"
  ( cd "$d" && timeout 900 make check -k >/dev/null 2>&1 ) || true
done

# 2) 冒煙：每個 ELF 執行檔跑 --help／--version（20 秒硬上限各）
find pkg -type f 2>/dev/null | sort | while read -r f; do
  file -b "$f" 2>/dev/null | grep -q 'ELF.*executable' || continue
  timeout 20 "$f" --help    >/dev/null 2>&1 || true
  timeout 20 "$f" --version >/dev/null 2>&1 || true
done

echo "train: 收到 $(find "$pd" -name '*.gcda' 2>/dev/null | wc -l) 個 .gcda"
exit 0
