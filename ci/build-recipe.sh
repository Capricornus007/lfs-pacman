#!/bin/bash
# feed-bot 專用：容器隔離構建一個配方（取代 chroot）。
# 用法: build-recipe.sh <pkgdir 名> [新版本號]
# 流程: 依 ci/sources.urls.json 抓來源（新版本號時自動換檔名）→ updpkgsums 更新校驗 → makepkg -fs
set -uo pipefail
name=$1; newver=${2:-}
root="$(cd "$(dirname "$0")/.." && pwd)"
pdir="$root/packages/$name"
[ -d "$pdir" ] || { echo "無配方 $name"; exit 1; }
[ -f "$pdir/OBSOLETE" ] && { echo "SKIP OBSOLETE：$name"; exit 0; }
cd "$pdir"
# clean-room 等無法用 URL 表的本地來源（udev-standalone/libudev/udev-lfs）
[ -d "$root/ci/sources" ] && cp -n "$root"/ci/sources/* . 2>/dev/null || true
[ -n "$newver" ] && { sed -i -E "s/^pkgver=.*/pkgver=$newver/" PKGBUILD; echo "pkgver→$newver"; }

# 抓來源：解析 source=() 檔名 → URL 表查 URL（$pkgname/$pkgver 都要展開）
pv=$(sed -n 's/^pkgver=//p' PKGBUILD | head -1)
pn=$(sed -n 's/^pkgname=//p' PKGBUILD | head -1 | tr -d '"()' | awk '{print $1}')
ROOT="$root" python3 - "$pv" "$pn" <<'PY'
import re,sys,json,os,subprocess
pv,pn=sys.argv[1],sys.argv[2]
urls=json.load(open(os.environ.get("URLS", os.path.join(os.environ["ROOT"], "ci/sources.urls.json"))))
t=open("PKGBUILD",encoding="utf-8").read()
m=re.search(r'^source=\(([^)]*)\)',t,re.M|re.S)
if not m: sys.exit(0)
raw=m.group(1)
for var,val in (("pkgver",pv),("pkgname",pn)):
    raw=raw.replace("${"+var+"}",val).replace("$"+var,val)
srcs=re.findall(r'"?([\w.+-]+\.(?:tar\.(?:xz|gz|bz2|zst)|zip))"?',raw)
for s in srcs:
    if os.path.exists(s): continue
    u=urls.get(s)
    if not u: print("無URL:",s); sys.exit(1)
    cands=[u]
    # GNU 的 ftpmirror.gnu.org 從 GitHub runner 常連不上（2026-11-09 實錘：
    # gzip、mpc 都 curl 28 逾時，連 8 次重試全失敗）。補官方與 kernel.org 鏡像。
    if "ftpmirror.gnu.org/" in u:
        rest=u.split("ftpmirror.gnu.org/",1)[1]
        cands += ["https://ftp.gnu.org/gnu/"+rest,
                  "https://mirrors.kernel.org/gnu/"+rest]
    ok=False; last=""
    for uu in cands:
        print("wget:",uu)
        base=os.path.basename(uu)
        subprocess.run(["rm","-f",base])
        r=subprocess.run(["curl","-fsSLO","--retry","4","--retry-delay","3",
                          "--connect-timeout","20",uu])
        if r.returncode==0:
            if base!=s: os.rename(base,s)
            ok=True; break
        last=uu
    if not ok:
        print("下載失敗（含鏡像）:",last); sys.exit(1)
PY
chown -R builder . 2>/dev/null || true
# /usr/local/bin 放 znver3 編譯器外掛；su 會重建 PATH，這裡明確帶過去，
# 確保 makepkg／configure／Makefile 看到的 gcc 都是外掛版（64/32 位一體）。

