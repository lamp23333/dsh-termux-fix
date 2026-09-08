#!/data/data/com.termux/files/usr/bin/bash
# ============================================================================
# apply-dsh-patches.sh —— Termux 部署 DeepSeek Harness (dsh) 一键补丁
#
# 作用：固化从最初安装到现在遇到的所有问题修复，一次跑完全部生效。
# 特性：幂等（可重复运行）、改包自动备份 .bak、跑完自检、sed 失败会报 FAIL。
# 用法：bash apply-dsh-patches.sh
#
# 覆盖 11 项必选修复：
#   1. ~/.gyp/include.gypi          —— node-pty 编译的 android_ndk_path
#   2. ~/.npmrc                     —— npm 镜像（npmmirror + foreground-scripts）
#   3. ~/.bashrc                    —— PATH 含 ~/bin（dsh 命令可找到）
#   4. ~/dsh-link-fix.js            —— f2fs 禁硬链接的 fs.link fallback
#   5. ~/bin/dsh                    —— wrapper：--expose-internals + preload + 权限模式
#   6. ~/bin/bwrap-proot            —— bwrap→proot + PATH + /bin/bash 替换
#   7. cordis.patch.yml             —— sandbox runnerCommand + terminal-bash shellPath
#   8. dsh-subprocess-local         —— terminal inspection 的 android 兼容（sed）
#   9. dsh-terminal-bash            —— shellPath 默认值 /bin/bash → PREFIX（sed）
#  10. sharp WASM                   —— @img/sharp-wasm32 + @emnapi（attachment-local）
#  11. dsh-client-connection        —— SameSite Strict → Lax（自动开浏览器可认证）
# ============================================================================

PREFIX="/data/data/com.termux/files/usr"
HOME_DIR="/data/data/com.termux/files/home"
DSH_ROOT="$PREFIX/lib/node_modules/@deepseek-ai/dsh"
DSH_NM="$DSH_ROOT/node_modules"
BASH_PATH="$PREFIX/bin/bash"

log()  { echo "[patch] $*"; }
ok()   { echo "  [OK]   $*"; }
fail() { echo "  [FAIL] $*"; }

# 读取某个已安装 npm 包的版本号（不存在则输出空字符串）
pkg_ver() { node -p "require('$1/package.json').version" 2>/dev/null; }

echo "================================================"
echo " dsh Termux 一键补丁 (11 项必选)"
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
log "1/11 写入 ~/.gyp/include.gypi (node-pty 编译修复)"
mkdir -p "$HOME_DIR/.gyp"
if grep -q "android_ndk_path" "$HOME_DIR/.gyp/include.gypi" 2>/dev/null; then
  ok "~/.gyp/include.gypi（已存在，跳过）"
else
  echo "{'variables':{'android_ndk_path':''}}" > "$HOME_DIR/.gyp/include.gypi"
  ok "~/.gyp/include.gypi"
fi

# ---------- 2. npm 镜像 ----------
log "2/11 配置 ~/.npmrc (npmmirror 镜像)"
touch "$HOME_DIR/.npmrc"
grep -q '^registry=' "$HOME_DIR/.npmrc" || echo 'registry=https://registry.npmmirror.com' >> "$HOME_DIR/.npmrc"
grep -q '^foreground-scripts=' "$HOME_DIR/.npmrc" || echo 'foreground-scripts=true' >> "$HOME_DIR/.npmrc"
ok "~/.npmrc"

# ---------- 3. PATH ----------
log "3/11 配置 ~/.bashrc (PATH 含 ~/bin)"
touch "$HOME_DIR/.bashrc"
# 仅清理会导致 HMR 报错的历史 NODE_OPTIONS，保留你自己设置的其它 NODE_OPTIONS
[ -f "$HOME_DIR/.bashrc.bak" ] || cp "$HOME_DIR/.bashrc" "$HOME_DIR/.bashrc.bak"
sed -i '/NODE_OPTIONS.*expose-internals/d' "$HOME_DIR/.bashrc"
grep -q 'HOME/bin' "$HOME_DIR/.bashrc" || echo 'export PATH=$HOME/bin:$PATH' >> "$HOME_DIR/.bashrc"
ok "~/.bashrc"

# ---------- 4. fs.link fallback preload ----------
log "4/11 写入 ~/dsh-link-fix.js (f2fs 硬链接 fallback)"
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
log "5/11 写入 ~/bin/dsh (--expose-internals + preload + 权限模式)"
mkdir -p "$HOME_DIR/bin"
cat > "$HOME_DIR/bin/dsh" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
export DSH_PERMISSION_MODE="${DSH_PERMISSION_MODE:-danger-full-access}"
exec node --expose-internals -r /data/data/com.termux/files/home/dsh-link-fix.js /data/data/com.termux/files/usr/lib/node_modules/@deepseek-ai/dsh/lib/bin.js "$@"
EOF
chmod +x "$HOME_DIR/bin/dsh"
ok "~/bin/dsh"

