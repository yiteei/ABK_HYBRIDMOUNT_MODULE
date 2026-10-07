#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only

set -euo pipefail

UPSTREAM_SETUP_URL="https://raw.githubusercontent.com/Hybrid-Mount/meta-hybrid_mount/dev/module/vfs/setup.sh"
FS_DIR_NAME="hybridmount"

: "${KERNEL_ROOT:?KERNEL_ROOT is not set (run this through ABK)}"
: "${DEFCONFIG:?DEFCONFIG is not set (run this through ABK)}"

[ -f "$DEFCONFIG" ] \
  || { echo "[hybridmount] defconfig not found: $DEFCONFIG" >&2; exit 1; }

# 上游只支持这几条线，其它线的源码兼容性未验证
if [ -n "${CONFIG:-}" ]; then
  case "$CONFIG" in
    android12-5.10-*|android13-5.15-*|android14-6.1-*|android15-6.6-*|android16-6.12-*) ;;
    *)
      echo "[hybridmount] unsupported kernel line: $CONFIG" >&2
      echo "[hybridmount] supported: android12-5.10, android13-5.15, android14-6.1, android15-6.6, android16-6.12" >&2
      exit 1
      ;;
  esac
else
  echo "[hybridmount] warning: CONFIG is not set; skipping kernel line check" >&2
fi

# GKI 分支把源码放在 common/，其它分支直接在根
if [ -d "$KERNEL_ROOT/common/fs" ]; then
  KERNEL_SRC="$KERNEL_ROOT/common"
else
  KERNEL_SRC="$KERNEL_ROOT"
fi

FS_DIR="$KERNEL_SRC/fs"
[ -d "$FS_DIR" ] || { echo "[hybridmount] no fs/ tree under $KERNEL_SRC" >&2; exit 1; }

# CONFIG_KEYS=n 时 key-type.h 被整段 #ifdef 掉，register_key_type 无声明，该符号通常由 FS_ENCRYPTION 等 select 得到而不写在 defconfig 里，故只认显式值
CONFIG_DIR="$KERNEL_SRC/arch/arm64/configs"
KEYS_STATE=""
KEYS_EVIDENCE=""
for df in "$DEFCONFIG" "$CONFIG_DIR/gki_defconfig" "$CONFIG_DIR/defconfig"; do
  [ -f "$df" ] || continue
  if grep -qE '^CONFIG_KEYS=y$' "$df"; then
    KEYS_STATE="enabled"
    KEYS_EVIDENCE="$df"
    break
  fi
  if grep -qE '^# CONFIG_KEYS is not set$' "$df"; then
    KEYS_STATE="disabled"
    KEYS_EVIDENCE="$df"
    break
  fi
done
case "$KEYS_STATE" in
  enabled) echo "[hybridmount] CONFIG_KEYS=y in $KEYS_EVIDENCE" ;;
  disabled) echo "[hybridmount] warning: CONFIG_KEYS is explicitly off in $KEYS_EVIDENCE; hybridmount registers a key type" >&2 ;;
  *) : ;;
esac

# 上游非幂等，重跑即报错，所以判重要求文件与接线都齐，否则上次的残局会被当成已完成卡死
TARGET_DIR="$FS_DIR/$FS_DIR_NAME"
MAKEFILE_LINE='obj-$(CONFIG_HYBRIDMOUNT) += hybridmount/'
KCONFIG_LINE='source "fs/hybridmount/Kconfig"'

integrated() {
  for artifact in hybridmount.c hybridmount.h Kconfig Makefile; do
    [ -f "$TARGET_DIR/$artifact" ] || return 1
  done
  grep -qF "$MAKEFILE_LINE" "$FS_DIR/Makefile" || return 1
  grep -qF "$KCONFIG_LINE" "$FS_DIR/Kconfig" || return 1
}

# 上游只做追加，重跑前要先删净残留接线，否则会留两条重复行
drop_line() {
  grep -qxF "$2" "$1" || return 0
  awk -v l="$2" '$0 != l' "$1" > "$1.hybridmount.tmp"
  cat "$1.hybridmount.tmp" > "$1"
  rm -f "$1.hybridmount.tmp"
}

if integrated; then
  echo "[hybridmount] already integrated at $TARGET_DIR; skipping upstream setup"
else
  rm -rf "$TARGET_DIR"
  drop_line "$FS_DIR/Makefile" "$MAKEFILE_LINE"
  drop_line "$FS_DIR/Kconfig" "$KCONFIG_LINE"
  echo "[hybridmount] running upstream setup in $KERNEL_SRC"
  ( cd "$KERNEL_SRC" && curl -fLSs "$UPSTREAM_SETUP_URL" | bash )
fi

integrated \
  || { echo "[hybridmount] upstream output incomplete: want 4 files in $TARGET_DIR and wiring in fs/Makefile, fs/Kconfig" >&2; exit 1; }

# 上游不碰 defconfig，开关由这里补
if grep -q '^CONFIG_HYBRIDMOUNT=y$' "$DEFCONFIG"; then
  echo "[hybridmount] CONFIG_HYBRIDMOUNT=y already in $DEFCONFIG"
elif grep -q '^CONFIG_HYBRIDMOUNT=' "$DEFCONFIG"; then
  sed -i 's/^CONFIG_HYBRIDMOUNT=.*/CONFIG_HYBRIDMOUNT=y/' "$DEFCONFIG"
  echo "[hybridmount] rewrote CONFIG_HYBRIDMOUNT=y in $DEFCONFIG"
elif grep -q '^# CONFIG_HYBRIDMOUNT is not set$' "$DEFCONFIG"; then
  sed -i 's/^# CONFIG_HYBRIDMOUNT is not set$/CONFIG_HYBRIDMOUNT=y/' "$DEFCONFIG"
  echo "[hybridmount] enabled CONFIG_HYBRIDMOUNT=y in $DEFCONFIG"
else
  printf 'CONFIG_HYBRIDMOUNT=y\n' >> "$DEFCONFIG"
  echo "[hybridmount] appended CONFIG_HYBRIDMOUNT=y to $DEFCONFIG"
fi

echo "[hybridmount] done"
