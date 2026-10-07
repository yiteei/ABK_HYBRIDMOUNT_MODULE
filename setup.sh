#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
#
# ABK Hybrid Mount Module —— ABK 自定义外部模块入口脚本
# =============================================================================
# 目标
#   把 Hybrid Mount 的 VFS 路径重定向内核子系统 hybridmount 以内建（built-in）
#   方式集成进当前 GKI 内核源码树。本仓库不携带内核源码；源码由上游脚本在构建
#   时拉取（见文件末尾“上游脚本”一节）。
#
# 谁在跑这个脚本
#   ABK（App 或 GitHub Actions 流水线）在 CUSTOM_EXTERNAL_MODULE_STAGE 阶段把
#   本仓库浅克隆到 $GITHUB_WORKSPACE/custom_external_module_NN-<仓库名>，然后执行
#   `bash setup.sh`。因此：
#     * cwd = 本仓库根目录，不是内核树；脚本内不得依赖相对路径找内核；
#     * 仓库是 --depth 1 浅克隆，不要依赖 git 历史；
#     * 同一个阶段只执行一次，但重试、以及同时声明两个阶段时会再次执行，
#       所以整段逻辑必须幂等。
#
# 输入（由 ABK 注入）
#   KERNEL_ROOT                  必需。ABK 内核工作区根。GKI 布局下真正的内核
#                                源码根是 $KERNEL_ROOT/common。
#   DEFCONFIG                    必需。本次构建实际使用的 defconfig 路径。
#   CONFIG                       可选。内核线标识，形如 android14-6.1-162。
#                                未注入时仅告警；不属于受支持内核线时直接失败。
#   CUSTOM_EXTERNAL_MODULE_STAGE 只读。本脚本不区分阶段（幂等，两阶段都安全），
#                                故不读取该变量，仅在文档中说明。
#
# 输出 / 副作用（只写内核树与 defconfig，不写工作区其它位置）
#   $KERNEL_SRC/fs/hybridmount/   上游源码 + 上游生成的 Makefile
#   $KERNEL_SRC/fs/Makefile       追加 obj-$(CONFIG_HYBRIDMOUNT) += hybridmount/
#   $KERNEL_SRC/fs/Kconfig        插入 source "fs/hybridmount/Kconfig"
#   $DEFCONFIG                    写入 CONFIG_HYBRIDMOUNT=y
#
# 退出码
#   0  已集成（含“此前已集成、本次判重跳过”）；全部校验通过
#   1  缺必需环境变量 / 不支持的内核线 / defconfig 不存在 / 内核树无 fs/ /
#      上游脚本执行或下载失败 / 集成产物缺失 / fs/Makefile 或 fs/Kconfig 未被改动
#   其它 上游脚本或 curl 自身的退出码经 pipefail 透传
#
# 幂等性
#   整段可重复执行：fs/hybridmount 已存在时跳过上游（上游非幂等，二次执行会以
#   “fs/hybridmount already exists; run --cleanup first”失败）；defconfig 为
#   就地改写，不会追加重复行。
#
# 上游脚本（每次构建实时拉取自 dev 分支，未做版本固定）
#   https://raw.githubusercontent.com/Hybrid-Mount/meta-hybrid_mount/dev/module/vfs/setup.sh
#   上游行为（与本脚本第 3~5 段互相咬合，改动上游时需重核）：
#     * 拒绝在已集成 NoMount 的内核树上工作（二者都劫持 inode 操作，注册的
#       key type 不同，内核不会阻止其共存）；
#     * 下载 hybridmount.c / hybridmount.h / Kconfig / LICENSE，并校验非空；
#     * 自行生成 fs/hybridmount/Makefile，内容含 -std=gnu11（5.18 之前的内核
#       默认 gnu89，而源码使用 C99 声明）；
#     * fs/Makefile 追加一行；fs/Kconfig 在最后一个 endmenu 之前插入一行；
#     * 支持 --cleanup 回滚（本包装脚本未使用，见 README 的“回滚”一节）。
# =============================================================================

set -euo pipefail

# 上游入口与集成目录名。
UPSTREAM_SETUP_URL="https://raw.githubusercontent.com/Hybrid-Mount/meta-hybrid_mount/dev/module/vfs/setup.sh"
FS_DIR_NAME="hybridmount"

# --- 1. 必需输入 -------------------------------------------------------------
# 缺失时用 ${VAR:?} 直接带信息退出；这两个值在本脚本内被反复引用。
: "${KERNEL_ROOT:?KERNEL_ROOT is not set (run this through ABK)}"
: "${DEFCONFIG:?DEFCONFIG is not set (run this through ABK)}"

