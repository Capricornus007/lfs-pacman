#!/usr/bin/env python3
# 掃描：對每個現行配方，查 URL 表父目錄的檔案列表，比 pkgver 找新版本。
# 輸出每行 "pkgname 新版本號"；--all 輸出全部現行配方（全量重建）
import json,os,re,sys,html
from urllib.request import urlopen, Request
from urllib.parse import urlparse
allf = "--all" in sys.argv
urls=json.load(open(os.path.join(os.path.dirname(__file__),"sources.urls.json")))
def vkey(v):
    out=[]
    for p in re.split(r'[.\-_]',v):
        out.append((0,int(p)) if p.isdigit() else (1,p))
    return out
for pkg in sorted(os.listdir("packages")):
    pb=f"packages/{pkg}/PKGBUILD"
    if not os.path.isfile(pb): continue
    t=open(pb,encoding="utf-8").read()
    if "OBSOLETE" in t: continue
    pv=re.search(r'^pkgver=(\S+)',t,re.M)
    if not pv: continue
    pv=pv.group(1)
    if allf:
        print(pkg); continue
    src=re.search(r'^source=\(([^)]*)\)',t,re.M|re.S)
    if not src: continue
    fn=re.findall(r'([\w.+-]+)\.(?:tar\.(?:xz|gz|bz2|zst)|zip)',src.group(1).replace("${pkgver}",pv).replace("$pkgver",pv))
    if not fn: continue
    # 取主來源檔（與包同名優先）
    main=next((f for f in fn if f.startswith(pkg[:4])),fn[0])
    u=urls.get(f"{main}.{src.group(1)[0:0]}") or urls.get(main+"") 
    # 表以完整檔名indexed:
    key=next((k for k in urls if k.startswith(main+"-") or k==main),None)
    if not key: continue
    base=urls[key].rsplit("/",1)[0]+"/"
    try:
        raw=urlopen(Request(base,headers={"User-Agent":"curl/8"}),timeout=25).read(400000).decode("utf-8","ignore")
    except Exception as e:
        print(f"# {pkg} 掃描失敗 {e}",file=sys.stderr); continue
    cands=[m for m in re.findall(re.escape(main)+r'-(\d[\w.]*)\.tar\.(?:xz|gz|bz2|zst)',html.unescape(raw))]
    if not cands: continue
    latest=sorted(set(cands),key=vkey)[-1]
    try: newer=vkey(latest)>vkey(pv)
    except TypeError: newer=False
    if newer:
        print(pkg,latest)
