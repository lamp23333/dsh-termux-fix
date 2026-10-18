#!/data/data/com.termux/files/usr/bin/bash
# ============================================================================
# apply-dsh-patches.sh —— Termux 部署 DeepSeek Harness (dsh) 一键补丁
#
# 作用：固化从最初安装到现在遇到的所有问题修复，一次跑完全部生效。
# 特性：幂等（可重复运行）、改包自动备份 .bak、跑完自检、sed 失败会报 FAIL。
# 用法：bash apply-dsh-patches.sh [命令]
#        无参数 = help（使用说明）；看状态用 status
#
# 包级补丁不写死 lib/index.js，而是按「特征字符串」动态定位目标文件：dsh 会把
# 代码拆进 lib/runner-launch-<hash>.js 这类哈希命名的 chunk（hash 每次发版都
# 变），写死路径必然失效。sed 同时兼容单引号 / 双引号两种写法。
#
# 覆盖 14 项必选修复：
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
#  13. node-addon-system            —— flock 的 android-arm64（本地编译 system.node + 放开平台守卫）
#  14. dsh-attachment-local         —— Android 附件目录 fsync 权限容错（贴图发不出去）
# ============================================================================

# ---- 环境定位 --------------------------------------------------------------
# PREFIX / HOME 优先取环境变量，但必须通过校验才采用：
#   1. 非空且为绝对路径
#   2. 形如 <root>/com.termux/files/usr（HOME 同理 .../files/home）
#   3. $PREFIX/bin/bash 真实存在且可执行
# 任一不满足就回退 Termux 官方默认路径——避免被无关的 PREFIX / HOME 污染
# （例如某些构建脚本 export PREFIX=/usr/local，或 proot 里 PREFIX=/usr）。
_TERMUX_PREFIX="/data/data/com.termux/files/usr"
_TERMUX_HOME="/data/data/com.termux/files/home"

_prefix_ok() { # $1=候选 prefix
  [ -n "$1" ] || return 1
  case "$1" in /*) ;; *) return 1 ;; esac
  case "$1" in */com.termux/files/usr) ;; *) return 1 ;; esac
  [ -d "$1" ] && [ -x "$1/bin/bash" ] || return 1
}

_home_ok() { # $1=候选 HOME
  [ -n "$1" ] || return 1
  case "$1" in /*) ;; *) return 1 ;; esac
  case "$1" in */com.termux/files/home) ;; *) return 1 ;; esac
  [ -d "$1" ] || return 1
}

if _prefix_ok "${PREFIX-}"; then :; else PREFIX="$_TERMUX_PREFIX"; fi
# 是否真的位于 Termux：只允许只读命令在非 Termux 下运行（help / status / doctor / channels），
# 其余会写路径的命令在命令分发处拦截，避免往错误的位置写文件。
TERMUX_OK=1
if [ ! -x "$PREFIX/bin/bash" ]; then
  TERMUX_OK=0
fi
_p_root="${PREFIX%/com.termux/files/usr}"   # 已校验，必带该后缀
# HOME 必须与 PREFIX 同根（同一个 Termux 安装），否则以 PREFIX 推导，保证自洽
if _home_ok "${HOME-}" && [ "${HOME%/com.termux/files/home}" = "$_p_root" ]; then
  HOME_DIR="$HOME"
else
  HOME_DIR="$_p_root/com.termux/files/home"
fi
export PREFIX                       # 子进程（node / npm）与脚本用同一套路径
if [ "$TERMUX_OK" -eq 1 ]; then
  export HOME="$HOME_DIR"
fi
DSH_ROOT="$PREFIX/lib/node_modules/@deepseek-ai/dsh"
DSH_NM="$DSH_ROOT/node_modules"
BASH_PATH="$PREFIX/bin/bash"

log()  { emit_pre "[patch] " "$*"; }
ok()   { emit_state "[OK]"   "$C_OK"   "$*"; }
fail() { emit_state "[FAIL]" "$C_BAD"  "$*"; }
skip() { emit_state "[SKIP]" "$C_WARN" "$*"; }

# 读取某个已安装 npm 包的版本号（不存在则输出空字符串）
pkg_ver() { node -p "require('$1/package.json').version" 2>/dev/null; }

# ============================================================================
# 统一入口层：命令解析 / 环境体检 / 阶段判定
#
#   bash apply-dsh-patches.sh            → status（只读体检，不改文件）
#   bash apply-dsh-patches.sh status     → 只体检并告知处于哪个阶段
#   bash apply-dsh-patches.sh doctor     → 体检 + 列出判定依据
#   bash apply-dsh-patches.sh patch      → 只打补丁
#   bash apply-dsh-patches.sh install    → 安装 dsh 本体（安装器阶段 1~2）
#   bash apply-dsh-patches.sh all        → 安装 + 打补丁
#   bash apply-dsh-patches.sh all        → 从零到可用（三阶段全跑）
#   bash apply-dsh-patches.sh channels   → 查询 npm 三个频道当前版本
#   bash apply-dsh-patches.sh help       → 帮助
#
# 阶段判定（依赖 / 本体 / 补丁 三层）：
#   阶段 0  环境未就绪——缺系统依赖或编译工具链
#   阶段 1  dsh 本体尚未安装
#   阶段 2  dsh 已安装，但补丁未齐
#   阶段 3  已就绪，可直接启动
# ============================================================================

CMD="${1:-help}"
[ $# -gt 0 ] && shift
ARGS=("$@")

SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
NS_ROOT="$DSH_NM/@deepseek-ai/node-addon-system"

# 颜色（仅终端输出时启用，重定向到文件/管道自动关掉）
C_OK=""; C_WARN=""; C_BAD=""; C_RST=""
if [ -t 1 ]; then
  C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_BAD=$'\033[31m'; C_RST=$'\033[0m'
fi
# ---- 终端宽度 / 折行：长行折回时让开状态标签的宽度 ----
_hwrap() {   # stdin：逐行；两列行（行首 2 空格）续行让开标签列（14）
  local ln
  while IFS= read -r ln; do
    case "$ln" in
      '') printf '\n' ;;
      "  "*) emit_info "" "$ln" 16 ;;
      *) emit_info "" "$ln" 0 ;;
    esac
  done
}

# 路径大小（不存在 → "（元数据未知）"）
_sz() {
  local f="$1"
  [ -e "$f" ] || { printf '（不存在）'; return 0; }
  local v=""; v="$(du -sh --apparent-size "$f" 2>/dev/null | cut -f1)"
  [ -n "$v" ] || v="$(du -sh "$f" 2>/dev/null | cut -f1)"   # 老 du 不支持 --apparent-size 时回退
  case "$v" in ''|*[!0-9]*) ;; *) v="${v}B" ;; esac   # 小于 1K 时 du 不带单位，补个 B
  printf '%s' "${v:-?}"
}

# 多路径合计大小（模仿 du -h 的取整规则）
_szs() {
  local total=0 f v t
  for f in "$@"; do
    [ -e "$f" ] || continue
    v="$(du -sb --apparent-size "$f" 2>/dev/null | cut -f1)"
    case "$v" in ''|*[!0-9]*) continue ;; esac
    total=$((total + v))
  done
  if   [ "$total" -lt 1024 ]; then printf '%dB' "$total"
  elif [ "$total" -lt 10240 ]; then t=$(( (total * 10 + 512) / 1024 )); printf '%d.%dK' $((t / 10)) $((t % 10))
  elif [ "$total" -lt 1048576 ]; then printf '%dK' $(( (total + 512) / 1024 ))
  elif [ "$total" -lt 10485760 ]; then t=$(( (total * 10 + 524288) / 1048576 )); printf '%d.%dM' $((t / 10)) $((t % 10))
  elif [ "$total" -lt 1073741824 ]; then printf '%dM' $(( (total + 524288) / 1048576 ))
  else t=$(( (total * 10 + 536870912) / 1073741824 )); printf '%d.%dG' $((t / 10)) $((t % 10)); fi
}

_tw() {   # 终端列数：stty/tput 从 /dev/tty 实测，结果本次运行内缓存
  [ -n "${TW_OVERRIDE:-}" ] && { printf '%s\n' "$TW_OVERRIDE"; return 0; }
  [ -n "${_TW_CACHE:-}" ] && { printf '%s\n' "$_TW_CACHE"; return 0; }
  local w=0 s
  s="$(stty size 2>/dev/null </dev/tty || true)"
  case "$s" in *' '*) w="${s#* }" ;; esac
  case "$w" in ''|*[!0-9]*) w=0 ;; esac
  if [ "$w" -le 0 ]; then
    s="$(tput cols 2>/dev/null </dev/tty || true)"
    case "$s" in ''|*[!0-9]*) s=0 ;; esac
    [ "$s" -gt 0 ] && w="$s"
  fi
  if [ "$w" -le 0 ]; then w="${COLUMNS:-0}"; fi
  case "$w" in ''|*[!0-9]*) w=0 ;; esac
  [ "$w" -le 0 ] && w=80
  [ "$w" -lt 24 ] && w=80
  _TW_CACHE="$w"
  printf '%s\n' "$w"
}

_wrap() {   # $1=可用宽度；stdin 文本；按显示宽度折行（中文计 2 列，不切断英文单词）
  local w="$1"
  LC_ALL=C awk -v W="$w" -v W2="${2:-$w}" '
  BEGIN{ for(i=1;i<256;i++) T[sprintf("%c",i)]=i }
  {
    str=$0; n=length(str); lim=W; buf=""; col=0; bplit=0; bpcol=0; emitted=0
    if(n==0){ print ""; emitted=1; next }
    i=1
    while(i<=n){
      c=substr(str,i,1); b=T[c]; step=1; w2=1
      if(b==27){   # ANSI 颜色序列：原样保留，但不计宽度
        j=i+1
        while(j<=n && substr(str,j,1)!="m"){ j++ }
        buf=buf substr(str,i,j-i+1)
        i=j+1
        continue
      }
      if(b>=240){ w2=2; step=4 }
      else if(b>=224){ w2=2; step=3 }
      else if(b>=192){ w2=2; step=2 }
      if(col+w2>lim && col>0 && (i+step-1)<n){
        if(bplit>0 && bplit<length(buf) && (col-bpcol)<=lim*4/10){
          print substr(buf,1,bplit); emitted=1
          rem=substr(buf,bplit+1); sp=0
          while(substr(rem,1,1)==" "){ rem=substr(rem,2); sp++ }
          buf=rem; col=col-bpcol-sp; lim=W2
        } else { print buf; buf=""; col=0; emitted=1 }
        bplit=0; bpcol=0
      }
      if(c==" " && col==0 && emitted>0){ i+=step; continue }   # 续行行首不留空格
      buf=buf substr(str,i,step); col+=w2
      if(c==" "){ bplit=length(buf)-1; bpcol=col-1 }
      else if(b>=192){ bplit=length(buf); bpcol=col }
      i+=step
    }
    if(col>0) print buf
  }'
}