# ---------- 6. bwrap-proot ----------
log "6/11 写入 ~/bin/bwrap-proot (bwrap→proot + PATH + /bin/bash 替换)"
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
# 注意：已存在的文件不会被整体覆盖——只补齐缺失的 id 块，保留你手动添加的其它配置
log "7/11 写入 ~/.dsh/profiles/web/cordis.patch.yml (runnerCommand + shellPath)"
PATCH_YML="$HOME_DIR/.dsh/profiles/web/cordis.patch.yml"
mkdir -p "$(dirname "$PATCH_YML")"
if [ ! -f "$PATCH_YML" ]; then
  cat > "$PATCH_YML" <<'EOF'
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
  ok "cordis.patch.yml（新建）"
else
  need_sandbox=0
  need_terminal=0
  grep -qE '^[[:space:]]*-[[:space:]]*id:[[:space:]]*sandbox[[:space:]]*$' "$PATCH_YML" || need_sandbox=1
  grep -qE '^[[:space:]]*-[[:space:]]*id:[[:space:]]*terminal-bash[[:space:]]*$' "$PATCH_YML" || need_terminal=1
  if [ "$need_sandbox" = 1 ]; then
    cat >> "$PATCH_YML" <<'EOF'

- id: sandbox
  config:
    runnerCommand:
      - /data/data/com.termux/files/home/bin/bwrap-proot
    runnerFailureSignatures:
      - "permission denied"
EOF
  fi
  if [ "$need_terminal" = 1 ]; then
    cat >> "$PATCH_YML" <<'EOF'

- id: terminal-bash
  config:
    shellPath: /data/data/com.termux/files/usr/bin/bash
EOF
  fi
  if [ "$need_sandbox" = 0 ] && [ "$need_terminal" = 0 ]; then
    ok "cordis.patch.yml（已含 sandbox + terminal-bash，跳过）"
  else
    ok "cordis.patch.yml（已补齐缺失块）"
  fi
fi

# ---------- 8. subprocess-local android 兼容 ----------
log "8/11 补丁 dsh-subprocess-local (terminal inspection android)"
F="$DSH_NM/@deepseek-ai/dsh-subprocess-local/lib/index.js"
if [ ! -f "$F" ]; then
  fail "找不到 $F"
elif grep -q 'platform === "linux" || platform === "android"' "$F"; then
  ok "dsh-subprocess-local 已打补丁（跳过）"
else
  [ -f "$F.bak" ] || cp "$F" "$F.bak"
  sed -i 's/if (platform === "linux") return new LinuxProcessInspector(arch, internals);/if (platform === "linux" || platform === "android") return new LinuxProcessInspector(arch, internals);/' "$F"
  if grep -q 'platform === "linux" || platform === "android"' "$F"; then
    ok "dsh-subprocess-local 已打补丁"
  else
    fail "sed 未生效——dsh 代码结构可能已变，请人工检查 $F"
  fi
fi

# ---------- 9. terminal-bash shellPath ----------
log "9/11 补丁 dsh-terminal-bash (shellPath 默认值)"
F="$DSH_NM/@deepseek-ai/dsh-terminal-bash/lib/index.js"
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
  if grep -q "DEFAULT_BASH_SHELL = \"$BASH_PATH\"" "$F" || grep -q "default(\"$BASH_PATH\")" "$F"; then
    ok "dsh-terminal-bash 已打补丁"
  else
    fail "sed 未生效——dsh 代码结构可能已变，请人工检查 $F"
  fi
fi

# ---------- 10. sharp WASM（attachment-local 依赖 sharp，android-arm64 无原生二进制） ----------
log "10/11 补装 sharp WASM (@img/sharp-wasm32 + @emnapi)"
SHARP_DIR="$DSH_NM/sharp"
WASM_SRC="$HOME_DIR/sharp-wasm/node_modules"
if [ ! -d "$SHARP_DIR" ]; then
  ok "当前 dsh 未依赖 sharp，跳过"
