#!/bin/bash
# feed-bot 專用：容器隔離構建一個配方（取代 chroot）。
# 用法: build-recipe.sh <pkgdir 名> [新版本號]
# 流程: 依 ci/sources.urls.json 抓來源（新版本號時自動換檔名）→ updpkgsums 更新校驗 → makepkg -fs
set -uo pipefail
name=$1; newver=${2:-}
root="$(cd "$(dirname "$0")/.." && pwd)"
pdir="$root/packages/$name"
[ -d "$pdir" ] || { echo "無配方 $name"; exit 1; }
cd "$pdir"
[ -n "$newver" ] && { sed -i -E "s/^pkgver=.*/pkgver=$newver/" PKGBUILD; echo "pkgver→$newver"; }

# 抓來源：解析 source=() 檔名 → URL 表查 URL（檔名含版本時用 PKGBUILD 的 pkgver 展開）
pv=$(sed -n 's/^pkgver=//p' PKGBUILD | head -1)
ROOT="$root" python3 - "$pv" <<'PY'
import re,sys,json,os,subprocess
pv=sys.argv[1]
urls=json.load(open(os.environ.get("URLS", os.path.join(os.environ["ROOT"], "ci/sources.urls.json"))))
t=open("PKGBUILD",encoding="utf-8").read()
m=re.search(r'^source=\(([^)]*)\)',t,re.M|re.S)
if not m: sys.exit(0)
srcs=re.findall(r'"?([\w.+-]+\.(?:tar\.(?:xz|gz|bz2|zst)|zip))"?',m.group(1).replace("${pkgver}",pv).replace("$pkgver",pv))
for s in srcs:
    if os.path.exists(s): continue
    u=urls.get(s)
    if not u: print("無URL:",s); sys.exit(1)
    print("wget:",u)
    subprocess.run(["curl","-fsSLO","--retry","8","--retry-delay","3","--connect-timeout","25",u],check=True)
    if os.path.basename(u)!=s: os.rename(os.path.basename(u),s)
PY
chown -R builder . 2>/dev/null || true
su builder -c "cd '$pdir' && updpkgsums && makepkg -fs --noconfirm" || { echo "構建失敗：$name"; exit 1; }
echo "OK：$name $(ls "$pdir"/*.pkg.tar.zst)"