emit_state() {   # $1 标签 $2 颜色 $3 文本 $4 缩进（默认 1 空格）
  local tag="$1" col="$2" txt="$3" ind="${4:- }"
  local w pad avail first=1 ln gap
  w="$(_tw)"
  gap="$(printf '%*s' $(( 7 - ${#tag} )) '')"
  [ "${#tag}" -ge 7 ] && gap=" "
  pad="$ind$(printf '%*s' $(( ${#tag} + ${#gap} )) '')"
  avail=$(( w - ${#ind} - ${#tag} - ${#gap} - 1 ))
  [ "$avail" -lt 16 ] && avail=$(( w - ${#ind} ))
  while IFS= read -r ln; do
    case "$ln" in *[![:space:]]*) ;; *) continue ;; esac
    if [ "$first" -eq 1 ]; then
      printf '%s%s%s%s%s%s\n' "$ind" "$col" "$tag" "$C_RST" "$gap" "$ln"; first=0
    else
      printf '%s%s\n' "$pad" "$ln"
    fi
  done <<EOF
$(printf '%s' "$txt" | _wrap "$avail")
EOF
}

emit_pre() {   # $1 前缀 $2 文本：首行带前缀，续行用等宽空格让开
  local pre="$1" txt="$2" w avail1 avail2 ln first=1 pad
  pad="$(printf '%*s' ${#pre} '')"
  w="$(_tw)"; avail1=$(( w - ${#pre} - 1 )); avail2=$(( w - ${#pad} - 1 ))
  [ "$avail1" -lt 16 ] && avail1=$(( w - 8 ))
  [ "$avail2" -lt 16 ] && avail2=$(( w - 8 ))
  while IFS= read -r ln; do
    case "$ln" in *[![:space:]]*) ;; *) continue ;; esac
    if [ "$first" -eq 1 ]; then printf '%s%s\n' "$pre" "$ln"; first=0
    else printf '%s%s\n' "$pad" "$ln"; fi
  done <<EOF
$(printf '%s' "$txt" | _wrap "$avail1" "$avail2")
EOF
}

emit_info() {   # $1 缩进 $2 文本 $3 悬挂宽度（续行让开前缀）
  local ind="$1" txt="$2" hang="${3:-0}" w avail ln ind2 first=1
  ind2="$ind$(printf '%*s' "$hang" '')"
  local avail1 avail2
  w="$(_tw)"; avail1=$(( w - ${#ind} - 1 )); avail2=$(( w - ${#ind2} - 1 ))
  [ "$avail1" -lt 16 ] && avail1=$(( w - 8 ))
  [ "$avail2" -lt 16 ] && avail2=$(( w - 8 ))
  while IFS= read -r ln; do
    case "$ln" in *[![:space:]]*) ;; *) continue ;; esac
    if [ "$first" -eq 1 ]; then printf '%s%s\n' "$ind" "$ln"; first=0
    else printf '%s%s\n' "$ind2" "$ln"; fi
  done <<EOF
$(printf '%s' "$txt" | _wrap "$avail1" "$avail2")
EOF
}

emit_plist() {   # 逐条打印补丁项（OK<TAB>desc / MISS<TAB>desc）
  local line st desc
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    st="${line%%$'\t'*}"
    desc="${line#*$'\t'}"
    case "$st" in
      OK)   emit_state "[OK]"   "$C_OK"  "$desc" "  " ;;
      MISS) emit_state "[MISS]" "$C_BAD" "$desc" "  " ;;
      *)    emit_info "  " "$line" ;;
    esac
  done <<EOF
$P_LIST
EOF
}

s_ok()   { emit_state "[OK]"   "$C_OK"   "$*" ; }
s_warn() { emit_state "[WARN]" "$C_WARN" "$*" ; }
s_bad()  { emit_state "[MISS]" "$C_BAD"  "$*" ; }
s_info() { emit_info "         " "$*"; }
tagok()   { printf '%s' "$C_OK$1$C_RST"; }
tagbad()  { printf '%s' "$C_BAD$1$C_RST"; }
tagwarn() { printf '%s' "$C_WARN$1$C_RST"; }
havec()  { command -v "$1" >/dev/null 2>&1; }
pkgok()  { dpkg -s "$1" >/dev/null 2>&1; }
bar()    { local n; n=$(( ${1:-$(_tw)} - 1 )); [ "$n" -lt 24 ] && n=24; printf "%*s\n" "$n" "" | tr ' ' '='; }

usage() {
  local WR WT OC OTW
  WR="$(_tw)"                             # 真实终端宽度：框线用它
  WT="$WR"; [ "$WT" -gt 72 ] && WT=72      # 正文最宽 72 列，避免长行难读
  OC="${COLUMNS:-}"; OTW="${TW_OVERRIDE:-}"
  export COLUMNS="$WT"; export TW_OVERRIDE="$WT"
  bar "$WR"
  echo " dsh-termux-fix 使用说明"
  bar "$WR"
  cat <<'USAGE' | _hwrap
用法：bash apply-dsh-patches.sh [命令] [选项]

命令
  status        显示环境状态
  doctor        显示环境状态详细报告
  patch         仅安装补丁
  install       仅安装 DeepSeek Harness
  all           安装 DeepSeek Harness 与补丁
  channels      查询 DeepSeek Harness 最新版本
  backup        备份数据
  uninstall     卸载 DeepSeek Harness 与补丁
  help          显示本使用说明

选项
1. 适用于 install / all
  --next        安装 next 频道的最新版本
  --alpha       安装 alpha 频道的最新版本
  --ver=X.Y.Z   安装指定版本
  --scripts     尝试全量 install scripts（失败回退）
  -y, --yes     不弹出询问

2. 适用于 backup
  --all         全量备份（会话/配置/补丁/工作区）
  --sessions    只备份会话与配置（~/.dsh）
  --config      只备份配置文件（npm/终端/编译/网页端）
  --patches     只备份补丁产物（~/bin/dsh 等）
  --workspace   只备份工作区（~/workspace）
  --dest=路径   指定输出目录（默认 ~/dsh-backups）
  --list        列出可备份项与大小

3. 适用于 uninstall
  --only-patches 只卸补丁，保留 dsh 本体
  --only-dsh    只卸本体，保留补丁
  --keep-config 不动 .npmrc / .bashrc
  --purge-data  连 ~/.dsh 一起删（需输入 PURGE）
  --list        列出卸载范围
  --yes         不询问

4. 适用于 patch / install / all / backup / uninstall
  --dry-run     模拟运行
USAGE
  export COLUMNS="$OC"; export TW_OVERRIDE="$OTW"
  exit "${1:-0}"
}

case "$CMD" in
  -h|--help|help) usage ;;
esac

# ---------------------------------------------------------------------------
# 依赖探测
#   清单写成「命令:包名」——命令可用即视为满足。dpkg 名字与实际安装方式
#   经常对不上（例如 node 由 nodejs 包提供、ld 由 llvm 提供），只看 dpkg
#   会误报，误报又会导致 pkg install 去重装 node，风险很大。
# ---------------------------------------------------------------------------
DEPS_RUN="node:nodejs npm:nodejs bash:bash proot:proot sed:sed grep:grep tar:tar gzip:gzip diff:diffutils find:findutils cut:coreutils"
DEPS_BUILD="clang:clang make:make python:python pkg-config:pkg-config"
DEPS_MISS=""

deps_scan() {
  local pair cmd pk x dup
  DEPS_MISS=""
  for pair in $DEPS_RUN $DEPS_BUILD; do
    cmd="${pair%%:*}"
    pk="${pair##*:}"
    if havec "$cmd" || pkgok "$pk"; then continue; fi
    dup=0
    for x in $DEPS_MISS; do [ "$x" = "$pk" ] && dup=1; done
    [ "$dup" -eq 0 ] && DEPS_MISS="$DEPS_MISS $pk"
  done
  if ! havec ld && ! havec ld.lld && ! pkgok binutils; then
    DEPS_MISS="$DEPS_MISS binutils"
  fi
  DEPS_MISS="${DEPS_MISS# }"
}

# ---------------------------------------------------------------------------
# dsh 本体探测
# ---------------------------------------------------------------------------
DSH_VER=""
PTY_OK=0
SPAWN_OK=0
NDK_OK=0
SHARP_PKG=""

dsh_scan() {
  DSH_VER=""
  [ -d "$DSH_ROOT" ] && DSH_VER="$(pkg_ver "$DSH_ROOT")"

  PTY_OK=0
  if [ -d "$DSH_NM/node-pty" ]; then
    if ( cd "$DSH_ROOT" 2>/dev/null && node -e "const p=require('node-pty');if(typeof p.spawn!=='function')process.exit(1)" ) >/dev/null 2>&1; then
      PTY_OK=1
    fi
  fi

  SPAWN_OK=0
  [ -f "$DSH_NM/@deepseek-ai/dsh-subprocess-local/scripts/ensure-spawn-helper.mjs" ] && SPAWN_OK=1

  NDK_OK=0
  if [ -f "$HOME_DIR/.gyp/include.gypi" ] && grep -q android_ndk_path "$HOME_DIR/.gyp/include.gypi" 2>/dev/null; then
    NDK_OK=1
  fi

  SHARP_PKG=""
  [ -f "$DSH_NM/sharp/package.json" ] && SHARP_PKG="$(pkg_ver "$DSH_NM/sharp")"
}

# ---------------------------------------------------------------------------
# 补丁状态探测（只读）
# ⚠ 维护提醒：这里的判据与文件末尾「自检」段的 check / check_pkg 一一对应，
#   新增或修改补丁项时，两处必须同时改，否则 status 会误报阶段。
# ---------------------------------------------------------------------------
P_PASS=0
P_TOT=0
P_FAILED=""
P_LIST=""

_pc() {
  local desc="$1"; shift
  P_TOT=$((P_TOT+1))
  if "$@" >/dev/null 2>&1; then
    P_PASS=$((P_PASS+1))
    P_LIST="$P_LIST
OK	$desc"
  else
    P_FAILED="$P_FAILED
· $desc"
    P_LIST="$P_LIST
MISS	$desc"
  fi
}

patch_scan() {
  P_PASS=0; P_TOT=0; P_FAILED=""; P_LIST=""
  _pc "~/.gyp/include.gypi（node-pty 编译前置）"      grep -q android_ndk_path "$HOME_DIR/.gyp/include.gypi"
  _pc "~/.npmrc（registry 镜像）"                      grep -q npmmirror "$HOME_DIR/.npmrc"
  _pc "~/.npmrc（foreground-scripts）"                 grep -q foreground-scripts "$HOME_DIR/.npmrc"
  _pc "~/.bashrc（PATH 含 ~/bin）"                     grep -q "HOME/bin" "$HOME_DIR/.bashrc"
  _pc "~/dsh-link-fix.js（硬链接 fallback）"           test -f "$HOME_DIR/dsh-link-fix.js"
  _pc "~/bin/dsh（启动 wrapper）"                      test -x "$HOME_DIR/bin/dsh"
  _pc "~/bin/bwrap-proot（沙箱 runner）"               test -x "$HOME_DIR/bin/bwrap-proot"
  _pc "cordis.patch.yml（runnerCommand）"              grep -q runnerCommand "$HOME_DIR/.dsh/profiles/web/cordis.patch.yml"
  _pc "subprocess-local（android 终端检查）"           grep -rqE 'platform === .android.' "$DSH_NM/@deepseek-ai/dsh-subprocess-local/lib"
  _pc "terminal-bash（shellPath 指向 Termux bash）"    grep -rq "$BASH_PATH" "$DSH_NM/@deepseek-ai/dsh-terminal-bash/lib"
  _pc "client-connection（SameSite=Lax）"              grep -rq "SameSite=Lax" "$DSH_NM/@deepseek-ai/dsh-client-connection/lib"
  _pc "require-builtin（JS 实现）"                     grep -rq "js-expose-internals" "$DSH_NM/node-addon-require-builtin"
  _pc "attachment-local（附件 fsync 权限容错）"        grep -rq "dsh-android-sync-guard" "$DSH_NM/@deepseek-ai/dsh-attachment-local/lib"
  if [ -d "$NS_ROOT" ]; then
    _pc "flock android（产物 + 可获锁）"               node "$HOME_DIR/dsh-flock-check.mjs" "$NS_ROOT"
  fi
  if [ -d "$DSH_NM/sharp" ]; then
    _pc "sharp-wasm32（图片解码）"                     test -d "$DSH_NM/@img/sharp-wasm32"
  fi
}

# ---------------------------------------------------------------------------
# 阶段判定
# ---------------------------------------------------------------------------
stage_of() {
  if [ -n "$DEPS_MISS" ]; then echo "0"; return; fi
  if [ -z "$DSH_VER" ];   then echo "1"; return; fi
  if [ "$P_PASS" -lt "$P_TOT" ]; then echo "2"; return; fi
  echo "3"
}

stage_name() {
  case "$1" in
    0) echo "阶段 0 / 3  环境未就绪（系统依赖 / 工具链）" ;;
    1) echo "阶段 1 / 3  未安装 DeepSeek Harness" ;;
    2) echo "阶段 2 / 3  已安装 DeepSeek Harness，未安装补丁" ;;
    3) echo "阶段 3 / 3  全部准备就绪" ;;
    *) echo "未知阶段" ;;
  esac
}

