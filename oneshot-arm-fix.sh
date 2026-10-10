#!/bin/sh
# oneshot-arm-fix.sh — 让 Steam 版 OneShot（AppID 420530）在 aarch64 + FEX-Emu /
# Steam Linux Runtime (scout-on-soldier) 环境下正常启动。
#
# 用法:
#   ./oneshot-arm-fix.sh [apply|revert|status|doctor] [-d 游戏目录]
#
# 本脚本只做「改名」和「写包装脚本」，不删除任何游戏文件，可随时 revert 还原。
set -u

ACTION="apply"
GAME_DIR=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    apply|revert|status|doctor) ACTION="$1"; shift ;;
    -d)
      if [ "$#" -lt 2 ]; then echo "错误: -d 需要目录参数" >&2; exit 2; fi
      GAME_DIR="$2"; shift 2 ;;
    -h|--help)
      echo "用法: $0 [apply|revert|status|doctor] [-d /path/to/OneShot]"; exit 0 ;;
    *) echo "未知参数: $1（用 -h 查看帮助）" >&2; exit 2 ;;
  esac
done

# 默认查找 Steam 常见安装路径
if [ -z "$GAME_DIR" ]; then
  for cand in \
    "$HOME/.local/share/Steam/steamapps/common/OneShot" \
    "$HOME/.steam/steam/steamapps/common/OneShot" \
    "$HOME/.steam/root/steamapps/common/OneShot"; do
    if [ -d "$cand" ]; then GAME_DIR="$cand"; break; fi
  done
fi

if [ -z "$GAME_DIR" ] || [ ! -d "$GAME_DIR" ]; then
  echo "错误: 找不到 OneShot 游戏目录，请用 -d /path/to/OneShot 指定" >&2
  exit 1
fi

# 会被禁用的三个自带旧库（按出错顺序）
LIBS="librt.so.1 libcrypt.so.1 libstdc++.so.6"
WRAPPER="$GAME_DIR/oneshot"
REAL_BIN="$GAME_DIR/oneshot.bin"

is_elf() {
  [ -f "$1" ] || return 1
  [ "$(head -c 4 "$1" | od -An -tx1 | tr -d ' \n')" = "7f454c46" ]
}

msg() { printf '%s\n' "$*"; }

apply() {
  changed=0
  for f in $LIBS; do
    src="$GAME_DIR/$f"
    dst="$GAME_DIR/$f.disabled"
    if [ -f "$dst" ]; then
      msg "  [跳过] $f 已禁用"
    elif is_elf "$src"; then
      mv "$src" "$dst" && msg "  [禁用] $f -> $f.disabled" && changed=1
    else
      msg "  [跳过] $f 不存在或非 ELF"
    fi
  done

  if is_elf "$WRAPPER"; then
    mv "$WRAPPER" "$REAL_BIN" && msg "  [改名] oneshot -> oneshot.bin"
  elif [ -f "$REAL_BIN" ]; then
    msg "  [跳过] 包装脚本已存在"
  else
    msg "  [警告] 找不到 oneshot 主程序，跳过包装脚本"
    return 0
  fi

  cat > "$WRAPPER" <<'EOF'
#!/bin/sh
# OneShot 启动包装（由 oneshot-arm-fix.sh 生成）
# - LIBGL_ALWAYS_SOFTWARE: ARM 主机上 x86 容器无可用硬件 GL 驱动，强制 mesa llvmpipe
# - MESA_LOADER_DRIVER_OVERRIDE: 显式指定 swrast，避免探测到不可用的硬件驱动
# 如需诊断动态库加载问题，可加:
#   export LD_DEBUG=libs
#   export LD_DEBUG_OUTPUT=/tmp/lddebug
export LIBGL_ALWAYS_SOFTWARE=1
export MESA_LOADER_DRIVER_OVERRIDE=swrast
exec "$(dirname "$0")/oneshot.bin" "$@"
EOF
  chmod +x "$WRAPPER" && msg "  [写入] 启动包装脚本 oneshot"
  msg ""
  msg "完成。请从 Steam 正常启动游戏（不要用 box64/box86 手动直跑，"
  msg "那会缺少 Steamworks 环境而无法进入游戏）。"
}

revert() {
  for f in $LIBS; do
    if [ -f "$GAME_DIR/$f.disabled" ] && [ ! -f "$GAME_DIR/$f" ]; then
      mv "$GAME_DIR/$f.disabled" "$GAME_DIR/$f" && msg "  [还原] $f"
    fi
  done
  if [ -f "$REAL_BIN" ]; then
    # 仅当 oneshot 是我们生成的包装脚本时才覆盖
    if grep -q "oneshot-arm-fix" "$WRAPPER" 2>/dev/null || ! is_elf "$WRAPPER"; then
      rm -f "$WRAPPER"
      mv "$REAL_BIN" "$WRAPPER" && msg "  [还原] oneshot 主程序"
    else
      msg "  [跳过] oneshot 不是本脚本生成的包装，未改动"
    fi
  fi
  msg "已回滚到原始状态（Steam 校验完整性也会达到同样效果）。"
}

status() {
  msg "游戏目录: $GAME_DIR"
  msg ""
  msg "禁用的旧库:"
  for f in $LIBS; do
    if [ -f "$GAME_DIR/$f.disabled" ]; then st="已禁用"; else st="未禁用"; fi
    msg "  $f: $st"
  done
  msg ""
  msg "启动包装:"
  if is_elf "$WRAPPER"; then
    msg "  oneshot 为原始 ELF（未打补丁）"
  elif [ -f "$REAL_BIN" ]; then
    msg "  oneshot 为包装脚本，原程序 oneshot.bin"
  else
    msg "  状态未知"
  fi
}

doctor() {
  status
  msg ""
  msg "环境检查:"
  if [ -d /dev/dri ]; then msg "  宿主 /dev/dri: 存在"; else msg "  宿主 /dev/dri: 缺失（软件渲染不受影响）"; fi
  log="/tmp/oneshot-game.log"
  if [ -f "$log" ]; then
    msg "  最近错误日志 ($log):"
    grep -iE "error|GLX|EGL|version .* not found" "$log" 2>/dev/null | tail -5 | sed 's/^/    /' \
      || msg "    （无匹配错误）"
  else
    msg "  尚无游戏日志 $log"
  fi
  msg ""
  msg "深入诊断: 在包装脚本里 export LD_DEBUG=libs LD_DEBUG_OUTPUT=/tmp/lddebug，"
  msg "启动一次后 grep 'version .* not found' /tmp/lddebug.* 即可看到缺符号的库。"
}

case "$ACTION" in
  apply)   msg "==> 应用修复 ($GAME_DIR)"; apply ;;
  revert)  msg "==> 回滚修复 ($GAME_DIR)"; revert ;;
  status)  status ;;
  doctor)  doctor ;;
  *)       echo "用法: $0 [apply|revert|status|doctor] [-d /path/to/OneShot]" >&2; exit 2 ;;
esac
