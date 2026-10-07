# ABK Hybrid Mount Module

[简体中文](README.md) | English

Integrates [Hybrid Mount](https://github.com/Hybrid-Mount/meta-hybrid_mount)'s VFS path-redirection kernel subsystem `hybridmount` into a GKI kernel built by ABK, as a built-in.

- This repository contains **no kernel source**; at build time it calls the upstream script, which fetches the sources and wires them into `fs/hybridmount/`.
- Once integrated, the kernel carries `CONFIG_HYBRIDMOUNT=y`, so the device no longer needs to `insmod` upstream's prebuilt `.ko`.
- The module script is idempotent, so `after_patch` and `before_build` may both be declared (`after_patch` is recommended — see [How it works](#how-it-works)).

## Contents

- [Quick start](#quick-start)
- [How it works](#how-it-works)
- [Prerequisites](#prerequisites)
- [Device-side requirements](#device-side-requirements)
- [Usage in ABK](#usage-in-abk)
- [Environment variables the script reads](#environment-variables-the-script-reads)
- [Verification](#verification)
- [Rollback](#rollback)
- [Troubleshooting](#troubleshooting)
- [Layout](#layout)
- [License](#license)
- [Notes](#notes)

## Quick start

Enter this under "Custom external modules" in the ABK App or GitHub Actions:

```text
https://github.com/yiteei/ABK_HYBRIDMOUNT_MODULE.git;after_patch
```

To reproduce locally (run this repository's `setup.sh` from the kernel tree root):

```sh
KERNEL_ROOT=/path/to/abk/kernel \
DEFCONFIG=/path/to/kernel/common/arch/arm64/configs/gki_defconfig \
CONFIG=android14-6.1-162 \
bash setup.sh
```

## How it works

ABK shallow-clones this repository (`git clone --depth 1`) into `$GITHUB_WORKSPACE/custom_external_module_NN-<repo name>` at the configured stage, then runs `bash setup.sh` with the **repository root** as the working directory. This repository's script only does four things — validate the environment, invoke upstream, validate the result, write the config switch; the actual integration is done by the upstream script.

### Steps of this repository's script

1. Validate the required environment variables `KERNEL_ROOT` and `DEFCONFIG` (a missing one exits with an explanatory `exit 1`).
2. Validate that `$CONFIG` is one of the Android/GKI lines upstream supports (`android12-5.10`, `android13-5.15`, `android14-6.1`, `android15-6.6`, `android16-6.12` — the same set as upstream's prebuilt-module table). Any other kernel line is terminated with `exit 1` rather than producing a broken kernel; a missing `$CONFIG` only warns and continues.
3. Validate that the `$DEFCONFIG` file exists (so the script fails before touching the kernel tree, not after).
4. Locate the kernel source root: `$KERNEL_ROOT/common` (GKI layout) is preferred; if absent, fall back to `$KERNEL_ROOT`. If neither has an `fs/` directory, fail.
5. De-duplicate: if `fs/hybridmount` already exists, skip the upstream script. Upstream is not idempotent and would fail with `fs/hybridmount already exists; run --cleanup first` if run twice.
6. Run the upstream script from the kernel source root (`curl -fLSs <upstream URL> | bash`). The script enables `set -o pipefail`, so a curl failure (DNS, timeout, HTTP error) aborts the whole pipeline instead of being silently treated as empty input.
7. Verify the result: `hybridmount.c`, `hybridmount.h`, `Kconfig`, and `Makefile` are present under `fs/hybridmount/`; `fs/Makefile` contains `obj-$(CONFIG_HYBRIDMOUNT) += hybridmount/`; `fs/Kconfig` contains `source "fs/hybridmount/Kconfig"`. Any missing item exits with `exit 1`, so that no "not actually wired up" kernel is produced.
8. Write `CONFIG_HYBRIDMOUNT=y` to `$DEFCONFIG`. The edit is **in-place** (`sed -i`: no temporary file, no change to file permissions) and idempotent: if it is already `=y` nothing happens; an existing `CONFIG_HYBRIDMOUNT=<other value>` or `# CONFIG_HYBRIDMOUNT is not set` line is rewritten in place; otherwise the line is appended.

The `after_patch` stage is recommended. Because the script is idempotent, declaring both `after_patch` and `before_build` will not cause duplicate integration — the second stage takes the de-duplication branch and exits early.

### What the upstream script does

The upstream script is fetched live from the `dev` branch and is not version-pinned:

- it refuses to touch a tree that already integrates NoMount (both implementations hijack inode operations and register different key types, so the kernel will not stop them from coexisting);
- it downloads `hybridmount.c`, `hybridmount.h`, `Kconfig`, and `LICENSE` into `fs/hybridmount/` and checks that the downloads are non-empty;
- it generates `fs/hybridmount/Makefile` itself, containing `obj-$(CONFIG_HYBRIDMOUNT) += hybridmount.o` and `ccflags-y += -std=gnu11 -Wno-declaration-after-statement` (kernels before 5.18 default to gnu89 while the sources use C99 declarations, hence the explicit gnu11);
- it appends `obj-$(CONFIG_HYBRIDMOUNT) += hybridmount/` to `fs/Makefile`;
- it inserts `source "fs/hybridmount/Kconfig"` into `fs/Kconfig`, just before the **last `endmenu`**;
- it offers a `--cleanup` option (not wrapped by this repository — see [Rollback](#rollback)).

## Prerequisites

- An ABK kernel build environment (GKI) that injects `KERNEL_ROOT`, `DEFCONFIG`, `CONFIG`, and `CUSTOM_EXTERNAL_MODULE_STAGE`.
- Network access on the build host. Both the upstream script and this module fetch from `raw.githubusercontent.com`.
- The target kernel tree must not already integrate NoMount. Both hijack inode operations, so upstream will refuse integration; do not enable another module that injects NoMount after this one in the same build either.

## Device-side requirements

This module only covers the kernel side. For the VFS backend to actually work, the device must also have Hybrid Mount's metamodule installed (the ZIP from its Releases, installed with the KernelSU / APatch manager; it provides the `hybrid-mount` CLI, the WebUI, and `/data/adb/hybrid-mount/config.toml`).

- When the kernel already carries `hybridmount`, `vfs-doctor` reports the provider as available and no matching entry appears in `/proc/modules` (a `/sys/module/hybridmount` directory means it is built in).
- When the kernel does not carry it, the metamodule automatically loads one of its prebuilt `hybridmount-android<NN>-<kernel>.ko` files matching the kernel release's Android/GKI label. Building `hybridmount` into the kernel is therefore only worthwhile when you want to avoid the `insmod`, or when your kernel line has no prebuilt module.
- Hybrid Mount is a KernelSU / APatch metamodule, not a Magisk module, so this module declares no `ABK_MAGISK_MODULE_*` flash dependency; install it yourself.

## Usage in ABK

Enter the following under "Custom external modules" in the App or GitHub Actions:

```text
https://github.com/yiteei/ABK_HYBRIDMOUNT_MODULE.git;after_patch
```

`custom_external_modules` in GitHub Actions accepts only `http(s)://`, `git://`, `ssh://`, and `git@` links; a local directory path is rejected with `::error::自定义外部模块链接不支持`. To reproduce locally, run this script directly from the kernel tree root:

```sh
KERNEL_ROOT=/path/to/abk/kernel \
DEFCONFIG=/path/to/kernel/common/arch/arm64/configs/gki_defconfig \
CONFIG=android14-6.1-162 \
bash setup.sh
```

## Environment variables the script reads

| Variable | Required | Description |
| --- | --- | --- |
| `KERNEL_ROOT` | yes | ABK kernel workspace root. Under the GKI layout the real kernel source root is its `common/` subdirectory. Missing → fail. |
| `DEFCONFIG` | yes | Path of the defconfig actually used by this build; the script writes `CONFIG_HYBRIDMOUNT=y` into it. Missing or nonexistent → fail. |
| `CONFIG` | no | Kernel line identifier such as `android14-6.1-162`, used for the allow-list check. If absent, only a warning is printed. |
| `CUSTOM_EXTERNAL_MODULE_STAGE` | no | Stage name injected by ABK. This script is stage-agnostic and does not read it. |

## Verification

After the build completes, confirm the following in the kernel source tree:

- `common/fs/hybridmount/` exists and contains `hybridmount.c`, `hybridmount.h`, `Kconfig`, `LICENSE`, and `Makefile`;
- `common/fs/Makefile` contains `obj-$(CONFIG_HYBRIDMOUNT) += hybridmount/`;
- `common/fs/Kconfig` contains `source "fs/hybridmount/Kconfig"`;
- `CONFIG_HYBRIDMOUNT=y` took effect: on kernel lines ABK builds with bazel/kleaf (`android14-6.1` and newer) the build restores the pristine `gki_defconfig` before compiling and moves this line, with the rest of the additions, into `common/arch/arm64/configs/ksu.fragment` — check that fragment file; on kernel lines using `build/build.sh` the line stays in `common/arch/arm64/configs/gki_defconfig`;
- if the kernel keeps `/proc/config.gz`, then on the device `zcat /proc/config.gz | grep HYBRIDMOUNT` should output `y`; the presence of `/sys/module/hybridmount` also confirms it is built in rather than externally loaded.

## Rollback

The built-in integration is plain text, so reverting by hand is enough:

```sh
KERNEL_SRC=<kernel tree root>        # $KERNEL_ROOT/common on GKI
rm -rf "$KERNEL_SRC/fs/hybridmount"
sed -i '\#^obj-$(CONFIG_HYBRIDMOUNT) += hybridmount/$#d' "$KERNEL_SRC/fs/Makefile"
sed -i '\#^source "fs/hybridmount/Kconfig"$#d' "$KERNEL_SRC/fs/Kconfig"
sed -i '/^CONFIG_HYBRIDMOUNT=/d' "$DEFCONFIG"
```

Alternatively, call upstream's own `--cleanup` (from the kernel source root):

```sh
curl -fLSs "https://raw.githubusercontent.com/Hybrid-Mount/meta-hybrid_mount/dev/module/vfs/setup.sh" | bash -s -- --cleanup
```

Note: upstream's `--cleanup` only removes `fs/hybridmount/` and reverts `fs/Makefile` and `fs/Kconfig`. It does **not** clean `CONFIG_HYBRIDMOUNT=y` out of the defconfig; remove that with the `sed` above.

## Troubleshooting

Messages from this script are prefixed `[hybridmount]`; messages from the upstream script are prefixed `[ERROR]`.

| Symptom / log | Cause and fix |
| --- | --- |
| `KERNEL_ROOT is not set (run this through ABK)` / `DEFCONFIG is not set (run this through ABK)` | Not run through ABK, or a manual run forgot the variables. Pass them as in [Quick start](#quick-start). |
| `warning: CONFIG is not set; skipping kernel line check` | `CONFIG` is absent outside ABK. Warning only — the run continues, but the kernel-line allow-list check is skipped. |
| `unsupported kernel line: <CONFIG>` | The kernel line is not on upstream's supported list. Switch to a supported line, or verify source compatibility yourself and extend the allow-list. |
| `defconfig not found: <path>` | `$DEFCONFIG` does not exist — usually a wrong variable value or a different kernel tree layout. |
| `no fs/ tree under <KERNEL_SRC>` | The `KERNEL_ROOT` passed in is not a kernel tree and has no `common/` either. |
| `[ERROR] this kernel tree already integrates NoMount.` | The tree already integrates NoMount (upstream refuses coexistence). Note that upstream's detection is **substring-based**: an `fs/nomount/` directory, `^CONFIG_NOMOUNT=` in `$KERNEL_ROOT/.config`, any line containing `nomount` in `fs/Makefile`, or `fs/nomount/Kconfig` in `fs/Kconfig` all trigger it. A harmless line such as `obj-$(CONFIG_XXX_NOMOUNT_YYY) += foo_nomount_bar/` is therefore a false positive — rename it or remove NoMount first. On this path the script fails right after invoking upstream and writes **nothing** to `fs/Makefile`, `fs/Kconfig`, or the defconfig. |
| `[ERROR] fs/hybridmount already exists; run --cleanup first` | Should not happen: this script de-duplicates before calling upstream. If it appears, the tree is half-integrated — clean up per [Rollback](#rollback) and retry. |
| `[ERROR] downloaded source is empty: <file>`, or curl reporting `Could not resolve host` / `HTTP 404` | The build host cannot reach `raw.githubusercontent.com`, or upstream's `dev` branch layout changed. Check network/proxy and the upstream mirror. |
| `integration missing: <path>` / `missing artifact: <path>` | The upstream script did not produce its files. Look further up the log for the upstream failure. |
| `fs/Makefile was not patched` / `fs/Kconfig was not patched` | Upstream output differs from expectations (upstream change or a patch conflict). Re-check the upstream script revision. |

To self-test `after_patch` idempotency locally, simply run the local reproduction command above twice: the second run should print `already integrated …; skipping upstream setup`, and `$DEFCONFIG` should contain no duplicate lines.

## Layout

```text
setup.sh      ABK external module entry script
module.conf   ABK module metadata (for module repository indexing)
README.md     Chinese documentation
README-EN.md  This English documentation
LICENSE       Full GPL-3.0-only license text
```

## License

This repository (`setup.sh`, `module.conf`, `README.md`, `README-EN.md`) is released under **GPL-3.0-only**; see [`LICENSE`](LICENSE) for the full text.

This repository does not contain upstream `hybridmount` source code; it is fetched from upstream at build time only. The integrated `hybridmount` source is distributed under its **GPL-2.0-only** license; see [Hybrid-Mount/meta-hybrid_mount](https://github.com/Hybrid-Mount/meta-hybrid_mount).

## Notes

- Builds as built-in (`CONFIG_HYBRIDMOUNT=y`) by default. To use `=m`, edit the corresponding line in `setup.sh`; this is generally not recommended for GKI.
- Do not enable a module that injects NoMount in the same build. Upstream can only detect a tree that already integrates NoMount; if NoMount is injected after this module, both will hijack inode operations and the kernel will not stop them from coexisting.
- The upstream integration script is fetched live from upstream's `dev` branch (`curl … | bash`) and is not version-pinned; its behaviour or interface may change with upstream updates. The branch that script downloads `hybridmount.c`, `hybridmount.h`, and the rest of the sources from is likewise hardcoded to `dev`.
