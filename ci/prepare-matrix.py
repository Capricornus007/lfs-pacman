#!/usr/bin/env python3
# feed-bot 專用：把 scan-updates.py 的輸出轉成 GitHub Actions 的 per-package matrix JSON。
#
# 用法：
#   ci/prepare-matrix.py                      # 排程：只列掃到上游新版本的配方
#   ci/prepare-matrix.py --all               # 全量：所有現行配方（force）
#   ci/prepare-matrix.py --only gcc,expect   # 驗證：只列指定配方，不碰網路
#
# 輸出（單行，供 $GITHUB_OUTPUT / fromJSON 使用）：
#   [{"index":1,"name":"acl","version":"","total":91}, ...]
import argparse
import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

ap = argparse.ArgumentParser()
ap.add_argument("--all", action="store_true", help="全量重建")
ap.add_argument("--only", default="", help="只建這些套件（逗號分隔）")
args = ap.parse_args()

if args.only:
    # 驗證用捷徑：不走 scan-updates.py，完全不需要網路。
    raw = [(n.strip(), "") for n in args.only.split(",") if n.strip()]
    raw.sort()
else:
    cmd = [sys.executable, os.path.join(ROOT, "ci", "scan-updates.py")]
    if args.all:
        cmd.append("--all")
    # scan-updates.py 用 os.listdir("packages")，工作目錄必須是倉庫根。
    done = subprocess.run(cmd, cwd=ROOT, text=True, capture_output=True)
    if done.stderr:
        print(done.stderr, file=sys.stderr, end="")
    done.check_returncode()
    raw = []
    for line in done.stdout.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        fields = line.split()
        # 一般掃描會輸出 "pkgname 新版本號"；--all 只輸出 pkgname。
        raw.append((fields[0], fields[1] if len(fields) > 1 else ""))

items = []
for name, version in raw:
    pdir = os.path.join(ROOT, "packages", name)
    if not os.path.isfile(os.path.join(pdir, "PKGBUILD")):
        print(f"略過（無 PKGBUILD）：{name}", file=sys.stderr)
        continue
    # scan-updates.py 只檢查 PKGBUILD 內文有沒有 "OBSOLETE" 字串；
    # 本專案真正的停用標記是 packages/<name>/OBSOLETE 檔案，這裡補過濾。
    if os.path.isfile(os.path.join(pdir, "OBSOLETE")):
        continue
    items.append({"index": 0, "name": name, "version": version, "total": 0})

total = len(items)
for i, item in enumerate(items, 1):
    item["index"] = i
    item["total"] = total

print(json.dumps(items, separators=(",", ":"), ensure_ascii=False))
if total == 0:
    print("沒有待建套件（matrix 為空）", file=sys.stderr)