# ── v2.26（2026-11-15 用戶定案）：全量兩段式 PGO ────────────────────────────
# 100 包無白名單全部套用（gcc／glibc 在內）。流程：
#   pass1  CFLAGS+=-fprofile-generate=$PD -fprofile-update=atomic，
#          OPTIONS 用 !strip（strip 會剝掉 gcov 節區，.gcda 就寫不出來），
#          makepkg --noarchive 編出插樁樹 → ci/pgo-train.sh 限時訓練收 .gcda
#   pass2  清樹重編，CFLAGS+=-fprofile-use=$PD -fprofile-correction
#          -Wno-missing-profile -fprofile-partial-training → strip 出最終包
# profile 與兩份 pass conf 都放 /tmp，不污染倉庫樹；訓練只收集不判死。
# 用戶鐵律：六最無豁免——PGO 全量強制，任何包都不許 NO_PGO 旁路或無 PGO 降級。
# 構建失敗即 exit 1 暴露問題，源頭修好再過，不靜默降旗標。
gen_pgo_conf() {  # $1=pass1|pass2  $2=輸出 conf  $3=gcda 目錄
  local pass=$1 out=$2 pd=$3 extra cf cxf ld lto
  cf=$(set +u; . /etc/makepkg.conf; printf '%s' "${CFLAGS:-}")
  cxf=$(set +u; . /etc/makepkg.conf; printf '%s' "${CXXFLAGS:-$cf}")
  ld=$(set +u; . /etc/makepkg.conf; printf '%s' "${LDFLAGS:-}")
  lto=$(set +u; . /etc/makepkg.conf; printf '%s' "${LTOFLAGS:--flto=auto}")
  case "$pass" in
    pass1) extra="-fprofile-generate=$pd -fprofile-update=atomic"
           printf 'OPTIONS=(!strip docs !libtool staticlibs emptydirs zipman purge !debug lto)\n' ;;
    pass2) extra="-fprofile-use=$pd -fprofile-correction -Wno-missing-profile -fprofile-partial-training"
           printf 'OPTIONS=(strip docs !libtool staticlibs emptydirs zipman purge !debug lto)\n' ;;
  esac > "$out"
  printf 'MAKEFLAGS="-j$(nproc)"\n'  >> "$out"
  printf 'CFLAGS="%s %s"\n'  "$cf"  "$extra" >> "$out"
  printf 'CXXFLAGS="%s %s"\n' "$cxf" "$extra" >> "$out"
  printf 'LDFLAGS="%s"\n'  "$ld"  >> "$out"
  printf 'LTOFLAGS="%s"\n' "$lto" >> "$out"
}

