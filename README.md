# dsh-termux-fix

**一键补丁脚本**，让 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 在 Android Termux 环境正常运行。


## 为什么需要它

在 Android 设备上使用 Termux 部署 DeepSeek Harness 会遇到一系列问题。这个脚本把 11 个问题的修复全部固化，一次运行全部解决。

## 快速开始

### 前置条件

- Android 手机 + [Termux](https://termux.dev/)
- 编译工具链：`pkg install -y clang cmake ninja make pkg-config`
- proot：`pkg install -y proot`

### 1. 安装 DSH

```bash
npm install -g @deepseek-ai/dsh
```

### 2. 下载并导入补丁

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

### 3.运行补丁

```bash
bash apply-dsh-patches.sh
```

### 4. 启动 DeepSeek Harness

```bash
cd ~/workspace   # 建议在专门目录启动
dsh web
```

## 补丁明细（11 项）

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

## 脚本特性

- **幂等**：可重复运行，已打补丁自动跳过，不会重复改
- **自动备份**：包级修改自动备份 `.bak`，可回滚
- **抗拆包**：包级补丁按「代码特征字符串」定位目标文件，不写死 `lib/index.js`。dsh 会把代码拆进 `lib/runner-launch-<hash>.js` 这类哈希命名文件（hash 每次发版都变），写死路径必然失效
- **包缺失不误报**：对应包未安装时输出 `[SKIP]`，不计入失败项
- **自检**：跑完输出 `[OK]/[FAIL]` 清单，12 项全部通过才算成功；sed 类修改会再 grep 复核，不符预期直接报 `[FAIL]`
- **无敏感信息**：不碰 API Key、会话历史、凭据文件

## 原理简述

DSH 底层为 Linux 桌面设计，在 Android 上主要有五类水土不服：

1. **文件系统**：f2fs + 加密分区禁 `link()` 系统调用，脚本用 preload 劫持 `fs.link` 在失败时 fallback 到 `rename`
2. **沙箱**：官方 bwrap/Landlock 后端依赖 Linux 内核能力，Android 内核不提供，脚本用 proot 做路径级替代（`runnerCommand` 注入）
3. **路径**：`/bin/bash`、`/tmp` 等 Linux 标准路径在 Termux 不存在，脚本统一改到 `$PREFIX` 真实路径
4. **原生依赖与浏览器认证**：sharp 在 android-arm64 无官方预编译二进制，脚本改用同版本 WASM 版替代；`dsh web` 自动打开浏览器时 `SameSite=Strict` 的认证 cookie 不被外部应用导航携带，脚本改为 `Lax`
5. **原生扩展**：dsh 部分能力依赖 Node 原生 addon（如 `node-addon-require-builtin` 访问 Node 内部模块），官方只发布桌面平台预编译产物，脚本用 `--expose-internals` + 纯 JS 实现替代（拿到的是同一批 Node 内部模块实例）

## 免责声明

- 沙箱后端用 proot 是**路径级隔离**，不是真正的内核隔离，安全性低于官方 bwrap/Landlock
- 适合在**自己的设备上跑可信任务**，不要用它执行来历不明的代码
- 本项目与 DeepSeek 官方无关，且不会用于商业活动

## License

[MIT](./LICENSE)

## 备注
此 README 文件由 DeepSeek 撰写