# ---------------------------------------------------------------------------
# status / doctor
# ---------------------------------------------------------------------------
cmd_status() {
  local stage detail tail
  detail="${1:-0}"
  tail="${2:-1}"
  if [ "$TERMUX_OK" -eq 0 ]; then
    s_warn "当前不在 Termux 环境（缺 $PREFIX/bin/bash）—— 以下结果仅供参考"
    echo
  fi
  deps_scan
  dsh_scan
  patch_scan
  stage="$(stage_of)"

  if [ "$detail" -eq 1 ]; then
    bar; echo " dsh-termux-fix 状态详细报告"; bar
  else
    bar; echo " dsh-termux-fix 状态"; bar
  fi
  echo
  echo "[1] 系统依赖与编译工具链"
  if [ -z "$DEPS_MISS" ]; then
    s_ok "依赖齐全（node npm bash proot sed grep tar gzip diff find cut + clang make python pkg-config）"
  else
    s_bad "缺少：$DEPS_MISS"
  fi
  if [ "$detail" -eq 1 ]; then
    local pair c pk cpath
    for pair in $DEPS_RUN $DEPS_BUILD; do
      c="${pair%%:*}"
      pk="${pair##*:}"
      cpath="$(command -v "$c" 2>/dev/null)"
      if [ -n "$cpath" ]; then
        s_ok "$(printf '%-11s %s' "$c" "$cpath")"
      elif pkgok "$pk"; then
        s_ok "$(printf '%-11s %s' "$c" "包 $pk 已装，但命令不在 PATH")"
      else
        s_bad "$(printf '%-11s %s' "$c" "缺失（包 $pk 未安装）")"
      fi
    done
    if havec ld || havec ld.lld || pkgok binutils; then
      s_ok "$(printf '%-11s %s' ld "$(command -v ld 2>/dev/null || command -v ld.lld 2>/dev/null || echo '包 binutils 已装')")"
    else
      s_bad "$(printf '%-11s %s' ld "缺失（binutils 未安装）")"
    fi
    s_info "node    $(node -v 2>/dev/null)    npm    $(npm -v 2>/dev/null)"
    s_info "python  $(python -V 2>&1 | head -1)"
    s_info "clang   $(command -v clang >/dev/null 2>&1 && clang --version 2>/dev/null | head -1 || echo 缺)"
    s_info "bash    $(bash --version 2>/dev/null | head -1)"
    s_info "架构    $(uname -m)    内核 $(uname -r)"
  else
    havec node && s_ok "node $(node -v 2>/dev/null)   npm $(npm -v 2>/dev/null)"
  fi
  [ -f "$PREFIX/include/node/node_api.h" ] && s_ok "Node 头文件（flock 编译用）：$PREFIX/include/node/node_api.h" || s_warn "缺 Node 头文件（flock 无法编译）"
  [ "$NDK_OK" -eq 1 ] && s_ok "gyp 前置：$HOME_DIR/.gyp/include.gypi" || s_warn "缺 ~/.gyp/include.gypi（node-pty 编译会失败）"
  echo

  echo "[2] dsh 本体"
  if [ -n "$DSH_VER" ]; then
    s_ok "已安装：$DSH_VER"
    if [ "$detail" -eq 1 ]; then
      s_info "路径      $DSH_ROOT"
      s_info "体积      $(du -sh "$DSH_ROOT" 2>/dev/null | cut -f1)   package.json 改动于 $(date -r "$DSH_ROOT/package.json" '+%Y-%m-%d %H:%M' 2>/dev/null || echo 未知)"
      local ptv; ptv="$(pkg_ver "$DSH_NM/node-pty")"; [ -n "$ptv" ] || ptv="$(tagbad 未安装)"
      s_info "node-pty  $ptv   spawn 可用 = $PTY_OK"
      s_info "sharp     ${SHARP_PKG:-$(tagbad 未找到)}"
      s_info "wrapper   $HOME_DIR/bin/dsh  $([ -x "$HOME_DIR/bin/dsh" ] && echo "$(tagok 可执行)" || echo "$(tagbad 缺失)")"
      s_info "spawn     $DSH_NM/@deepseek-ai/dsh-subprocess-local/scripts/ensure-spawn-helper.mjs  $([ "$SPAWN_OK" -eq 1 ] && echo "$(tagok 存在)" || echo "$(tagbad 缺失)")"
    fi
    [ "$PTY_OK" -eq 1 ]     && s_ok "node-pty 可用（终端功能）"     || s_warn "node-pty 不可用 —— 终端面板会坏"
    [ "$SPAWN_OK" -eq 1 ]   && s_ok "spawn helper 就位"             || s_warn "spawn helper 缺失"
    [ -n "$SHARP_PKG" ]     && s_ok "sharp $SHARP_PKG"              || s_warn "未找到 sharp"
    [ -x "$HOME_DIR/bin/dsh" ] && s_ok "~/bin/dsh wrapper 已就位"   || s_warn "~/bin/dsh 缺失（PATH 里可能没有 dsh）"
  else
    s_bad "未安装（$DSH_ROOT 不存在）"
  fi
  echo

  echo "[3] 补丁状态：$P_PASS / $P_TOT"
  if [ "$detail" -eq 1 ]; then
    if [ -n "$P_LIST" ]; then emit_plist; else s_info "（无补丁项）"; fi
  else
    if [ -n "$P_FAILED" ]; then
      s_bad "以下项未生效："
      while IFS= read -r _pl; do
        [ -n "$_pl" ] || continue
        emit_info "         " "$_pl" 2
      done <<EOF
$(printf '%s\n' "$P_FAILED" | sed '/^[[:space:]]*$/d')
EOF
    else
      s_ok "全部生效"
    fi
  fi
  echo

  echo "[4] 运行前提"
  if [ "$detail" -eq 1 ]; then
    s_info "~/.dsh     $HOME_DIR/.dsh  $([ -d "$HOME_DIR/.dsh" ] && echo "$(tagok 存在)（$(du -sh "$HOME_DIR/.dsh" 2>/dev/null | cut -f1)）" || echo "$(tagbad 不存在)")"
    s_info "~/workspace $HOME_DIR/workspace  $([ -d "$HOME_DIR/workspace" ] && echo "$(tagok 存在)" || echo "$(tagbad 不存在)")"
    s_info "~/.npmrc   $(grep -c . "$HOME_DIR/.npmrc" 2>/dev/null || echo 0) 行，registry = $(grep -i '^registry' "$HOME_DIR/.npmrc" 2>/dev/null | tail -1 | cut -d= -f2-)"
    s_info "剩余空间   $(df -h "$HOME_DIR" 2>/dev/null | tail -1 | awk '{print $4}')"
    s_info "日志目录   $LOG_DIR"
  fi
  [ -d "$HOME_DIR/.dsh" ] && s_ok "~/.dsh 已初始化" || s_warn "~/.dsh 不存在（首次启动会自动创建）"
  [ -d "$HOME_DIR/workspace" ] && s_ok "~/workspace 存在" || s_warn "~/workspace 不存在（建议 mkdir -p ~/workspace）"
  echo

  if [ "$tail" -eq 1 ]; then
  bar; echo " 当前：$(stage_name "$stage")"; bar
  echo
  case "$stage" in
    0)
      echo " 下一步：先补齐系统依赖"
      echo "   pkg install -y $DEPS_MISS"
      echo
      emit_info " " "或者一条命令从零装到可用（会先装依赖，再装 dsh，再打补丁）："
      echo "   bash ~/apply-dsh-patches.sh all"
      ;;
    1)
      echo " 下一步：安装 dsh"
      echo "   bash ~/apply-dsh-patches.sh install          # 稳定频道（推荐）"
      echo
      echo " 或者一步到底（含依赖、安装、补丁）："
      echo "   bash ~/apply-dsh-patches.sh all"
      ;;
    2)
      echo " 下一步：打补丁"
      echo "   bash ~/apply-dsh-patches.sh patch"
      ;;
    3)
      echo " 下一步：启动"
      echo "   cd ~/workspace && dsh web"
      echo
      echo " 升级到最新版本并自动打补丁："
      echo "   bash ~/apply-dsh-patches.sh all"
      ;;
  esac
  fi
}

cmd_doctor() {
  # doctor = status 的详细模式：四段体检每项都给出实测值
  cmd_status 1 0

  echo "[5] 本次调用"
  s_info "命令 = $CMD   参数 = ${ARGS[*]:-无}"
  s_info "阶段 = $(stage_of) / 3  （$(stage_name "$(stage_of)")）"
  echo
}

# ---------------------------------------------------------------------------
# channels：查询 npm 三个频道当前的版本，并给出本脚本里对应的安装命令
#   只读操作，需要联网（走 npm 配置的 registry）
# ---------------------------------------------------------------------------
cmd_channels() {
  local REG RAW cur t v rel opt desc cn
  local YEL="" GRN="" RST=""
  if [ -t 1 ]; then YEL=$'\033[33m'; GRN=$'\033[32m'; RST=$'\033[0m'; fi
  REG="$(npm config get registry 2>/dev/null | sed 's:/*$::')"
  [ -n "$REG" ] || REG="https://registry.npmjs.org"

  bar; echo " DeepSeek Harness 当前版本"; bar
  echo "registry：$REG"
  cur="$(pkg_ver "$DSH_ROOT")"
  if [ -n "$cur" ]; then
    echo "当前版本：$cur"
  else
    echo "当前未安装 DeepSeek Harness"
  fi
  echo

  RAW="$(node -e '
    const https=require("https"),http=require("http");
    const base=process.argv[1], cur=process.argv[2]||"";
    const lib=base.startsWith("https")?https:http;
    function cmp(a,b){
      const pa=a.split("-"), pb=b.split("-");
      const na=pa[0].split(".").map(Number), nb=pb[0].split(".").map(Number);
      for(let i=0;i<3;i++){ if((na[i]||0)!==(nb[i]||0)) return (na[i]||0)-(nb[i]||0); }
      const sa=pa[1]||"", sb=pb[1]||"";
      if(sa===sb) return 0;
      if(!sa) return 1;              // 正式版 > 预发布
      if(!sb) return -1;
      return sa.localeCompare(sb,"en",{numeric:true});
    }
    const req=lib.get(base+"/@deepseek-ai/dsh",{headers:{"user-agent":"dsh-patches"}},res=>{
      let d="";res.on("data",c=>d+=c);
      res.on("end",()=>{
        let j;try{j=JSON.parse(d);}catch(e){console.log("ERR|响应无法解析（registry 可能不是 npm 源）");return;}
        const t=j["dist-tags"]||{};
        ["latest","next","alpha"].forEach(k=>{
          const v=t[k]||"";
          let rel="";
          if(!cur){
            rel="未安装";
          } else if(v){
            const c=cmp(v,cur);
            rel = c>0 ? "新版本"
                : c===0 ? "当前版本"
                        : "旧版本";
          }
          console.log(k+"|"+v+"|"+rel);
        });
      });
    });
    req.setTimeout(15000,()=>{req.destroy();console.log("ERR|请求超时 15s（网络不通？）");});
    req.on("error",e=>console.log("ERR|"+e.code));
  ' "$REG" "$cur" 2>/dev/null)"

  case "$RAW" in
    ERR*)
      s_bad "查询失败：${RAW#ERR|}"
      s_info "网络不可用时可以先跳过，直接指定已知版本：--ver=X.Y.Z"
      return 1
      ;;
  esac

  # 先把三行数据收进数组，再按实际内容算列宽（版本号 / 频道名变长也不会错位）
  local -a T_TAG=() T_CN=() T_VER=() T_REL=() T_DESC=() T_OPT=()
  local n i tagw verw
  n=0
  while IFS='|' read -r t v rel; do
    [ -n "$t" ] || continue
    case "$t" in
      latest)
        cn="稳定频道"; opt="install"
        desc="默认安装的稳定版本。"
        ;;
      next)
        cn="候选频道"; opt="install --next"
        desc="当前最新的 rc 预发布版本。"
        ;;
      alpha)
        cn="前沿频道"; opt="install --alpha"
        desc="最早暴露下一版本雏形的 alpha 版本。"
        ;;
      *)
        cn="-"; opt=""; desc=""
        ;;
    esac
    T_TAG[$n]="$t"; T_CN[$n]="$cn"; T_VER[$n]="${v:--}"
    T_REL[$n]="$rel"; T_DESC[$n]="$desc"; T_OPT[$n]="$opt"
    n=$((n + 1))
  done <<EOF
$RAW
EOF

  # 列宽 = 实际最长内容；频道列下限 6，版本列下限 13
  tagw=6; verw=13
  for ((i = 0; i < n; i++)); do
    [ "${#T_TAG[$i]}" -gt "$tagw" ] && tagw="${#T_TAG[$i]}"
    [ "${#T_VER[$i]}" -gt "$verw" ] && verw="${#T_VER[$i]}"
  done
  verw=$((verw + 1))   # 给最长版本号留 1 格间隙

  printf ' %s   %s   %s   %s\n' \
    "频道$(printf '%*s' $((tagw - 4)) '')" \
    "        " \
    "版本$(printf '%*s' $((verw - 4)) '')" \
    "状态"
  echo

  for ((i = 0; i < n; i++)); do
    printf ' %-*s   %s   %-*s   %s\n' \
      "$tagw" "${T_TAG[$i]}" "${T_CN[$i]}" "$verw" "${T_VER[$i]}" "${T_REL[$i]}"
    [ -n "${T_DESC[$i]}" ] && printf '%s\n' "${YEL}${T_DESC[$i]}${RST}"
    [ -n "${T_OPT[$i]}" ] && printf '%s\n' "${GRN}bash ~/apply-dsh-patches.sh ${T_OPT[$i]}${RST}"
    echo
  done

  echo " 指定任意版本："
  echo "   bash ~/apply-dsh-patches.sh install --ver=X.Y.Z"
  echo
}

# ============================================================================
# 安装器（原 install-dsh-termux.sh，已并入本脚本）
# ============================================================================
PREFIX_DIR="$PREFIX"
LOG_DIR="$HOME_DIR/dsh-install-logs"
[ "$TERMUX_OK" -eq 1 ] && mkdir -p "$LOG_DIR" 2>/dev/null || true

# 安装相关选项（由 parse_install_opts 从 ARGS 中解析）
TARGET_VER=""
NEXT=0
ALPHA=0
SCRIPTS=0
ASSUME_YES=0
DRY_RUN=0

say()    { echo; bar; echo " $*"; bar; }
dry_banner() { if _dry; then bar; echo " 全流程模拟"; bar; fi }
warn()   { emit_state "[WARN]" "$C_WARN" "$*"; }
info()   { emit_info "         " "$*"; }
die()    { emit_state "[FAIL]" "$C_BAD" "$*"
  if [ -n "${FAIL_LABEL:-}" ]; then echo; bar; echo " $FAIL_LABEL"; bar; fi
  echo; emit_info "" "中断后可重跑：bash ~/apply-dsh-patches.sh all"
  exit 1; }
have()   { command -v "$1" >/dev/null 2>&1; }
pkg_ok() { dpkg -s "$1" >/dev/null 2>&1; }

# 解析 install / all 的选项
#   --next / --alpha   --ver=X.Y.Z   --scripts   --dry-run   -y/--yes
parse_install_opts() {
  TARGET_VER=""; NEXT=0; ALPHA=0; SCRIPTS=0; ASSUME_YES=0; DRY_RUN=0
  local a
  for a in "$@"; do
    case "$a" in
      --next)    NEXT=1 ;;
      --alpha)   ALPHA=1 ;;
      --ver=*)   TARGET_VER="${a#*=}" ;;
      --scripts) SCRIPTS=1 ;;
      --dry-run) DRY_RUN=1 ;;
      -y|--yes)  ASSUME_YES=1 ;;
      --ver)     echo; echo "  [FAIL] --ver 需要写成一体：--ver=X.Y.Z"
                 exit 1 ;;
      *)         echo; echo "  [FAIL] 未识别的选项：$a"
                 echo "        可用选项：--next  --alpha  --ver=X.Y.Z  --scripts  --dry-run  -y/--yes"
                 exit 1 ;;
    esac
  done
}

cmd_install() {
  parse_install_opts "$@"
  dry_banner
  STEPS=2
  say "DeepSeek Harness 安装程序"
  phase1
  phase2
  if [ "$DRY_RUN" -eq 1 ]; then
    return 0
  fi
  echo
  info "补丁未执行。需要时："
  info "  bash ~/apply-dsh-patches.sh patch      # 只补"
  info "  bash ~/apply-dsh-patches.sh all        # 安装 + 补（下次直接用这个）"
}

