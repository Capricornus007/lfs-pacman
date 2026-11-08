#!/bin/sh
# feed-bot CI 專用：把目標機（AMD Ryzen 5 5600U / Zen 3）的 -march 套到每一次
# gcc / g++ / cc / c++ 呼叫，含 -m32 的 32 位步驟。
#
# 為什麼需要它：makepkg.conf 的 CFLAGS 只會進到 configure/meson 型配方；
# bzip2 的 Makefile 自己寫死 CFLAGS=，libcap 硬寫 CC="gcc -m32 -march=i686"，
# udev-standalone 直接 make CFLAGS=...，這些都吃不到 makepkg.conf。
# 把 -march 放在 argv 最後，GCC 由左至右處理，會蓋掉前面的 -march=i686 /
# -mtune=generic，所以 64 位與 32 位一致都是 znver3。
#
# 這不是 -march=native：不探測宿主 CPU，GitHub runner 是什麼 CPU 都不影響目標。
real="/usr/bin/${0##*/}"
for a in "$@"; do
  case "$a" in
    -dumpmachine|-dumpversion|--version|-print-*|-v|-###)
      exec "$real" "$@"
      ;;
  esac
done
exec "$real" "$@" -march=znver3 -mtune=znver3
