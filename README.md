# dsh-termux-fix

**一键补丁脚本**，让 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 在 Android Termux 环境正常运行。

## 为什么需要它

在 Android 设备上使用 Termux 部署 DeepSeek Harness 会遇到一系列问题。

## 快速开始

### 前置条件

- Android 手机 + [Termux](https://termux.dev/)
- 设备可用空间需大于 1.5 GB（`node-pty` 与 `flock` 要现场编译）
- 可能需要使用 `termux-change-repo` 更换国内源
- 首次安装需联网（npm registry），可能需要使用 `npm config set registry https://registry.npmmirror.com` 更换 npm 国内源，可以使用 `npm config get registry` 验证是否更改成功。

### 1. 下载并导入补丁

首先确保已在 Termux 中安装了 curl 和 unzip

```bash
pkg install -y curl unzip
```

**方式一**：直接下载

```bash
curl -O https://raw.githubusercontent.com/lamp23333/dsh-termux-fix/main/apply-dsh-patches.sh
```

**方式二**：手动下载导入 Termux

1. 通过下载仓库zip文件或 `apply-dsh-patches.sh` 到手机存储来获取补丁文件
2. 在 Termux 授权访问存储
```bash
termux-setup-storage
```
（运行后会出现权限授权弹窗，点「允许」）

3. 导入补丁文件到 home（也就是 `~` ，即 `/data/data/com.termux/files/home` ）

- 复制单文件导入
```bash
cp /storage/emulated/0/[补丁所在文件夹]/apply-dsh-patches.sh ~/
```

或者

- 解压仓库zip包导入
```bash
cd ~
unzip /storage/emulated/0/[仓库zip包所在文件夹]/dsh-termux-fix-main.zip

# 解压后文件在 ~/dsh-termux-fix-main/apply-dsh-patches.sh

# 移动到 Termux 根目录
cp ~/dsh-termux-fix-main/apply-dsh-patches.sh ~/
```

### 3. 安装 DeepSeek Harness

> 首次安装时，可使用一部到位的懒人指令：
>
> ```bash
> bash ~/apply-dsh-patches.sh all
> ```

> 也可以分段进行
>
> 先安装环境依赖、前置补丁和 DeepSeek Harness：
> ```bash
> bash ~/apply-dsh-patches.sh install
> ```
> 接着看一眼当前状态：
> ```bash
> bash ~/apply-dsh-patches.sh status
> ```
> 确认为“阶段 2/3”
>
> 最后补齐后续补丁：
> ```bash
> bash ~/apply-dsh-patches.sh patch
> ```

### 4. 启动 DeepSeek Harness

```bash
cd ~/workspace   # 建议在专门目录启动
dsh web
```

### 5. 更新 DeepSeek Harness

更新方式与安装同理，但不要忘了再次安装补丁固化哦～

### 6. 备注

补丁中使用 pkg install 安装的包：
```
运行期：node nodejs bash proot sed grep tar gzip diffutils findutils coreutils
编译期：clang make python pkg-config
```

## 命令

不带参数 = 打印使用说明（`help`）。

| 命令 | 作用 |
| --- | --- |
| `status` | 显示环境状态 |
| `doctor` | 显示环境状态详细报告 |
| `patch` | 仅安装补丁 |
| `install` | 仅安装 DeepSeek Harness |
| `all` | 安装 DeepSeek Harness 与补丁 |
| `channels` | 查询 DeepSeek Harness 最新版本 |
| `backup` | 备份数据（会话、配置、补丁产物、工作区） |
| `uninstall` | 卸载 DeepSeek Harness 与补丁 |
| `help` | 显示使用说明 |

## 补丁明细

| # | 文件 / 修改 | 解决的原始问题 |
|---|-------------|---------------|
| 1 | `~/.gyp/include.gypi` | node-pty 编译报 `android_ndk_path` 未定义，dsh 装不上 |
| 2 | `~/.npmrc` | npm 默认源下载慢/失败（切 npmmirror） |
| 3 | `~/.bashrc` | `dsh` 命令找不到（PATH 补 `~/bin`） |
| 4 | `~/dsh-link-fix.js` | f2fs 文件系统禁硬链接，会话保存报 `EACCES` |
| 5 | `~/bin/dsh` | HMR 插件崩溃（需 `--expose-internals`）+ 权限模式 |
| 6 | `~/bin/bwrap-proot` | 沙箱后端缺失（bwrap 不可用，转 proot） |
| 7 | `~/.dsh/profiles/web/cordis.patch.yml` | 沙箱 runnerCommand 注入 |
| 8 | `dsh-subprocess-local`（动态定位） | 终端检查崩溃（平台检测拒绝 Android） |
| 9 | `dsh-terminal-bash`（动态定位） | PTY 启动失败（shellPath 默认 `/bin/bash`） |
| 10 | `node_modules/@img/sharp-wasm32` | sharp 无 android-arm64 原生二进制，启动报加载失败（attachment-local） |
| 11 | `dsh-client-connection`（动态定位） | `dsh web` 自动打开浏览器后停在 authentication required |
| 12 | `node-addon-require-builtin`（JS 兜底） | 官方无 android-arm64 原生产物，dsh 启动报 `No usable native binding found` |
| 13 | `@deepseek-ai/node-addon-system`（本地编译） | `flock` 无 android-arm64 预编译产物，Agent 每轮运行报 `flock is not supported on android-arm64` |
| 14 | `dsh-attachment-local`（动态定位） | 附件目录 fsync 越权，一贴图就报 `prompt rejected (session/agent-busy)` |

- 第 3、8、9、11、12、13、14 项为 DeepSeek Harness 安装后补丁，安装时会改到已有文件，首次执行把原件备份成 `.bak`。

## 脚本特性

- **幂等**：可重复运行，已打补丁自动跳过，不会重复改
- **自动备份**：包级修改自动备份 `.bak`，可回滚
- **抗拆包**：包级补丁按「代码特征字符串」定位目标文件，不写死 `lib/index.js`。dsh 会把代码拆进 `lib/runner-launch-<hash>.js` 这类哈希命名文件（hash 每次发版都变），写死路径必然失效
- **包缺失不误报**：对应包未安装时输出 `[SKIP]`，不计入失败项
- **自检**：跑完输出 `[OK]/[FAIL]` 清单，所有项全部通过才算成功（依赖缺失的项显示 `[SKIP]` 且不计入）；sed 类修改会再 grep 复核，不符预期直接报 `[FAIL]`
- **无敏感信息**：不碰 API Key、会话历史、凭据文件
- **本地编译原生扩展**：`flock` 在 Termux 现场用 `clang` 编译（只需随 `nodejs` 包提供的 `node_api.h`），不依赖 node-gyp，也不需要联网下载预编译产物
- **路径自适应**：`PREFIX` / `HOME` 先校验再采用（非空、绝对路径、形如 `.../com.termux/files/usr`、`$PREFIX/bin/bash` 真实可执行），任一不满足就回退官方默认路径；生成的 wrapper 与 `cordis.patch.yml` 也按实际路径注入
- **非 Termux 可诊断**：不在 Termux 里跑时，`help` / `status` / `doctor` / `channels` 照常可用，写文件类命令会直接报错退出

## 原理简述

DSH 底层为 Linux 桌面设计，在 Android 上主要有五类水土不服：

1. **文件系统**：f2fs + 加密分区禁 `link()` 系统调用，脚本用 preload 劫持 `fs.link` 在失败时 fallback 到 `rename`
2. **沙箱**：官方 bwrap/Landlock 后端依赖 Linux 内核能力，Android 内核不提供，脚本用 proot 做路径级替代（`runnerCommand` 注入）
3. **路径**：`/bin/bash`、`/tmp` 等 Linux 标准路径在 Termux 不存在，脚本统一改到 `$PREFIX` 真实路径；多用户或非默认安装位置下 `$PREFIX` 并不等于 `/data/data/com.termux/files/usr`，所以脚本先校验 `PREFIX` / `HOME` 再采用，校验不过才回退默认值
4. **原生依赖**：sharp 在 android-arm64 没有官方预编译二进制，脚本改用同版本 WASM 版替代
5. **浏览器认证**：`dsh web` 自动打开浏览器时，`SameSite=Strict` 的 cookie 不被外部应用导航携带，脚本改为 `Lax`
6. **原生扩展**：dsh 部分能力依赖 Node 原生 addon，官方只发布桌面平台预编译产物。脚本按「能否本地编译」分两条路：
    - **可编译的**（如 `node-addon-system` 的 `flock`，包内自带 `src/flock.c`）：用 `clang` 现场编译成 `system.node`，放入自建的 android-arm64 平台包并放开平台守卫——保留真原生语义，内核级文件锁可用
    - **不可编译的**（如 `node-addon-require-builtin`，源码未公开）：用 `--expose-internals` + 纯 JS 实现替代（拿到的是同一批 Node 内部模块实例）

## 备份与还原

备份：
```bash
bash ~/apply-dsh-patches.sh backup --all
```

产物在 `~/dsh-backups/<YYYYmmdd-HHMMSS>/`：

```
dsh-home.tar.gz    # ~/.dsh（会话 + 网页端设置）
config.tar.gz      # .npmrc / .bashrc / .gyp / cordis.patch.yml
patches.tar.gz     # ~/bin/dsh / bwrap-proot / dsh-link-fix.js / dsh-flock-check.mjs
workspace.tar.gz   # ~/workspace
MANIFEST.txt       # 时间、版本、平台、还原方式
```

还原：
```bash
tar xzf dsh-home.tar.gz -C ~
```

## 部分问题排查

| 现象 | 处理 |
| --- | --- |
| `pkg install` 报 `Unable to locate package` | `pkg update` 或 `termux-change-repo` 换源后重跑 |
| 卡在 `npm install` | 看 `~/dsh-install-logs/install-*.log`；国内建议 `registry=https://registry.npmmirror.com` |
| `status` 一直是阶段 2 | 看 `[3]` 里哪几项 MISS，单独重跑 `patch` 并读 `[FAIL]` 说明 |
| 终端面板坏了 | `node-pty` 没编译成功，`pkg install clang make python` 后重跑 `patch` |
| 贴图发不出去 | 第 14 项没生效，检查 `dsh-attachment-local/lib/index.js` 里是否有 `dsh-android-sync-guard` |
| 报「找不到 Termux 运行环境」 | 你在非 Termux 里跑了写文件类命令；`status` / `help` 仍然可用 |

## 声明

- 为了兼容 Android 系统，沙箱后端用 proot 是**路径级隔离**，不是真正的内核隔离，安全性低于官方 bwrap/Landlock
- 适合在**自己的设备上跑可信任务**，不要用它执行来历不明的代码
- 目前开发者仅在自己的设备上验证了可行性，如发现问题，可以向专业人士和人工智能求助，问题发现或解决后欢迎各位在 issue 中提出
- 本人不是专业的开发者，有意要维护此补丁的，请通过 xingyunMC@outlook.com 和我联系
- 本项目与 DeepSeek 官方无关，且不用于任何商业活动

## License

[MIT](./LICENSE)

## 备注
此 README 文件由 DeepSeek 撰写
