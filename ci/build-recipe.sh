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
    print("wget:",u)
    subprocess.run(["curl","-fsSLO","--retry","8","--retry-delay","3","--connect-timeout","25",u],check=True)
    if os.path.basename(u)!=s: os.rename(os.path.basename(u),s)
PY
chown -R builder . 2>/dev/null || true
# /usr/local/bin 放 znver3 編譯器外掛；su 會重建 PATH，這裡明確帶過去，
# 確保 makepkg／configure／Makefile 看到的 gcc 都是外掛版（64/32 位一體）。
su builder -c "export PATH=/usr/local/bin:\$PATH; cd '$pdir' && updpkgsums && makepkg -fs --noconfirm --nodeps --nocheck" || { echo "構建失敗：$name"; exit 1; }
echo "OK：$name $(ls "$pdir"/*.pkg.tar.zst)"
