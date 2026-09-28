#!/data/data/com.termux/files/usr/bin/bash
# ============================================================================
# apply-dsh-patches.sh —— Termux 部署 DeepSeek Harness (dsh) 一键补丁
#
# 作用：固化从最初安装到现在遇到的所有问题修复，一次跑完全部生效。
# 特性：幂等（可重复运行）、改包自动备份 .bak、跑完自检、sed 失败会报 FAIL。
# 用法：bash apply-dsh-patches.sh
#
# 包级补丁不写死 lib/index.js，而是按「特征字符串」动态定位目标文件：dsh 会把
# 代码拆进 lib/runner-launch-<hash>.js 这类哈希命名的 chunk（hash 每次发版都
# 变），写死路径必然失效。sed 同时兼容单引号 / 双引号两种写法。
#
# 覆盖 12 项必选修复：
#   1. ~/.gyp/include.gypi          —— node-pty 编译的 android_ndk_path
#   2. ~/.npmrc                     —— npm 镜像（npmmirror + foreground-scripts）
#   3. ~/.bashrc                    —— PATH 含 ~/bin（dsh 命令可找到）
#   4. ~/dsh-link-fix.js            —— f2fs 禁硬链接的 fs.link fallback
#   5. ~/bin/dsh                    —— wrapper：--expose-internals + preload + 权限模式
#   6. ~/bin/bwrap-proot            —— bwrap→proot + PATH + /bin/bash 替换
#   7. cordis.patch.yml             —— sandbox runnerCommand + terminal-bash shellPath
#   8. dsh-subprocess-local         —— terminal inspection 的 android 兼容（动态 sed）
#   9. dsh-terminal-bash            —— shellPath 默认值 /bin/bash → PREFIX（动态 sed）
#  10. sharp WASM                   —— @img/sharp-wasm32 + @emnapi（attachment-local）
#  11. dsh-client-connection        —— SameSite Strict → Lax（自动开浏览器可认证）
#  12. node-addon-require-builtin   —— Android 无原生 binding，改用 --expose-internals 的 JS 实现
# ============================================================================

PREFIX="/data/data/com.termux/files/usr"
HOME_DIR="/data/data/com.termux/files/home"
DSH_ROOT="$PREFIX/lib/node_modules/@deepseek-ai/dsh"
DSH_NM="$DSH_ROOT/node_modules"
BASH_PATH="$PREFIX/bin/bash"

log()  { echo "[patch] $*"; }
ok()   { echo "  [OK]   $*"; }
fail() { echo "  [FAIL] $*"; }
skip() { echo "  [SKIP] $*"; }

# 读取某个已安装 npm 包的版本号（不存在则输出空字符串）
pkg_ver() { node -p "require('$1/package.json').version" 2>/dev/null; }

echo "================================================"
echo " dsh Termux 一键补丁 (12 项必选)"
echo "================================================"

# ---------- 前置检查：dsh 主程序是否已安装 ----------
if [ ! -d "$DSH_ROOT" ]; then
  echo "  [警告] 未检测到 dsh 主程序："
  echo "         $DSH_ROOT"
  echo "         请先执行：npm install -g @deepseek-ai/dsh"
  echo "         然后重新运行本脚本。"
  exit 1
fi
echo " 检测到 dsh 版本：$(pkg_ver "$DSH_ROOT")"
echo ""

# ---------- 1. gyp：node-pty 编译的 android_ndk_path ----------
log "1/12 写入 ~/.gyp/include.gypi (node-pty 编译修复)"
mkdir -p "$HOME_DIR/.gyp"
if grep -q "android_ndk_path" "$HOME_DIR/.gyp/include.gypi" 2>/dev/null; then
  ok "~/.gyp/include.gypi（已存在，跳过）"
else
  echo "{'variables':{'android_ndk_path':''}}" > "$HOME_DIR/.gyp/include.gypi"
  ok "~/.gyp/include.gypi"
fi