else
  SHARP_VER=$(pkg_ver "$SHARP_DIR")
  if [ -z "$SHARP_VER" ]; then
    fail "无法读取 sharp 版本（$SHARP_DIR）"
  else
    INSTALLED_VER=$(pkg_ver "$DSH_NM/@img/sharp-wasm32")
    if [ -n "$INSTALLED_VER" ] && [ "$INSTALLED_VER" = "$SHARP_VER" ]; then
      ok "sharp-wasm32 已就位（$SHARP_VER，跳过）"
    else
      SRC_VER=$(pkg_ver "$WASM_SRC/@img/sharp-wasm32")
      if [ -z "$SRC_VER" ] || [ "$SRC_VER" != "$SHARP_VER" ]; then
        log "  在 ~/sharp-wasm 安装 @img/sharp-wasm32@$SHARP_VER ..."
        mkdir -p "$HOME_DIR/sharp-wasm"
        (
          cd "$HOME_DIR/sharp-wasm" || exit 1
          [ -f package.json ] || npm init -y >/dev/null 2>&1
          NODE_OPTIONS="-r $HOME_DIR/dsh-link-fix.js" npm install "@img/sharp-wasm32@$SHARP_VER" >/dev/null 2>&1
        )
      fi
      if [ -d "$WASM_SRC/@img/sharp-wasm32" ]; then
        mkdir -p "$DSH_NM/@img"
        cp -r "$WASM_SRC/@img/sharp-wasm32" "$DSH_NM/@img/"
        [ -d "$WASM_SRC/@emnapi" ] && cp -r "$WASM_SRC/@emnapi" "$DSH_NM/"
        if ( cd "$DSH_ROOT" && node -e "import('sharp').then(()=>process.exit(0)).catch(()=>process.exit(1))" ) >/dev/null 2>&1; then
          ok "sharp-wasm32 + emnapi 已拷入，sharp 可加载"
        else
          fail "已拷入但 sharp 仍无法加载，请检查 $DSH_NM/@img/"
        fi
      else
        fail "sharp-wasm32 源缺失（$WASM_SRC/@img/sharp-wasm32），检查网络后重跑"
      fi
    fi
  fi
fi

# ---------- 11. SameSite Strict → Lax（外部 intent 打开浏览器时携带 cookie） ----------
log "11/11 补丁 dsh-client-connection (SameSite Strict→Lax)"
F="$DSH_NM/@deepseek-ai/dsh-client-connection/lib/index.js"
if [ ! -f "$F" ]; then
  fail "找不到 $F"
elif grep -q "SameSite=Lax" "$F"; then
  ok "dsh-client-connection 已打补丁（跳过）"
elif grep -q "SameSite=Strict" "$F"; then
  [ -f "$F.bak" ] || cp "$F" "$F.bak"
  sed -i 's/SameSite=Strict/SameSite=Lax/' "$F"
  if grep -q "SameSite=Lax" "$F"; then
    ok "dsh-client-connection 已打补丁"
  else
    fail "sed 未生效，请人工检查 $F"
  fi
else
  fail "未找到 SameSite 属性——dsh 版本可能已变，请人工检查 $F"
fi

# ============ 自检 ============
echo "================================================"
echo " 自检结果"
echo "================================================"

c=0
TOTAL=11
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
check "~/.npmrc (registry)"            grep -q "npmmirror" "$HOME_DIR/.npmrc"
check "~/.npmrc (foreground-scripts)"  grep -q "foreground-scripts" "$HOME_DIR/.npmrc"
check "~/.bashrc (PATH)"               grep -q "HOME/bin" "$HOME_DIR/.bashrc"
check "~/dsh-link-fix.js"              test -f "$HOME_DIR/dsh-link-fix.js"
check "~/bin/dsh (可执行)"             test -x "$HOME_DIR/bin/dsh"
check "~/bin/bwrap-proot (可执行)"     test -x "$HOME_DIR/bin/bwrap-proot"
check "cordis.patch.yml (runnerCommand)" grep -q "runnerCommand" "$PATCH_YML"
check "subprocess-local (android)"     grep -q 'platform === "linux" || platform === "android"' "$DSH_NM/@deepseek-ai/dsh-subprocess-local/lib/index.js"
check "terminal-bash (shellPath)"      grep -Eq "DEFAULT_BASH_SHELL = \"$BASH_PATH\"|default\(\"$BASH_PATH\"\)" "$DSH_NM/@deepseek-ai/dsh-terminal-bash/lib/index.js"
check "client-connection (SameSite)"   grep -q "SameSite=Lax" "$DSH_NM/@deepseek-ai/dsh-client-connection/lib/index.js"

# sharp 自检只在 dsh 确实依赖 sharp 时计入
if [ -d "$SHARP_DIR" ]; then
  TOTAL=$((TOTAL+1))
  check "sharp-wasm32 (已就位)"        test -d "$DSH_NM/@img/sharp-wasm32"
else
  echo "  [SKIP] sharp-wasm32（当前 dsh 未依赖 sharp）"
fi

echo "================================================"
echo " 完成：$c / $TOTAL 项通过"
echo ""
echo " 说明："
echo "   - 第 8、9、11 项为包级 sed 修改，首次执行会自动备份 .bak"
echo "   - npm 更新 dsh 后，包级补丁会被覆盖，请重新运行本脚本"
echo "   - 第 10 项会自动匹配当前 sharp 版本并复用 ~/sharp-wasm 缓存"
echo "   - 打完补丁后，用 'dsh web' 启动（建议先 cd ~/workspace）"
echo "================================================"