cmd_all() {
  parse_install_opts "$@"
  dry_banner
  STEPS=3
  say "DeepSeek Harness 安装程序"
  phase1
  phase2
  echo
  cmd_patch_checked
}

# ============================================================================
# 阶段 1：环境预检与准备
# ============================================================================
phase1() {
  FAIL_LABEL="环境部署异常"
  say "步骤 1 / $STEPS   环境检测"

  # ---- 1.1 平台断言 ----
  [ -d "$PREFIX_DIR" ] || die "未检测到 Termux 前缀目录 $PREFIX_DIR —— 本脚本只能在 Termux 内运行"
  ARCH="$(uname -m)"
  case "$ARCH" in
    aarch64|arm64) ok "架构：$ARCH" ;;
    *) warn "架构是 $ARCH，不是 aarch64 —— 预编译产物与本次验证环境不同，可能需要在阶段 3 额外处理" ;;
  esac
  ok "Android $(getprop ro.build.version.release 2>/dev/null || echo '?') / 前缀 $PREFIX_DIR"

  # ---- 1.2 软件包清单 ----
  # 运行期必需：node(含 npm)、bash(终端与补丁脚本)、proot(沙箱 runner)、
  #             基础 coreutils 全家（sed/grep/tar/gzip 等在补丁里被直接调用）
  # 清单写成「命令:包名」——命令可用即视为满足。dpkg 名字与实际安装方式经常
  # 对不上（node 由 nodejs 提供、ld 由 llvm 提供），只看 dpkg 会误报，而误报
  # 会让 pkg install 去重装 node，风险很大。
  PKGS_RUN="node:nodejs npm:nodejs bash:bash proot:proot sed:sed grep:grep tar:tar gzip:gzip diff:diffutils find:findutils cut:coreutils"
  # 编译期必需：node-pty / flock（node-addon-system）都要 clang + make + python
  PKGS_BUILD="clang:clang make:make python:python pkg-config:pkg-config"
  # 建议但非阻塞
  PKGS_OPT="git:git curl:curl"

  MISSING=""
  for pair in $PKGS_RUN $PKGS_BUILD; do
    _cmd="${pair%%:*}"; _pkg="${pair##*:}"
    have "$_cmd" && continue
    pkg_ok "$_pkg" && continue
    case " $MISSING " in
      *" $_pkg "*) : ;;
      *) MISSING="$MISSING $_pkg" ;;
    esac
  done
  # 链接器：clang 包通常已经带 ld.lld，不一定需要 binutils
  if ! have ld && ! have ld.lld && ! pkg_ok binutils; then
    MISSING="$MISSING binutils"
  fi
  MISSING="${MISSING# }"

  MISSING_OPT=""
  for pair in $PKGS_OPT; do
    _cmd="${pair%%:*}"; _pkg="${pair##*:}"
    have "$_cmd" || pkg_ok "$_pkg" || MISSING_OPT="$MISSING_OPT $_pkg"
  done

  if [ -n "$MISSING" ]; then
    echo "  需要安装的软件包："
    for p in $MISSING; do info "· $p"; done
    if [ "$DRY_RUN" -eq 1 ]; then
      warn "--dry-run：跳过实际安装"
    else
      echo "  执行：pkg install -y$MISSING"
      # shellcheck disable=SC2086
      if DEBIAN_FRONTEND=noninteractive pkg install -y $MISSING; then
        ok "软件包安装完成"
      else
        warn "pkg install 返回非 0。若提示 Unable to locate package，多半是软件源列表过期："
        info "先执行  pkg update  （或 termux-change-repo 换源）后再重跑本脚本"
      fi
    fi
  else
    ok "运行期 + 编译期依赖包齐全"
  fi
  [ -n "$MISSING_OPT" ] && info "（可选包未装，不影响安装：$MISSING_OPT）"

  # ---- 1.3 关键命令复查 ----
  CRIT_MISS=""
  for c in node npm bash sed grep tar; do
    have "$c" || CRIT_MISS="$CRIT_MISS $c"
  done
  [ -n "$CRIT_MISS" ] && die "以下关键命令仍不可用：$CRIT_MISS（请先手动 pkg install）"
  ok "关键命令可用：node / npm / bash / sed / grep / tar"

  # ---- 1.4 版本与头文件 ----
  NODE_V="$(node -v 2>/dev/null)"
  NPM_V="$(npm -v 2>/dev/null)"
  ok "node $NODE_V   npm $NPM_V"
  case "$NODE_V" in
    v2[0-9].*|v[3-9][0-9].*) : ;;
    *) warn "node 版本 $NODE_V 偏低，dsh 官方要求较新的 Node（建议 v20+）" ;;
  esac

  if [ -f "$PREFIX_DIR/include/node/node_api.h" ]; then
    ok "Node 头文件存在（node-addon-system 可本地编译）"
  else
    warn "缺少 $PREFIX_DIR/include/node/node_api.h —— flock 将无法编译"
    info "通常重装 nodejs 可恢复：pkg install --reinstall nodejs"
  fi

  if have clang && have make && have python; then
    ok "编译工具链：clang / make / python 就绪"
  else
    warn "编译工具链不完整：node-pty 与 flock 会编译失败"
  fi
  if have python3; then
    ok "python3 可用（node-gyp 依赖）"
  elif have python; then
    warn "只有 python 没有 python3 —— node-gyp 可能报 Could not find any Python"
    info "解决：pkg install python3（或建 ~/bin/python3 → python 的软链）"
  else
    warn "没有 python/python3 —— node-gyp 无法运行"
  fi

  # ---- 1.5 gyp 前置（node-pty 在 Android 上的关键）----
  d_mkdir "$HOME_DIR/.gyp"
  if grep -q "android_ndk_path" "$HOME_DIR/.gyp/include.gypi" 2>/dev/null; then
    ok "~/.gyp/include.gypi（已存在）"
  else
    [ "$DRY_RUN" -eq 1 ] && warn "--dry-run：不写 ~/.gyp/include.gypi" || {
      d_echo "$HOME_DIR/.gyp/include.gypi" "{'variables':{'android_ndk_path':''}}"
      ok "~/.gyp/include.gypi（空 NDK 路径，跳过 NDK 探测）"
    }
  fi

  # ---- 1.6 npm 配置（只补缺，不覆盖用户已有设置）----
  d_touch "$HOME_DIR/.npmrc"
  add_npmrc() {
    local k="$1" v="$2"
    grep -qE "^${k}=" "$HOME_DIR/.npmrc" || { [ "$DRY_RUN" -eq 1 ] || echo "${k}=${v}" >> "$HOME_DIR/.npmrc"; }
  }
  add_npmrc registry              "https://registry.npmmirror.com"
  add_npmrc foreground-scripts    "true"
  add_npmrc fetch-retries         "5"
  add_npmrc fetch-retry-maxtimeout "120000"
  add_npmrc fetch-timeout         "600000"
  ok "~/.npmrc（registry / foreground-scripts / 重试与超时）"

  REG="$(npm config get registry 2>/dev/null | sed 's:/*$::')"
  [ -n "$REG" ] || REG="https://registry.npmjs.org"
  info "npm registry = $REG"

  # ---- 1.7 磁盘空间 ----
  AVAIL_KB="$(df -k "$HOME_DIR" 2>/dev/null | sed -n '2p' | tr -s ' ' | cut -d' ' -f4)"
  case "$AVAIL_KB" in ''|*[!0-9]*) AVAIL_KB=0 ;; esac
  if [ "$AVAIL_KB" -gt 0 ]; then
    AVAIL_MB=$((AVAIL_KB / 1024))
    if [ "$AVAIL_KB" -lt 1500000 ]; then
      warn "可用空间仅 ${AVAIL_MB}MB，安装 + 编译建议 ≥ 1.5GB"
    else
      ok "可用空间 ${AVAIL_MB}MB"
    fi
  fi

  # ---- 1.8 网络与通道探测 ----
  [ "$DRY_RUN" -eq 1 ] && { ok "（--dry-run）跳过网络探测"; return 0; }
  NET="$(node -e '
    const https=require("https"), http=require("http");
    const base=process.argv[1];
    const url=base+"/@deepseek-ai/dsh";
    const lib=url.startsWith("https")?https:http;
    const req=lib.get(url,{headers:{"user-agent":"dsh-installer"}},res=>{
      res.resume();
      console.log(res.statusCode===200?"ok":"http-"+res.statusCode);
    });
    req.setTimeout(15000,()=>{req.destroy();console.log("timeout");});
    req.on("error",e=>console.log("error:"+e.code));
  ' "$REG" 2>/dev/null)"
  case "$NET" in
    ok) ok "registry 可达（$REG）" ;;
    timeout) die "registry 超时：检查网络；国内建议 registry=https://registry.npmmirror.com" ;;
    *)  warn "registry 探测返回 $NET —— 安装阶段可能失败" ;;
  esac
}

# ============================================================================
# 阶段 2：安装 dsh 本体
# ============================================================================
resolve_version() {
  local tag="$1"
  node -e '
    const https=require("https"), http=require("http");
    const base=process.argv[1], tag=process.argv[2];
    const url=base+"/@deepseek-ai/dsh";
    const lib=url.startsWith("https")?https:http;

    function cmp(a,b){
      const pa=a.split("-"), pb=b.split("-");
      const na=pa[0].split(".").map(Number), nb=pb[0].split(".").map(Number);
      for(let i=0;i<3;i++){ if((na[i]||0)!==(nb[i]||0)) return (na[i]||0)-(nb[i]||0); }
      const sa=pa[1]||"", sb=pb[1]||"";
      if(sa===sb) return 0;
      if(!sa) return 1;              // 正式版 > 预发布
      if(!sb) return -1;
      return sa.localeCompare(sb, "en", {numeric:true});
    }

    lib.get(url,{headers:{"user-agent":"dsh-installer"}},res=>{
      let d=""; res.on("data",c=>d+=c);
      res.on("end",()=>{
        let j; try{ j=JSON.parse(d); }catch(e){ console.log(""); return; }
        const tags=j["dist-tags"]||{};
        if(tag && tag!=="__any_pre__"){ console.log(tags[tag]||""); return; }
        const vs=Object.keys(j.versions||{});
        const pre=vs.filter(v=>v.indexOf("-")>0).sort(cmp);
        console.log(pre.length?pre[pre.length-1]:"");
      });
    }).on("error",()=>console.log(""));
  ' "$1" "$2" 2>/dev/null
}