# --- 2. 内核线白名单 ---------------------------------------------------------
# 上游只声明支持这些 Android/GKI 线（与其预编译模块表同源）。
# 其他内核线的源码兼容性未经验证，宁可明确失败，也不要产出构建失败的内核。
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

# 提前校验 defconfig 存在：第 6 段要就地改写它，缺失时应在调用上游之前失败，
# 而不是先污染内核树再报错。
[ -f "$DEFCONFIG" ] \
  || { echo "[hybridmount] defconfig not found: $DEFCONFIG" >&2; exit 1; }

# --- 3. 定位内核源码根 -------------------------------------------------------
# GKI 的内核源码根是 $KERNEL_ROOT/common；普通内核树直接用 $KERNEL_ROOT。
if [ -d "$KERNEL_ROOT/common/fs" ]; then
  KERNEL_SRC="$KERNEL_ROOT/common"
else
  KERNEL_SRC="$KERNEL_ROOT"
fi

FS_DIR="$KERNEL_SRC/fs"
[ -d "$FS_DIR" ] || { echo "[hybridmount] no fs/ tree under $KERNEL_SRC" >&2; exit 1; }

# --- 4. 判重后调用上游 -------------------------------------------------------
# 上游脚本非幂等：fs/hybridmount 已存在时会直接报错，所以这里先判重。
if [ -d "$FS_DIR/$FS_DIR_NAME" ]; then
  echo "[hybridmount] already integrated at $FS_DIR/$FS_DIR_NAME; skipping upstream setup"
else
  echo "[hybridmount] running upstream setup in $KERNEL_SRC"
  # 上游脚本以内核树为工作目录；管道方式执行时它没有相邻 src/，因此会自行从
  # 上游 dev 分支下载源码。外层已开启 pipefail，curl 失败（HTTP 错误、DNS、
  # 超时）会中断整个脚本，不会被 bash 当作空输入静默跳过。
  ( cd "$KERNEL_SRC" && curl -fLSs "$UPSTREAM_SETUP_URL" | bash )
fi

# --- 5. 校验集成结果 ---------------------------------------------------------
# 校验上游确实改了 Makefile/Kconfig 并落盘了源码，避免构建出一个没接上的内核。
[ -d "$FS_DIR/$FS_DIR_NAME" ] \
  || { echo "[hybridmount] integration missing: $FS_DIR/$FS_DIR_NAME" >&2; exit 1; }
for artifact in hybridmount.c hybridmount.h Kconfig Makefile; do
  [ -f "$FS_DIR/$FS_DIR_NAME/$artifact" ] \
    || { echo "[hybridmount] missing artifact: $FS_DIR/$FS_DIR_NAME/$artifact" >&2; exit 1; }
done
# 字符串必须与上游保持逐字一致（上游用 grep -F 写入，这里同样用 -F 匹配）。
grep -qF 'obj-$(CONFIG_HYBRIDMOUNT) += hybridmount/' "$FS_DIR/Makefile" \
  || { echo "[hybridmount] fs/Makefile was not patched" >&2; exit 1; }
grep -qF 'source "fs/hybridmount/Kconfig"' "$FS_DIR/Kconfig" \
  || { echo "[hybridmount] fs/Kconfig was not patched" >&2; exit 1; }

# --- 6. 写入 defconfig 开关 --------------------------------------------------
# 上游脚本只拷源码，不碰 defconfig；这里补上开关。
# 就地改写（sed -i 保留文件属主/权限，不引入临时文件），且重复执行结果一致：
#   已经是 =y            → 不动
#   存在 CONFIG_HYBRIDMOUNT=<其他值> → 原地替换为 =y（例如 =m 或 =n）
#   存在 "# CONFIG_HYBRIDMOUNT is not set" → 原地替换为 =y
#   都没有               → 追加到文件末尾
if grep -q '^CONFIG_HYBRIDMOUNT=y$' "$DEFCONFIG"; then
  :
elif grep -q '^CONFIG_HYBRIDMOUNT=' "$DEFCONFIG"; then
  sed -i 's/^CONFIG_HYBRIDMOUNT=.*/CONFIG_HYBRIDMOUNT=y/' "$DEFCONFIG"
elif grep -q '^# CONFIG_HYBRIDMOUNT is not set$' "$DEFCONFIG"; then
  sed -i 's/^# CONFIG_HYBRIDMOUNT is not set$/CONFIG_HYBRIDMOUNT=y/' "$DEFCONFIG"
else
  printf 'CONFIG_HYBRIDMOUNT=y\n' >> "$DEFCONFIG"
fi
echo "[hybridmount] set CONFIG_HYBRIDMOUNT=y in $DEFCONFIG"

echo "[hybridmount] done"
