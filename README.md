# ABK_HYBRIDMOUNT_MODULE

把 [Hybrid Mount](https://github.com/Hybrid-Mount/meta-hybrid_mount) 的 VFS 路径重定向子系统 `hybridmount` 集成进 ABK 编译的内核，以 built-in 方式编译，复用上游 `setup.sh`，不复制它的源码。

## 用法

在 ABK 里引用本模块即可，`module.conf` 已经声明了跑哪个阶段：

```conf
ABK_MODULE_KIND="module"
ABK_MODULE_ID="abk_hybridmount"
ABK_MODULE_SUPPORTED_STAGES="after_patch,before_build"
ABK_MODULE_DEFAULT_STAGE="after_patch"
ABK_MODULE_RECOMMENDED_STAGES="after_patch"
```

两个阶段都会执行，内容一致：两处源码接线发生在编译之前，所以放在 `after_patch` 还是 `before_build` 都可以，重复执行不会叠加。

手动跑（需要有 `KERNEL_ROOT`、`DEFCONFIG`）：

```bash
KERNEL_ROOT=/path/to/kernel DEFCONFIG=/path/to/defconfig bash setup.sh
```

## 它改了什么

| 位置 | 改动 |
| --- | --- |
| `fs/hybridmount/` | 上游脚本写入的目录：`hybridmount.c`、`hybridmount.h`、`Kconfig`、`LICENSE`，外加它现生成的 in-tree `Makefile` |
| `fs/Makefile` | 追加一行 `obj-$(CONFIG_HYBRIDMOUNT) += hybridmount/` |
| `fs/Kconfig` | 追加一行 `source "fs/hybridmount/Kconfig"` |
| `$DEFCONFIG` | 一行 `CONFIG_HYBRIDMOUNT=y`，按下面的四态规则写入 |

前两处接线由上游脚本追加，本模块只负责判重、清理残留和写 defconfig。

## 执行流程

1. 校验 `KERNEL_ROOT`、`DEFCONFIG` 已设置，且 `$DEFCONFIG` 文件存在。
2. **内核线检查**：`CONFIG` 必须是 `android12-5.10`、`android13-5.15`、`android14-6.1`、`android15-6.6`、`android16-6.12` 之一（带 `-*` 后缀）；`CONFIG` 未设置时只提示并继续。
3. **定位源码根**：`$KERNEL_ROOT/common` 存在就使用它（GKI 布局），否则用 `$KERNEL_ROOT`；`fs/` 必须存在。
4. **`CONFIG_KEYS` 检查**：依次扫 `$DEFCONFIG`、`arch/arm64/configs/gki_defconfig`、`arch/arm64/configs/defconfig`，命中第一个显式值即停；只在明确关闭时告警，见[前置条件](#前置条件)。
5. **判重**：`fs/hybridmount/` 下的 `hybridmount.c`、`hybridmount.h`、`Kconfig`、`Makefile` 都在，且 `fs/Makefile`、`fs/Kconfig` 里已有接线，才算已集成，跳过上游；否则删净残留目录和两处接线，重新跑上游。
6. **跑上游**：在 `$KERNEL_SRC` 下执行 `curl -fLSs "$UPSTREAM_SETUP_URL" | bash`，`pipefail` 已开，curl 失败不会当成空输入。
7. **验上游产物**：四个文件与两处接线按字节比对（`grep -F`），缺一项就退出。
8. **写 defconfig**，按下面的四态规则。

第 5 步让整个脚本幂等：第二次运行走"已集成"分支，不重复集成、不留重复接线、不重复写 defconfig 行。被中断的上游留下的残局由同一步清理重建，不需要手动 `--cleanup`。

## 环境变量

| 变量 | 必需 | 用途 |
| --- | --- | --- |
| `KERNEL_ROOT` | 是 | ABK 交下来的源码根，脚本自己判断它下面有没有 `common/` |
| `DEFCONFIG` | 是 | 当前构建要写入的目标 defconfig，被写入的那一行只落在这里 |
| `CONFIG` | 否 | 内核线，如 `android14-6.1-lts`；未设置时跳过内核线检查 |

## defconfig 写入规则

`$DEFCONFIG` 里 `CONFIG_HYBRIDMOUNT` 的四种状态对应四种改法与四种日志：

| 当前状态 | 处理 | 日志 |
| --- | --- | --- |
| `CONFIG_HYBRIDMOUNT=y` | 原样不动 | `CONFIG_HYBRIDMOUNT=y already in <path>` |
| `CONFIG_HYBRIDMOUNT=<其它值>` | 改写成 `=y` | `rewrote CONFIG_HYBRIDMOUNT=y in <path>` |
| `# CONFIG_HYBRIDMOUNT is not set` | 替换成 `=y` | `enabled CONFIG_HYBRIDMOUNT=y in <path>` |
| 完全没有这一行 | 追加 | `appended CONFIG_HYBRIDMOUNT=y to <path>` |

不会改 `arch/arm64/configs/` 下的任何文件，也不会写 `Kconfig` 的默认值；`module/vfs/src/Kconfig` 里 `HYBRIDMOUNT` 本来就是 `default y`，所以这一行是明确打开，不是纠正错误值。

## 前置条件

- 一棵打过 patch 的 kernel 源码树，`KERNEL_ROOT` 指向它。
- 内核线属于上面五条之一，其它线的源码兼容性未验证。
- **不能同时集成 NoMount**：两者都改写 inode 操作，内核不会阻止它们共存（它们注册的 key type 不同），所以上游脚本检测到 `fs/nomount/Kconfig` 就直接失败。
- `CONFIG_KEYS=y`：`hybridmount.c` 调用 `register_key_type`，`CONFIG_KEYS=n` 时 `key-type.h` 整段被 `#ifdef` 掉，编译在声明处就断。`CONFIG_KEYS` 通常由 `FS_ENCRYPTION`、`INTEGRITY`、`NFS_FS`、`CEPH_FS` 等 `select` 得到，GKI 的 `gki_defconfig` 里没有它的字面行，所以"三个文件都没有显式值"是正常且静默的，只有明确写了 `# CONFIG_KEYS is not set` 才告警。

## 跟随上游

上游地址写死在脚本里，指向 `dev` 分支的 `module/vfs/setup.sh`：

```bash
UPSTREAM_SETUP_URL="https://raw.githubusercontent.com/Hybrid-Mount/meta-hybrid_mount/dev/module/vfs/setup.sh"
```

上游更新会直接生效，本仓库不锁版本。要锁版本就把这个 URL 换成 commit SHA。

## 上游脚本做了什么

了解它才能理解这里的幂等和清理逻辑：

- 以 `pwd` 作为源码根，通过管道执行时从 raw 地址下载 `hybridmount.c`、`hybridmount.h`、`Kconfig`、`LICENSE` 到临时目录。
- `mkdir -p fs/hybridmount` 并把这些文件复制进去，另生成一份 in-tree 用的 `Makefile`（上游仓库里的那份是给 DDK 外置编译的，在内核树里不适用）。
- 往 `fs/Makefile`、`fs/Kconfig` 追加接线；只追加，不判断是否已有。
- 检测到 `fs/nomount` 时拒绝执行。
- 自带 `--cleanup` 参数可以回滚自己的改动，本模块不调用它，回滚见下文。

它不做的事：不写 defconfig、不检查 `CONFIG_KEYS`、不判断是否已集成，这三件都在本模块里补齐。

## 设备侧

- `hybridmount` 以 built-in 方式编译进 `vmlinux`，刷入后没有独立的 `.ko` 文件，模块列表里也看不到它。
- 编译产物在 `fs/hybridmount/hybridmount.o` 与最终的 `vmlinux` 中，可用 `nm vmlinux | grep -i hybridmount` 确认符号存在。
- 开关由 defconfig 里的 `CONFIG_HYBRIDMOUNT=y` 决定，运行期行为由 upstream 的 userspace 工具控制，本模块不改运行期配置。

## 验证

编译期：日志里出现 `[hybridmount] done`，且 defconfig 里是 `CONFIG_HYBRIDMOUNT=y`。

设备侧：

```bash
zcat /proc/config.gz | grep HYBRIDMOUNT
grep -i hybridmount /proc/kallsyms | head
dmesg | grep -i hybridmount
```

## 退出码

| 退出码 | 原因 |
| --- | --- |
| `0` | 已集成并写好 defconfig，或本来已集成 |
| `1` | `KERNEL_ROOT` / `DEFCONFIG` 未设置；defconfig 文件不存在；内核线不在白名单；找不到 `fs/`；上游执行失败；上游产物或接线不完整；写 defconfig 失败 |

ABK 看到非零退出码会把本次构建判为失败，所以不会带着半成品继续编译。

## 回滚

```bash
rm -rf fs/hybridmount
sed -i '\|^obj-$(CONFIG_HYBRIDMOUNT) += hybridmount/$|d' fs/Makefile
sed -i '\|^source "fs/hybridmount/Kconfig"$|d' fs/Kconfig
sed -i '/^CONFIG_HYBRIDMOUNT=y$/d' "$DEFCONFIG"
```

想用上游自己的回滚，就手动跑一次它的 `--cleanup`：

```bash
curl -fLSs "https://raw.githubusercontent.com/Hybrid-Mount/meta-hybrid_mount/dev/module/vfs/setup.sh" | bash -s -- --cleanup
```

## 排错

| 现象 | 原因与处理 |
| --- | --- |
| `defconfig not found: <path>` | `DEFCONFIG` 指错了，或 ABK 还没把 defconfig 落到那个位置 |
| `unsupported kernel line: <CONFIG>` | 内核线不在五条白名单内，换线或改白名单 |
| `no fs/ tree under <path>` | `KERNEL_ROOT` 不是内核树，且它下面也没有 `common/` |
| `warning: CONFIG_KEYS is explicitly off in <path>` | 该 defconfig 明确关了 `KEYS`，打开它再编译，否则 `register_key_type` 无声明 |
| `upstream output incomplete: want 4 files ...` | 上游被中断或网络失败；直接重跑脚本，它会清理残局并重新集成 |
| 上游报 nomount 冲突 | 同一棵树里已有 NoMount，先移除它 |
| 日志是 `already integrated ... skipping` 但编译报找不到文件 | 说明四个文件与两处接线都在，但目录内容被外力破坏（例如手工删过文件）；`rm -rf fs/hybridmount` 后重跑 |

## 许可

本仓库脚本为 GPL-3.0-only（见 SPDX 头）。集成进去的上游 `hybridmount` 源码为 GPL-2.0-only，LICENSE 随源码一起落在 `fs/hybridmount/`。