phase2() {
  FAIL_LABEL="DeepSeek Harness 安装异常"
  say "步骤 2 / $STEPS   安装 DeepSeek Harness"

  REG="$(npm config get registry 2>/dev/null | sed 's:/*$::')"
  [ -n "$REG" ] || REG="https://registry.npmjs.org"

  # ---- 2.1 解析版本 ----
  if [ -n "$TARGET_VER" ]; then
    VER="$TARGET_VER"
    ok "使用指定版本：$VER"
  elif [ "$ALPHA" -eq 1 ]; then
    VER="$(resolve_version "$REG" alpha)"
    [ -n "$VER" ] || die "无法从 registry 解析 alpha 版本（网络或源不可用）"
    ok "alpha 频道：$VER"
  elif [ "$NEXT" -eq 1 ]; then
    VER="$(resolve_version "$REG" next)"
    if [ -z "$VER" ]; then
      warn "next 频道为空，回退到最高预发布版本"
      VER="$(resolve_version "$REG" __any_pre__)"
    fi
    [ -n "$VER" ] || die "无法从 registry 解析预发布版本（网络或源不可用）"
    ok "next 频道：$VER"
  else
    VER="$(resolve_version "$REG" latest)"
    [ -n "$VER" ] || die "无法解析 latest 版本（网络或源不可用）"
    ok "稳定频道：$VER"
  fi
  SPEC="@deepseek-ai/dsh@$VER"

  if [ "$DRY_RUN" -eq 1 ]; then
    info "（模拟）npm install -g $SPEC"
    if npm view "$SPEC" version >/dev/null 2>&1; then
      ok "（模拟）registry 可解析 $SPEC  $(tagok "预计通过")"
    else
      warn "（模拟）registry 无法解析 $SPEC  $(tagbad "预计失败：网络或源不可达")"
    fi
    info "（模拟）假定安装成功，继续后面的步骤"
    return 0
  fi

  # ---- 2.2 运行中检测 ----
  if have ps && ps -ef 2>/dev/null | grep -q "[d]sh/lib/bin.js"; then
    warn "检测到 dsh 可能正在运行，覆盖安装可能碰到文件占用（ETXTBSY/EBUSY）"
    info "建议先退出正在运行的 dsh（Ctrl+C / exit）再继续"
  fi

  # ---- 2.3 确认 ----
  if [ "$ASSUME_YES" -ne 1 ]; then
    printf '  即将执行：npm install -g %s\n  5 秒后开始，Ctrl+C 取消 ...\n' "$SPEC"
    sleep 5
  fi

  # ---- 2.4 安装 ----
  LOG_FILE="$LOG_DIR/install-$(date +%Y%m%d-%H%M%S).log"
  ok "日志：$LOG_FILE"
  echo "  ---------- npm install 输出 ----------"

  RC=0
  if [ "$SCRIPTS" -eq 1 ]; then
    info "模式：完整执行 install scripts（不加 --ignore-scripts）"
    npm install -g "$SPEC" --foreground-scripts 2>&1 | tee "$LOG_FILE"
    RC=${PIPESTATUS[0]}
    if [ "$RC" -ne 0 ]; then
      echo "  ---------- 失败原因摘要 ----------"
      grep -iE "koffi|statx|sharp|prebuild|node-gyp|gyp (ERR|info ok)|EACCES|ENOTFOUND|ETIMEDOUT|404|EBUSY|ETXTBSY" "$LOG_FILE" 2>/dev/null | tail -12 | sed 's/^/         /'
      warn "全量安装失败，按已知不可行包回退到 --ignore-scripts（原生依赖由后续步骤逐一重建）"
      npm install -g "$SPEC" --ignore-scripts 2>&1 | tee -a "$LOG_FILE"
      RC=${PIPESTATUS[0]}
    fi
  else
    info "模式：--ignore-scripts（避免 koffi 等 Android 不可编译包阻断整棵树）"
    info "      node-pty / flock / sharp / require-builtin 由下面几步逐一补上"
    npm install -g "$SPEC" --ignore-scripts 2>&1 | tee "$LOG_FILE"
    RC=${PIPESTATUS[0]}
  fi
  echo "  -------------------------------------"

  [ "$RC" -eq 0 ] || die "npm install 失败（exit $RC），完整日志：$LOG_FILE"
  ok "npm install 完成"

  # ---- 2.5 目录核对 ----
  [ -d "$DSH_ROOT" ] || die "安装后仍未找到 $DSH_ROOT"
  ok "dsh 版本：$(node -p "require('$DSH_ROOT/package.json').version" 2>/dev/null)"

  # ---- 2.6 原生依赖精确重建 ----
  # node-pty：Android 无可用预编译产物，必须源码编译（gyp 前置已在阶段 1 写好）
  if [ -d "$DSH_NM/node-pty" ]; then
    info "重建 node-pty（源码编译，1~5 分钟，勿中断）"
    ( cd "$DSH_ROOT" && npm_config_build_from_source=true npm rebuild node-pty --foreground-scripts ) 2>&1 | tee -a "$LOG_FILE"
    if ( cd "$DSH_ROOT" && node -e "const p=require('node-pty'); if(typeof p.spawn!=='function') process.exit(1)" ) >/dev/null 2>&1; then
      ok "node-pty: OK"
    else
      warn "node-pty 仍不可用 —— 常见原因：clang/make 缺失、~/.gyp/include.gypi 被覆盖、python3 找不到"
      info "手动复查：cd $DSH_ROOT && npm_config_build_from_source=true npm rebuild node-pty"
    fi
  else
    warn "未找到 node-pty 包（终端功能将不可用）"
  fi

  # spawn helper：subprocess-local 的启动器
  HELPER="$DSH_NM/@deepseek-ai/dsh-subprocess-local/scripts/ensure-spawn-helper.mjs"
  if [ -f "$HELPER" ]; then
    if node "$HELPER" >/dev/null 2>&1; then ok "spawn helper 就位"; else warn "spawn helper 执行失败"; fi
  else
    warn "未找到 ensure-spawn-helper.mjs（包结构可能已变）"
  fi

  # ---- 2.7 冒烟测试 ----
  if [ -x "$PREFIX_DIR/bin/dsh" ]; then
    V="$("$PREFIX_DIR/bin/dsh" --version 2>&1 | tr -d '\r')"
    echo "         dsh --version → $V"
    case "$V" in
      *"$VER"*) ok "版本与目标一致" ;;
      *)        warn "版本字符串与目标 $VER 不完全一致，请核对" ;;
    esac
  else
    warn "未生成 $PREFIX_DIR/bin/dsh"
  fi

  if [ -d "$DSH_NM/sharp" ]; then
    SV="$(node -p "require('$DSH_NM/sharp/package.json').version" 2>/dev/null)"
    ok "sharp $SV（原生二进制由阶段 3 用 WASM 补齐）"
  fi
}


# ---- --dry-run 拦截：只打模拟日志，不落盘；同时判定真实运行时本项能否通过 ----
_dry() { [ "${DRY_RUN:-0}" -eq 1 ]; }
d_log() { info "（模拟）$*"; }
DRY_MADE=""
_d_mark() { case "$DRY_MADE" in *"|$1|"*) ;; *) DRY_MADE="$DRY_MADE$1|" ;; esac; }
_d_made() { case "$DRY_MADE" in *"|$1|"*) return 0 ;; *) return 1 ;; esac; }
# 可行性判定：目标可写 → 绿；源/文件缺失 → 红
d_feas_w() {   # $1=要写入的路径
  local t="$1" p; p="$t"
  if _d_made "$t"; then printf '%s' "$(tagok "预计通过（已模拟创建）")"; return; fi
  while [ -n "$p" ] && [ ! -e "$p" ]; do p="$(dirname "$p")"; [ "$p" = "/" ] && break; done
  if [ -w "$p" ]; then
    if [ -e "$t" ]; then printf '%s' "$(tagok "预计通过")"
    else printf '%s' "$(tagok "预计通过（将新建）")"; fi
  else
    printf '%s' "$(tagbad "预计失败：$p 不可写")"
  fi
}
d_feas_r() { if _d_made "$1" || [ -e "$1" ]; then printf '%s' "$(tagok "预计通过")"; else printf '%s' "$(tagbad "预计失败：源不存在")"; fi }
d_feas_f() { # $1=目标文件（sed/chmod 用）
  if _d_made "$1"; then printf '%s' "$(tagok "预计通过（已模拟创建）")"
  elif [ -f "$1" ] && [ -w "$1" ]; then printf '%s' "$(tagok "预计通过")"
  elif [ -f "$1" ]; then printf '%s' "$(tagbad "预计失败：不可写")"
  else printf '%s' "$(tagbad "预计失败：文件不存在")"; fi
}
d_fmt() { printf '%s\n' "$1"; }
d_out()  { local f="$1"; if _dry; then d_log "写入 $f  $(d_feas_w "$f")"; _d_mark "$f"; cat >/dev/null; else cat > "$f"; fi }
d_outa() { local f="$1"; if _dry; then d_log "追加 $f  $(d_feas_w "$f")"; _d_mark "$f"; cat >/dev/null; else cat >> "$f"; fi }
d_echo() { local f="$1"; shift; if _dry; then d_log "写入 $f（1 行）  $(d_feas_w "$f")"; _d_mark "$f"; else echo "$*" > "$f"; fi }
d_echoapp() { local f="$1"; shift; if _dry; then d_log "追加 $f（1 行）  $(d_feas_w "$f")"; _d_mark "$f"; else echo "$*" >> "$f"; fi }
d_mkdir() { if _dry; then d_log "mkdir -p ${*: -1}  $(d_feas_w "${*: -1}")"; _d_mark "${*: -1}"; else mkdir -p "$@"; fi }
d_touch() { if _dry; then d_log "touch ${*: -1}  $(d_feas_w "${*: -1}")"; _d_mark "${*: -1}"; else touch "$@"; fi }
d_cp()   { if _dry; then d_log "cp $1 → ${*: -1}  $(d_feas_r "$1")"; _d_mark "${*: -1}"; else cp "$@"; fi }
d_sed()  { if _dry; then d_log "sed -i ${*: -1}  $(d_feas_f "${*: -1}")"; else sed -i "$@"; fi }
d_chmod(){ if _dry; then d_log "chmod $*  $(d_feas_f "${*: -1}")"; else chmod "$@"; fi }
d_npm()  { if _dry; then d_log "npm $*  $(tagwarn "需联网 / 会改 node_modules")"; else npm "$@"; fi }
d_rm()   { local opts="" f; for f in "$@"; do case "$f" in -*) opts="$opts $f" ;; *) if _dry; then d_log "rm$opts $f  $(d_feas_r "$f")"; else rm $opts "$f"; fi ;; esac; done }
d_tar()  { local out="$1" dir="$2"; shift 2; if _dry; then d_log "tar czf $out（$*）  $(d_feas_w "$out")"; _d_mark "$out"; else tar czf "$out" -C "$dir" "$@" 2>/dev/null; fi }
# 把刚写入文件里的 __PREFIX__ / __HOME__ 换成实际路径（支持非默认安装位置）
_fill_paths() { # $1=文件
  [ -f "$1" ] || return 0
  grep -qE '__PREFIX__|__HOME__' "$1" 2>/dev/null || return 0
  if _dry; then
    d_log "注入实际路径 $1（PREFIX / HOME）"
  else
    sed -i "s|__PREFIX__|$PREFIX|g; s|__HOME__|$HOME_DIR|g" "$1"
  fi
}
# 打完补丁后根据返回码给结论（all 调用）
cmd_patch() {   # patch [--dry-run]
  DRY_RUN=0
  local a
  for a in "$@"; do
    case "$a" in
      --dry-run) DRY_RUN=1 ;;
      *) echo; echo "  [FAIL] patch 只接受 --dry-run，收到：$a"; echo "        用法：bash ~/apply-dsh-patches.sh patch [--dry-run]"; exit 1 ;;
    esac
  done
  dry_banner
  run_patches
}

cmd_patch_checked() {
  run_patches stage
  local rc=$?
  echo
  if _dry; then
    bar; echo " 模拟结束"; bar
    return 0
  fi
  if [ "$rc" -eq 0 ]; then
    bar; echo " 全部准备就绪"; bar
    echo " 启动："
    echo "   cd ~/workspace && dsh web"
  else
    bar; echo " 部分补丁项未生效"; bar
    echo " 看上面的 [FAIL] 段落；想知道差哪些："
    echo "   bash ~/apply-dsh-patches.sh status"
    exit 1
  fi
}



