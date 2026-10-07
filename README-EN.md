# ABK_HYBRIDMOUNT_MODULE

Integrates `hybridmount`, the VFS path redirection subsystem from [Hybrid Mount](https://github.com/Hybrid-Mount/meta-hybrid_mount), into a kernel built by ABK. It builds in-tree (built-in), reuses upstream's `setup.sh`, and does not copy its sources.

## Usage

Reference the module from ABK; `module.conf` already declares the stages:

```conf
ABK_MODULE_KIND="module"
ABK_MODULE_ID="abk_hybridmount"
ABK_MODULE_SUPPORTED_STAGES="after_patch,before_build"
ABK_MODULE_DEFAULT_STAGE="after_patch"
ABK_MODULE_RECOMMENDED_STAGES="after_patch"
```

Both stages run the same work: the two source wirings happen before compilation, so `after_patch` and `before_build` are interchangeable and repeated runs do not stack up.

Manually, with `KERNEL_ROOT` and `DEFCONFIG` provided:

```bash
KERNEL_ROOT=/path/to/kernel DEFCONFIG=/path/to/defconfig bash setup.sh
```

## What it changes

| Location | Change |
| --- | --- |
| `fs/hybridmount/` | Directory written by upstream: `hybridmount.c`, `hybridmount.h`, `Kconfig`, `LICENSE`, plus the in-tree `Makefile` it generates |
| `fs/Makefile` | One appended line, `obj-$(CONFIG_HYBRIDMOUNT) += hybridmount/` |
| `fs/Kconfig` | One appended line, `source "fs/hybridmount/Kconfig"` |
| `$DEFCONFIG` | One line, `CONFIG_HYBRIDMOUNT=y`, written per the rule below |

Upstream appends both wirings. This module only de-duplicates, cleans up leftovers, and writes the defconfig.

## Pipeline

1. Check that `KERNEL_ROOT` and `DEFCONFIG` are set and `$DEFCONFIG` exists.
2. **Kernel line check**: `CONFIG` must be one of `android12-5.10`, `android13-5.15`, `android14-6.1`, `android15-6.6`, `android16-6.12` (with a `-*` suffix); when `CONFIG` is unset the check only warns.
3. **Locate the source root**: `$KERNEL_ROOT/common` when it exists (GKI layout), otherwise `$KERNEL_ROOT`; `fs/` must exist.
4. **`CONFIG_KEYS` check**: scans `$DEFCONFIG`, `arch/arm64/configs/gki_defconfig`, `arch/arm64/configs/defconfig` and stops at the first explicit value; warns only on an explicit disable, see [Prerequisites](#prerequisites).
5. **De-duplicate**: four files (`hybridmount.c`, `hybridmount.h`, `Kconfig`, `Makefile`) plus both wirings must all be present before the tree counts as integrated; otherwise the leftover directory and both wiring lines are removed and upstream runs again.
6. **Run upstream**: `curl -fLSs "$UPSTREAM_SETUP_URL" | bash` from `$KERNEL_SRC`; `pipefail` is on, so a curl failure is never treated as empty input.
7. **Verify upstream output**: the four files and both wirings are compared byte-for-byte (`grep -F`); any miss exits.
8. **Write the defconfig** per the rule below.

Step 5 makes the script idempotent: a second run takes the "already integrated" branch, re-integrate nothing, and leaves no duplicate wiring or duplicate defconfig lines. A tree left half-integrated by an interrupted upstream run is cleaned and rebuilt by the same step, no manual `--cleanup` needed.

## Environment

| Variable | Required | Purpose |
| --- | --- | --- |
| `KERNEL_ROOT` | yes | Source root handed down by ABK; the script decides whether it has a `common/` below it |
| `DEFCONFIG` | yes | Target defconfig for this build; the written line lands only here |
| `CONFIG` | no | Kernel line such as `android14-6.1-lts`; the line check is skipped when unset |

## Defconfig write rule

The existing state of `CONFIG_HYBRIDMOUNT` in `$DEFCONFIG` selects the edit and the log message:

| State | Action | Log |
| --- | --- | --- |
| `CONFIG_HYBRIDMOUNT=y` | left alone | `CONFIG_HYBRIDMOUNT=y already in <path>` |
| `CONFIG_HYBRIDMOUNT=<other>` | rewritten to `=y` | `rewrote CONFIG_HYBRIDMOUNT=y in <path>` |
| `# CONFIG_HYBRIDMOUNT is not set` | replaced with `=y` | `enabled CONFIG_HYBRIDMOUNT=y in <path>` |
| line absent | appended | `appended CONFIG_HYBRIDMOUNT=y to <path>` |

Nothing under `arch/arm64/configs/` is touched and no Kconfig default is written. `HYBRIDMOUNT` in `module/vfs/src/Kconfig` already defaults to `y`, so this line turns the option on deliberately rather than correcting a wrong value.

## Prerequisites

- A patched kernel tree, with `KERNEL_ROOT` pointing at it.
- A kernel line from the five above; compatibility of other lines is unverified.
- **NoMount must not be integrated alongside**: both hook inode operations and the kernel will not stop them from coexisting (they register different key types), so upstream fails when it sees `fs/nomount/Kconfig`.
- `CONFIG_KEYS=y`: `hybridmount.c` calls `register_key_type`, and with `CONFIG_KEYS=n` the whole body of `key-type.h` is `#ifdef`-ed out, breaking compilation at the declaration. `CONFIG_KEYS` normally arrives through `select` from `FS_ENCRYPTION`, `INTEGRITY`, `NFS_FS`, `CEPH_FS` and others, and GKI's `gki_defconfig` has no literal line for it, so "no explicit value in any of the three files" is normal and silent. Only an explicit `# CONFIG_KEYS is not set` warns.

## Following upstream

The upstream URL lives in the script and points at the `dev` branch:

```bash
UPSTREAM_SETUP_URL="https://raw.githubusercontent.com/Hybrid-Mount/meta-hybrid_mount/dev/module/vfs/setup.sh"
```

Upstream updates take effect directly; this repository pins no version. To pin one, replace the URL with a commit SHA.

## What upstream does

Knowing this explains the idempotency and cleanup logic here:

- Treats `pwd` as the source root and, when piped, downloads `hybridmount.c`, `hybridmount.h`, `Kconfig`, `LICENSE` from a raw URL into a temp directory.
- `mkdir -p fs/hybridmount` and copies them in, then generates an in-tree `Makefile` (the one in the upstream repository targets a DDK build and does not apply inside a kernel tree).
- Appends the wirings to `fs/Makefile` and `fs/Kconfig`; it only appends and never checks whether they already exist.
- Refuses to run when `fs/nomount` is present.
- Its own `--cleanup` flag reverts its changes; this module does not call it, see Rollback.

What it does not do: write a defconfig, check `CONFIG_KEYS`, or detect an existing integration. This module covers those three.

## On device

- `hybridmount` is built into `vmlinux`, so there is no separate `.ko` and no module list entry.
- Build output lives in `fs/hybridmount/hybridmount.o` and the final `vmlinux`; check symbols with `nm vmlinux | grep -i hybridmount`.
- The build-time switch is `CONFIG_HYBRIDMOUNT=y` in the defconfig; runtime behaviour is driven by upstream's userspace tooling, which this module does not configure.

## Verification

Build time: `[hybridmount] done` in the log and `CONFIG_HYBRIDMOUNT=y` in the defconfig.

On device:

```bash
zcat /proc/config.gz | grep HYBRIDMOUNT
grep -i hybridmount /proc/kallsyms | head
dmesg | grep -i hybridmount
```

## Exit codes

| Code | Cause |
| --- | --- |
| `0` | Integrated with the defconfig written, or already integrated |
| `1` | `KERNEL_ROOT` / `DEFCONFIG` unset; defconfig missing; kernel line unsupported; no `fs/` tree; upstream failed; upstream output or wiring incomplete; defconfig write failed |

ABK treats a non-zero exit as a failed build, so it never compiles from a half-integrated tree.

## Rollback

```bash
rm -rf fs/hybridmount
sed -i '\|^obj-$(CONFIG_HYBRIDMOUNT) += hybridmount/$|d' fs/Makefile
sed -i '\|^source "fs/hybridmount/Kconfig"$|d' fs/Kconfig
sed -i '/^CONFIG_HYBRIDMOUNT=y$/d' "$DEFCONFIG"
```

To use upstream's own revert, run its `--cleanup` by hand:

```bash
curl -fLSs "https://raw.githubusercontent.com/Hybrid-Mount/meta-hybrid_mount/dev/module/vfs/setup.sh" | bash -s -- --cleanup
```

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| `defconfig not found: <path>` | `DEFCONFIG` points elsewhere, or ABK has not placed the defconfig yet |
| `unsupported kernel line: <CONFIG>` | The line is outside the five-entry allow-list; switch lines or extend the list |
| `no fs/ tree under <path>` | `KERNEL_ROOT` is not a kernel tree and has no `common/` |
| `warning: CONFIG_KEYS is explicitly off in <path>` | That defconfig disables `KEYS`; enable it or `register_key_type` has no declaration |
| `upstream output incomplete: want 4 files ...` | Upstream was interrupted or the network failed; rerun the script, it cleans up and re-integrates |
| Upstream reports a nomount conflict | The tree already carries NoMount; remove it first |
| Log says `already integrated ... skipping` but the build cannot find a file | All four files and both wirings were present while the directory was damaged externally (files deleted by hand); `rm -rf fs/hybridmount` and rerun |

## License

The scripts in this repository are GPL-3.0-only (see the SPDX header). The integrated upstream `hybridmount` sources are GPL-2.0-only and ship their LICENSE into `fs/hybridmount/`.
