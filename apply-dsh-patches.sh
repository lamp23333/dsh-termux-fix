#!/data/data/com.termux/files/usr/bin/bash
# ============================================================================
# apply-dsh-patches.sh —— Termux 部署 DeepSeek Harness (dsh) 一键补丁
#
# 作用：固化从最初安装到现在遇到的所有问题修复，一次跑完全部生效。
# 特性：幂等（可重复运行）、改包自动备份 .bak、跑完自检。
# 用法：bash apply-dsh-patches.sh
#
# 覆盖 9 项必选修复：
#   1. ~/.gyp/include.gypi          —— node-pty 编译的 android_ndk_path
#   2. ~/.npmrc                     —— npm 镜像（npmmirror + foreground-scripts）
#   3. ~/.bashrc                    —— PATH 含 ~/bin（dsh 命令可找到）
#   4. ~/dsh-link-fix.js            —— f2fs 禁硬链接的 fs.link fallback
#   5. ~/bin/dsh                    —— wrapper：--expose-internals + preload + 权限模式
#   6. ~/bin/bwrap-proot            —— bwrap→proot + PATH + /bin/bash 替换
#   7. cordis.patch.yml             —— sandbox runnerCommand + terminal-bash shellPath
#   8. dsh-subprocess-local         —— terminal inspection 的 android 兼容（sed）
#   9. dsh-terminal-bash            —— shellPath 默认值 /bin/bash → PREFIX（sed）
# ============================================================================

PREFIX="/data/data/com.termux/files/usr"
HOME_DIR="/data/data/com.termux/files/home"
DSH_ROOT="$PREFIX/lib/node_modules/@deepseek-ai/dsh"
BASH_PATH="$PREFIX/bin/bash"

log()  { echo "[patch] $*"; }
ok()   { echo "  [OK]   $*"; }
fail() { echo "  [FAIL] $*"; }

echo "================================================"
echo " dsh Termux 一键补丁 (9 项必选)"
echo "================================================"

# ---------- 前置检查：dsh 主程序是否已安装 ----------
if [ ! -d "$DSH_ROOT" ]; then
  echo "  [警告] 未检测到 dsh 主程序："
  echo "         $DSH_ROOT"
  echo "         请先执行：npm install -g @deepseek-ai/dsh"
  echo "         然后重新运行本脚本。"
  exit 1
fi

# ---------- 1. gyp：node-pty 编译的 android_ndk_path ----------
log "1/9 写入 ~/.gyp/include.gypi (node-pty 编译修复)"
mkdir -p "$HOME_DIR/.gyp"
echo "{'variables':{'android_ndk_path':''}}" > "$HOME_DIR/.gyp/include.gypi"
ok "~/.gyp/include.gypi"

# ---------- 2. npm 镜像 ----------
log "2/9 配置 ~/.npmrc (npmmirror 镜像)"
touch "$HOME_DIR/.npmrc"
grep -q '^registry=' "$HOME_DIR/.npmrc" || echo 'registry=https://registry.npmmirror.com' >> "$HOME_DIR/.npmrc"
grep -q '^foreground-scripts=' "$HOME_DIR/.npmrc" || echo 'foreground-scripts=true' >> "$HOME_DIR/.npmrc"
ok "~/.npmrc"

# ---------- 3. PATH ----------
log "3/9 配置 ~/.bashrc (PATH 含 ~/bin)"
touch "$HOME_DIR/.bashrc"
sed -i '/NODE_OPTIONS/d' "$HOME_DIR/.bashrc"
grep -q 'HOME/bin' "$HOME_DIR/.bashrc" || echo 'export PATH=$HOME/bin:$PATH' >> "$HOME_DIR/.bashrc"
ok "~/.bashrc"

