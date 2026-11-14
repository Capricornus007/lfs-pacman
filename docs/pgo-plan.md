# MLFS 套件 PGO / AutoFDO / BOLT 最佳化計畫

> 疊在 feed-bot #16（`-O3` + LTO + 激進旗標）之上的下一階。
> 目標：新系統的 feed 包。工具鏈一律裝在 **CI 構建容器**，不裝到使用者本機（Artix）桌面。
>
> **狀態（2026-11-15）**：§3 兩段式 PGO 已於 v2.26 落地——用戶定案**全量 100 包、
> 無白名單**（gcc／glibc 在內），實作在 `ci/build-recipe.sh`（pass1 插樁 →
> `ci/pgo-train.sh` 限時訓練 → pass2 套用）。§4 AutoFDO／BOLT 依用戶定案為
> 「新系統起來後的**雲端**疊加」：本機僅 perf 錄製＋上傳 perf.data，
> **編譯全在 GitHub Actions，不在本機**。

## 1. 三種技術與工具歸屬

| 技術 | 做什麼 | 關鍵工具 | 裝在哪 |
|---|---|---|---|
| GCC 兩段式 PGO | 照訓練集重排熱點、內聯 | `gcov` / `gcov-tool`（GCC 內建） | CI 容器，零額外安裝 |
| AutoFDO | 用真機 `perf` 取樣當訓練集 | `create_gcov`（`autofdo-git`） | CI 容器：裝 `autofdo-git`（AUR）；容器內一併提供 `llvm11` 滿足其依賴（或對當前 LLVM 自編 autofdo） |
| BOLT | 連結後基本塊重排 | `llvm-bolt` | CI 容器：`pacman -S llvm-bolt` |

## 2. 為什麼 autofdo 在本機缺 llvm11「不算卡住」

- autofdo 本就**不該裝在本機**。它是給 CI 容器編新系統包用的。
- CI 容器要拿它有三条路，任意一條都通：
  1. 容器內對齊當前 LLVM（23.x）自編 autofdo；
  2. 容器內用 `autofdo-git` 並臨時降 LLVM 版本；
  3. 先跳過 AutoFDO，走 GCC PGO + BOLT 兩條已通的路，AutoFDO 留到真機取樣階段再接。
- 本機官方 repo 有沒有 llvm11，與新系統完全無關。

## 3. 實施（先導：GCC 兩段式 PGO）

白名單包：`zstd`、`openssl`、`python`、`gcc`、`glibc`（熱點、且 `make check` 可作訓練）。

feed-bot 對白名單包做兩段構建：

1. **第一段（產生 profile）**
   - `makepkg` 注入 `CFLAGS+=" -fprofile-generate"`（LTO 時用 `-fprofile-generate -flto=auto`）。
   - 編出包並於 `check()` 跑 `make check`（或代表性 workload）→ 跑出 `.gcda`。
   - 收斂 `.gcda` 到 `$srcdir/../pgo-data/` 並清掉，供第二段用。
2. **第二段（套用 profile）**
   - `CFLAGS+=" -fprofile-use -fprofile-dir=$srcdir/../pgo-data"` 重編 → 最終包。

需改：`ci/build-recipe.sh`（加兩段邏輯與白名單）、`packages/*/PKGBUILD` 的 `options()`（確保 `!lto` 不在第一段擋、`check()` 存在且會跑）。

## 4. AutoFDO / BOLT 的訓練資料來源（新系統裝好後）

- **AutoFDO**：真機 `perf record -e cycles:u -j any,u -a -- sleep 60`（或跑日常負載）→ `create_gcov perf.data profile.prof` → 上傳 CI → 包構建加 `-fauto-profile=profile.prof`。
- **BOLT**：同上 `perf` 取樣 → `llvm-bolt --perfdata=perf.data --reorder-blocks=ext-tsp 二進位 -o 二進位.bolt`。

## 5. 時程

1. #16 全綠 → `repo-add` 發 feed（當前進行中，74/91 綠）。
2. 本計畫合入 feed-bot：GCC PGO 先導（CI 容器加 gcov 即可，無額外依賴）。
3. 新系統裝好 → 真機取樣 → AutoFDO / BOLT 疊加。

## 6. 風險

- PGO 訓練集若不代表真實負載，可能對特定路徑反優化；先用 `make check`（包自帶測試）當保守訓練。
- AutoFDO 的 `create_gcov` 依賴較舊 LLVM，容器內需鎖版本或自編；若麻煩，先不上。
- BOLT 對少數手寫彙編或 CFI 敏感的二進位可能崩，需白名單排除。
