[![lang-zh-hans](https://img.shields.io/badge/简体中文-AAAAAA?style=for-the-badge)](./README.zh-hans.md)
[![lang-zh-hant](https://img.shields.io/badge/繁體中文-AAAAAA?style=for-the-badge)](./README.zh-hant.md)
[![lang-en](https://img.shields.io/badge/English-AAAAAA?style=for-the-badge)](./README.md)
![lang-ja](https://img.shields.io/badge/日本語-555555?style=for-the-badge)


# dsh-termux-fix

[![License](https://img.shields.io/badge/License-MIT-A31F34?style=flat-square)](./LICENSE)
[![dsh](https://img.shields.io/badge/Made_by-dsh-4D6BFE?style=flat-square&logo=deepseek&logoColor=white)](https://www.deepseek.com/harness)
[![Website](https://img.shields.io/badge/Official_Website-555555?style=flat-square)](https://lamp23333.github.io/dshtermux)
[![Android](https://img.shields.io/badge/Powered_by-Android-3DDC84?style=flat-square&logo=android&logoColor=white)](https://developer.android.google.cn/about)

**ワンクリックパッチスクリプト** — [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) を Android 上の Termux 環境で正常に動作させるためのものです。

> [!NOTE]
> 注意：本プロジェクトは、Termux 上で動作するスクリプトのみを提供するものであり、DeepSeek Harness のプラグインではありません。

`気に入っていただけたら GitHub にスターをお願いします！`

## なぜ必要なのか

Android 端末で Termux を使って DeepSeek Harness をデプロイすると、さまざまな問題に直面します。

## クイックスタート

### 前提条件

- Android 端末 + [Termux](https://termux.dev/)
- 端末の空き容量が 1.5 GB 以上あること（`node-pty` と `flock` はその場でコンパイルします）。
- `pkg install` が遅い、または失敗する場合は、`termux-change-repo` でより近いミラーに切り替えられます。
- 初回インストールにはネットワーク接続（npm registry）が必要です。ダウンロードが遅い場合は `npm config set registry <ミラーURL>` でより速いミラーに切り替えることができます。設定が反映されたかは `npm config get registry` で確認できます。

### 1. パッチをダウンロードして取り込む

まず、Termux に curl と unzip がインストールされていることを確認してください。

```bash
pkg install -y curl unzip
```

**方法 1**：直接ダウンロードする

```bash
curl -O https://raw.githubusercontent.com/lamp23333/dsh-termux-fix/main/apply-dsh-patches.sh
```

**方法 2**：手動でダウンロードして Termux に取り込む

1. リポジトリの zip ファイルまたは `apply-dsh-patches.sh` を端末のストレージにダウンロードして、パッチファイルを取得します。
2. Termux でストレージへのアクセスを許可します。
```bash
termux-setup-storage
```
（実行するとアクセス許可を求めるダイアログが表示されるので、「許可」をタップします）

3. パッチファイルをホームディレクトリ（つまり `~`、すなわち `/data/data/com.termux/files/home`）に取り込みます。

- 単一ファイルをコピーして取り込む
```bash
cp /storage/emulated/0/[パッチのあるフォルダ]/apply-dsh-patches.sh ~/
```

または

- リポジトリの zip パッケージを展開して取り込む
```bash
cd ~
unzip /storage/emulated/0/[リポジトリの zip パッケージのあるフォルダ]/dsh-termux-fix-main.zip

# 展開後のファイルは ~/dsh-termux-fix-main/apply-dsh-patches.sh にあります

# Termux のホームディレクトリへ移動
cp ~/dsh-termux-fix-main/apply-dsh-patches.sh ~/
```

### 2. DeepSeek Harness をインストールする

> 初回インストールは、次のコマンドを実行するだけで完了します：
>
> ```bash
> bash ~/apply-dsh-patches.sh all
> ```

> 段階的に進めることもできます。
>
> まず、実行環境の依存パッケージと前提パッチ、DeepSeek Harness をインストールします：
> ```bash
> bash ~/apply-dsh-patches.sh install
> ```
> 次に、現在の状態を確認します：
> ```bash
> bash ~/apply-dsh-patches.sh status
> ```
> 「ステージ 2/3」と表示されることを確認してください。
>
> 最後に残りのパッチを適用します：
> ```bash
> bash ~/apply-dsh-patches.sh patch
> ```

### 3. DeepSeek Harness を起動する

```bash
cd ~/workspace   # 専用のディレクトリで起動することを推奨します
dsh web
```

### 4. DeepSeek Harness を更新する

更新方法はインストールと同じです。更新後は、パッチを再適用してください。

### 備考

パッチが `pkg install` でインストールするパッケージ：
```
実行時：node nodejs bash proot sed grep tar gzip diffutils findutils coreutils
ビルド時：clang make python pkg-config
```

## コマンド

引数を指定しない場合は、使い方の説明（`help`）を表示します。

| コマンド | 役割 |
| --- | --- |
| `status` | 環境の状態を表示 |
| `doctor` | 環境の状態について詳細なレポートを表示 |
| `patch` | パッチのみをインストール |
| `install` | DeepSeek Harness のみをインストール |
| `all` | DeepSeek Harness とパッチをインストール |
| `channels` | DeepSeek Harness の最新バージョンを確認 |
| `backup` | データをバックアップ（セッション、設定、パッチ成果物、ワークスペース） |
| `uninstall` | DeepSeek Harness とパッチをアンインストール |
| `help` | 使い方の説明を表示 |

## パッチの詳細

| # | ファイル / 変更 | 解決する問題 |
|---|-------------|---------------|
| 1 | `~/.gyp/include.gypi` | node-pty のコンパイル時に `android_ndk_path` が未定義でエラーになり、dsh がインストールできない |
| 2 | `~/.npmrc` | npm のデフォルトレジストリが遅い／失敗する（npmmirror に切り替え） |
| 3 | `~/.bashrc` | `dsh` コマンドが見つからない（PATH に `~/bin` を追加） |
| 4 | `~/dsh-link-fix.js` | f2fs ファイルシステムはハードリンクを禁止しているため、セッション保存時に `EACCES` が出る |
| 5 | `~/bin/dsh` | HMR プラグインがクラッシュする（`--expose-internals` が必要）。あわせて権限モード（`DSH_PERMISSION_MODE`、既定値は `danger-full-access`）を設定する |
| 6 | `~/bin/bwrap-proot` | サンドボックスバックエンドが存在しない（bwrap が使えないため proot に切り替え） |
| 7 | `~/.dsh/profiles/web/cordis.patch.yml` | サンドボックスの runnerCommand インジェクション |
| 8 | `dsh-subprocess-local`（動的検出） | ターミナルチェックがクラッシュする（プラットフォーム判定で Android が拒否される） |
| 9 | `dsh-terminal-bash`（動的検出） | PTY の起動に失敗する（shellPath のデフォルトが `/bin/bash`） |
| 10 | `node_modules/@img/sharp-wasm32` | sharp には android-arm64 用のネイティブバイナリがなく、起動時に読み込み失敗を報告する（attachment-local） |
| 11 | `dsh-client-connection`（動的検出） | `dsh web` がブラウザを自動で開いた後、authentication required で止まる |
| 12 | `node-addon-require-builtin`（JS フォールバック） | 公式に android-arm64 のネイティブ成果物がなく、dsh の起動時に `No usable native binding found` が出る |
| 13 | `@deepseek-ai/node-addon-system`（ローカルコンパイル） | `flock` に android-arm64 のプリビルド成果物がなく、Agent がターンごとに `flock is not supported on android-arm64` を報告する |
| 14 | `dsh-attachment-local`（動的検出） | 添付ディレクトリの fsync が権限の範囲を超えてしまい、画像を貼っただけで `prompt rejected (session/agent-busy)` が出る |

- 3、8、9、11、12、13、14 番目の項目は、DeepSeek Harness インストール後に適用するパッチです。インストール時に既存のファイルを変更するため、初回実行時に元のファイルを `.bak` としてバックアップします。

## スクリプトの特長
。
- **冪等**：何度でも実行でき、適用済みのパッチは自動でスキップされ、二重に変更されることはありません。
- **自動バックアップ**：パッケージレベルの変更は自動で `.bak` としてバックアップされ、ロールバックできます。
- **パッケージ分割耐性**：パッケージレベルのパッチは「コードの特徴的な文字列」で対象ファイルを特定し、`lib/index.js` を決め打ちしません。dsh はコードを `lib/runner-launch-<hash>.js` のようなハッシュ名のファイルに分割します（hash はリリースごとに変わります）ため、パスの決め打ちは必ず失敗します。
- **パッケージ未インストール時に誤検出しない**：該当するパッケージがインストールされていない場合は `[SKIP]` と出力し、失敗として数えません。
- **セルフチェック**：実行後に `[OK]/[FAIL]` の一覧を出力し、すべての項目が通って初めて成功とみなします（依存関係が欠けている項目は `[SKIP]` と表示され、カウントされません）。sed による変更はさらに grep で再確認し、期待どおりでなければ直ちに `[FAIL]` を報告します。
- **機密情報を扱わない**：API Key、セッション履歴、認証情報ファイルには一切触れません。
- **ネイティブ拡張のローカルコンパイル**：`flock` は Termux 上で `clang` を使ってその場でコンパイルします（`nodejs` パッケージに同梱される `node_api.h` だけで足ります）。node-gyp に依存せず、プリビルド成果物をネットワークからダウンロードする必要もありません。
- **パスの自動調整**：`PREFIX` / `HOME` は検証してから採用します（空でないこと、絶対パスであること、`.../com.termux/files/usr` の形であること、`$PREFIX/bin/bash` が実際に実行可能であること）。いずれかの条件を満たさない場合は公式のデフォルトパスにフォールバックします。生成される wrapper と `cordis.patch.yml` も実際のパスに合わせて注入されます。
- **Termux 外でも診断可能**：Termux の中で実行していない場合でも、`help` / `status` / `doctor` / `channels` は通常どおり使え、ファイル書き込み系のコマンドはエラーを出してすぐ終了します。

## 原理の概要

DSH は基本的に Linux デスクトップ向けに設計されており、Android 上では主に 6 種類の不適合があります：

1. **ファイルシステム**：f2fs + 暗号化パーティションは `link()` システムコールを禁止しているため、スクリプトは preload で `fs.link` をフックし、失敗時に `rename` へフォールバックします。
2. **サンドボックス**：公式の bwrap/Landlock バックエンドは Linux カーネルの機能に依存していますが、Android カーネルはそれを提供しません。スクリプトは proot でパスレベルの代替を行います（`runnerCommand` インジェクション）。
3. **パス**：`/bin/bash` や `/tmp` などの Linux 標準パスは Termux には存在しないため、スクリプトは一律に `$PREFIX` 下の実際のパスに変更します。マルチユーザー環境やデフォルト以外のインストール位置では `$PREFIX` は `/data/data/com.termux/files/usr` と等しくないため、スクリプトは `PREFIX` / `HOME` を検証してから採用し、検証に通らない場合のみデフォルト値にフォールバックします。
4. **ネイティブ依存**：sharp には android-arm64 向けの公式プリビルドバイナリがないため、スクリプトは同バージョンの WASM 版で代替します。
5. **ブラウザ認証**：`dsh web` がブラウザを自動で開くとき、`SameSite=Strict` の cookie は外部アプリからのナビゲーションでは送られないため、スクリプトは `Lax` に変更します。
6. **ネイティブ拡張**：dsh の一部機能は Node のネイティブアドオンに依存しており、公式はデスクトッププラットフォーム向けのプリビルド成果物しか公開していません。スクリプトは「ローカルでコンパイルできるか」で 2 つの道筋に分けます：
    - **コンパイルできるもの**（例：`node-addon-system` の `flock`。パッケージに `src/flock.c` が同梱）：`clang` でその場で `system.node` にコンパイルし、自作の android-arm64 プラットフォームパッケージに入れてプラットフォームガードを外します——本来のネイティブなセマンティクスが保たれ、カーネルレベルのファイルロックが利用できます。
    - **コンパイルできないもの**（例：`node-addon-require-builtin`。ソースコードは非公開）：`--expose-internals` + 純粋な JS 実装で代替します（得られるのは同一の Node 内部モジュールのインスタンスです）。

## バックアップと復元

バックアップ：
```bash
bash ~/apply-dsh-patches.sh backup --all
```

成果物は `~/dsh-backups/<YYYYmmdd-HHMMSS>/` にあります：

```
dsh-home.tar.gz    # ~/.dsh（セッション + Web UI 設定）
config.tar.gz      # .npmrc / .bashrc / .gyp / cordis.patch.yml
patches.tar.gz     # ~/bin/dsh / bwrap-proot / dsh-link-fix.js / dsh-flock-check.mjs
workspace.tar.gz   # ~/workspace
MANIFEST.txt       # 日時、バージョン、プラットフォーム、復元方法
```

復元：
```bash
tar xzf dsh-home.tar.gz -C ~
```

## トラブルシューティング

| 症状 | 対処 |
| --- | --- |
| `pkg install` が `Unable to locate package` を出す | `pkg update` を実行するか、`termux-change-repo` でリポジトリを変更してから再実行してください |
| `npm install` で止まる | `~/dsh-install-logs/install-*.log` を確認してください。ダウンロードが遅い場合は、より速いミラーに切り替えてください |
| `status` がずっとステージ 2 のまま | `[3]` の中でどの項目が MISS かを確認し、`patch` を単独で再実行して `[FAIL]` の説明を読んでください |
| ターミナルパネルが壊れた | `node-pty` のコンパイルに失敗しています。`pkg install clang make python` を実行してから `patch` を再実行してください |
| 画像を貼っても送信できない | 14 番目の項目が効いていません。`dsh-attachment-local/lib/index.js` に `dsh-android-sync-guard` があるか確認してください |
| 「Termux 実行環境が見つかりません」と出る | Termux 以外の場所でファイル書き込み系のコマンドを実行しています。`status` / `help` は引き続き使用できます |

## 本プロジェクトについて

- Android システムとの互換性のため、サンドボックスバックエンドに proot を使うのは**パスレベルの隔離**であり、本来のカーネル隔離ではありません。安全性は公式の bwrap/Landlock より低くなります。
- **自分の端末で信頼できるタスクを実行する**用途に向いています。出所の不明なコードの実行には使わないでください。
- 現時点で開発者は自分の端末でのみ実現可能性を検証しています。問題を見つけた場合は、専門家や AI に相談してください。問題を発見または解決したら、issue での報告を歓迎します。
- プロの開発者ではありません。このパッチを保守する意思のある方は、xingyunMC@outlook.com までご連絡ください。
- 本プロジェクトは DeepSeek 公式とは無関係であり、商用利用も行いません。
- 簡体字中国語版以外の README はすべて AI による翻訳です。表現が不正確だったり、用語が標準的でない箇所があるかもしれません。お気づきの点は issue でお知らせください。

## License

[MIT](./LICENSE)

## 備考
この README は DeepSeek が執筆しました。
