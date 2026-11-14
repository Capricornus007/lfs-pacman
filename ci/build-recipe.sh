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
# 緊急旁路：NO_PGO=1 跳過 PGO 單包重試（僅炸包時用，同 v2.25 單包降級慣例）。
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
if [ -z "${NO_PGO:-}" ]; then
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
  find "$PD" -name 'conftest.gcda' -delete 2>/dev/null || true
  echo "PGO 訓練：$name"
  su builder -c "cd '$pdir' && bash '$root/ci/pgo-train.sh' '$pdir' '$PD'" || true
  find "$PD" -name 'conftest.gcda' -delete 2>/dev/null || true
  rm -rf "$pdir/src" "$pdir/pkg"
  printf '\n# v2.26 PGO pass2\nCFLAGS+=" -fprofile-use=%s -fprofile-correction -Wno-missing-profile -fprofile-partial-training"\nCXXFLAGS+=" -fprofile-use=%s -fprofile-correction -Wno-missing-profile -fprofile-partial-training"\nLDFLAGS+=" -fprofile-use=%s -fprofile-correction -Wno-missing-profile -fprofile-partial-training"\n' "$PD" "$PD" "$PD" >> /etc/makepkg.conf
  echo "PGO pass2（套用 profile）：$name"
  if ! su builder -c "export PATH=/usr/local/bin:\$PATH; cd '$pdir' && makepkg -fs --noconfirm --nodeps --nocheck"; then
    cp "$MKCONF_BAK" /etc/makepkg.conf
    # 診斷：run 43627019385 實測 pass2 死在 configure 編譯器自檢
    # （cannot compute suffix of executables），本地系統 gcc 無法重現 →
    # 懷疑容器 /usr/local/bin 自編 gcc 不認 pass2 某旗標。印出關鍵證據。
    echo "═══ PGO pass2 診斷：$name ═══"
    gcc --version | head -1
    echo 'int main(){return 0;}' > /tmp/wb-conftest.c
    for probe in "-fprofile-use=$PD -fprofile-correction -Wno-missing-profile -fprofile-partial-training" \
                 "-fprofile-use=$PD -Wno-missing-profile"; do
      if gcc $probe /tmp/wb-conftest.c -o /tmp/wb-conftest 2>/tmp/wb-probe.err; then
        echo "probe OK: $probe"
      else
        echo "probe FAIL: $probe"; head -3 /tmp/wb-probe.err
      fi
    done
    tail -20 "$pdir/src"/*/config.log 2>/dev/null | head -20
    # config.log 尾段只有 confdefs.h，gcc 真實報錯在「cannot compute suffix」
    # 之前的測試命令區塊；抓出來看真正死因。
    for cfglog in "$pdir/src"/*/config.log; do
      [ -f "$cfglog" ] || continue
      grep -B25 'cannot compute suffix' "$cfglog" 2>/dev/null | tail -35 && break
    done
    # 二級降級：只留 -fprofile-use（去掉 -fprofile-correction / -fprofile-partial-training）
    # 重試前必須清 srcdir/pkg：makepkg 不重新解壓已存在的 srcdir，補丁
    # 「already exists」會讓 prepare() 先炸，重試根本走不到 build()
    # （run 43631404963 coreutils 實測）。
    rm -rf "$pdir/src" "$pdir/pkg"
    echo "PGO pass2 重試（精簡旗標）：$name"
    printf '\n# v2.26 PGO pass2 retry\nCFLAGS+=" -fprofile-use=%s -Wno-missing-profile"\nCXXFLAGS+=" -fprofile-use=%s -Wno-missing-profile"\nLDFLAGS+=" -fprofile-use=%s -Wno-missing-profile"\n' "$PD" "$PD" "$PD" >> /etc/makepkg.conf
    if ! su builder -c "export PATH=/usr/local/bin:\$PATH; cd '$pdir' && makepkg -fs --noconfirm --nodeps --nocheck"; then
      cp "$MKCONF_BAK" /etc/makepkg.conf
      echo "═══ PGO-FALLBACK：$name pass2 兩種旗標都炸，改出無 PGO 最終包（大聲標記，非靜默）═══"
      rm -rf "$pdir/src" "$pdir/pkg"
      su builder -c "export PATH=/usr/local/bin:\$PATH; cd '$pdir' && makepkg -fs --noconfirm --nodeps --nocheck" \
        || { echo "構建失敗（含 fallback）：$name"; exit 1; }
      echo "PGO-FALLBACK-USED：$name"
    fi
    cp "$MKCONF_BAK" /etc/makepkg.conf
  else
    cp "$MKCONF_BAK" /etc/makepkg.conf
  fi
else
  su builder -c "export PATH=/usr/local/bin:\$PATH; cd '$pdir' && updpkgsums && makepkg -fs --noconfirm --nodeps --nocheck" \
    || { echo "構建失敗：$name"; exit 1; }
fi
echo "OK：$name $(ls "$pdir"/*.pkg.tar.zst 2>/dev/null | tail -1)"
