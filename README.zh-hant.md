[![lang-zh-hans](https://img.shields.io/badge/简体中文-AAAAAA?style=for-the-badge)](./README.zh-hans.md)
![lang-zh-hant](https://img.shields.io/badge/繁體中文-555555?style=for-the-badge)
[![lang-en](https://img.shields.io/badge/English-AAAAAA?style=for-the-badge)](./README.md)
[![lang-ja](https://img.shields.io/badge/日本語-AAAAAA?style=for-the-badge)](./README.ja.md)

# dsh-termux-fix

[![License](https://img.shields.io/badge/License-MIT-A31F34?style=flat-square)](./LICENSE)
[![dsh](https://img.shields.io/badge/Made_by-dsh-4D6BFE?style=flat-square&logo=deepseek&logoColor=white)](https://www.deepseek.com/harness)
[![Website](https://img.shields.io/badge/Official_Website-555555?style=flat-square)](https://lamp23333.github.io/dshtermux)
[![Android](https://img.shields.io/badge/Powered_by-Android-3DDC84?style=flat-square&logo=android&logoColor=white)](https://developer.android.google.cn/about)

**一鍵修補腳本**，讓 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 在 Android 的 Termux 環境中正常執行。

> [!NOTE]
> 注意：本專案僅提供可在 Termux 上執行的腳本，並非 DeepSeek Harness 外掛。

`如果你喜歡這個專案，歡迎給個 Star！`

## 為什麼需要它

在 Android 裝置上使用 Termux 部署 DeepSeek Harness 會遇到一系列問題。

## 快速開始

### 前置條件

- Android 手機 + [Termux](https://termux.dev/)。
- 裝置可用空間建議預留 1.5 GB 以上（`node-pty` 與 `flock` 需在本機編譯；空間不足僅會警告，不會中止）。
- 若 `pkg install` 緩慢或失敗，可使用 `termux-change-repo` 更換為較近的鏡像站。
- 首次安裝需連上網路（npm registry）。若下載緩慢，可用 `npm config set registry <鏡像網址>` 指定較快的鏡像站，再以 `npm config get registry` 確認是否設定成功。

### 1. 下載並匯入修補程式

首先確認已在 Termux 中安裝 curl 和 unzip。

```bash
pkg install -y curl unzip
```

**方式一**：直接下載

```bash
curl -O https://raw.githubusercontent.com/lamp23333/dsh-termux-fix/main/apply-dsh-patches.sh
```

**方式二**：手動下載匯入 Termux

1. 將儲存庫的 zip 檔或 `apply-dsh-patches.sh` 下載到手機儲存空間，取得修補檔案。
2. 在 Termux 中授予儲存空間存取權。
```bash
termux-setup-storage
```
（執行後會出現權限授權對話框，請點「允許」）

3. 將修補檔案放進家目錄（即 `~`，或 `/data/data/com.termux/files/home`）。

- 複製單一檔案：
```bash
cp /storage/emulated/0/[修補程式所在資料夾]/apply-dsh-patches.sh ~/
```

或者

- 解壓縮儲存庫壓縮檔
```bash
cd ~
unzip /storage/emulated/0/[儲存庫壓縮檔所在資料夾]/dsh-termux-fix-main.zip

# 解壓後檔案在 ~/dsh-termux-fix-main/apply-dsh-patches.sh

# 移動到 Termux Home 目錄
cp ~/dsh-termux-fix-main/apply-dsh-patches.sh ~/
```

### 2. 安裝 DeepSeek Harness

> 首次安裝時，可用下列指令一次完成：
>
> ```bash
> bash ~/apply-dsh-patches.sh all
> ```

> 也可以分段進行。
>
> 先安裝環境相依套件、前置修補程式與 DeepSeek Harness：
> ```bash
> bash ~/apply-dsh-patches.sh install
> ```
> 接著確認目前狀態：
> ```bash
> bash ~/apply-dsh-patches.sh status
> ```
> 確認顯示為「階段 2/3」。
>
> 最後補齊後續修補程式：
> ```bash
> bash ~/apply-dsh-patches.sh patch
> ```

### 3. 啟動 DeepSeek Harness

```bash
cd ~/workspace   # 建議在專用目錄中啟動
dsh web
```

### 4. 更新 DeepSeek Harness

更新方式與安裝相同，但更新後需重新套用修補程式。

### 備註

修補程式會透過 `pkg install` 安裝的套件：
```
執行時：node nodejs bash proot sed grep tar gzip diffutils findutils coreutils
編譯時：clang make python pkg-config（缺少 `ld` 時另會補裝 binutils）
```

## 指令

不帶參數時，會印出使用說明（`help`）。

| 指令 | 作用 |
| --- | --- |
| `status` | 顯示環境狀態 |
| `doctor` | 顯示環境狀態的詳細報告 |
| `patch` | 僅安裝修補程式 |
| `install` | 僅安裝 DeepSeek Harness |
| `all` | 安裝 DeepSeek Harness 與修補程式 |
| `channels` | 查詢 DeepSeek Harness 最新版本 |
| `backup` | 備份資料（工作階段、設定、修補程式產物、工作區） |
| `uninstall` | 解除安裝 DeepSeek Harness 與修補程式 |
| `help` | 顯示使用說明 |

## 修補程式明細

| # | 檔案 / 修改 | 解決的原始問題 |
|---|-------------|---------------|
| 1 | `~/.gyp/include.gypi` | node-pty 編譯時因 `android_ndk_path` 未定義而失敗，導致 dsh 無法安裝 |
| 2 | `~/.npmrc` | npm 預設 registry 下載緩慢或失敗（改為 npmmirror） |
| 3 | `~/.bashrc` | 找不到 `dsh` 指令（在 PATH 加入 `~/bin`） |
| 4 | `~/dsh-link-fix.js` | f2fs 檔案系統禁止硬連結，儲存工作階段時出現 `EACCES` |
| 5 | `~/bin/dsh` | HMR 外掛崩潰（需 `--expose-internals`），另設定權限模式（`DSH_PERMISSION_MODE`，預設 `danger-full-access`） |
| 6 | `~/bin/bwrap-proot` | 沙箱後端缺失（bwrap 不可用，改用 proot） |
| 7 | `~/.dsh/profiles/web/cordis.patch.yml` | 沙箱 runnerCommand 注入 |
| 8 | `dsh-subprocess-local`（動態定位） | 終端機檢查失敗（平台偵測不接受 Android） |
| 9 | `dsh-terminal-bash`（動態定位） | PTY 啟動失敗（shellPath 預設 `/bin/bash`） |
| 10 | `node_modules/@img/sharp-wasm32` | sharp 無 android-arm64 原生二進位檔，啟動時回報載入失敗（attachment-local） |
| 11 | `dsh-client-connection`（動態定位） | `dsh web` 自動開啟瀏覽器後停在 authentication required 步驟 |
| 12 | `node-addon-require-builtin`（JS 備援方案） | 官方未提供 android-arm64 原生建置產物，dsh 啟動報 `No usable native binding found` |
| 13 | `@deepseek-ai/node-addon-system`（本機編譯） | `flock` 無 android-arm64 預先編譯的產物，Agent 每一輪都會回報 `flock is not supported on android-arm64` |
| 14 | `dsh-attachment-local`（動態定位） | 附件目錄的 fsync 超出權限範圍，一貼圖就會出現 `prompt rejected (session/agent-busy)` |
| 15 | `dsh-attachment-local`（動態定位） | Android 的 f2fs 不允許硬連結，儲存附件時 `link()` 回報 `EACCES`，一貼圖就出現 `Unable to persist attachment.` |

- 第 3、8、9、11、12、13、14、15 項為 DeepSeek Harness 安裝後修補程式，安裝時會修改既有檔案，首次執行把原件備份成 `.bak`。

## 腳本特性

- **冪等**：可重複執行，已打修補程式自動跳過，不會重複修改。
- **自動備份**：套件級修改會自動備份為 `.bak`，可回滾。
- **不受程式碼拆分影響**：套件級修補程式按「程式碼特徵字串」定位目標檔案，不寫死 `lib/index.js`。dsh 會把程式碼拆進 `lib/runner-launch-<hash>.js` 這類雜湊命名檔案（hash 每次發版都變），寫死路徑必然失效。
- **套件缺失不誤報**：對應套件未安裝時輸出 `[SKIP]`，不計入失敗項。
- **自我檢查**：執行完畢後輸出 `[OK]/[FAIL]` 清單，所有項全部通過才算成功（依賴缺失的項顯示 `[SKIP]` 且不計入）；sed 類修改會再以 grep 複查，不符預期直接回報 `[FAIL]`。
- **不含敏感資訊**：不會碰觸 API Key、工作階段歷史或憑證檔案。
- **本機編譯原生擴充**：`flock` 直接在 Termux 上用 `clang` 編譯（只需 `nodejs` 套件內附的 `node_api.h`），不依賴 node-gyp，也不需要連線下載預編譯產物。
- **路徑自動調整**：`PREFIX` / `HOME` 先驗證再採用（非空、絕對路徑、形如 `.../com.termux/files/usr`、`$PREFIX/bin/bash` 真實可執行），任一不滿足就回退官方預設路徑；產生的 wrapper 與 `cordis.patch.yml` 也按實際路徑注入。
- **非 Termux 可診斷**：不在 Termux 中執行時，`help` / `status` / `doctor` / `channels` 照常可用，寫入檔案類指令會直接報錯退出。

## 原理簡述

DSH 底層為 Linux 桌面設計，在 Android 上主要有六類水土不服：

1. **檔案系統**：Android 的 f2fs 會拒絕 `link()`（回傳 `EACCES`），而儲存附件的主要路徑正是「暫存檔案 --link--> 正式檔案」。腳本分兩層處理：以 preload 攔截 `fs.link` / `fs.promises.link`，為 CJS 呼叫點提供備援（失敗時退回 `rename`）；對 `dsh-attachment-local` 則直接把兩處 `link()` 換成 `linkOrCopy()`，硬連結失敗時改用 `copyFile` 複製（第 15 項）——ESM 的 `import { link }` 取得的是內建模組的原函式，preload 攔截不到。
2. **沙箱**：官方 bwrap/Landlock 後端依賴 Linux 核心能力，Android 核心不提供，腳本用 proot 做路徑級替代（`runnerCommand` 注入）。
3. **路徑**：`/bin/bash`、`/tmp` 等 Linux 標準路徑在 Termux 不存在，腳本統一改到 `$PREFIX` 真實路徑；多使用者或非預設安裝位置下 `$PREFIX` 並不等於 `/data/data/com.termux/files/usr`，所以腳本先驗證 `PREFIX` / `HOME` 再採用，驗證不過才回退預設值。
4. **原生依賴**：sharp 在 android-arm64 沒有官方預編譯二進位檔，腳本改用同版本的 WASM 版本代替。
5. **瀏覽器認證**：`dsh web` 自動開啟瀏覽器時，`SameSite=Strict` 的 cookie 不被外部應用程式導覽攜帶，腳本改為 `Lax`。
6. **原生擴充**：dsh 部分能力依賴 Node 原生 addon，官方只發布桌面平台預編譯產物。腳本按「能否本機編譯」分兩條路：
    - **可編譯的**（如 `node-addon-system` 的 `flock`，套件內自帶 `src/flock.c`）：用 `clang` 直接編譯成 `system.node`，放入自建的 android-arm64 平台套件並繞過平台檢查——保留真正的原生語意，核心級檔案鎖可用。
    - **不可編譯的**（如 `node-addon-require-builtin`，原始碼未公開）：用 `--expose-internals` + 純 JS 實作替代（取得的是同一組 Node 內部模組實例）。

## 備份與還原

備份：
```bash
bash ~/apply-dsh-patches.sh backup --all
```

備份產物位於 `~/dsh-backups/<YYYYmmdd-HHMMSS>/`：

```
dsh-home.tar.gz    # ~/.dsh（工作階段 + 網頁介面設定）
config.tar.gz      # .npmrc / .bashrc / .gyp / cordis.patch.yml
patches.tar.gz     # ~/bin/dsh / bwrap-proot / dsh-link-fix.js / dsh-flock-check.mjs
workspace.tar.gz   # ~/workspace
MANIFEST.txt       # 時間、版本、平台、還原方式
```

還原：
```bash
tar xzf dsh-home.tar.gz -C ~
```

## 部分問題排解

| 現象 | 處理 |
| --- | --- |
| `pkg install` 報 `Unable to locate package` | `pkg update` 或 `termux-change-repo` 更換鏡像站後重新執行 |
| 卡在 `npm install` | 查看 `~/dsh-install-logs/install-*.log`；若下載緩慢，建議改用較快的鏡像站 |
| `status` 一直是階段 2 | 查看 `[3]` 中哪幾項為 MISS，單獨重新執行 `patch`，並閱讀 `[FAIL]` 說明 |
| 終端機面板壞了 | `node-pty` 未編譯成功，`pkg install clang make python` 後重新執行 `patch` |
| 貼圖後出現 `prompt rejected (session/agent-busy)` | 第 14 項未生效，檢查 `dsh-attachment-local/lib/index.js` 裡是否有 `dsh-android-sync-guard` |
| 貼圖後出現 `Unable to persist attachment.` | 第 15 項未生效，檢查同一檔案裡是否有 `dsh-android-link-guard` |
| 報「找不到 Termux 執行環境」 | 你在 Termux 以外的環境執行了寫入檔案類指令；`status` / `help` 仍然可用 |

## 關於本專案

- 為了相容 Android 系統，沙箱後端用 proot 是**路徑級隔離**，不是真正的核心隔離，安全性低於官方 bwrap/Landlock。
- 適合在**自己的裝置上跑可信任務**，不要用它執行來歷不明的程式碼。
- 目前開發者僅在自己的裝置上驗證了可行性，如發現問題，可以向專業人士和人工智慧求助，若發現或解決了問題，歡迎在 issue 中提出。
- 本人不是專業的開發者，有意維護此修補程式者，請透過 xingyunMC@outlook.com 與我聯絡。
- 本專案與 DeepSeek 官方無關，亦不用於任何商業用途。
- 除簡體中文以外的 README 檔案均使用 AI 翻譯，可能出現表述不準確、含義不標準等問題，歡迎在 issue 中指出。

## License

[MIT](./LICENSE)

## 備註
此 README 檔案由 DeepSeek 撰寫。