run_patches() {   # $1=stage 时作为「步骤 3 / 3」子标题
  if [ "${1:-}" = "stage" ]; then
    say "步骤 3 / 3   安装 dsh-termux-fix 补丁"
  else
    bar; echo " dsh-termux-fix 补丁程序"; bar
  fi

# ---------- 前置检查：dsh 主程序是否已安装 ----------
if [ ! -d "$DSH_ROOT" ]; then
  if _dry; then
    warn "（模拟）dsh 本体尚未安装 → 按「已安装」继续模拟"
    ok "（模拟）假定 dsh 已安装 $DSH_ROOT  $(tagwarn "前提：真实运行需先完成前两步") "
  else
  echo "  [警告] 未检测到 dsh 主程序："
  echo "         $DSH_ROOT"
  echo "         请先执行：npm install -g @deepseek-ai/dsh"
  echo "         然后重新运行本脚本。"
  exit 1
  fi
fi
_dl_ver="$(pkg_ver "$DSH_ROOT")"
if [ -z "$_dl_ver" ]; then
  if _dry; then
    echo " DeepSeek Harness：未安装（流程中假定已安装）"
  else
    echo " DeepSeek Harness：未安装"
  fi
else
  echo " DeepSeek Harness：$_dl_ver"
fi
echo ""

# ---------- 1. gyp：node-pty 编译的 android_ndk_path ----------
log "1/13 写入 ~/.gyp/include.gypi (node-pty 编译修复)"
d_mkdir "$HOME_DIR/.gyp"
if grep -q "android_ndk_path" "$HOME_DIR/.gyp/include.gypi" 2>/dev/null; then
  ok "~/.gyp/include.gypi（已存在，跳过）"
else
  d_echo "$HOME_DIR/.gyp/include.gypi" "{'variables':{'android_ndk_path':''}}"
  ok "~/.gyp/include.gypi"
fi

# ---------- 2. npm 镜像 ----------
log "2/13 配置 ~/.npmrc (npmmirror 镜像)"
d_touch "$HOME_DIR/.npmrc"
grep -q '^registry=' "$HOME_DIR/.npmrc" 2>/dev/null || d_echoapp "$HOME_DIR/.npmrc" 'registry=https://registry.npmmirror.com'
grep -q '^foreground-scripts=' "$HOME_DIR/.npmrc" 2>/dev/null || d_echoapp "$HOME_DIR/.npmrc" 'foreground-scripts=true'
ok "~/.npmrc"

# ---------- 3. PATH ----------
log "3/13 配置 ~/.bashrc (PATH 含 ~/bin)"
d_touch "$HOME_DIR/.bashrc"
# 仅清理会导致 HMR 报错的历史 NODE_OPTIONS，保留你自己设置的其它 NODE_OPTIONS
[ -f "$HOME_DIR/.bashrc.bak" ] || d_cp "$HOME_DIR/.bashrc" "$HOME_DIR/.bashrc.bak"
d_sed '/NODE_OPTIONS.*expose-internals/d' "$HOME_DIR/.bashrc"
grep -q 'HOME/bin' "$HOME_DIR/.bashrc" 2>/dev/null || d_echoapp "$HOME_DIR/.bashrc" 'export PATH=$HOME/bin:$PATH'
ok "~/.bashrc"

# ---------- 4. fs.link fallback preload ----------
log "4/13 写入 ~/dsh-link-fix.js (f2fs 硬链接 fallback)"
d_out "$HOME_DIR/dsh-link-fix.js" <<'EOF'
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
log "5/13 写入 ~/bin/dsh (--expose-internals + preload + 权限模式)"
d_mkdir "$HOME_DIR/bin"
d_out "$HOME_DIR/bin/dsh" <<'EOF'
#!__PREFIX__/bin/bash
export DSH_PERMISSION_MODE="${DSH_PERMISSION_MODE:-danger-full-access}"
exec node --expose-internals -r __HOME__/dsh-link-fix.js __PREFIX__/lib/node_modules/@deepseek-ai/dsh/lib/bin.js "$@"
EOF
_fill_paths "$HOME_DIR/bin/dsh"
d_chmod +x "$HOME_DIR/bin/dsh"
ok "~/bin/dsh"

# ---------- 6. bwrap-proot ----------
log "6/13 写入 ~/bin/bwrap-proot (bwrap→proot + PATH + /bin/bash 替换)"
d_out "$HOME_DIR/bin/bwrap-proot" <<'EOF'
#!__PREFIX__/bin/bash
export PATH="__PREFIX__/bin:__PREFIX__/bin/applets:${PATH:-}"
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
      d_mkdir "__PREFIX__/tmp"
      args+=("-b" "__PREFIX__/tmp:$dst") ;;
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
  set -- "__PREFIX__/bin/bash" "${@:2}"
fi
exec proot "${args[@]}" "$@"
EOF
_fill_paths "$HOME_DIR/bin/bwrap-proot"
d_chmod +x "$HOME_DIR/bin/bwrap-proot"
ok "~/bin/bwrap-proot"

# ---------- 7. cordis.patch.yml ----------
# 注意：已存在的文件不会被整体覆盖——只补齐缺失的 id 块，保留你手动添加的其它配置
log "7/13 写入 ~/.dsh/profiles/web/cordis.patch.yml (runnerCommand + shellPath)"
PATCH_YML="$HOME_DIR/.dsh/profiles/web/cordis.patch.yml"
d_mkdir "$(dirname "$PATCH_YML")"
if [ ! -f "$PATCH_YML" ]; then
  d_out "$PATCH_YML" <<'EOF'
- id: sandbox
  config:
    runnerCommand:
      - __HOME__/bin/bwrap-proot
    runnerFailureSignatures:
      - "permission denied"
- id: terminal-bash
  config:
    shellPath: __PREFIX__/bin/bash
EOF
  _fill_paths "$PATCH_YML"
  ok "cordis.patch.yml（新建）"
else
  need_sandbox=0
  need_terminal=0
  grep -qE '^[[:space:]]*-[[:space:]]*id:[[:space:]]*sandbox[[:space:]]*$' "$PATCH_YML" || need_sandbox=1
  grep -qE '^[[:space:]]*-[[:space:]]*id:[[:space:]]*terminal-bash[[:space:]]*$' "$PATCH_YML" || need_terminal=1
  if [ "$need_sandbox" = 1 ]; then
    d_outa "$PATCH_YML" <<'EOF'

- id: sandbox
  config:
    runnerCommand:
      - __HOME__/bin/bwrap-proot
    runnerFailureSignatures:
      - "permission denied"
EOF
  fi
  if [ "$need_terminal" = 1 ]; then
    d_outa "$PATCH_YML" <<'EOF'

- id: terminal-bash
  config:
    shellPath: __PREFIX__/bin/bash
EOF
  fi
  _fill_paths "$PATCH_YML"
  if [ "$need_sandbox" = 0 ] && [ "$need_terminal" = 0 ]; then
    ok "cordis.patch.yml（已含 sandbox + terminal-bash，跳过）"
  else
    ok "cordis.patch.yml（已补齐缺失块）"
  fi
fi

# ---------- 8. subprocess-local：terminal inspection 的 android 兼容 ----------
# dsh 0.1.5+ 把 createProcessInspector 拆进 lib/runner-launch-<hash>.js（hash 每次发版都变），
# 因此这里按特征字符串「new LinuxProcessInspector」动态定位文件，绝不写死文件名。
log "8/13 补丁 dsh-subprocess-local (terminal inspection android)"
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
      [ -f "$f.bak" ] || d_cp "$f" "$f.bak"
      # 双引号写法（当前版本）
      d_sed 's/if (platform === "linux") return new LinuxProcessInspector/if (platform === "linux" || platform === "android") return new LinuxProcessInspector/' "$f"
      # 单引号写法（旧版本）
      d_sed "s/if (platform === 'linux') return new LinuxProcessInspector/if (platform === 'linux' || platform === 'android') return new LinuxProcessInspector/" "$f"
      if _dry; then sb_hit=$((sb_hit+1)); elif grep -qE 'platform === .android.' "$f"; then sb_hit=$((sb_hit+1)); fi
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
log "9/13 补丁 dsh-terminal-bash (shellPath 默认值)"
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
      [ -f "$f.bak" ] || d_cp "$f" "$f.bak"
      # rc.6 旧写法：shellPath: z.string().default("/bin/bash")
      d_sed 's|shellPath: z.string().default("/bin/bash")|shellPath: z.string().default("'"$BASH_PATH"'")|' "$f"
      # rc.7+ 新写法：const DEFAULT_BASH_SHELL = "/bin/bash";
      d_sed 's|const DEFAULT_BASH_SHELL = "/bin/bash";|const DEFAULT_BASH_SHELL = "'"$BASH_PATH"'";|' "$f"
      if _dry; then tb_hit=$((tb_hit+1)); elif grep -qF "$BASH_PATH" "$f"; then tb_hit=$((tb_hit+1)); fi
    done
    if [ "$tb_hit" -gt 0 ]; then
      ok "dsh-terminal-bash 已打补丁（$tb_hit 个文件）"
    else
      fail "sed 未生效——dsh 代码结构可能已变，请人工检查 $TB_ROOT/lib"
    fi
  fi
fi

# ---------- 10. sharp WASM（attachment-local 依赖 sharp，android-arm64 无原生二进制） ----------
log "10/13 补装 sharp WASM (@img/sharp-wasm32 + @emnapi)"
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
        d_mkdir "$HOME_DIR/sharp-wasm"
        if _dry; then
          d_log "npm init -y（在 ~/sharp-wasm）"
          d_log "npm install @img/sharp-wasm32@$SHARP_VER"
        else
          (
            cd "$HOME_DIR/sharp-wasm" || exit 1
            [ -f package.json ] || npm init -y >/dev/null 2>&1
            NODE_OPTIONS="-r $HOME_DIR/dsh-link-fix.js" npm install "@img/sharp-wasm32@$SHARP_VER" >/dev/null 2>&1
          )
        fi
      fi
      if _dry; then
        ok "（模拟）将拷入 sharp-wasm32 + emnapi  $(tagwarn "预计通过：需联网装 @img/sharp-wasm32")"
      elif [ -d "$WASM_SRC/@img/sharp-wasm32" ]; then
        d_mkdir "$DSH_NM/@img"
        d_cp -r "$WASM_SRC/@img/sharp-wasm32" "$DSH_NM/@img/"
        [ -d "$WASM_SRC/@emnapi" ] && d_cp -r "$WASM_SRC/@emnapi" "$DSH_NM/"
        if _dry; then
          ok "（模拟）已拷入 sharp-wasm32 + emnapi"
        elif ( cd "$DSH_ROOT" && node -e "import('sharp').then(()=>process.exit(0)).catch(()=>process.exit(1))" ) >/dev/null 2>&1; then
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
log "11/13 补丁 dsh-client-connection (SameSite Strict→Lax)"
CC_ROOT="$DSH_NM/@deepseek-ai/dsh-client-connection"
if [ ! -d "$CC_ROOT" ]; then
  skip "dsh-client-connection 未安装（跳过）"
elif _dry || grep -rqF --exclude='*.bak' "SameSite=Lax" "$CC_ROOT/lib" 2>/dev/null; then
  ok "dsh-client-connection 已打补丁（跳过）"
else
  cc_files=$(grep -rlF --exclude='*.bak' "SameSite=Strict" "$CC_ROOT/lib" 2>/dev/null)
  if [ -z "$cc_files" ]; then
    fail "未找到 SameSite=Strict——dsh 版本可能已变，请人工检查 $CC_ROOT/lib"
  else
    for f in $cc_files; do
      [ -f "$f.bak" ] || d_cp "$f" "$f.bak"
      d_sed 's/SameSite=Strict/SameSite=Lax/' "$f"
    done
    if _dry || grep -rqF --exclude='*.bak' "SameSite=Lax" "$CC_ROOT/lib" 2>/dev/null; then
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
log "12/13 补丁 node-addon-require-builtin (Android 无原生 binding，改用 --expose-internals)"
NA_ROOT="$DSH_NM/node-addon-require-builtin"
NA_FILE="$NA_ROOT/lib/index.js"
if [ ! -f "$NA_FILE" ]; then
  skip "node-addon-require-builtin 未安装（跳过）"
elif grep -q "js-expose-internals" "$NA_FILE" 2>/dev/null; then
  ok "node-addon-require-builtin 已替换为 JS 实现（跳过）"
elif ! node --expose-internals -e "require('internal/modules/esm/loader')" >/dev/null 2>&1; then
  fail "当前 Node 不支持 --expose-internals，JS 兜底无法生效（请确认用 ~/bin/dsh 启动）"
else
  [ -f "$NA_FILE.bak" ] || d_cp "$NA_FILE" "$NA_FILE.bak"
  d_out "$NA_FILE" <<'EOF_JS'
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

# ---------- 13. node-addon-system：flock 的 android-arm64 ----------
# 官方只发了 darwin / linux 预编译产物，没有 android-arm64。而 dsh-session-persistence-jsonl
# 用它给每个 session 的 session.lock 加内核级独占锁，缺失会直接让 Agent 每轮运行失败
# （flock is not supported on android-arm64）。同一包的 landlock-run 缺失只会被探针判为
# unusable 并自动降级，flock 则是硬失败，所以只需要救这一个。
# 包里自带 src/flock.c（Node-API v8，只依赖 node_api.h 与 sys/file.h，Android bionic 有
# flock()），所以本地用 clang 编成 system.node，放进自建的平台包，再放开平台守卫。
log "13/13 补丁 node-addon-system (flock 的 android-arm64 本地编译)"
NS_ROOT="$DSH_NM/@deepseek-ai/node-addon-system"
if [ ! -d "$NS_ROOT" ]; then
  NS_ROOT=$(find "$DSH_NM" -maxdepth 4 -type d -path "*@deepseek-ai/node-addon-system" \
            -not -path "*/node-addon-system/node_modules/*" 2>/dev/null | head -1)
fi
if [ ! -d "$NS_ROOT" ]; then
  skip "node-addon-system 未安装（跳过）"
elif [ ! -f "$NS_ROOT/src/flock.c" ]; then
  fail "包内没有 src/flock.c（官方可能不再随包发源码），无法本地编译"
elif [ ! -f "$PREFIX/include/node/node_api.h" ]; then
  fail "缺少 Node 头文件（$PREFIX/include/node/node_api.h）"
elif ! command -v clang >/dev/null 2>&1; then
  fail "未找到 clang，无法编译 flock.c（可执行：pkg install clang）"
else
  NS_DEST="$NS_ROOT/node_modules/@deepseek-ai/node-addon-system-android-arm64"
  d_mkdir "$NS_DEST/bin"
  d_out "$NS_DEST/package.json" <<EOF_PKG
{
  "name": "@deepseek-ai/node-addon-system-android-arm64",
  "version": "$(pkg_ver "$NS_ROOT")",
  "main": "package.json",
  "license": "BSD-3-Clause"
}
EOF_PKG

  if [ -f "$NS_DEST/bin/system.node" ] && [ "$NS_DEST/bin/system.node" -nt "$NS_ROOT/src/flock.c" ]; then
    ok "system.node 已是最新（跳过编译）"
  else
    # NAPI_MODULE_INIT 导出 napi_register_module_v1，不需要 node-gyp / binding.gyp
    if _dry; then
      d_log "clang -shared -fPIC -O2 -I$PREFIX/include/node -o $NS_DEST/bin/system.node（不实际编译）"
      if have clang; then
        ok "（模拟）将编译 system.node  $(tagok "预计通过")"
      else
        ok "（模拟）将编译 system.node  $(tagbad "预计失败：clang 缺失")"
      fi
    else
    clang -shared -fPIC -O2 -I"$PREFIX/include/node" \
      -o "$NS_DEST/bin/system.node" "$NS_ROOT/src/flock.c" 2>/dev/null
    if [ -f "$NS_DEST/bin/system.node" ]; then
      ok "已编译 system.node（$NS_DEST/bin/system.node）"
    else
      fail "clang 编译失败，请手动执行看报错："
      echo "         clang -shared -fPIC -O2 -I\"$PREFIX/include/node\" -o \"$NS_DEST/bin/system.node\" \"$NS_ROOT/src/flock.c\""
    fi
    fi
  fi

  # 自检脚本：真的 import flock.js 并取得一次锁（成功 exit 0）
  d_out "$HOME_DIR/dsh-flock-check.mjs" <<'EOF_MJS'
import { closeSync, openSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
const root = process.argv[2];
const { tryLockExclusive } = await import(pathToFileURL(join(root, 'lib', 'flock.js')).href);
const lockPath = join(process.env.HOME || '.', '.dsh-flock-check.lock');
const fd = openSync(lockPath, 'w');
try {
  await tryLockExclusive(fd);
} finally {
  closeSync(fd);
  rmSync(lockPath, { force: true });
}
EOF_MJS

  ns_files=$(grep -rlF --exclude='*.bak' "flock is not supported on" "$NS_ROOT/lib" 2>/dev/null)
  if [ -z "$ns_files" ]; then
    fail "未找到 flock 平台守卫——dsh 结构可能已变，请人工检查 $NS_ROOT/lib"
  else
    ns_hit=0
    for f in $ns_files; do
      if grep -qE "platform !== .android." "$f"; then
        ns_hit=$((ns_hit+1)); continue
      fi
      [ -f "$f.bak" ] || d_cp "$f" "$f.bak"
      # 单引号写法（当前版本）
      d_sed "s/if (platform !== 'linux' && platform !== 'darwin')/if (platform !== 'linux' \&\& platform !== 'darwin' \&\& platform !== 'android')/" "$f"
      # 双引号写法（兼容）
      d_sed 's/if (platform !== "linux" && platform !== "darwin")/if (platform !== "linux" \&\& platform !== "darwin" \&\& platform !== "android")/' "$f"
      if _dry; then ns_hit=$((ns_hit+1)); elif grep -qE "platform !== .android." "$f"; then ns_hit=$((ns_hit+1)); fi
    done
    if [ "$ns_hit" -gt 0 ]; then
      ok "node-addon-system 已打补丁（$ns_hit 个文件）"
    else
      fail "sed 未生效——请人工检查 $NS_ROOT/lib"
    fi
  fi
fi

# ---------- 14. dsh-attachment-local：Android 附件目录 fsync 的权限容错 ----------
# 写附件时，publishImmutableObject 会把附件目录一路 open+fsync 到文件系统根 "/"；
# 走到 /data/data 时 Termux 用户无读权限 → EACCES → 被上层兜底成
# "prompt rejected (session/agent-busy)"，表现为"一贴图就发不出去"。
# 这里给 syncDirectory() 加上 EACCES/EPERM/ENOENT/EROFS 容错（跳过该层 fsync）。
log "14/14 补丁 dsh-attachment-local (Android 目录 fsync 权限容错)"
AL_ROOT="$DSH_NM/@deepseek-ai/dsh-attachment-local"
if [ ! -d "$AL_ROOT" ]; then
  skip "dsh-attachment-local 未安装（跳过）"
elif [ ! -f "$AL_ROOT/lib/index.js" ]; then
  fail "未找到 $AL_ROOT/lib/index.js"
else
  AL_OUT=$(DRY_RUN="$DRY_RUN" node - "$AL_ROOT/lib/index.js" <<'ALJS'
const fs = require("fs");
const p = process.argv[2];
const MARK = "dsh-android-sync-guard";
let s = fs.readFileSync(p, "utf8");
if (s.indexOf(MARK) >= 0) { console.log("ALREADY"); process.exit(0); }
const origOpen = "\tconst handle = await open(path, constants.O_RDONLY);\n";
const origSync = "\t\tawait handle.sync();\n";
if (s.indexOf(origOpen) < 0 || s.indexOf(origSync) < 0) { console.log("NOMATCH"); process.exit(2); }
if (process.env.DRY_RUN === "1") { console.log("WOULD_PATCH"); process.exit(0); }
fs.copyFileSync(p, p + ".bak");
const patchedOpen =
  "\tlet handle;\n" +
  "\t/* " + MARK + ": Android 上 /data/data 等祖先目录不可读，跳过该层 fsync */\n" +
  "\ttry {\n" +
  "\t\thandle = await open(path, constants.O_RDONLY);\n" +
  "\t} catch (error) {\n" +
  "\t\tif (error && (error.code === \"EACCES\" || error.code === \"EPERM\" || error.code === \"ENOENT\" || error.code === \"EROFS\")) return;\n" +
  "\t\tthrow error;\n" +
  "\t}\n";
const patchedSync =
  "\t\ttry {\n" +
  "\t\t\tawait handle.sync();\n" +
  "\t\t} catch (error) {\n" +
  "\t\t\tif (!(error && (error.code === \"EACCES\" || error.code === \"EPERM\" || error.code === \"EINVAL\" || error.code === \"EROFS\"))) throw error;\n" +
  "\t\t}\n";
fs.writeFileSync(p, s.replace(origOpen, patchedOpen).replace(origSync, patchedSync));
console.log("PATCHED");
ALJS
)
  case "$AL_OUT" in
    PATCHED) ok "dsh-attachment-local 已打补丁（目录 fsync 权限容错）" ;;
    WOULD_PATCH) ok "（模拟）将打补丁（目录 fsync 权限容错）" ;;
    ALREADY) ok "dsh-attachment-local 已打补丁（跳过）" ;;
    NOMATCH) fail "未找到 syncDirectory 特征串——dsh 结构可能已变，请人工检查 $AL_ROOT/lib/index.js" ;;
    *)       fail "补丁失败：$AL_OUT" ;;
  esac