# ---------- 4. fs.link fallback preload ----------
log "4/9 写入 ~/dsh-link-fix.js (f2fs 硬链接 fallback)"
cat > "$HOME_DIR/dsh-link-fix.js" <<'EOF'
'use strict';
const fs = require('fs');
function isFallback(err) {
  return err && (err.code === 'EACCES' || err.code === 'EPERM' || err.code === 'ENOTSUP' || err.code === 'EXDEV');
}
const origLink = fs.link;
if (typeof origLink === 'function') {
  fs.link = function (src, dest, cb) {
    origLink.call(this, src, dest, (err) => {
      if (isFallback(err)) {
        fs.rename(src, dest, cb);
      } else {
        cb(err);
      }
    });
  };
}
const origLinkSync = fs.linkSync;
if (typeof origLinkSync === 'function') {
  fs.linkSync = function (src, dest) {
    try {
      return origLinkSync.call(this, src, dest);
    } catch (err) {
      if (isFallback(err)) {
        return fs.renameSync(src, dest);
      }
      throw err;
    }
  };
}
if (fs.promises && typeof fs.promises.link === 'function') {
  const origPLink = fs.promises.link;
  fs.promises.link = function (src, dest) {
    return origPLink.call(this, src, dest).catch((err) => {
      if (isFallback(err)) {
        return fs.promises.rename(src, dest);
      }
      throw err;
    });
  };
}
console.log('[dsh-link-fix] link() fallback injected');
EOF
ok "~/dsh-link-fix.js"

# ---------- 5. wrapper ----------
log "5/9 写入 ~/bin/dsh (--expose-internals + preload + 权限模式)"
mkdir -p "$HOME_DIR/bin"
cat > "$HOME_DIR/bin/dsh" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
export DSH_PERMISSION_MODE="${DSH_PERMISSION_MODE:-danger-full-access}"
exec node --expose-internals -r /data/data/com.termux/files/home/dsh-link-fix.js /data/data/com.termux/files/usr/lib/node_modules/@deepseek-ai/dsh/lib/bin.js "$@"
EOF
chmod +x "$HOME_DIR/bin/dsh"
ok "~/bin/dsh"

# ---------- 6. bwrap-proot ----------
log "6/9 写入 ~/bin/bwrap-proot (bwrap→proot + PATH + /bin/bash 替换)"
cat > "$HOME_DIR/bin/bwrap-proot" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
export PATH="/data/data/com.termux/files/usr/bin:/data/data/com.termux/files/usr/bin/applets:${PATH:-}"
# bwrap -> proot 转换器：让 dsh 受限沙箱模式在 Termux 可用
# 作为 dsh-sandbox-local 的 runnerCommand 使用（argv 是 bwrap 风格参数）
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --) shift; break ;;
    --ro-bind) shift 3 ;;                       # 整根只读绑定：proot 不需要
    --bind) src="$2"; dst="$3"; shift 3         # workspace 可写绑定：保留
      [ -e "$src" ] && args+=("-b" "$src:$dst") ;;
    --tmpfs) dst="$2"; shift 2                  # /tmp -> Termux 的 tmp
      mkdir -p "/data/data/com.termux/files/usr/tmp"
      args+=("-b" "/data/data/com.termux/files/usr/tmp:$dst") ;;
    --dev) shift 2 ;;                           # proot 下默认可见
    --proc) shift 2 ;;
    --die-with-parent|--unshare-all|--unshare-user|--unshare-pid|--unshare-net) shift ;;
    *) shift ;;
  esac
done
# 兜底：确保基础设备路径可见
for p in /dev /proc /sys; do
  [ -e "$p" ] && args+=("-b" "$p:$p")
done
if [ "${1:-}" = "/bin/bash" ]; then
  set -- "/data/data/com.termux/files/usr/bin/bash" "${@:2}"
fi
exec proot "${args[@]}" "$@"
EOF
chmod +x "$HOME_DIR/bin/bwrap-proot"
ok "~/bin/bwrap-proot"

# ---------- 7. cordis.patch.yml ----------
log "7/9 写入 ~/.dsh/profiles/web/cordis.patch.yml (runnerCommand + shellPath)"
mkdir -p "$HOME_DIR/.dsh/profiles/web"
cat > "$HOME_DIR/.dsh/profiles/web/cordis.patch.yml" <<'EOF'
- id: sandbox
  config:
    runnerCommand:
      - /data/data/com.termux/files/home/bin/bwrap-proot
    runnerFailureSignatures:
      - "permission denied"
- id: terminal-bash
  config:
    shellPath: /data/data/com.termux/files/usr/bin/bash
