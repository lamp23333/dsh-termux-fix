[![lang-zh-hans](https://img.shields.io/badge/简体中文-AAAAAA?style=for-the-badge)](./README.zh-hans.md)
[![lang-zh-hant](https://img.shields.io/badge/繁體中文-AAAAAA?style=for-the-badge)](./README.zh-hant.md)
![lang-en](https://img.shields.io/badge/English-555555?style=for-the-badge)
[![lang-ja](https://img.shields.io/badge/日本語-AAAAAA?style=for-the-badge)](./README.ja.md)

# dsh-termux-fix

[![License](https://img.shields.io/badge/License-MIT-A31F34?style=flat-square)](./LICENSE)
[![dsh](https://img.shields.io/badge/Made_by-dsh-4D6BFE?style=flat-square&logo=deepseek&logoColor=white)](https://www.deepseek.com/harness)
[![Website](https://img.shields.io/badge/Official_Website-555555?style=flat-square)](https://lamp23333.github.io/dshtermux)
[![Android](https://img.shields.io/badge/Powered_by-Android-3DDC84?style=flat-square&logo=android&logoColor=white)](https://developer.android.google.cn/about)

**A one-click patch script** that gets [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) running properly in Termux on Android.

> [!NOTE]
> This project only provides scripts that run on Termux; it is not a DeepSeek Harness plugin.

`If you like this project, a star would be appreciated! `

## Why it is needed

Deploying DeepSeek Harness with Termux on an Android device runs into a whole series of problems.

## Quick start

### Prerequisites

- An Android phone + [Termux](https://termux.dev/).
- 1.5 GB or more of free space is recommended on the device (`node-pty` and `flock` have to be built on the device; if space runs short it only warns, it does not abort).
- If `pkg install` is slow or fails, you can switch to a closer mirror with `termux-change-repo`.
- The first installation requires network access (npm registry). If it is slow, you can point npm at a faster mirror with `npm config set registry <mirror-url>`, and check the result with `npm config get registry`.

### 1. Download and import the patch

First make sure curl and unzip are installed in Termux.

```bash
pkg install -y curl unzip
```

**Option 1**: Download directly

```bash
curl -O https://raw.githubusercontent.com/lamp23333/dsh-termux-fix/main/apply-dsh-patches.sh
```

**Option 2**: Download manually and import into Termux

1. Get the patch file by downloading the repository zip or `apply-dsh-patches.sh` to your phone's storage.
2. Grant storage access in Termux.
```bash
termux-setup-storage
```
(a permission dialog will pop up after running it; tap "Allow")

3. Import the patch file into your home directory (`~`, or `/data/data/com.termux/files/home`).

- Copy a single file:
```bash
cp /storage/emulated/0/[folder containing the patch]/apply-dsh-patches.sh ~/
```

or

- Unzip the repository archive:
```bash
cd ~
unzip /storage/emulated/0/[folder containing the repository zip]/dsh-termux-fix-main.zip

# After unzipping, the file is at ~/dsh-termux-fix-main/apply-dsh-patches.sh

# Move it into the Termux home directory
cp ~/dsh-termux-fix-main/apply-dsh-patches.sh ~/
```

### 2. Install DeepSeek Harness

> For a first install, this single command does everything:
>
> ```bash
> bash ~/apply-dsh-patches.sh all
> ```

> You can also do it in stages.
>
> First install the system dependencies, the prerequisite patch and DeepSeek Harness:
> ```bash
> bash ~/apply-dsh-patches.sh install
> ```
> Then take a look at the current status:
> ```bash
> bash ~/apply-dsh-patches.sh status
> ```
> and confirm it says "stage 2/3".
>
> Finally, apply the remaining patches:
> ```bash
> bash ~/apply-dsh-patches.sh patch
> ```

### 3. Start DeepSeek Harness

```bash
cd ~/workspace   # It is recommended to start it in a dedicated directory
dsh web
```

### 4. Update DeepSeek Harness

Updating works the same way as installing, but the patches have to be re-applied afterwards.

### Remarks

Packages that the patch installs via `pkg install`:
```
At runtime: node nodejs bash proot sed grep tar gzip diffutils findutils coreutils
At build time: clang make python pkg-config (adds binutils automatically if `ld` is missing)
```

## Backup and restore

> [!IMPORTANT]
> This section covers **full data backup**. Snapshots created by patching are kept separately under `~/dsh-patch-backups/` and rolled back with the `restore` command.

> What follows is a simplified backup procedure; for all backup options, see `help` or `backup --list`.

### 1. Back up

```bash
bash ~/apply-dsh-patches.sh backup --all
```

The artifacts land in `~/dsh-backups/[YYYYmmdd-HHMMSS]/` and include:
```
sessions.tar.gz    # sessions and attachments
settings.tar.gz    # settings and identity (includes .credentials.yaml)
patches.tar.gz     # patch artifacts
workspace.tar.gz   # workspace
plugins.tar.gz     # plugin dependencies and plugin state
MANIFEST.txt       # time, version, data root, scope, restore method
```

### 2. Restore

- Restore a single file:
```bash
tar -xzf ~/dsh-backups/[YYYYmmdd-HHMMSS]/<name>.tar.gz -C /
```

- Restore everything:
```bash
for f in ~/dsh-backups/[YYYYmmdd-HHMMSS]/*.tar.gz; do tar -xzf "$f" -C /; done
```

Replace the text in angle brackets with your own values.

> [!WARNING]
> `settings.tar.gz` contains private information such as login credentials; never share it with anyone!

## Uninstall

> What follows is a simplified uninstall procedure; for all uninstall options, see `help` or `uninstall --list`.

### 1. Review the deletion scopes first (nothing is deleted)

```bash
bash ~/apply-dsh-patches.sh uninstall
```

### 2. Run the uninstall

Pick the scopes to remove by the number they are listed under.

- A single number:
```bash
bash ~/apply-dsh-patches.sh uninstall 2
```

- Several numbers:
```bash
bash ~/apply-dsh-patches.sh uninstall 1 3
```

- Or wipe all DeepSeek Harness and patch data:
```bash
bash ~/apply-dsh-patches.sh uninstall --all
```

> [!WARNING]
> Data is priceless — uninstall with care!

### Remarks

The uninstaller leaves these untouched: `pkg` dependencies such as `node` / `npm` / `pnpm`, the npm caches (`~/.npm/_cacache`, `~/.local/share/pnpm/store`), `~/.agents`, `~/node_modules`, `~/workspace`, `~/package.json`, and the backup and cache directories (`~/dsh-backups`, `~/dsh-patch-backups`, `~/sharp-wasm`, `~/dsh-install-logs`). Delete them yourself if you need to.

## Commands

With no arguments, it prints the usage instructions (`help`).

| Command | Purpose |
| --- | --- |
| `status` | Show the environment status |
| `doctor` | Show a detailed environment status report |
| `patch` | Install patches only |
| `install` | Install DeepSeek Harness only |
| `all` | Install DeepSeek Harness and the patches |
| `channels` | Check the latest DeepSeek Harness version |
| `backup` | Back up data |
| `restore` | Roll back to a patch snapshot |
| `uninstall` | Uninstall DeepSeek Harness and the patches |
| `help` | Show the usage instructions |

## Patch details

| # | File / change | Original problem it solves |
|---|-------------|---------------|
| 1 | `~/.gyp/include.gypi` | node-pty fails to compile with `android_ndk_path` undefined, so dsh cannot be installed |
| 2 | `~/.npmrc` | The default npm registry downloads slowly/fails (switch to npmmirror) |
| 3 | `~/.bashrc` | The `dsh` command is not found (add `~/bin` to PATH) |
| 4 | `~/dsh-link-fix.js` | The f2fs file system forbids hard links, so saving a session fails with `EACCES` |
| 5 | `~/bin/dsh` | The HMR plugin crashes (requires `--expose-internals`); also sets the permission mode (`DSH_PERMISSION_MODE`, default `danger-full-access`) |
| 6 | `~/bin/bwrap-proot` | The sandbox backend is missing (bwrap is unavailable, fall back to proot) |
| 7 | `~/.dsh/profiles/web/cordis.patch.yml` (data root, follows `$DSH_HOME`) | Sandbox runnerCommand injection |
| 8 | `dsh-subprocess-local` (located dynamically) | The terminal check crashes (platform detection rejects Android) |
| 9 | `dsh-terminal-bash` (located dynamically) | PTY fails to start (shellPath defaults to `/bin/bash`) |
| 10 | `node_modules/@img/sharp-wasm32` | sharp has no android-arm64 native binary, so startup reports a load failure (attachment-local) |
| 11 | `dsh-client-connection` (located dynamically) | After `dsh web` auto-opens the browser, it gets stuck at the "authentication required" step |
| 12 | `node-addon-require-builtin` (JS fallback) | There is no official android-arm64 native artifact, so dsh fails at startup with `No usable native binding found` |
| 13 | `@deepseek-ai/node-addon-system` (compiled locally) | `flock` has no prebuilt android-arm64 artifact, so every agent turn fails with `flock is not supported on android-arm64` |
| 14 | `dsh-attachment-local` (located dynamically) | The fsync on the attachment directory goes beyond the permitted scope, so pasting an image immediately fails with `prompt rejected (session/agent-busy)` |
| 15 | `dsh-attachment-local` (located dynamically) | Android's f2fs does not allow hard links, so saving an attachment fails with `EACCES` from `link()` and pasting an image reports `Unable to persist attachment.` |

- Items 1 and 2 are pre-install patches, applied before DeepSeek Harness is installed. `install` writes `~/.gyp/include.gypi` and `~/.npmrc` during its environment-setup stage; without them `node-pty` will not compile and npm cannot pull packages.
- Items 3–15 are post-install patches, applied after DeepSeek Harness is installed. Of these, items 3, 8, 9, 11, 12, 13, 14 and 15 modify files that already exist.
- The originals are backed up centrally to `~/dsh-patch-backups/[YYYYmmdd-HHMMSS]/` (`lib/` is relative to the dsh packages, `home/` to the home directory, `abs/` to any other absolute path). Within a snapshot each file is kept only once, at its earliest version, and the snapshot includes `MANIFEST.txt` (time, dsh version, source path, size, sha256).

## Script features

- **Idempotent**: re-running it is safe; already-applied patches are skipped automatically and nothing is changed twice.
- **Automatic backup**: before patching, the originals are backed up centrally to `~/dsh-patch-backups/[YYYYmmdd-HHMMSS]/`, and within a snapshot each file is kept only once, at its earliest version. `restore [YYYYmmdd-HHMMSS]` rolls back that whole snapshot; adding `--only=[text]` rolls back only the files whose relative path contains that text (e.g. `--only=index.js`). Before rolling back, the current files are saved as a new snapshot, so you can undo the previous undo. If nothing was changed, no empty snapshot is left behind.
- **Survives code splitting**: package-level patches locate the target files by "code signature strings" instead of hard-coding `lib/index.js`. dsh splits its code into hash-named files such as `lib/runner-launch-<hash>.js` (the hash changes with every release), so hard-coded paths are bound to break.
- **No false alarms for missing packages**: when the corresponding package is not installed, it prints `[SKIP]` and does not count it as a failure.
- **Self-check**: when it finishes it prints an `[OK]/[FAIL]` list, and everything must pass for it to count as success (items whose dependencies are missing show `[SKIP]` and are not counted); sed-based changes are re-checked with grep, and anything unexpected is reported directly as `[FAIL]`.
- **Installation never touches sensitive data**: neither installation nor patching changes API keys, session history or credential files. Backup and uninstall are the exceptions: `backup 2` packs `.credentials.yaml` into `settings.tar.gz`, `uninstall 5` deletes `.credentials.yaml`, and `uninstall 7` deletes `sessions` / `attachments` / `storages`.
- **Locally compiled native extensions**: `flock` is built on the device in Termux with `clang` (it only needs `node_api.h` provided with the `nodejs` package); it does not depend on node-gyp and does not need to download prebuilt artifacts over the network.
- **Automatic path handling**: `PREFIX` / `HOME` are validated before being adopted (non-empty, absolute path, shaped like `.../com.termux/files/usr`, `$PREFIX/bin/bash` actually executable); if any check fails it falls back to the official default paths. The generated wrapper and `cordis.patch.yml` are also injected with the actual paths.
- **Diagnosable outside Termux**: when not run inside Termux, `help` / `status` / `doctor` / `channels` still work as usual, while file-writing commands error out and exit immediately.
- **Explicit scopes, no defaults**: every scope of `backup` / `uninstall` stands on equal footing, and running either with no arguments only lists the scopes; `--yes` cannot skip the data-destruction confirmation either (deleting session data requires typing `PURGE` by hand).
- **Follows the official data root**: `status`, item 7, `backup` and `uninstall` all resolve the data root from `${DSH_HOME:-~/.dsh}` instead of hard-coding `~/.dsh`.

## How it works

DSH is designed at its core for Linux desktops, and on Android it is mainly incompatible in six respects:

1. **File system**: Android's f2fs rejects `link()` (returning `EACCES`), and the main path for saving attachments is exactly "staging file --link--> final file". The script handles this in two layers: a preload intercepts `fs.link` / `fs.promises.link` as a fallback for CommonJS call sites (falling back to a `copyFile` copy on failure, keeping the source file); for `dsh-attachment-local` it replaces both `link()` calls with `linkOrCopy()`, which copies with `copyFile` when a hard link fails (item 15) — the ESM `import { link }` gets the original function from the built-in module, which the preload cannot intercept.
2. **Sandbox**: the official bwrap/Landlock backends depend on Linux kernel capabilities that the Android kernel does not provide; the script uses proot as a path-level substitute (injected via `runnerCommand`).
3. **Paths**: standard Linux paths such as `/bin/bash` and `/tmp` do not exist in Termux, so the script rewrites them all to the real paths under `$PREFIX`; under multi-user setups or non-default install locations `$PREFIX` is not equal to `/data/data/com.termux/files/usr`, so the script validates `PREFIX` / `HOME` before adopting them and only falls back to the default values if validation fails.
4. **Native dependencies**: sharp has no official prebuilt binary for android-arm64, so the script substitutes the WASM build of the same version.
5. **Browser authentication**: when `dsh web` auto-opens the browser, cookies with `SameSite=Strict` are not carried along by navigation from an external app, so the script changes it to `Lax`.
6. **Native extensions**: some dsh capabilities depend on Node native addons, and the official project only publishes prebuilt artifacts for desktop platforms. The script takes two routes depending on "whether it can be compiled locally":
    - **Compilable ones** (such as `flock` in `node-addon-system`, whose package ships its own `src/flock.c`): build it locally with `clang` into `system.node`, put it into a self-built android-arm64 platform package and bypass the platform check — genuine native semantics are preserved and kernel-level file locking is available.
    - **Non-compilable ones** (such as `node-addon-require-builtin`, whose source code is not public): replace it with `--expose-internals` + a pure JS implementation (you get instances of the same Node internal modules).

## Troubleshooting

| Symptom | What to do |
| --- | --- |
| `pkg install` reports `Unable to locate package` | Run `pkg update` or switch the mirror with `termux-change-repo`, then run it again |
| It hangs at `npm install` | Check `~/dsh-install-logs/install-*.log`; if downloads are slow, point npm at a faster mirror |
| `status` stays at stage 2 | Look at which items in `[3]` are MISS, re-run `patch` on its own and read the `[FAIL]` explanation |
| The terminal panel is broken | `node-pty` was not compiled successfully; run `pkg install clang make python` and then re-run `patch` |
| Pasting an image fails with `prompt rejected (session/agent-busy)` | Item 14 did not take effect; check whether `dsh-attachment-local/lib/index.js` contains `dsh-android-sync-guard` |
| Pasting an image fails with `Unable to persist attachment.` | Item 15 did not take effect; check whether the same file contains `dsh-android-link-guard` |
| It reports "Termux runtime environment not found" | You ran a file-writing command outside Termux; `status` / `help` still work |

## About this project

- To stay compatible with Android, the sandbox backend uses proot for **path-level isolation**, which is not real kernel isolation and is less secure than the official bwrap/Landlock.
- It is suitable for **running trusted tasks on your own device**; do not use it to execute code of unknown origin.
- So far the developer has only verified feasibility on their own device. If you run into problems, you can turn to professionals and AI for help, and once a problem is found or solved, you are welcome to raise it in an issue.
- I am not a professional developer; if you intend to maintain this patch, please contact me at xingyunMC@outlook.com.
- This project is not affiliated with DeepSeek, and is not intended for commercial use.
- All README files other than the Simplified Chinese one were translated by AI, so the wording may be imprecise and some terms may be non-standard. If you notice anything, please point it out in an issue.

## License

[MIT](./LICENSE)

## Remarks
This README file was written by DeepSeek.
