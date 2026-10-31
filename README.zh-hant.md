[![lang-zh-hans](https://img.shields.io/badge/简体中文-AAAAAA?style=for-the-badge)](./README.zh-hans.md)
![lang-zh-hant](https://img.shields.io/badge/繁體中文-555555?style=for-the-badge)
[![lang-en](https://img.shields.io/badge/English-AAAAAA?style=for-the-badge)](./README.md)
[![lang-ja](https://img.shields.io/badge/日本語-AAAAAA?style=for-the-badge)](./README.ja.md)

# dsh-termux-fix

[![License](https://img.shields.io/badge/License-MIT-A31F34?style=flat-square)](./LICENSE)
[![dsh](https://img.shields.io/badge/Made_by-dsh-4D6BFE?style=flat-square&logo=deepseek&logoColor=white)](https://www.deepseek.com/harness)
[![Website](https://img.shields.io/badge/Official_Website-555555?style=flat-square)](https://lamp23333.github.io/dshtermux)
[![Android](https://img.shields.io/badge/Powered_by-Android-3DDC84?style=flat-square&logo=android&logoColor=white)](https://developer.android.google.cn/about)

**一鍵補丁腳本**，讓 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 在 Android Termux 環境正常執行。

> [!NOTE]
> 注意：本專案開發的僅為可在 Termux 上執行的腳本檔案，不是 DeepSeek Harness 外掛。

`如果你喜歡這個專案，記得點個 Star 喵`

## 為什麼需要它

在 Android 裝置上使用 Termux 部署 DeepSeek Harness 會遇到一系列問題。

## 快速開始

### 前置條件

- Android 手機 + [Termux](https://termux.dev/)
- 裝置可用空間需大於 1.5 GB（`node-pty` 與 `flock` 要現場編譯）
- 若 `pkg install` 緩慢或失敗，可使用 `termux-change-repo` 更換至較近的鏡像源
- 首次安裝需連網（npm registry），若下載緩慢，可使用 `npm config set registry <鏡像網址>` 指定較快的鏡像，並以 `npm config get registry` 驗證是否更改成功。

### 1. 下載並匯入補丁

首先確認已在 Termux 中安裝 curl 和 unzip

```bash
pkg install -y curl unzip
```

**方式一**：直接下載

```bash
curl -O https://raw.githubusercontent.com/lamp23333/dsh-termux-fix/main/apply-dsh-patches.sh
```

**方式二**：手動下載匯入 Termux

1. 透過下載倉庫 zip 檔案或 `apply-dsh-patches.sh` 到手機儲存空間來取得補丁檔案
2. 在 Termux 授權存取儲存空間
```bash
termux-setup-storage
```
（執行後會出現權限授權彈窗，點「允許」）

3. 匯入補丁檔案到家目錄（也就是 `~`，即 `/data/data/com.termux/files/home`）

- 複製單一檔案匯入
```bash
cp /storage/emulated/0/[補丁所在資料夾]/apply-dsh-patches.sh ~/
```

或者

- 解壓縮倉庫 zip 包匯入
```bash
cd ~
unzip /storage/emulated/0/[倉庫 zip 包所在資料夾]/dsh-termux-fix-main.zip

# 解壓後檔案在 ~/dsh-termux-fix-main/apply-dsh-patches.sh

# 移動到 Termux 家目錄
cp ~/dsh-termux-fix-main/apply-dsh-patches.sh ~/
```

### 2. 安裝 DeepSeek Harness

> 首次安裝時，可使用一步到位的懶人指令：
>
> ```bash
> bash ~/apply-dsh-patches.sh all
> ```

> 也可以分段進行
>
> 先安裝環境依賴、前置補丁和 DeepSeek Harness：
> ```bash
> bash ~/apply-dsh-patches.sh install
> ```
> 接著看一下目前狀態：
> ```bash
> bash ~/apply-dsh-patches.sh status
> ```
> 確認為「階段 2/3」
>
> 最後補齊後續補丁：
> ```bash
> bash ~/apply-dsh-patches.sh patch
> ```

### 3. 啟動 DeepSeek Harness

```bash
cd ~/workspace   # 建議在專門目錄啟動
dsh web
```

### 4. 更新 DeepSeek Harness

更新方式與安裝同理，但別忘了再次安裝補丁固化喔～

### 備註

補丁中使用 pkg install 安裝的套件：
```
執行期：node nodejs bash proot sed grep tar gzip diffutils findutils coreutils
編譯期：clang make python pkg-config
```

## 指令

不帶參數 = 印出使用說明（`help`）。

| 指令 | 作用 |
| --- | --- |
| `status` | 顯示環境狀態 |
| `doctor` | 顯示環境狀態詳細報告 |
| `patch` | 僅安裝補丁 |
| `install` | 僅安裝 DeepSeek Harness |
| `all` | 安裝 DeepSeek Harness 與補丁 |
| `channels` | 查詢 DeepSeek Harness 最新版本 |
| `backup` | 備份資料（會話、設定、補丁產物、工作區） |
| `uninstall` | 解除安裝 DeepSeek Harness 與補丁 |
| `help` | 顯示使用說明 |

## 補丁明細

| # | 檔案 / 修改 | 解決的原始問題 |
|---|-------------|---------------|
| 1 | `~/.gyp/include.gypi` | node-pty 編譯報 `android_ndk_path` 未定義，dsh 裝不上 |
| 2 | `~/.npmrc` | npm 預設源下載慢/失敗（切 npmmirror） |
| 3 | `~/.bashrc` | `dsh` 指令找不到（PATH 補 `~/bin`） |
| 4 | `~/dsh-link-fix.js` | f2fs 檔案系統禁硬連結，會話儲存報 `EACCES` |
| 5 | `~/bin/dsh` | HMR 外掛崩潰（需 `--expose-internals`）+ 權限模式 |
| 6 | `~/bin/bwrap-proot` | 沙箱後端缺失（bwrap 不可用，轉 proot） |
| 7 | `~/.dsh/profiles/web/cordis.patch.yml` | 沙箱 runnerCommand 注入 |
| 8 | `dsh-subprocess-local`（動態定位） | 終端機檢查崩潰（平台偵測拒絕 Android） |
| 9 | `dsh-terminal-bash`（動態定位） | PTY 啟動失敗（shellPath 預設 `/bin/bash`） |
| 10 | `node_modules/@img/sharp-wasm32` | sharp 無 android-arm64 原生二進位檔，啟動報載入失敗（attachment-local） |
| 11 | `dsh-client-connection`（動態定位） | `dsh web` 自動開啟瀏覽器後停在 authentication required |
| 12 | `node-addon-require-builtin`（JS 後備方案） | 官方無 android-arm64 原生產物，dsh 啟動報 `No usable native binding found` |
| 13 | `@deepseek-ai/node-addon-system`（本機編譯） | `flock` 無 android-arm64 預編譯產物，Agent 每輪執行報 `flock is not supported on android-arm64` |
| 14 | `dsh-attachment-local`（動態定位） | 附件目錄 fsync 越權，一貼圖就報 `prompt rejected (session/agent-busy)` |

- 第 3、8、9、11、12、13、14 項為 DeepSeek Harness 安裝後補丁，安裝時會改到既有檔案，首次執行把原件備份成 `.bak`。

## 腳本特性

- **冪等**：可重複執行，已打補丁自動跳過，不會重複改
- **自動備份**：套件級修改自動備份 `.bak`，可回滾
- **抗拆包**：套件級補丁按「程式碼特徵字串」定位目標檔案，不寫死 `lib/index.js`。dsh 會把程式碼拆進 `lib/runner-launch-<hash>.js` 這類雜湊命名檔案（hash 每次發版都變），寫死路徑必然失效
- **套件缺失不誤報**：對應套件未安裝時輸出 `[SKIP]`，不計入失敗項
- **自我檢查**：跑完輸出 `[OK]/[FAIL]` 清單，所有項全部通過才算成功（依賴缺失的項顯示 `[SKIP]` 且不計入）；sed 類修改會再 grep 複核，不符預期直接報 `[FAIL]`
- **不含敏感資訊**：不碰 API Key、會話歷史、憑證檔案
- **本機編譯原生擴充**：`flock` 在 Termux 現場用 `clang` 編譯（只需隨 `nodejs` 套件提供的 `node_api.h`），不依賴 node-gyp，也不需要連網下載預編譯產物
- **路徑自我適應**：`PREFIX` / `HOME` 先驗證再採用（非空、絕對路徑、形如 `.../com.termux/files/usr`、`$PREFIX/bin/bash` 真實可執行），任一不滿足就回退官方預設路徑；生成的 wrapper 與 `cordis.patch.yml` 也按實際路徑注入
- **非 Termux 可診斷**：不在 Termux 裡跑時，`help` / `status` / `doctor` / `channels` 照常可用，寫檔案類指令會直接報錯退出

## 原理簡述

DSH 底層為 Linux 桌面設計，在 Android 上主要有六類水土不服：

1. **檔案系統**：f2fs + 加密分區禁 `link()` 系統呼叫，腳本用 preload 劫持 `fs.link` 在失敗時 fallback 到 `rename`
2. **沙箱**：官方 bwrap/Landlock 後端依賴 Linux 核心能力，Android 核心不提供，腳本用 proot 做路徑級替代（`runnerCommand` 注入）
3. **路徑**：`/bin/bash`、`/tmp` 等 Linux 標準路徑在 Termux 不存在，腳本統一改到 `$PREFIX` 真實路徑；多使用者或非預設安裝位置下 `$PREFIX` 並不等於 `/data/data/com.termux/files/usr`，所以腳本先驗證 `PREFIX` / `HOME` 再採用，驗證不過才回退預設值
4. **原生依賴**：sharp 在 android-arm64 沒有官方預編譯二進位檔，腳本改用同版本 WASM 版替代
5. **瀏覽器認證**：`dsh web` 自動開啟瀏覽器時，`SameSite=Strict` 的 cookie 不被外部應用程式導覽攜帶，腳本改為 `Lax`
6. **原生擴充**：dsh 部分能力依賴 Node 原生 addon，官方只發布桌面平台預編譯產物。腳本按「能否本機編譯」分兩條路：
    - **可編譯的**（如 `node-addon-system` 的 `flock`，套件內自帶 `src/flock.c`）：用 `clang` 現場編譯成 `system.node`，放入自建的 android-arm64 平台套件並放開平台守衛——保留真原生語意，核心級檔案鎖可用
    - **不可編譯的**（如 `node-addon-require-builtin`，原始碼未公開）：用 `--expose-internals` + 純 JS 實作替代（拿到的是同一批 Node 內部模組實例）

## 備份與還原

備份：
```bash
bash ~/apply-dsh-patches.sh backup --all
```

產物在 `~/dsh-backups/<YYYYmmdd-HHMMSS>/`：

```
dsh-home.tar.gz    # ~/.dsh（會話 + 網頁端設定）
config.tar.gz      # .npmrc / .bashrc / .gyp / cordis.patch.yml
patches.tar.gz     # ~/bin/dsh / bwrap-proot / dsh-link-fix.js / dsh-flock-check.mjs
workspace.tar.gz   # ~/workspace
MANIFEST.txt       # 時間、版本、平台、還原方式
```

還原：
```bash
tar xzf dsh-home.tar.gz -C ~
```

## 部分問題排查

| 現象 | 處理 |
| --- | --- |
| `pkg install` 報 `Unable to locate package` | `pkg update` 或 `termux-change-repo` 換源後重跑 |
| 卡在 `npm install` | 看 `~/dsh-install-logs/install-*.log`；若下載緩慢，建議改用較快的鏡像 |
| `status` 一直是階段 2 | 看 `[3]` 裡哪幾項 MISS，單獨重跑 `patch` 並讀 `[FAIL]` 說明 |
| 終端機面板壞了 | `node-pty` 沒編譯成功，`pkg install clang make python` 後重跑 `patch` |
| 貼圖發不出去 | 第 14 項沒生效，檢查 `dsh-attachment-local/lib/index.js` 裡是否有 `dsh-android-sync-guard` |
| 報「找不到 Termux 執行環境」 | 你在非 Termux 裡跑了寫檔案類指令；`status` / `help` 仍然可用 |

## 聲明

- 為了相容 Android 系統，沙箱後端用 proot 是**路徑級隔離**，不是真正的核心隔離，安全性低於官方 bwrap/Landlock
- 適合在**自己的裝置上跑可信任務**，不要用它執行來歷不明的程式碼
- 目前開發者僅在自己的裝置上驗證了可行性，如發現問題，可以向專業人士和人工智慧求助，問題發現或解決後歡迎各位在 issue 中提出
- 本人不是專業的開發者，有意要維護此補丁的，請透過 xingyunMC@outlook.com 和我聯絡
- 本專案與 DeepSeek 官方無關，且不用於任何商業活動

## License

[MIT](./LICENSE)

## 備註
此 README 檔案由 DeepSeek 撰寫