EOF
ok "~/.dsh/profiles/web/cordis.patch.yml"

# ---------- 8. subprocess-local android 兼容 ----------
log "8/9 补丁 dsh-subprocess-local (terminal inspection android)"
F="$DSH_ROOT/node_modules/@deepseek-ai/dsh-subprocess-local/lib/index.js"
if [ ! -f "$F" ]; then
  fail "找不到 $F"
elif grep -q 'platform === "linux" || platform === "android"' "$F"; then
  ok "dsh-subprocess-local 已打补丁（跳过）"
else
  [ -f "$F.bak" ] || cp "$F" "$F.bak"
  sed -i 's/if (platform === "linux") return new LinuxProcessInspector(arch, internals);/if (platform === "linux" || platform === "android") return new LinuxProcessInspector(arch, internals);/' "$F"
  ok "dsh-subprocess-local 已打补丁"
fi

# ---------- 9. terminal-bash shellPath ----------
log "9/9 补丁 dsh-terminal-bash (shellPath 默认值)"
F="$DSH_ROOT/node_modules/@deepseek-ai/dsh-terminal-bash/lib/index.js"
if [ ! -f "$F" ]; then
  fail "找不到 $F"
elif grep -q "DEFAULT_BASH_SHELL = \"$BASH_PATH\"" "$F" || grep -q "default(\"$BASH_PATH\")" "$F"; then
  ok "dsh-terminal-bash 已打补丁（跳过）"
else
  [ -f "$F.bak" ] || cp "$F" "$F.bak"
  # 兼容 rc.6 旧写法：shellPath: z.string().default("/bin/bash")
  sed -i 's|shellPath: z.string().default("/bin/bash")|shellPath: z.string().default("'"$BASH_PATH"'")|' "$F"
  # 兼容 rc.7+ 新写法：const DEFAULT_BASH_SHELL = "/bin/bash";
  sed -i 's|const DEFAULT_BASH_SHELL = "/bin/bash";|const DEFAULT_BASH_SHELL = "'"$BASH_PATH"'";|' "$F"
  ok "dsh-terminal-bash 已打补丁"
fi

# ============ 自检 ============
echo "================================================"
echo " 自检结果"
echo "================================================"

c=0
check() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "  [OK]   $desc"
    c=$((c+1))
  else
    echo "  [FAIL] $desc"
  fi
}

check "~/.gyp/include.gypi"            grep -q "android_ndk_path" "$HOME_DIR/.gyp/include.gypi"
check "~/.npmrc (registry)"           grep -q "npmmirror" "$HOME_DIR/.npmrc"
check "~/.npmrc (foreground-scripts)" grep -q "foreground-scripts" "$HOME_DIR/.npmrc"
check "~/.bashrc (PATH)"              grep -q "HOME/bin" "$HOME_DIR/.bashrc"
check "~/dsh-link-fix.js"             test -f "$HOME_DIR/dsh-link-fix.js"
check "~/bin/dsh (可执行)"             test -x "$HOME_DIR/bin/dsh"
check "~/bin/bwrap-proot (可执行)"     test -x "$HOME_DIR/bin/bwrap-proot"
check "cordis.patch.yml (runnerCommand)" grep -q "runnerCommand" "$HOME_DIR/.dsh/profiles/web/cordis.patch.yml"
check "subprocess-local (android)"    grep -q 'platform === "linux" || platform === "android"' "$DSH_ROOT/node_modules/@deepseek-ai/dsh-subprocess-local/lib/index.js"
check "terminal-bash (shellPath)"     grep -Eq "DEFAULT_BASH_SHELL = \"$BASH_PATH\"|default\(\"$BASH_PATH\"\)" "$DSH_ROOT/node_modules/@deepseek-ai/dsh-terminal-bash/lib/index.js"

echo "================================================"
echo " 完成：$c / 10 项通过"
echo ""
echo " 说明："
echo "   - 第 8、9 项为包级 sed 修改，首次执行会自动备份 .bak"
echo "   - npm 更新 dsh 后，包级补丁会被覆盖，请重新运行本脚本"
echo "   - 打完补丁后，用 'dsh web' 启动（建议先 cd ~/workspace）"
echo "================================================"