fi


# ============ 自检 ============
bar
echo " 自检结果"
bar

if _dry; then
  emit_info "  " "模拟运行下跳过自检"
  echo
  return 0
fi

c=0
TOTAL=14

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
check_pkg "attachment-local (android fsync)" "$DSH_NM/@deepseek-ai/dsh-attachment-local" "dsh-android-sync-guard"

# flock 自检：产物存在、flock.js 已放开 android、真能拿到一次锁
if [ -d "$NS_ROOT" ]; then
  check "flock android (产物 + 可获锁)"  node "$HOME_DIR/dsh-flock-check.mjs" "$NS_ROOT"
else
  TOTAL=$((TOTAL-1))
  echo "  [SKIP] flock android（node-addon-system 未安装）"
fi

# sharp 自检只在 dsh 确实依赖 sharp 时计入
if [ -d "$SHARP_DIR" ]; then
  TOTAL=$((TOTAL+1))
  check "sharp-wasm32 (已就位)"        test -d "$DSH_NM/@img/sharp-wasm32"
else
  echo "  [SKIP] sharp-wasm32（当前 dsh 未依赖 sharp）"
fi

bar
echo " 完成：$c / $TOTAL 项通过"
echo ""
echo " 说明："
echo "   - 第 8、9、11、12、13、14 项为包级修改，首次执行会自动备份 .bak"
echo "   - 包级补丁按「特征字符串」动态定位文件，适配 dsh 拆包 / 改 hash 名"
echo "   - npm 更新 dsh 后，包级补丁会被覆盖，请重新运行本脚本"
echo "   - 第 10 项会自动匹配当前 sharp 版本并复用 ~/sharp-wasm 缓存"
echo "   - 第 13 项用 clang 本地编译 flock.c（依赖随 nodejs 包提供的 node_api.h）"
echo "   - 打完补丁后，用 'dsh web' 启动（建议先 cd ~/workspace）"

  # 返回码即结论：全绿 0，有未通过 1（供 all / CI 判定）
  if [ "$c" -eq "$TOTAL" ]; then
    return 0
  fi

  return 1
}


# ============================================================
# 命令分发
# ============================================================

# ---------- uninstall：卸载 dsh 本体与全部补丁（正规方式） ----------
cmd_uninstall() {
  DRY_RUN=0
  local ASSUME=0 ONLY_PATCH=0 ONLY_DSH=0 KEEP_CONF=0 PURGE_DATA=0 LIST_ONLY=0 a NARG=$#
  for a in "$@"; do
    case "$a" in
      --dry-run)     DRY_RUN=1 ;;
      --yes|-y)      ASSUME=1 ;;
      --only-patches) ONLY_PATCH=1 ;;
      --only-dsh)    ONLY_DSH=1 ;;
      --keep-config) KEEP_CONF=1 ;;
      --purge-data)  PURGE_DATA=1 ;;
      --list)        LIST_ONLY=1 ;;
      1)             : ;;                       # 全卸（默认）
      2)             ONLY_PATCH=1 ;;
      3)             ONLY_DSH=1 ;;
      4)             KEEP_CONF=1 ;;
      5)             PURGE_DATA=1 ;;
      *) echo; echo "  [FAIL] uninstall 不识别：$a"; echo "        可用：编号 1~5 或 --only-patches / --only-dsh / --keep-config / --purge-data / --list / --yes / --dry-run"; exit 1 ;;
    esac
  done
  [ "$NARG" -eq 0 ] && LIST_ONLY=1   # 不带参数 → 只看范围，不动手
  if [ "$LIST_ONLY" -eq 1 ]; then
    say "dsh-termux-fix 卸载范围"
    _bl() { printf '  [%s] %s\n' "$1" "$2"; }
    _rm() { emit_info "      " "删除：$1"; shift; }
    _p()  { emit_info "            " "$*"; }
    _pf() { local f r d; for f in "$@"; do r="${f/#\~/$HOME_DIR}"; d="$(_sz "$r")"; emit_info "            " "$f  $d"; done }
    _kp() { emit_info "      " "保留：$1"; shift; }

    _bl 1 "全卸：DeepSeek Harness 本体 + 全部补丁"
    _rm "@deepseek-ai/dsh（npm uninstall -g，不删包目录）"
    _pf "~/bin/dsh"
    _pf "~/bin/bwrap-proot"
    _pf "~/dsh-link-fix.js"
    _pf "~/dsh-flock-check.mjs"
    _pf "~/.gyp/include.gypi"
    _p "~/.npmrc（仅本脚本加的 2 行）"
    _p "~/.bashrc（仅本脚本加的 1 行）"
    _kp "~/.dsh（聊天记录）"
    _pf "~/workspace"
    _pf "~/dsh-backups"
    emit_info "      " "快捷：uninstall 1    （等同 uninstall）"
    echo

    _bl 2 "只卸补丁：删启动器与兼容文件，留下 dsh 本体"
    _rm "下列补丁文件"
    _pf "~/bin/dsh"
    _pf "~/bin/bwrap-proot"
    _pf "~/dsh-link-fix.js"
    _pf "~/dsh-flock-check.mjs"
    _pf "~/.gyp/include.gypi"
    _p "~/.npmrc、~/.bashrc 中本脚本加的那几行"
    _kp "@deepseek-ai/dsh（本体）"
    _pf "~/.dsh"
    _pf "~/workspace"
    emit_info "      " "快捷：uninstall 2    （等同 --only-patches）"
    echo

    _bl 3 "只卸本体：npm 卸载 dsh，补丁文件全留"
    _rm "@deepseek-ai/dsh（npm uninstall -g）"
    _kp "下列补丁文件全部不动"
    _pf "~/bin/dsh"
    _pf "~/bin/bwrap-proot"
    _pf "~/dsh-link-fix.js"
    _pf "~/dsh-flock-check.mjs"
    _pf "~/.gyp/include.gypi"
    emit_info "      " "快捷：uninstall 3    （等同 --only-dsh）"
    echo

    _bl 4 "全卸但保留配置"
    _rm "@deepseek-ai/dsh"
    _pf "~/bin/dsh"
    _pf "~/bin/bwrap-proot"
    _pf "~/dsh-link-fix.js"
    _pf "~/dsh-flock-check.mjs"
    _kp "~/.npmrc、~/.bashrc（一个字不动）"
    _pf "~/.dsh"
    _pf "~/workspace"
    emit_info "      " "快捷：uninstall 4    （等同 --keep-config）"
    echo

    _bl 5 "全卸，并删掉聊天记录（~/.dsh）"
    _rm "同第 1 项，另加下列内容"
    _p "~/.dsh/sessions/*（全部对话记录）"
    _p "~/.dsh/profiles/web/cordis.patch.yml（网页端设置）"
    _kp "~/workspace"
    _pf "~/dsh-backups"
    _p "二次确认时要输入 PURGE"
    emit_info "      " "快捷：uninstall 5    （等同 --purge-data）"
    echo
    emit_info "  " "不带参数 = 只看范围，不动手"
    emit_info "  " "卸载前建议先备份：backup"
    return 0
  fi
  if [ "$ONLY_PATCH" -eq 1 ] && [ "$ONLY_DSH" -eq 1 ]; then
    echo; echo "  [FAIL] --only-patches 与 --only-dsh 不能同时用"; echo "        一次只能选一种范围。"; echo; exit 1
  fi
  local DO_DSH=1 DO_PATCH=1 DO_CONF=1 SCOPE
  [ "$ONLY_PATCH" -eq 1 ] && DO_DSH=0
  [ "$ONLY_DSH" -eq 1 ] && DO_PATCH=0
  [ "$DO_PATCH" -eq 0 ] && DO_CONF=0
  [ "$KEEP_CONF" -eq 1 ] && DO_CONF=0
  if [ "$DO_DSH" -eq 1 ] && [ "$DO_PATCH" -eq 1 ]; then SCOPE="本体 + 补丁"
  elif [ "$DO_DSH" -eq 1 ]; then SCOPE="仅本体，补丁保留"
  else SCOPE="仅补丁，本体保留"; fi

  dry_banner
  say "dsh-termux-fix 卸载"
  warn "卸载范围：$SCOPE"
  if [ "$DO_DSH" -eq 1 ]; then
    local cur=""; cur="$(pkg_ver "$DSH_ROOT" 2>/dev/null || true)"
    emit_info "      " "本体：${cur:-未安装} → npm uninstall -g @deepseek-ai/dsh（不删包目录）"
  else
    emit_info "      " "本体：保留（不动 npm 包）"
  fi
  if [ "$DO_PATCH" -eq 1 ]; then
    emit_info "      " "补丁：~/bin/dsh  ~/bin/bwrap-proot  ~/dsh-link-fix.js  ~/dsh-flock-check.mjs  ~/.gyp/include.gypi"
  else
    emit_info "      " "补丁：保留（wrapper 等文件不动）"
  fi
  if [ "$DO_CONF" -eq 1 ]; then
    emit_info "      " "配置：只删本脚本加的 3 行（~/.npmrc 2 行、~/.bashrc 1 行）"
  else
    emit_info "      " "配置：保留（只说明，不改文件）"
  fi
  echo
  if [ "$PURGE_DATA" -eq 1 ]; then
    warn "另将删除：~/.dsh（全部聊天记录 + 网页端设置）"
  else
    ok "保留不动：~/.dsh（会话与配置）、~/workspace（工作区）、~/dsh-backups（备份）"
  fi
  echo
  warn "建议先备份：bash ~/apply-dsh-patches.sh backup"

  if [ "$DRY_RUN" -eq 0 ] && [ "$ASSUME" -eq 0 ]; then
    local ans=""
    printf ' 继续卸载？输入 yes 确认，其他取消：'
    read -r ans || ans=""
    if [ "$ans" != "yes" ]; then echo; warn "已取消，未做任何修改"; return 1; fi
    if [ "$PURGE_DATA" -eq 1 ]; then
      printf ' 危险：将删除 ~/.dsh 聊天记录。确认请输入 PURGE，其他取消：'
      read -r ans || ans=""
      if [ "$ans" != "PURGE" ]; then echo; warn "已取消，未做任何修改"; return 1; fi
    fi
    echo
  fi

  # 1) 本体（走 npm 正规卸载）
  if [ "$DO_DSH" -eq 1 ]; then
    log "1/3 卸载 dsh 本体"
    d_npm uninstall -g @deepseek-ai/dsh
  else
    skip "--only-patches：本体保留"
  fi
  # 2) 补丁产物
  if [ "$DO_PATCH" -eq 1 ]; then
    log "2/3 删除补丁产物"
    local f
    for f in "$HOME_DIR/bin/dsh" "$HOME_DIR/bin/bwrap-proot" "$HOME_DIR/dsh-link-fix.js" "$HOME_DIR/dsh-flock-check.mjs" "$HOME_DIR/.gyp/include.gypi"; do
      if [ -e "$f" ]; then
        d_rm "$f"
        [ "$DRY_RUN" -eq 1 ] || ok "已删 ${f#$HOME_DIR/}"
      else
        skip "${f#$HOME_DIR/} 不存在（跳过）"
      fi
    done
  else
    skip "--only-dsh：补丁保留"
  fi
  # 3) 配置行
  if [ "$DO_CONF" -eq 1 ]; then
    log "3/3 清理本脚本写入的配置行"
    if [ -f "$HOME_DIR/.npmrc" ]; then
      d_sed -i '/^registry=https:\/\/registry.npmmirror.com$/d' "$HOME_DIR/.npmrc"
      d_sed -i '/^foreground-scripts=true$/d' "$HOME_DIR/.npmrc"
      [ "$DRY_RUN" -eq 1 ] || ok "已清理 ~/.npmrc 中本脚本加的 2 行"
    else
      skip "~/.npmrc 不存在（跳过）"
    fi
    if [ -f "$HOME_DIR/.bashrc" ]; then
      d_sed -i '/^export PATH=\$HOME\/bin:\$PATH$/d' "$HOME_DIR/.bashrc"
      [ "$DRY_RUN" -eq 1 ] || ok "已清理 ~/.bashrc 中本脚本加的 1 行"
    else
      skip "~/.bashrc 不存在（跳过）"
    fi
  else
    skip "配置保留（--only-dsh / --keep-config）"
  fi
  # 4) 可选：删掉 ~/.dsh
  if [ "$PURGE_DATA" -eq 1 ]; then
    log "4/4 删除 ~/.dsh（聊天记录 + 网页端设置）"
    if [ -d "$HOME_DIR/.dsh" ]; then
      d_rm -rf "$HOME_DIR/.dsh"
      [ "$DRY_RUN" -eq 1 ] || ok "已删 ~/.dsh"
    else
      skip "~/.dsh 不存在（跳过）"
    fi
  fi

  echo
  if [ "$DRY_RUN" -eq 1 ]; then
    info "模拟结束（--dry-run，未做任何修改）"
  else
    ok "卸载完成（范围：$SCOPE）"
    info "重新安装：bash ~/apply-dsh-patches.sh all"
  fi
  return 0
}

