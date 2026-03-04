# RCU Stall Warnings When Running Install Scripts in a VM

## Context

When running the installation scripts (`scripts/01` through `scripts/04`) on a VM with 8 vCPUs and 16 GB RAM, Linux kernel RCU (Read-Copy-Update) stall warnings appear repeatedly.

RCU stall warnings fire when a CPU fails to reach a quiescent state within the grace period timeout (default: ~21 seconds, controlled by `CONFIG_RCU_CPU_STALL_TIMEOUT`). They indicate that some CPU was stuck in a non-preemptible kernel context for too long.

---

## Root Causes

### 1. `cryptsetup luksFormat --type luks2` — Primary Suspect

**Scripts:** `01-partition-and-encrypt.sh` lines 107 and 123 (run twice — OS disk + Incus disk)

LUKS2's default PBKDF is **Argon2id**, which is intentionally memory-hard. At format time, `cryptsetup` benchmarks the system and allocates up to **~1 GiB of RAM** per `luksFormat` call to derive the key. The memory access pattern is deliberately non-sequential to defeat hardware acceleration.

In a VM this is problematic because:

- The kernel crypto subsystem runs in a context with preemption restrictions
- The hypervisor may steal vCPUs during the memory-intensive phase
- The guest kernel sees the stolen CPU time as a missed quiescent state → RCU stall
- `luksFormat` is called **twice**, so the risk is doubled

This is a well-known interaction between Argon2id and virtualised environments.

### 2. `update-initramfs -u -k all` — Secondary Cause

**Script:** `03-configure-system.sh` line 177

Rebuilding the initramfs compresses a 100–200 MB archive. Kernels installed via `debootstrap` typically use a `CONFIG_PREEMPT_NONE` (server) configuration. Under that config, the compression loop can run without yielding long enough to breach the RCU stall threshold.

### 3. Btrfs + LUKS2 + zstd:3 Write Amplification — Contributing Factor

**Scripts:** `01-partition-and-encrypt.sh` (Btrfs creation), `02-install-ubuntu.sh` (debootstrap + apt)

The write path for every file during `debootstrap` and package installation is:

```
write → Btrfs CoW + zstd:3 compression → LUKS2 AES-XTS encryption → virtual disk
```

Writing thousands of small files (as debootstrap does) into this stack generates heavy metadata churn on Btrfs. Under memory pressure this can produce extended kernel I/O wait states that delay RCU grace periods.

### 4. vCPU Preemption by the Hypervisor

This is not caused by a bug in the scripts but is a VM-specific amplifier. Any of the CPU-intensive operations above (Argon2, initramfs compression, Btrfs metadata) can be interrupted mid-kernel-section by the hypervisor scheduling another VM. The guest kernel has no visibility into this stolen time and counts it against the RCU timeout.

---

## Fix

The most impactful change is to cap Argon2id's memory usage when formatting LUKS2 volumes. The scripts currently call `cryptsetup luksFormat` with no PBKDF flags, accepting the default (~1 GiB).

In `01-partition-and-encrypt.sh`, change both `luksFormat` calls:

```bash
# Before (lines 107, 123)
cryptsetup luksFormat --type luks2 "$ROOT_PART"
cryptsetup luksFormat --type luks2 "$INCUS_PART"

# After — cap Argon2 memory at 256 MiB
cryptsetup luksFormat --type luks2 --pbkdf-memory 262144 "$ROOT_PART"
cryptsetup luksFormat --type luks2 --pbkdf-memory 262144 "$INCUS_PART"
```

`--pbkdf-memory 262144` = 256 MiB. This is still well above the commonly recommended minimum (64 MiB) for passphrase-protected disks. The 1 GiB default matters most for resistance against GPU-based offline cracking; 256 MiB is a reasonable trade-off for VM environments.

**For VM testing only** (not recommended for production), you can eliminate memory pressure entirely by switching to PBKDF2:

```bash
cryptsetup luksFormat --type luks2 --pbkdf pbkdf2 "$ROOT_PART"
```

PBKDF2 is CPU-only, eliminating the Argon2 memory pressure, but it is significantly weaker against modern GPU-based cracking attacks.

---

## Bare Metal

On bare metal the RCU stall warnings do not occur in normal circumstances:

- **Argon2id / `luksFormat`** — the CPU is never stolen by a hypervisor, so Argon2id runs uninterrupted. It will still peg a core for several seconds but the RCU grace period machinery keeps ticking normally.
- **`update-initramfs` compression** — the compression loop yields at normal scheduling points with no hypervisor interference.
- **Btrfs write amplification** — still present, but real NVMe latency is far lower than a virtualised block device, so kernel I/O threads complete well within the stall threshold.

The `--pbkdf-memory` workaround documented in the Fix section above is only needed for VM environments.

---

## Effect of Using ext4 Instead of Btrfs

Switching to ext4 does **not** eliminate the RCU stall risk in a VM. The Argon2id `luksFormat` calls happen at the LUKS layer, which is below the filesystem — Btrfs vs ext4 is irrelevant there.

| Cause | With Btrfs | With ext4 |
|---|---|---|
| `luksFormat` Argon2id (×2) | Present | Present (unchanged) |
| `update-initramfs` compression | Present | Present (unchanged) |
| Write amplification during debootstrap | High — CoW + zstd + metadata churn | Low — simpler writes, no CoW, no inline compression |
| Hypervisor vCPU preemption amplifier | Present | Present (unchanged) |

Switching to ext4 on a VM would reduce but not eliminate the risk. The `--pbkdf-memory` fix remains necessary regardless of filesystem choice.

On bare metal, neither filesystem causes RCU stall warnings under normal conditions.

---

## Summary Table

| Operation | Script | Mechanism | Severity |
|---|---|---|---|
| `luksFormat --type luks2` (×2) | `01` | Argon2id allocates ~1 GiB, hypervisor preempts vCPU during crypto | **High** |
| `update-initramfs -u -k all` | `03` | Long non-preemptible compression loop under `PREEMPT_NONE` kernel | Medium |
| `debootstrap` + `apt-get install` on Btrfs+LUKS | `02` | Write amplification causes extended I/O wait, delays quiescent states | Low–Medium |
| Hypervisor vCPU preemption | N/A | Amplifies all of the above; invisible to the guest kernel | Amplifier |