# ---------- 2. npm 镜像 ----------
log "2/12 配置 ~/.npmrc (npmmirror 镜像)"
touch "$HOME_DIR/.npmrc"
grep -q '^registry=' "$HOME_DIR/.npmrc" || echo 'registry=https://registry.npmmirror.com' >> "$HOME_DIR/.npmrc"
grep -q '^foreground-scripts=' "$HOME_DIR/.npmrc" || echo 'foreground-scripts=true' >> "$HOME_DIR/.npmrc"
ok "~/.npmrc"

# ---------- 3. PATH ----------
log "3/12 配置 ~/.bashrc (PATH 含 ~/bin)"
touch "$HOME_DIR/.bashrc"
# 仅清理会导致 HMR 报错的历史 NODE_OPTIONS，保留你自己设置的其它 NODE_OPTIONS
[ -f "$HOME_DIR/.bashrc.bak" ] || cp "$HOME_DIR/.bashrc" "$HOME_DIR/.bashrc.bak"
sed -i '/NODE_OPTIONS.*expose-internals/d' "$HOME_DIR/.bashrc"
grep -q 'HOME/bin' "$HOME_DIR/.bashrc" || echo 'export PATH=$HOME/bin:$PATH' >> "$HOME_DIR/.bashrc"
ok "~/.bashrc"

# ---------- 4. fs.link fallback preload ----------
log "4/12 写入 ~/dsh-link-fix.js (f2fs 硬链接 fallback)"
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
log "5/12 写入 ~/bin/dsh (--expose-internals + preload + 权限模式)"
mkdir -p "$HOME_DIR/bin"
cat > "$HOME_DIR/bin/dsh" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
export DSH_PERMISSION_MODE="${DSH_PERMISSION_MODE:-danger-full-access}"
exec node --expose-internals -r /data/data/com.termux/files/home/dsh-link-fix.js /data/data/com.termux/files/usr/lib/node_modules/@deepseek-ai/dsh/lib/bin.js "$@"
EOF
chmod +x "$HOME_DIR/bin/dsh"
ok "~/bin/dsh"

# ---------- 6. bwrap-proot ----------
log "6/12 写入 ~/bin/bwrap-proot (bwrap→proot + PATH + /bin/bash 替换)"
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
log "7/12 写入 ~/.dsh/profiles/web/cordis.patch.yml (runnerCommand + shellPath)"
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

# ---------- 8. subprocess-local：terminal inspection 的 android 兼容 ----------
# dsh 0.1.5+ 把 createProcessInspector 拆进 lib/runner-launch-<hash>.js（hash 每次发版都变），
# 因此这里按特征字符串「new LinuxProcessInspector」动态定位文件，绝不写死文件名。
log "8/12 补丁 dsh-subprocess-local (terminal inspection android)"
SB_ROOT="$DSH_NM/@deepseek-ai/dsh-subprocess-local"
if [ ! -d "$SB_ROOT" ]; then
  skip "dsh-subprocess-local 未安装（跳过）"
else
  sb_files=$(grep -rlF --exclude='*.bak' "new LinuxProcessInspector" "$SB_ROOT/lib" 2>/dev/null)
  if [ -z "$sb_files" ]; then
    fail "未找到含 LinuxProcessInspector 的文件——dsh 结构可能已变，请人工检查 $SB_ROOT/lib"
  else
    sb_hit=0
    for f in $sb_files; do
      if grep -qE 'platform === .android.' "$f"; then
        sb_hit=$((sb_hit+1)); continue
      fi
      [ -f "$f.bak" ] || cp "$f" "$f.bak"
      # 双引号写法（当前版本）
      sed -i 's/if (platform === "linux") return new LinuxProcessInspector/if (platform === "linux" || platform === "android") return new LinuxProcessInspector/' "$f"
      # 单引号写法（旧版本）
      sed -i "s/if (platform === 'linux') return new LinuxProcessInspector/if (platform === 'linux' || platform === 'android') return new LinuxProcessInspector/" "$f"
      grep -qE 'platform === .android.' "$f" && sb_hit=$((sb_hit+1))
    done
    if [ "$sb_hit" -gt 0 ]; then
      ok "dsh-subprocess-local 已打补丁（$sb_hit 个文件）"
    else
      fail "sed 未生效——dsh 代码结构可能已变，请人工检查 $SB_ROOT/lib"
    fi
  fi