# ============================================================
# backup
# ============================================================
cmd_backup() {
  DRY_RUN=0
  local ANY=0 B_SESS=0 B_CONF=0 B_PATCH=0 B_WS=0 B_DEST="" LIST_ONLY=0 a NARG=$#
  for a in "$@"; do
    case "$a" in
      --dry-run)   DRY_RUN=1 ;;
      --all)       ANY=1 ;;
      --sessions)  ANY=1; B_SESS=1 ;;
      --config)    ANY=1; B_CONF=1 ;;
      --patches)   ANY=1; B_PATCH=1 ;;
      --workspace) ANY=1; B_WS=1 ;;
      --dest=*)    ANY=1; B_DEST="${a#--dest=}" ;;
      --list)      LIST_ONLY=1 ;;
      1)           ANY=1; B_SESS=1 ;;
      2)           ANY=1; B_CONF=1 ;;
      3)           ANY=1; B_PATCH=1 ;;
      4)           ANY=1; B_WS=1 ;;
      *) echo; echo "  [FAIL] backup 不识别：$a"; echo "        可用：编号 1~4 或 --all --sessions --config --patches --workspace --dest=路径 --list --dry-run"; exit 1 ;;
    esac
  done
  [ "$NARG" -eq 0 ] && LIST_ONLY=1   # 不带参数 → 只看范围，不备份
  if [ "$LIST_ONLY" -eq 1 ]; then
    say "dsh-termux-fix 备份范围"
    local sz n f
    _bl() { printf '  [%s] %s  %s\n' "$1" "$2" "$3"; }
    _pth() {
      local i=0 f r d
      for f in "$@"; do
        r="${f/#\~/$HOME_DIR}"; d="$(_sz "$r")"
        if [ "$i" -eq 0 ]; then emit_info "      " "路径：$f  $d"
        else emit_info "            " "$f  $d"; fi
        i=1
      done
    }
    if [ -d "$HOME_DIR/.dsh" ]; then
      sz="$(_sz "$HOME_DIR/.dsh")"; _bl 1 "会话与配置" "$sz"
    else _bl 1 "会话与配置" "（当前没有）"; fi
    _pth "~/.dsh"
    emit_info "      " "内容：sessions/*（聊天记录）+ profiles/web/cordis.patch.yml（网页端设置）"
    emit_info "      " "说明：删了就找不回来，最该保住的一项。"
    emit_info "      " "快捷：backup 1    （等同 --sessions）"
    echo

    local -a cf=( "$HOME_DIR/.npmrc" "$HOME_DIR/.bashrc" "$HOME_DIR/.gyp" "$HOME_DIR/.dsh/profiles/web/cordis.patch.yml" )
    n=0
    for f in "${cf[@]}"; do [ -e "$f" ] && n=$((n+1)); done
    _bl 2 "全局配置" "$n 个文件  $(_szs "${cf[@]}")"
    _pth "~/.npmrc" "~/.bashrc" "~/.gyp/" "~/.dsh/profiles/web/cordis.patch.yml"
    emit_info "      " "说明：npm 镜像、终端 PATH、编译参数、网页端补丁设置；换手机或重装时靠它还原。"
    emit_info "      " "快捷：backup 2    （等同 --config）"
    echo

    local -a pf=( "$HOME_DIR/bin/dsh" "$HOME_DIR/bin/bwrap-proot" "$HOME_DIR/dsh-link-fix.js" "$HOME_DIR/dsh-flock-check.mjs" )
    n=0
    for f in "${pf[@]}"; do [ -e "$f" ] && n=$((n+1)); done
    _bl 3 "补丁产物" "$n 个文件  $(_szs "${pf[@]}")"
    _pth "~/bin/dsh" "~/bin/bwrap-proot" "~/dsh-link-fix.js" "~/dsh-flock-check.mjs"
    emit_info "      " "说明：让 dsh 能在 Termux 里跑起来的启动器和兼容文件；不想重新打补丁就用它还原。"
    emit_info "      " "快捷：backup 3    （等同 --patches）"
    echo

    if [ -d "$HOME_DIR/workspace" ]; then
      sz="$(_sz "$HOME_DIR/workspace")"; _bl 4 "工作区" "$sz"
    else _bl 4 "工作区" "（当前没有）"; fi
    _pth "~/workspace"
    emit_info "      " "说明：dsh 干活时产生的文件，比如你的游戏项目和图片；通常体积最大。"
    emit_info "      " "快捷：backup 4    （等同 --workspace）"
    echo
    emit_info "  " "不带参数 = 只看范围，不备份"
    emit_info "  " "全量：backup --all"
    emit_info "  " "按编号：backup 1 3（可多选）"
    emit_info "  " "按选项：backup --sessions --patches"
    return 0
  fi
  if [ "$ANY" -eq 0 ]; then B_SESS=1; B_CONF=1; B_PATCH=1; B_WS=1; fi
  dry_banner
  say "dsh-termux-fix 备份"
  local ROOT STAMP DEST REL
  ROOT="${B_DEST:-$HOME_DIR/dsh-backups}"
  STAMP="$(date +%Y%m%d-%H%M%S)"
  DEST="$ROOT/$STAMP"
  info "备份目录：$DEST"
  d_mkdir "$DEST"
  local n=0
  if [ "$B_SESS" -eq 1 ]; then
    if [ -d "$HOME_DIR/.dsh" ]; then
      d_tar "$DEST/dsh-home.tar.gz" "$HOME_DIR" .dsh
      [ "$DRY_RUN" -eq 1 ] || ok "dsh-home.tar.gz  $(du -h "$DEST/dsh-home.tar.gz" 2>/dev/null | cut -f1)"
      n=$((n+1))
    else
      skip "~/.dsh 不存在（会话 / 配置未生成，跳过）"
    fi
  fi
  if [ "$B_CONF" -eq 1 ]; then
    local cf=() f
    for f in "$HOME_DIR/.npmrc" "$HOME_DIR/.bashrc" "$HOME_DIR/.gyp" "$HOME_DIR/.dsh/profiles/web/cordis.patch.yml"; do
      [ -e "$f" ] && cf+=("${f#$HOME_DIR/}")
    done
    if [ "${#cf[@]}" -gt 0 ]; then
      d_tar "$DEST/config.tar.gz" "$HOME_DIR" "${cf[@]}"
      [ "$DRY_RUN" -eq 1 ] || ok "config.tar.gz  ${cf[*]}"
      n=$((n+1))
    else
      skip "没有可备份的配置（.npmrc / .bashrc / .gyp / cordis.patch.yml）"
    fi
  fi
  if [ "$B_PATCH" -eq 1 ]; then
    local pf=() f
    for f in "$HOME_DIR/bin/dsh" "$HOME_DIR/bin/bwrap-proot" "$HOME_DIR/dsh-link-fix.js" "$HOME_DIR/dsh-flock-check.mjs"; do
      [ -e "$f" ] && pf+=("${f#$HOME_DIR/}")
    done
    if [ "${#pf[@]}" -gt 0 ]; then
      d_tar "$DEST/patches.tar.gz" "$HOME_DIR" "${pf[@]}"
      [ "$DRY_RUN" -eq 1 ] || ok "patches.tar.gz  ${pf[*]}"
      n=$((n+1))
    else
      skip "没有补丁产物（~/bin / dsh-link-fix.js）"
    fi
  fi
  if [ "$B_WS" -eq 1 ]; then
    if [ -d "$HOME_DIR/workspace" ]; then
      d_tar "$DEST/workspace.tar.gz" "$HOME_DIR" workspace
      [ "$DRY_RUN" -eq 1 ] || ok "workspace.tar.gz  $(du -h "$DEST/workspace.tar.gz" 2>/dev/null | cut -f1)"
      n=$((n+1))
    else
      skip "~/workspace 不存在（没有工作区内容）"
    fi
  fi
  d_out "$DEST/MANIFEST.txt" <<EOF
备份时间：$(date "+%Y-%m-%d %H:%M:%S")
DeepSeek Harness：$(pkg_ver "$DSH_ROOT" 2>/dev/null || echo 未安装)
平台：$(uname -m) / Android $(getprop ro.build.version.release 2>/dev/null || echo ?)
包含项数：$(echo "$n")

还原方式：
  tar xzf dsh-home.tar.gz -C ~      # 会话与配置
  tar xzf config.tar.gz   -C ~      # shell / npm / cordis 配置
  tar xzf patches.tar.gz  -C ~      # 补丁产物（wrapper 等）
  tar xzf workspace.tar.gz -C ~     # 工作区
EOF
  if [ "$DRY_RUN" -eq 1 ]; then
    [ "$n" -gt 0 ] && ok "模拟完成：共 $n 项（未实际打包）"
    echo
    bar; echo " 模拟结束"; bar
  else
    [ "$n" -gt 0 ] || warn "没有任何内容被备份（相关路径都不存在）"
    echo
    bar; echo " 备份完成：$DEST"; bar
    info "还原：tar xzf <某个.tar.gz> -C ~（详见 MANIFEST.txt）"
  fi
  return 0
}

# 不接受选项的命令：带了参数就报错退出（避免“选项没生效但看不出来”）
no_opt_guard() {
  [ "${#ARGS[@]}" -gt 0 ] || return 0
  echo
  echo "  [FAIL] $CMD 不接受选项，收到：${ARGS[*]}"
  echo "        用法：bash ~/apply-dsh-patches.sh $CMD"
  echo
  exit 1
}

# 非 Termux 环境：只读命令放行，会写文件的命令直接拦住（避免写到错误位置）
if [ "$TERMUX_OK" -eq 0 ]; then
  case "$CMD" in
    status|doctor|channels) : ;;          # 只读：照常运行
    patch|install|all|backup|uninstall)   # 会写 Termux 路径：拦住
      echo
      echo "  [FAIL] 找不到 Termux 运行环境：$PREFIX/bin/bash"
      echo "         本脚本只能在 Termux（Android）内运行；$CMD 会写入 Termux 路径，已中止。"
      echo "         仅查看信息可用：status / doctor / channels / help"
      echo
      exit 1
      ;;
    *) : ;;                              # 未知命令交给分派处报错
  esac
fi
case "$CMD" in
  status)  no_opt_guard; cmd_status ;;
  doctor)  no_opt_guard; cmd_doctor ;;
  patch)   cmd_patch "${ARGS[@]}" ;;
  install) cmd_install "${ARGS[@]}" ;;
  all)     cmd_all "${ARGS[@]}" ;;
  channels) no_opt_guard; cmd_channels ;;
  backup)   cmd_backup "${ARGS[@]}" ;;
  uninstall) cmd_uninstall "${ARGS[@]}" ;;
  *)       echo; echo "  [FAIL] 未知命令：$CMD"; echo; usage 1 ;;
esac
