# ABK Hybrid Mount Module

简体中文 | [English](README-EN.md)

把 [Hybrid Mount](https://github.com/Hybrid-Mount/meta-hybrid_mount) 的 VFS 路径重定向内核子系统 `hybridmount` 以内建（built-in）方式集成进由 ABK 构建的 GKI 内核。

- 本仓库**不含内核源码**，只在构建时调用上游脚本，把源码拉取并接入 `fs/hybridmount/`；
- 集成后内核带 `CONFIG_HYBRIDMOUNT=y`，设备端无需再 `insmod` 上游预编译的 `.ko`；
- 模块脚本幂等，`after_patch` 与 `before_build` 均可声明（推荐前者，见[工作原理](#工作原理)）。

## 目录

- [快速开始](#快速开始)
- [工作原理](#工作原理)
- [前置条件](#前置条件)
- [设备侧要求](#设备侧要求)
- [在 ABK 中使用](#在-abk-中使用)
- [脚本读取的环境变量](#脚本读取的环境变量)
- [验证](#验证)
- [回滚](#回滚)
- [故障排查](#故障排查)
- [目录结构](#目录结构)
- [许可](#许可)
- [注意事项](#注意事项)

## 快速开始

在 ABK App 或 GitHub Actions 的「自定义外部模块」中填入：

```text
https://github.com/yiteei/ABK_HYBRIDMOUNT_MODULE.git;after_patch
```

本地复现（在内核树根目录执行本仓库的 `setup.sh`）：

```sh
KERNEL_ROOT=/path/to/abk/kernel \
DEFCONFIG=/path/to/kernel/common/arch/arm64/configs/gki_defconfig \
CONFIG=android14-6.1-162 \
bash setup.sh
```

## 工作原理

ABK 在指定阶段把本仓库浅克隆（`git clone --depth 1`）到 `$GITHUB_WORKSPACE/custom_external_module_NN-<仓库名>`，随后以**本仓库根目录**为工作目录执行 `bash setup.sh`。本仓库的脚本只做“校验环境 → 调上游 → 校验产物 → 写开关”四件事，源码集成本身由上游脚本完成。

### 本仓库脚本的步骤

1. 校验必需环境变量 `KERNEL_ROOT`、`DEFCONFIG`（缺失即带信息 `exit 1`）。
2. 校验 `$CONFIG` 属于上游支持的 Android/GKI 线（`android12-5.10`、`android13-5.15`、`android14-6.1`、`android15-6.6`、`android16-6.12`，与上游预编译模块表同源）。其余内核线直接以 `exit 1` 终止，避免产出构建失败的内核；`$CONFIG` 未注入时仅告警并继续。
3. 校验 `$DEFCONFIG` 文件存在（避免先污染内核树再报错）。
4. 定位内核源码根：优先 `$KERNEL_ROOT/common`（GKI 布局），若不存在则回退 `$KERNEL_ROOT`；两者都没有 `fs/` 目录则失败。
5. 判重：`fs/hybridmount` 已存在则跳过上游脚本。原因是上游脚本不具备幂等性，重复执行会以 `fs/hybridmount already exists; run --cleanup first` 直接报错。
6. 以内核源码根为工作目录执行上游脚本（`curl -fLSs <上游 URL> | bash`）。脚本启用了 `set -o pipefail`：curl 因 DNS、超时或 HTTP 错误失败时整条流水线立即失败，不会被当作空输入静默跳过。
7. 校验集成结果：`fs/hybridmount/` 下 `hybridmount.c`、`hybridmount.h`、`Kconfig`、`Makefile` 均已落盘；`fs/Makefile` 含 `obj-$(CONFIG_HYBRIDMOUNT) += hybridmount/`；`fs/Kconfig` 含 `source "fs/hybridmount/Kconfig"`。任一缺失即 `exit 1`，避免产出“没接上”的内核。
8. 向 `$DEFCONFIG` 写入 `CONFIG_HYBRIDMOUNT=y`。该操作**就地改写**（`sed -i`，不产生临时文件、不改动文件权限），且幂等：已为 `=y` 则不动；存在 `CONFIG_HYBRIDMOUNT=<其他值>` 或 `# CONFIG_HYBRIDMOUNT is not set` 则原地替换；都不存在则追加到文件末尾。

推荐使用 `after_patch` 阶段。由于脚本幂等，即使同时声明 `after_patch` 与 `before_build` 也不会重复集成——第二个阶段会走判重分支直接跳过。

### 上游脚本做了什么

上游脚本自 `dev` 分支实时拉取，未做版本固定：

- 拒绝在已集成 NoMount 的内核树上工作（两者都劫持 inode 操作，且注册的 key type 不同，内核不会阻止其共存）；
- 下载 `hybridmount.c`、`hybridmount.h`、`Kconfig`、`LICENSE` 到 `fs/hybridmount/`，并校验下载结果非空；
- 自行生成 `fs/hybridmount/Makefile`，内容为 `obj-$(CONFIG_HYBRIDMOUNT) += hybridmount.o` 与 `ccflags-y += -std=gnu11 -Wno-declaration-after-statement`（5.18 之前的内核默认 gnu89，而源码使用 C99 声明，故显式指定 gnu11）；
- 向 `fs/Makefile` 追加 `obj-$(CONFIG_HYBRIDMOUNT) += hybridmount/`；
- 在 `fs/Kconfig` 的**最后一个 `endmenu` 之前**插入 `source "fs/hybridmount/Kconfig"`；
- 提供 `--cleanup` 回滚选项（本仓库未封装，用法见[回滚](#回滚)）。

## 前置条件

- 具备 ABK 内核构建环境（GKI），该环境会注入 `KERNEL_ROOT`、`DEFCONFIG`、`CONFIG` 与 `CUSTOM_EXTERNAL_MODULE_STAGE`。
- 构建主机可访问网络。上游脚本与本模块均需自 `raw.githubusercontent.com` 拉取内容。
- 目标内核树不得已集成 NoMount。二者均会劫持 inode 操作，故上游将拒绝集成；同一构建中亦不应再启用会在本模块之后注入 NoMount 的其它模块。

## 设备侧要求

本模块只负责内核侧。VFS 后端要真正可用，设备上还必须安装 Hybrid Mount 的 metamodule（经 KernelSU / APatch 管理器安装其 Releases 中的 ZIP；内含 `hybrid-mount` CLI、WebUI 与 `/data/adb/hybrid-mount/config.toml`）。

- 内核已内建 `hybridmount` 时，`vfs-doctor` 会报告 provider 可用，且 `/proc/modules` 中不出现对应条目（`/sys/module/hybridmount` 存在即表示已内建）。
- 内核未内建时，上游 metamodule 会按内核发行版的 Android/GKI 标签自动加载其自带的预编译 `hybridmount-android<NN>-<kernel>.ko`。因此，只有在希望避免 `insmod`、或该内核线没有预编译模块时，才有必要把 `hybridmount` 内建进内核。
- Hybrid Mount 是 KernelSU / APatch 的 metamodule 而非 Magisk 模块，故本模块不声明 `ABK_MAGISK_MODULE_*` 刷写依赖，请自行安装。

## 在 ABK 中使用

在 App 或 GitHub Actions 的「自定义外部模块」中填写：

```text
https://github.com/yiteei/ABK_HYBRIDMOUNT_MODULE.git;after_patch
```

GitHub Actions 的 `custom_external_modules` 只接受 `http(s)://`、`git://`、`ssh://`、`git@` 形式的链接，本地目录路径会被 `::error::自定义外部模块链接不支持` 拒绝。需要本地复现时，直接在内核树根目录执行本脚本：

```sh
KERNEL_ROOT=/path/to/abk/kernel \
DEFCONFIG=/path/to/kernel/common/arch/arm64/configs/gki_defconfig \
CONFIG=android14-6.1-162 \
bash setup.sh
```

## 脚本读取的环境变量

| 变量 | 必需 | 说明 |
| --- | --- | --- |
| `KERNEL_ROOT` | 是 | ABK 内核工作区根。GKI 布局下真正的内核源码根是其下的 `common/`。缺失即失败。 |
| `DEFCONFIG` | 是 | 本次构建实际使用的 defconfig 路径，脚本向其写入 `CONFIG_HYBRIDMOUNT=y`。缺失或文件不存在即失败。 |
| `CONFIG` | 否 | 内核线标识，形如 `android14-6.1-162`。用于白名单校验；未注入时仅告警并继续。 |
| `CUSTOM_EXTERNAL_MODULE_STAGE` | 否 | 由 ABK 注入的阶段名。本脚本不区分阶段，不读取该变量。 |

## 验证

构建完成后，请于内核源码树中确认以下各项：

- `common/fs/hybridmount/` 存在，且包含 `hybridmount.c`、`hybridmount.h`、`Kconfig`、`LICENSE` 与 `Makefile`；
- `common/fs/Makefile` 包含 `obj-$(CONFIG_HYBRIDMOUNT) += hybridmount/`；
- `common/fs/Kconfig` 包含 `source "fs/hybridmount/Kconfig"`；
- `CONFIG_HYBRIDMOUNT=y` 已生效：ABK 在内核线使用 bazel/kleaf 时（`android14-6.1` 及以上）会在编译前把 `gki_defconfig` 还原为基准版本，并把包括本行在内的改动移入 `common/arch/arm64/configs/ksu.fragment`，此时应检查该 fragment 文件；内核线使用 `build/build.sh` 时则该行保留在 `common/arch/arm64/configs/gki_defconfig` 中；
- 若内核保留了 `/proc/config.gz`，则在设备上执行 `zcat /proc/config.gz | grep HYBRIDMOUNT` 应输出 `y`；`/sys/module/hybridmount` 存在亦可确认是内建而非外部加载。

## 回滚

内建集成是纯文本改动，手动回滚即可：

```sh
KERNEL_SRC=<kernel tree root>        # GKI 下即 $KERNEL_ROOT/common
rm -rf "$KERNEL_SRC/fs/hybridmount"
sed -i '\#^obj-$(CONFIG_HYBRIDMOUNT) += hybridmount/$#d' "$KERNEL_SRC/fs/Makefile"
sed -i '\#^source "fs/hybridmount/Kconfig"$#d' "$KERNEL_SRC/fs/Kconfig"
sed -i '/^CONFIG_HYBRIDMOUNT=/d' "$DEFCONFIG"
```

也可直接调用上游自带的 `--cleanup`（在内核源码根目录执行）：

```sh
curl -fLSs "https://raw.githubusercontent.com/Hybrid-Mount/meta-hybrid_mount/dev/module/vfs/setup.sh" | bash -s -- --cleanup
```

注意：上游 `--cleanup` 只删除 `fs/hybridmount/` 并回滚 `fs/Makefile`、`fs/Kconfig`，**不会**清理 defconfig 中的 `CONFIG_HYBRIDMOUNT=y`，需按上面的 `sed` 自行删除。

## 故障排查

脚本自身的报错都以 `[hybridmount]` 前缀输出；上游脚本的报错以 `[ERROR]` 前缀输出。

| 现象 / 日志 | 原因与处理 |
| --- | --- |
| `KERNEL_ROOT is not set (run this through ABK)` / `DEFCONFIG is not set (run this through ABK)` | 未通过 ABK 运行，或手工执行时忘了传变量。按[快速开始](#快速开始)手动指定。 |
| `warning: CONFIG is not set; skipping kernel line check` | 非 ABK 环境下缺 `CONFIG`。仅告警，可继续，但内核线白名单校验被跳过。 |
| `unsupported kernel line: <CONFIG>` | 该内核线不在上游支持列表内。换受支持的内核线，或自行验证源码兼容性后修改白名单。 |
| `defconfig not found: <path>` | `$DEFCONFIG` 路径不存在，通常是变量传错或内核线布局不同。 |
| `no fs/ tree under <KERNEL_SRC>` | 传入的 `KERNEL_ROOT` 不是内核树，且其下也没有 `common/`。 |
| `[ERROR] this kernel tree already integrates NoMount.` | 内核树已集成 NoMount（上游拒绝共存）。注意上游的判定是**子串启发式**：`fs/nomount/` 目录存在、`$KERNEL_ROOT/.config` 含 `^CONFIG_NOMOUNT=`、`fs/Makefile` 任一含 `nomount`、或 `fs/Kconfig` 含 `fs/nomount/Kconfig` 都会触发。因此树里出现形如 `obj-$(CONFIG_XXX_NOMOUNT_YYY) += foo_nomount_bar/` 的无害行时也会被误判，需改名或先移除 NoMount。此路径下本脚本会在调用上游后立即失败，**不会**写入 `fs/Makefile`、`fs/Kconfig` 或 defconfig。 |
| `[ERROR] fs/hybridmount already exists; run --cleanup first` | 理论上不会出现：本脚本在调用上游前已判重。若出现，说明树处于半集成状态，按[回滚](#回滚)清理后重试。 |
| `[ERROR] downloaded source is empty: <file>` 或 curl 报 `Could not resolve host` / `HTTP 404` | 构建主机无法访问 `raw.githubusercontent.com`，或上游 `dev` 分支结构变更。检查网络/代理与上游镜像。 |
| `integration missing: <path>` / `missing artifact: <path>` | 上游脚本未成功落盘。回看更早的上游输出定位失败点。 |
| `fs/Makefile was not patched` / `fs/Kconfig was not patched` | 上游产物与预期不符（上游变更或补丁冲突）。核对上游脚本版本。 |

本地自测（`after_patch` 幂等性）可直接复用上面的本地复现命令跑两遍，第二遍应输出 `already integrated …; skipping upstream setup`，且 `$DEFCONFIG` 不出现重复行。

## 目录结构

```text
setup.sh      ABK 外部模块入口脚本
module.conf   ABK 模块元数据（供模块仓库索引）
README.md     中文说明文档
README-EN.md  英文说明文档
LICENSE       GPL-3.0-only 许可全文
```

## 许可

本仓库（`setup.sh`、`module.conf`、`README.md`、`README-EN.md`）以 **GPL-3.0-only** 发布，全文见 [`LICENSE`](LICENSE)。

本仓库不包含上游 `hybridmount` 源码，仅于构建时自上游拉取。被集成的 `hybridmount` 源码按其 **GPL-2.0-only** 许可分发，来源见 [Hybrid-Mount/meta-hybrid_mount](https://github.com/Hybrid-Mount/meta-hybrid_mount)。

## 注意事项

- 默认按内建方式（`CONFIG_HYBRIDMOUNT=y`）编译。如需改为 `=m`，请修改 `setup.sh` 中对应的那一行；在 GKI 场景下通常不建议如此。
- 请勿在同一构建中同时启用会注入 NoMount 的模块。上游只能检测“目标内核树已集成 NoMount”；若 NoMount 在本模块之后注入，二者会同时劫持 inode 操作，而内核不会阻止其共存。
- 上游集成脚本自上游 `dev` 分支实时拉取（`curl … | bash`），未做版本固定；其行为或接口可能随上游更新而改变。该脚本内部下载 `hybridmount.c`、`hybridmount.h` 等源码的地址同样硬编码为 `dev`。