fi

# ---------- 9. terminal-bash：shellPath 默认值 ----------
# 同样动态定位（谁含旧的 /bin/bash 默认值就改谁），兼容 rc.6 旧写法与 rc.7+ 新写法。
log "9/12 补丁 dsh-terminal-bash (shellPath 默认值)"
TB_ROOT="$DSH_NM/@deepseek-ai/dsh-terminal-bash"
if [ ! -d "$TB_ROOT" ]; then
  skip "dsh-terminal-bash 未安装（跳过）"
elif grep -rqF --exclude='*.bak' "$BASH_PATH" "$TB_ROOT/lib" 2>/dev/null; then
  ok "dsh-terminal-bash 已打补丁（跳过）"
else
  tb_files=$(grep -rlE --exclude='*.bak' 'DEFAULT_BASH_SHELL = "/bin/bash"|default\("/bin/bash"\)' "$TB_ROOT/lib" 2>/dev/null)
  if [ -z "$tb_files" ]; then
    fail "未找到 shellPath 的 /bin/bash 默认值——dsh 结构可能已变，请人工检查 $TB_ROOT/lib"
  else
    tb_hit=0
    for f in $tb_files; do
      [ -f "$f.bak" ] || cp "$f" "$f.bak"
      # rc.6 旧写法：shellPath: z.string().default("/bin/bash")
      sed -i 's|shellPath: z.string().default("/bin/bash")|shellPath: z.string().default("'"$BASH_PATH"'")|' "$f"
      # rc.7+ 新写法：const DEFAULT_BASH_SHELL = "/bin/bash";
      sed -i 's|const DEFAULT_BASH_SHELL = "/bin/bash";|const DEFAULT_BASH_SHELL = "'"$BASH_PATH"'";|' "$f"
      grep -qF "$BASH_PATH" "$f" && tb_hit=$((tb_hit+1))
    done
    if [ "$tb_hit" -gt 0 ]; then
      ok "dsh-terminal-bash 已打补丁（$tb_hit 个文件）"
    else
      fail "sed 未生效——dsh 代码结构可能已变，请人工检查 $TB_ROOT/lib"
    fi
  fi
fi

# ---------- 10. sharp WASM（attachment-local 依赖 sharp，android-arm64 无原生二进制） ----------
log "10/12 补装 sharp WASM (@img/sharp-wasm32 + @emnapi)"
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
# 认证逻辑在 0.1.2 搬到了 browser-auth.ts，但会被打包进 lib/index.js；这里依然动态定位，
# 以防未来再次拆包。
log "11/12 补丁 dsh-client-connection (SameSite Strict→Lax)"
CC_ROOT="$DSH_NM/@deepseek-ai/dsh-client-connection"
if [ ! -d "$CC_ROOT" ]; then
  skip "dsh-client-connection 未安装（跳过）"
elif grep -rqF --exclude='*.bak' "SameSite=Lax" "$CC_ROOT/lib" 2>/dev/null; then
  ok "dsh-client-connection 已打补丁（跳过）"
else
  cc_files=$(grep -rlF --exclude='*.bak' "SameSite=Strict" "$CC_ROOT/lib" 2>/dev/null)
  if [ -z "$cc_files" ]; then
    fail "未找到 SameSite=Strict——dsh 版本可能已变，请人工检查 $CC_ROOT/lib"
  else
    for f in $cc_files; do
      [ -f "$f.bak" ] || cp "$f" "$f.bak"
      sed -i 's/SameSite=Strict/SameSite=Lax/' "$f"
    done
    if grep -rqF --exclude='*.bak' "SameSite=Lax" "$CC_ROOT/lib" 2>/dev/null; then
      ok "dsh-client-connection 已打补丁"
    else
      fail "sed 未生效，请人工检查 $CC_ROOT/lib"
    fi
  fi
fi