# makepkg -p 自訂 conf 會踩 readonly OPTIONS（run 43623494641 實測：
# ".wb-pgo1.conf: line 1: OPTIONS: readonly variable" → PKGBUILD 變數解析全空，
# 90/91 包全死）。改為直接對 /etc/makepkg.conf 追加旗標、每段前快照後還原；
# pass1 的 strip 關閉改由追加 OPTIONS=(!strip … lto) 到 /etc/makepkg.conf 末尾
# （readonly 在 conf 讀完後才設，追加賦值合法）。
#
# ── v2.29（2026-11-15 用戶定案：廢除整包豁免，glibc/python 必須被 PGO 優化）──
# glibc：ld.so 組件在 PKGBUILD 內免插樁（rtld-CFLAGS + elf/Makefile 追加
#        -fno-profile-generate；ld.so 無 gcov dump 機制，插樁採不到數據且
#        -nostdlib 鏈接必炸），libc.so.6 等主體全量插樁 → 主體被 PGO 優化。
# python：PKGBUILD 廢除 --enable-optimizations（雙重插樁 _freeze_module abort），
#        外層兩段式 PGO 全權負責，訓練用 CPython 官方 PGO 負載（-m test --pgo）。
if true; then  # v2.30：PGO 無條件全量（無 NO_PGO 旁路）
  PD="/tmp/pgo-data-$name"; MKCONF_BAK="/tmp/makepkg.conf.bak-$name"
  cp /etc/makepkg.conf "$MKCONF_BAK"
  rm -rf "$PD" "$pdir/src" "$pdir/pkg"; mkdir -p "$PD"
  chown -R builder "$PD" 2>/dev/null || true
  # OPTIONS 追加在 /etc/makepkg.conf 末尾＝還在 makepkg 設 readonly 之前，合法；
  # strip 關掉保 gcov 節區，lto 保留。
  # PGO 旗標必須同時進 LDFLAGS：LTO 下最終鏈接由 lto1 重編，dhcpcd 類
  # 「編譯用 CFLAGS、鏈接只用 LDFLAGS」的構建系統會漏掉 libgcov，
  # 報 undefined reference to __gcov_*（run #51 dhcpcd 實測）。
  printf '\n# v2.26 PGO pass1\nCFLAGS+=" -fprofile-generate=%s -fprofile-update=atomic"\nCXXFLAGS+=" -fprofile-generate=%s -fprofile-update=atomic"\nLDFLAGS+=" -fprofile-generate=%s -fprofile-update=atomic"\nOPTIONS=(!strip docs !libtool staticlibs emptydirs zipman purge !debug lto)\n' "$PD" "$PD" "$PD" >> /etc/makepkg.conf
  echo "PGO pass1（插樁編譯）：$name"
  su builder -c "export PATH=/usr/local/bin:\$PATH; cd '$pdir' && updpkgsums && makepkg -fs --noconfirm --nodeps --noarchive --nocheck" \
    || { cp "$MKCONF_BAK" /etc/makepkg.conf; echo "PGO pass1 失敗：$name"; exit 1; }
  cp "$MKCONF_BAK" /etc/makepkg.conf
  # conftest.gcda 污染（run 43631404963 coreutils／run 43627019385 attr 實測）：
  # pass1 configure 每個測試程式都寫 $PD/<來源路徑>#conftest.gcda，pass2 的
  # configure conftest 路徑與 pass1 完全相同 → -fprofile-use 讀到 checksum
  # 不匹配的殘留 profile，configure 自檢「cannot compute suffix of executables」
  # 直接炸。真實來源的 .gcda 保留，只清 conftest 產物。
  # 2026-11-24 udev-standalone 實測：autotools 的 conftest profile 不只有
  # 精確的 conftest.gcda，還有 configure 各子測試的 conftest-<n>.gcda 等變體；
  # 只刪精確名會讓 pass2 的 configure 讀到 checksum 不符的殘留，照樣炸
  # 「cannot compute suffix of executables」。改成 conftest*.gcda 通配全清。
  find "$PD" -name 'conftest*.gcda' -delete 2>/dev/null || true
  echo "PGO 訓練：$name"
  su builder -c "cd '$pdir' && bash '$root/ci/pgo-train.sh' '$pdir' '$PD'" || true
  find "$PD" -name 'conftest*.gcda' -delete 2>/dev/null || true
  # 六最無豁免：訓練後必須有真實 .gcda,否則 pass2 的 -fprofile-use 等於沒 PGO。
  # 以往靜默繼續＝出無 profile 包,現在直接紅,迫使訓練負載被修好。
  _gcda=$(find "$PD" -name '*.gcda' 2>/dev/null | wc -l)
  if [ "$_gcda" -eq 0 ]; then
    cp "$MKCONF_BAK" /etc/makepkg.conf
    echo "::error::$name PGO 訓練零 .gcda（六最無豁免，不出無 profile 包；請修 ci/pgo-train.sh 訓練負載）"
    exit 1
  fi
  echo "PGO 訓練收到 $_gcda 個 .gcda：$name"
  rm -rf "$pdir/src" "$pdir/pkg"
  # pass2 清樹重解後 configure 會重寫 conftest profile；再清一次通配，
  # 避免任何訓練階段留下的 conftest 變體被 -fprofile-use 讀到（udev 實測）。
  find "$PD" -name 'conftest*.gcda' -delete 2>/dev/null || true
  printf '\n# v2.26 PGO pass2\nCFLAGS+=" -fprofile-use=%s -fprofile-correction -Wno-missing-profile -fprofile-partial-training"\nCXXFLAGS+=" -fprofile-use=%s -fprofile-correction -Wno-missing-profile -fprofile-partial-training"\nLDFLAGS+=" -fprofile-use=%s -fprofile-correction -Wno-missing-profile -fprofile-partial-training"\n' "$PD" "$PD" "$PD" >> /etc/makepkg.conf
  echo "PGO pass2（套用 profile）：$name"
  if ! su builder -c "export PATH=/usr/local/bin:\$PATH; cd '$pdir' && makepkg -fs --noconfirm --nodeps --nocheck"; then
    cp "$MKCONF_BAK" /etc/makepkg.conf
    echo "::error::PGO pass2 失敗：$name（六最無豁免，不降級出無 PGO 包；請修源頭）"
    exit 1
  fi
  cp "$MKCONF_BAK" /etc/makepkg.conf
fi
echo "OK：$name $(ls "$pdir"/*.pkg.tar.zst 2>/dev/null | tail -1)"