# ---------- 12. node-addon-require-builtin：Android 无原生 binding ----------
# 官方只发布了 darwin / linux-x64 / linux-arm64-gnu / win32 预编译产物，没有 android-arm64，
# 且源码未公开、无法本地编译。这里用纯 JS 实现替代：通过 --expose-internals 直接访问同一批
# Node 内部模块（与原生 addon 拿到的是同一个模块实例），dsh 的模块解析拦截因此可正常工作。
log "12/12 补丁 node-addon-require-builtin (Android 无原生 binding，改用 --expose-internals)"
NA_ROOT="$DSH_NM/node-addon-require-builtin"
NA_FILE="$NA_ROOT/lib/index.js"
if [ ! -f "$NA_FILE" ]; then
  skip "node-addon-require-builtin 未安装（跳过）"
elif grep -q "js-expose-internals" "$NA_FILE" 2>/dev/null; then
  ok "node-addon-require-builtin 已替换为 JS 实现（跳过）"
elif ! node --expose-internals -e "require('internal/modules/esm/loader')" >/dev/null 2>&1; then
  fail "当前 Node 不支持 --expose-internals，JS 兜底无法生效（请确认用 ~/bin/dsh 启动）"
else
  [ -f "$NA_FILE.bak" ] || cp "$NA_FILE" "$NA_FILE.bak"
  cat > "$NA_FILE" <<'EOF_JS'
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
// Android/Termux JS fallback：官方原生 addon 无 android-arm64 预编译产物，
// 改用 --expose-internals 直接访问同一批 Node 内部模块（与原生版是同一批对象）。
function requireBuiltin(moduleId) {
  return require(moduleId);
}
function isAllowedInternalId(moduleId) {
  try { require.resolve(moduleId); return true; } catch (_e) { return false; }
}
function getBindingInfo() {
  return {
    backend: 'js-expose-internals',
    abi: 'napi-v9',
    platform: process.platform,
    arch: process.arch,
    node: process.version,
  };
}
exports.requireBuiltin = requireBuiltin;
exports.isAllowedInternalId = isAllowedInternalId;
exports.getBindingInfo = getBindingInfo;
exports.default = { requireBuiltin, isAllowedInternalId, getBindingInfo };
EOF_JS
  if grep -q "js-expose-internals" "$NA_FILE" \
     && node --expose-internals -e "const m=require('$NA_ROOT'); if(typeof m.requireBuiltin('internal/modules/cjs/loader').Module!=='function')process.exit(1)" >/dev/null 2>&1; then
    ok "node-addon-require-builtin 已替换为 JS 实现，可加载 Node 内部模块"
  else
    fail "替换后校验失败，请人工检查 $NA_FILE"
  fi
fi

# ============ 自检 ============
echo "================================================"
echo " 自检结果"
echo "================================================"

c=0
TOTAL=12

check() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "  [OK]   $desc"
    c=$((c+1))
  else
    echo "  [FAIL] $desc"
  fi
}

# 包级补丁自检：包/目录不存在时 [SKIP]，并且不计入总数
check_pkg() {
  local desc="$1" dir="$2" pat="$3"
  if [ ! -d "$dir" ]; then
    skip "$desc（包未安装）"
    TOTAL=$((TOTAL-1))
    return
  fi
  if grep -rqE --exclude='*.bak' -- "$pat" "$dir/lib" 2>/dev/null; then
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
check_pkg "subprocess-local (android)"    "$DSH_NM/@deepseek-ai/dsh-subprocess-local" 'platform === .android.'
check_pkg "terminal-bash (shellPath)"     "$DSH_NM/@deepseek-ai/dsh-terminal-bash"      "$BASH_PATH"
check_pkg "client-connection (SameSite)"  "$DSH_NM/@deepseek-ai/dsh-client-connection"  "SameSite=Lax"
check_pkg "require-builtin (JS fallback)"  "$DSH_NM/node-addon-require-builtin"  "js-expose-internals"

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
echo "   - 第 8、9、11、12 项为包级修改，首次执行会自动备份 .bak"
echo "   - 包级补丁按「特征字符串」动态定位文件，适配 dsh 拆包 / 改 hash 名"
echo "   - npm 更新 dsh 后，包级补丁会被覆盖，请重新运行本脚本"
echo "   - 第 10 项会自动匹配当前 sharp 版本并复用 ~/sharp-wasm 缓存"
echo "   - 打完补丁后，用 'dsh web' 启动（建议先 cd ~/workspace）"
