# Infrastructure Benchmarking

Benchmark scripts for infrastructure using synthetic workloads. CPU, memory and
network use the [Phoronix Test Suite (PTS)](https://www.phoronix-test-suite.com/);
storage defaults to a direct [fio](https://fio.readthedocs.io/) method that
reports IOPS, throughput and latency percentiles (with a PTS path still available
via `--method pts`). Each script targets a single performance dimension. PTS
results can be compared locally or uploaded to
[OpenBenchmarking.org](https://openbenchmarking.org/).

**Supported distributions:** Ubuntu, Debian, Rocky Linux, openSUSE (Leap 15.6, Leap 16, Tumbleweed, Slowroll).
Runs on physical machines and virtual machines (vSphere, OpenStack).

---

## Contents

- [Scripts](#scripts)
- [Quick start](#quick-start)
- [benchmark-cpu-pts.sh](#benchmark-cpu-ptssh)
- [benchmark-memory-pts.sh](#benchmark-memory-ptssh)
- [benchmark-network-pts.sh](#benchmark-network-ptssh)
- [benchmark-storage-pts.sh](#benchmark-storage-ptssh)
- [create-report-pts.sh](#create-report-ptssh)
  - [Report samples](#report-samples)
- [Prerequisites](#prerequisites)
- [OS preparation](#os-preparation)
- [Virtual machine setup](#virtual-machine-setup)

---

## Scripts

| Script | Workload | Tests |
|---|---|---|
| `benchmark-cpu-pts.sh` | CPU | `pts/build-linux-kernel`, `pts/compress-7zip`, `pts/c-ray`, `pts/openssl`, `pts/stockfish` |
| `benchmark-memory-pts.sh` | Memory | `pts/stream`, `pts/ramspeed`, `pts/tinymembench`, `pts/cachebench` |
| `benchmark-network-pts.sh` | Network | `pts/network-loopback` †, `pts/sockperf`, `pts/iperf`, `pts/netperf` |
| `benchmark-storage-pts.sh` | Disk I/O | **`fio` direct** (default) §; or `pts/fio`, `pts/dbench`, `pts/fs-mark`, `pts/compilebench` ‡ via `--method pts` |
| `install-pts.sh` | *(shared library)* | Sourced by all benchmark scripts to install PTS and system-level build dependencies |

> † **`pts/network-loopback`** requires OpenBSD `nc`. On RHEL/Rocky the default
> `nc` is nmap's `ncat`, which is not CLI-compatible, so the script **detects
> this and skips the loopback test automatically** (with a warning); the other
> network tests run normally. Install OpenBSD netcat to enable it where
> available.
>
> § **Storage defaults to a direct `fio` method** (no PTS): a curated,
> time-boxed workload matrix reporting IOPS, throughput and p50/p99/p99.9
> latency. The legacy PTS path (`--method pts`) is still available and is the
> only one that uploads to OpenBenchmarking.org. See
> [benchmark-storage-pts.sh](#benchmark-storage-ptssh).
>
> ‡ **`pts/compilebench`** (PTS method only) requires Python 2, which is absent
> from current releases (Ubuntu 24.04+, Debian 13, Rocky 9+, openSUSE Leap 16+).
> The storage script **detects this and skips compilebench automatically** on
> those hosts, so the effective modern PTS storage suite is `pts/fio`,
> `pts/dbench`, and `pts/fs-mark`. It still runs on older distros that ship
> Python 2 (e.g. openSUSE Leap 15.6).

`create-report-pts.sh` consumes the `benchmark-results/` directories produced by any of the
above scripts and generates reports in all supported PTS formats (text, CSV, JSON, HTML, PDF),
with cross-run comparison when more than one run directory is supplied.

---

## Quick start

```bash
git clone https://github.com/ciroiriarte/benchmarking.git
cd benchmarking

# CPU benchmark — auto-detects topology, runs with all threads
sudo ./benchmark-cpu-pts.sh --result-id "my-server-baseline"

# Memory benchmark
sudo ./benchmark-memory-pts.sh --result-id "my-server-baseline"

# Storage benchmark (destructive — wipes target disk)
# Default direct-fio method writes its own IOPS/throughput/latency summary table.
sudo ./benchmark-storage-pts.sh --disk "/dev/vdb;nvme-test" --result-id "my-server-baseline"

# Generate reports from CPU/memory/network results (and storage with --method pts)
./create-report-pts.sh ./benchmark-results/my-server-baseline/
```

PTS and all test dependencies are installed automatically on first run via the
shared `install-pts.sh` library. Results are saved to `./benchmark-results/<result-id>/`.

---

## benchmark-cpu-pts.sh

Benchmarks CPU performance across five complementary workload classes: integer
multi-threaded compilation, LZMA compression, floating-point ray tracing,
cryptographic operations, and branchy integer search. Automatically detects CPU
topology (sockets, cores, threads) and scales accordingly. An unmeasured warmup
run is executed before each timed run to bring caches and branch predictor to
steady state.

### Usage

```
./benchmark-cpu-pts.sh [OPTIONS]

OPTIONS:
  -T, --tests <list>           Comma-separated PTS test identifiers (overrides defaults)
  -r, --runs <N>               Minimum timed runs per test (default: 3)
  -u, --upload                 Upload results to OpenBenchmarking.org
  -i, --result-id <id>         Run identifier, e.g. "dc1-node3-baseline"
  -n, --result-name <name>     Display name, e.g. "DC1 Node3 - AMD EPYC 9354"
  --identifier <value>         System identifier for PTS comparison columns.
                               "upload-id", "upload-name" (default), or custom string.
  -h, --help                   Show help
```

### Examples

```bash
# Run the full default test suite with all sub-option permutations
./benchmark-cpu-pts.sh --result-id "dc1-node3-baseline"

# Run a custom test subset
./benchmark-cpu-pts.sh --tests pts/compress-7zip,pts/c-ray --result-id "dc1-node3-fp"

# Run and upload results
./benchmark-cpu-pts.sh --upload \
  --result-id "dc1-node3-baseline" \
  --result-name "DC1 Node3 - AMD EPYC 9354"
```

### Sample report

The following was collected from 8-vCPU / 16 GB KVM virtual machines (Intel Xeon
E5-2680 v2) across three distributions. Tests were run with `--upload` to publish
results to OpenBenchmarking.org.

**Command:**

```bash
sudo ./benchmark-cpu-pts.sh --upload \
  --result-id cpu-rocky9-8vcpu \
  --result-name "Rocky Linux 9 - 8 vCPU benchmark"
```

**Run summary (abbreviated):**

```
--- Pre-run System Checks ---
INFO: cpufreq interface not available (VM or container); skipping governor check.
INFO: Thermal sensors not available; skipping temperature check.
OK: System load (0.00) is within normal range for 8 CPUs.
OK: CPU steal time is 0.0% (below 5% threshold).
------------------------------
=== Starting CPU Benchmark ===
Test profile: pts/build-linux-kernel
--- Warmup run (result discarded) ---
--- Timed runs (3) ---
=== Starting CPU Benchmark ===
Test profile: pts/compress-7zip
...
=== Starting CPU Benchmark ===
Test profile: pts/stockfish
--- Warmup run (result discarded) ---
--- Timed runs (3) ---
--- Collecting results to /home/cloudadmin/benchmark-results/cpu-rocky9-8vcpu ---
Results collected: 1 PTS result(s) + snapshot -> /home/cloudadmin/benchmark-results/cpu-rocky9-8vcpu
    Results Uploaded To: https://openbenchmarking.org/result/2603129-NE-CPUROCKY953
All uploads complete.

=== Benchmark Complete ===
```

**System snapshot excerpt** (`cpu-rocky9-8vcpu-system-snapshot.txt`):

```
=== Benchmark Configuration ===
Date:          2026-03-12 10:19:38 UTC
Result ID:     cpu-rocky9-8vcpu
Result Name:   Rocky Linux 9 - 8 vCPU benchmark
Tests:         pts/build-linux-kernel pts/compress-7zip pts/c-ray pts/openssl pts/stockfish
Threads:       8
Runs per test: 3

=== CPU Topology ===
Model name:          Intel(R) Xeon(R) CPU E5-2680 v2 @ 2.80GHz
CPU(s):              8
Thread(s) per core:  1
Core(s) per socket:  8
Socket(s):           1
Hypervisor vendor:   KVM
L1d cache:           256 KiB (8 instances)
L2 cache:            32 MiB (8 instances)
L3 cache:            16 MiB (1 instance)

=== Memory ===
               total        used        free
Mem:            15Gi       249Mi        15Gi
```

**Output structure:**

```
benchmark-results/
└── cpu-rocky9-8vcpu/
    ├── cpu-rocky9-8vcpu-system-snapshot.txt
    └── cpu-rocky9-8vcpu/
        ├── composite.xml
        ├── installation-logs/
        │   └── Intel Xeon E5-2680 v2/
        │       ├── pts_compress-7zip-1.12.0.log
        │       ├── pts_c-ray-2.0.0.log
        │       ├── pts_openssl-3.6.0.log
        │       └── pts_stockfish-1.7.0.log
        ├── system-logs/
        │   └── Intel Xeon E5-2680 v2/
        │       ├── cc, cmdline, config, cpuinfo, dmesg, ...
        │       └── lscpu, lsmod, meminfo, mounts, uname
        └── test-logs/
            └── <test-hash>/
                └── Intel Xeon E5-2680 v2.log
```

> **Note:** All CPU tests share a single PTS result directory named after the
> `--result-id`. This differs from the memory and storage scripts where each
> PTS test produces its own result directory.

**OpenBenchmarking.org results (standalone per VM):**

| Distro | Result URL |
|---|---|
| openSUSE Leap 16.0 | [2603127-NE-CPUOPENSU41](https://openbenchmarking.org/result/2603127-NE-CPUOPENSU41) |
| Ubuntu 24.04 | [2603123-NE-CPUUBUNTU26](https://openbenchmarking.org/result/2603123-NE-CPUUBUNTU26) |
| Rocky Linux 9.7 | [2603129-NE-CPUROCKY953](https://openbenchmarking.org/result/2603129-NE-CPUROCKY953) |

**Cross-distribution comparison:**

OpenBenchmarking.org can merge results from separate runs into a single comparison view:

https://openbenchmarking.org/result/merge/2603127-NE-CPUOPENSU41,2603123-NE-CPUUBUNTU26,2603129-NE-CPUROCKY953

To produce a local comparison report, collect results from each machine and feed
them to `create-report-pts.sh`:

```bash
# Step 1 — Run benchmarks on each machine
ssh cloudadmin@x.x.x.101 'sudo ./benchmark-cpu-pts.sh --upload \
  --result-id cpu-opensuse16-8vcpu \
  --result-name "openSUSE Leap 16.0 - 8 vCPU benchmark"'

ssh cloudadmin@x.x.x.102 'sudo ./benchmark-cpu-pts.sh --upload \
  --result-id cpu-ubuntu2404-8vcpu \
  --result-name "Ubuntu 24.04 LTS - 8 vCPU benchmark"'

ssh cloudadmin@x.x.x.103 'sudo ./benchmark-cpu-pts.sh --upload \
  --result-id cpu-rocky9-8vcpu \
  --result-name "Rocky Linux 9 - 8 vCPU benchmark"'

# Step 2 — Collect results locally
mkdir -p results/
for pair in "opensuse16:x.x.x.101" "ubuntu2404:x.x.x.102" "rocky9:x.x.x.103"; do
  name="${pair%%:*}"; ip="${pair##*:}"
  scp -r "cloudadmin@${ip}:~/benchmark-results/cpu-${name}-8vcpu" results/
done

# Step 3 — Generate combined report
./create-report-pts.sh \
  results/cpu-opensuse16-8vcpu/ \
  results/cpu-ubuntu2404-8vcpu/ \
  results/cpu-rocky9-8vcpu/
```

---

## benchmark-memory-pts.sh

Benchmarks the memory subsystem using four complementary tests that together
cover sustained DRAM bandwidth, integer vs. floating-point memory paths, cache
hierarchy bandwidth, and combined bandwidth + latency profiling. All sub-option
permutations are exercised automatically in a single run per test.

| Test | Measures |
|---|---|
| `pts/stream` | Sustained DRAM bandwidth — Copy, Scale, Add, Triad |
| `pts/ramspeed` | Integer and FP bandwidth — Copy, Scale, Add, Triad, Average |
| `pts/tinymembench` | Bandwidth and latency across L1/L2/L3/DRAM |
| `pts/cachebench` | Cache-level bandwidth — Read, Write, Read/Modify/Write |

### Usage

```
./benchmark-memory-pts.sh [OPTIONS]

OPTIONS:
  -u, --upload                 Upload results to OpenBenchmarking.org
  -i, --result-id <id>         Run identifier, e.g. "dc1-node3-ddr5"
  -n, --result-name <name>     Display name, e.g. "DC1 Node3 - DDR5 6400 MT/s"
  --identifier <value>         System identifier for PTS comparison columns.
                               "upload-id", "upload-name" (default), or custom string.
  -h, --help                   Show help
```

### Examples

```bash
# Run all memory benchmarks
./benchmark-memory-pts.sh --result-id "dc1-node3-baseline"

# Run and upload results
./benchmark-memory-pts.sh --upload \
  --result-id "dc1-node3-ddr5" \
  --result-name "DC1 Node3 - DDR5 6400 MT/s"
```

### Sample report

The following was collected from 8-vCPU / 16 GB KVM virtual machines (Intel Xeon
E5-2680 v2) across three distributions. Tests were run with `--upload` to publish
results to OpenBenchmarking.org.

**Command:**

```bash
sudo ./benchmark-memory-pts.sh --upload \
  --result-id mem-test-opensuse \
  --result-name "openSUSE Leap 16.0 - 8vCPU 16GB KVM"
```

**Run summary (abbreviated):**

```
--- Pre-run System Checks ---
INFO: cpufreq interface not available (VM or container); skipping governor check.
INFO: Thermal sensors not available; skipping temperature check.
OK: System load (0.01) is within normal range for 8 CPUs.
OK: CPU steal time is 0.0% (below 5% threshold).
------------------------------
=== Running memory benchmark: pts/stream ===
Result saved as: mem-test-opensuse_stream
=== Running memory benchmark: pts/ramspeed ===
Result saved as: mem-test-opensuse_ramspeed
=== Running memory benchmark: pts/tinymembench ===
Result saved as: mem-test-opensuse_tinymembench
=== Running memory benchmark: pts/cachebench ===
Result saved as: mem-test-opensuse_cachebench
--- Collecting results to /home/cloudadmin/benchmark-results/mem-test-opensuse ---
--- Uploading results to OpenBenchmarking.org ---

=== Memory Benchmark Summary ===
Completed results: 4
  [OK] mem-test-opensuse_stream
  [OK] mem-test-opensuse_ramspeed
  [OK] mem-test-opensuse_tinymembench
  [OK] mem-test-opensuse_cachebench

All tests completed successfully.
```

**System snapshot excerpt** (`mem-test-opensuse-system-snapshot.txt`):

```
=== Benchmark Configuration ===
Date:        2026-03-12 01:36:11 UTC
Result ID:   mem-test-opensuse
Result Name: openSUSE Leap 16.0 - 8vCPU 16GB KVM
Tests:       pts/stream pts/ramspeed pts/tinymembench pts/cachebench

=== CPU Topology ===
Model name:          Intel(R) Xeon(R) CPU E5-2680 v2 @ 2.80GHz
CPU(s):              8
Thread(s) per core:  1
Core(s) per socket:  8
Socket(s):           1
Hypervisor vendor:   KVM
L1d cache:           256 KiB (8 instances)
L2 cache:            32 MiB (8 instances)
L3 cache:            16 MiB (1 instance)

=== Memory ===
MemTotal:   16371064 kB
```

**OpenBenchmarking.org results (openSUSE Leap 16.0):**

| Test | URL |
|---|---|
| stream | https://openbenchmarking.org/result/2603124-NE-MEMTESTOP85 |
| ramspeed | https://openbenchmarking.org/result/2603126-NE-MEMTESTOP06 |
| tinymembench | https://openbenchmarking.org/result/2603129-NE-MEMTESTOP26 |
| cachebench | https://openbenchmarking.org/result/2603124-NE-MEMTESTOP46 |

**OpenBenchmarking.org results (Rocky Linux 9.7):**

| Test | URL |
|---|---|
| stream | https://openbenchmarking.org/result/2603120-NE-MEMTESTRO17 |
| ramspeed | https://openbenchmarking.org/result/2603129-NE-MEMTESTRO47 |
| tinymembench | https://openbenchmarking.org/result/2603121-NE-MEMTESTRO67 |
| cachebench | https://openbenchmarking.org/result/2603127-NE-MEMTESTRO87 |

**Output structure:**

```
benchmark-results/
└── mem-test-opensuse/
    ├── mem-test-opensuse-system-snapshot.txt
    ├── mem-test-opensusestream/
    │   ├── composite.xml
    │   ├── system-logs/
    │   └── test-logs/
    ├── mem-test-opensuseramspeed/
    │   ├── composite.xml
    │   ├── system-logs/
    │   └── test-logs/
    ├── mem-test-opensusetinymembench/
    │   └── ...
    └── mem-test-opensusecachebench/
        └── ...
```

> **Note:** PTS strips underscores from result directory names (e.g.
> `mem-test-opensuse_stream` → `mem-test-opensusestream`). The script handles
> this transparently when collecting results and uploading.

---

## benchmark-network-pts.sh

Benchmarks network performance across three modes:

| Test | Mode | Measures |
|---|---|---|
| `pts/network-loopback` | Standalone | TCP stack throughput via loopback (kernel buffer performance) |
| `pts/sockperf` | Standalone | Socket API latency (ping-pong, under-load) and throughput |
| `pts/iperf` | Peer | TCP bulk throughput (single and multi-stream scaled to link speed), UDP throughput |
| `pts/netperf` | Peer | TCP/UDP throughput (both directions) and request-response latency |

Standalone tests run on a single host. Peer tests require a second machine running
the script in `--server-mode`. Parallel stream count and UDP bandwidth scale
automatically with NIC line rate (e.g. 25 streams on 25 GbE). Override with
`--streams` or `--nic-speed` for virtual NICs that do not expose speed via sysfs.

### Server setup

Run on the remote host before starting the client. The script installs test
binaries via PTS and starts `iperf3` and `netserver` as local daemons. Stop
them with **Ctrl+C** when the run is complete.

```bash
# Bind to a specific interface or IP
./benchmark-network-pts.sh --server-mode --interface eth0
./benchmark-network-pts.sh --server-mode --interface 192.168.100.10

# Bind to all interfaces
./benchmark-network-pts.sh --server-mode
```

### Usage

```
./benchmark-network-pts.sh [OPTIONS]

OPTIONS:
  -s, --server <address>       Peer IP/hostname for iperf3/netperf tests.
                               Omit to run standalone tests only.
                               Mutually exclusive with --server-mode.
  --server-mode                Start iperf3 and netserver as local daemons.
                               Mutually exclusive with --server.
  -I, --interface <iface|IP>   Client: egress interface for NIC speed detection.
                               Server: interface/IP to bind daemons to.
  --nic-speed <Mbps>           Override NIC speed, e.g. 100000 for 100 GbE.
                               Client mode only.
  --streams <N>                Override parallel stream count. Client mode only.
  -u, --upload                 Upload results to OpenBenchmarking.org
  -i, --result-id <id>         Run identifier, e.g. "dc1-vm1-to-vm2"
  -n, --result-name <name>     Display name, e.g. "VM1 to VM2 - 100GbE vSwitch"
  --identifier <value>         System identifier for PTS comparison columns.
                               "upload-id", "upload-name" (default), or custom string.
  -h, --help                   Show help
```

### Examples

```bash
# Standalone tests only (no second machine needed)
./benchmark-network-pts.sh --result-id "dc1-node3-loopback"

# Full suite against a peer (auto-detects interface and stream count)
./benchmark-network-pts.sh --server 192.168.100.10 \
  --result-id "dc1-vm1-to-vm2" \
  --result-name "VM1 to VM2 - Ceph cluster network"

# 100 GbE link where the virtual NIC does not report speed via sysfs
./benchmark-network-pts.sh --server 192.168.100.10 \
  --interface eth0 --nic-speed 100000 \
  --result-id "dc1-vm1-to-vm2" \
  --result-name "VM1 to VM2 - 100GbE vSwitch"

# Full suite with upload
./benchmark-network-pts.sh --server 192.168.100.10 --upload \
  --result-id "dc1-vm1-to-vm2" \
  --result-name "VM1 to VM2 - 100GbE vSwitch"
```

---

## benchmark-storage-pts.sh

> **WARNING: This script is destructive. It formats and completely wipes all data on every target disk.**
> Safety guards (below) refuse the live system's disks, and a destructive run
> must be authorized — interactively by typing `WIPE`, or with `--force` for
> automation.

Benchmarks disk I/O across one or more disks sequentially (one at a time, to
avoid contention). It offers two methods:

| Method | Flag | What it does |
|---|---|---|
| **Direct fio** *(default)* | `--method direct` | Runs a small, curated, time-boxed `fio` matrix and reports **IOPS, throughput, and p50/p99/p99.9 latency** in a readable summary table (plus CSV and per-workload JSON). Fast (minutes/disk) and meaningful. No Phoronix Test Suite required. |
| **Phoronix Test Suite** | `--method pts` | Legacy path: runs `pts/fio`, `pts/dbench`, `pts/fs-mark` (and `pts/compilebench` where Python 2 exists). Slower and reports no latency, but supports **`--upload` to OpenBenchmarking.org**. |

The direct method exists because the PTS fio sweep ran 576 sub-tests per disk
(~10 h), reported no latency, and tied concurrency to CPU count (results not
comparable across hosts). The curated direct matrix fixes all three.

### Direct-fio workload matrix

Fixed `numjobs`/`iodepth` per workload (so results are comparable across hosts),
`direct=1`, one I/O engine (`io_uring`, falling back to `libaio`), time-boxed:

| Workload | Pattern | Block | Queue depth | numjobs | Measures |
|---|---|---|---|---|---|
| `randread_4k_qd1` | random read | 4 KiB | 1 | 1 | read latency floor |
| `randread_4k_qd32` | random read | 4 KiB | 32 | 4 | saturated read IOPS |
| `randwrite_4k_qd1` | random write | 4 KiB | 1 | 1 | write latency floor |
| `randwrite_4k_qd32` | random write | 4 KiB | 32 | 4 | saturated write IOPS |
| `randrw_4k_70_30_qd32` | 70/30 mixed | 4 KiB | 32 | 4 | real-world mixed |
| `seqread_1m_qd16` | sequential read | 1 MiB | 16 | 1 | read throughput |
| `seqwrite_1m_qd16` | sequential write | 1 MiB | 16 | 1 | write throughput |

`--mode quick` runs a 4-workload subset (the two QD32 randoms + both sequential)
with shorter runtimes and skips preconditioning — a fast sanity check. `--mode
full` (default) runs all seven.

### Safety guards and authorization

Because the script wipes its targets, it enforces two independent protections:

**1. Programmatic guards (always on, cannot be bypassed).** Before any write,
each target is validated; the run aborts (touching nothing) if any target — or
any of its partitions/holders — is:

- the root/boot disk (mounted at `/`, `/boot`, or `/boot/efi`),
- mounted anywhere else (e.g. `/dev/sdb1` mounted while `/dev/sdb` is the target),
- an LVM physical volume, a Linux MD RAID member, or an active swap area.

A stale mount at the target's own `/mnt/<label>` (left by an aborted prior run)
is tolerated and reclaimed. `--force` does **not** bypass these guards: a typo
that names the OS disk is refused even in automation.

**2. Destructive confirmation.** After printing the exact list of disks to be
wiped, the script requires authorization:

| Context | Without `--force` | With `--force` |
|---|---|---|
| Interactive (TTY) | prompts to type `WIPE` | proceeds |
| Non-interactive (`nohup`/SSH/cron) | **aborts** | **proceeds** |

So unattended runs are safe by default and need exactly one extra flag —
`--force` (aliases `--yes`, `-y`) — to authorize destruction:

```bash
sudo nohup ./benchmark-storage-pts.sh --disk "/dev/sdb;data01" --force \
  --result-id nightly > /tmp/bench.log 2>&1 &
```

### Disk configuration

Target disks are specified at runtime — no editing of the script is required.
Each entry uses the format `"<device>;<label>"`. The label names the mount point
(`/mnt/<label>`) and result directories. Always quote the argument to prevent the
shell from interpreting `;` as a command separator.

**Inline flags** (`--disk` may be repeated):

```bash
./benchmark-storage-pts.sh \
  --disk "/dev/vdb;NVMe_Replica3" \
  --disk "/dev/vdc;NVMe_EC32" \
  --disk "/dev/vdd;HDD_Replica3" \
  --disk "/dev/vde;HDD_EC32"
```

**Disk file** (one `device;label` per line; `#` comments and blank lines are ignored):

```
# Storage benchmark disk list
/dev/vdb;NVMe_Replica3
/dev/vdc;NVMe_EC32

/dev/vdd;HDD_Replica3
/dev/vde;HDD_EC32
```

```bash
./benchmark-storage-pts.sh --disk-file disks.conf
```

Both sources may be combined in the same invocation.

### SSD steady-state preconditioning

SSDs and NVMe drives perform significantly faster in a rested state than under
sustained load, producing results that overstate real-world performance and are
not reproducible across repeated runs. To address this, the script writes across
the full device twice before formatting it (two sequential passes, 128 KiB blocks,
queue depth 32), driving the device through its garbage-collection and
wear-levelling cycle so that measurements reflect steady-state performance.

Preconditioning is **enabled by default** in `--mode full` and skipped
automatically for HDDs, for unknown device types, and in `--mode quick`. Disable
it explicitly with `--skip-preconditioning` when re-running tests immediately
after a previous run (the drive is already conditioned) or when turnaround time
matters more than reproducibility. Note that preconditioning time scales with
drive capacity — plan for two full sequential write passes per disk before
testing begins.

### Usage

```
./benchmark-storage-pts.sh --disk "<dev;label>" [--disk "<dev;label>" ...] [OPTIONS]
./benchmark-storage-pts.sh --disk-file <path> [OPTIONS]

Disk target options (at least one required):
  --disk "<device;label>"      Add a target disk (repeatable). Must be quoted.
  --disk-file <path>           Read disk entries from a file.

OPTIONS:
  --method <direct|pts>        Benchmark method (default: direct). See table above.
  --mode <quick|full>          Direct-method run profile (default: full).
                               quick = 4-workload subset, shorter runtimes, skips
                               preconditioning; full = all 7 workloads.
  --fio-size <SIZE>            Direct-method test-file size (default: 8G; auto-capped
                               to ~80% of free space). e.g. 4G, 16G, 100G.
  --fio-engine <engine>        Direct-method fio engine (default: auto = io_uring
                               if available, else libaio).
  --force, --yes, -y           Authorize destruction without the interactive prompt.
                               Required to run destructively in non-interactive mode
                               (nohup/SSH/cron). Does NOT bypass the safety guards.
  --upload                     Upload results to OpenBenchmarking.org. Requires --method pts.
  --result-id <id>             Run identifier; names the benchmark-results/<id>/ output dir.
  --result-name <name>         Display name (pts method), e.g. "Ceph NVMe vs HDD - Q1 2026"
  --identifier <value>         System identifier for PTS comparison columns (pts method).
                               "upload-id", "upload-name" (default), or custom string.
  --skip-preconditioning       Skip SSD steady-state preconditioning (see above)
  --help                       Show help
```

### Examples

```bash
# Default: curated direct-fio matrix, two disks in one run.
# Produces a summary table + CSV + JSON per disk (no PTS, no upload).
./benchmark-storage-pts.sh \
  --disk "/dev/vdb;nvme" \
  --disk "/dev/vdd;hdd" \
  --result-id "ceph-dc1-q1-2026"

# Quick sanity check (4 workloads, shorter runtimes, no preconditioning)
./benchmark-storage-pts.sh --disk "/dev/vdb;nvme" --mode quick \
  --result-id "nvme-smoke"

# Larger test file to span more of the device (better steady-state on big SSDs)
./benchmark-storage-pts.sh --disk "/dev/vdb;nvme" --fio-size 64G \
  --result-id "nvme-full"

# Legacy PTS method WITH OpenBenchmarking.org upload
./benchmark-storage-pts.sh --disk-file disks.conf --method pts --upload \
  --result-id "ceph-dc1-q1-2026" \
  --result-name "Ceph NVMe vs HDD - Q1 2026"
```

### Direct-method output

Each disk gets a `fio-direct-<label>/` directory under the run directory:

```
benchmark-results/<result-id>/
├── <result-id>-system-snapshot.txt
├── fio-direct-nvme/
│   ├── summary.txt          # human-readable table (IOPS, MB/s, p50/p99 latency)
│   ├── summary.csv          # same data incl. p99.9, for spreadsheets
│   ├── randread_4k_qd1.json # raw fio JSON, one per workload
│   └── ...
└── fio-direct-hdd/
    └── ...
```

Example `summary.txt`:

```
=== fio direct results: nvme (/dev/vdb) ===
engine=io_uring runtime=45s ramp=10s file=8.0G
workload               bs   qd  jobs rw        |      rIOPS     rMB/s   r-p50us   r-p99us |      wIOPS     wMB/s   w-p50us   w-p99us
randread_4k_qd1        4k   1   1    randread  |       9123      35.6       105       210 |
randread_4k_qd32       4k   32  4    randread  |     312480    1220.6        95       380 |
randwrite_4k_qd32      4k   32  4    randwrite |                                          |     118734     463.8       210      1850
randrw_4k_70_30_qd32   4k   32  4    randrw    |      84210     328.9       180       720 |      36090     140.9       240      2100
seqread_1m_qd16        1m   16  1    read      |       3450    3450.0      4200      8900 |
seqwrite_1m_qd16       1m   16  1    write     |                                          |       1980    1980.0      7100     21000
```

The direct method is self-contained — it does **not** feed `create-report-pts.sh`
(which consumes PTS `composite.xml` files). Use `--method pts` if you need PTS
reports or OpenBenchmarking.org comparison. See
[report-samples/storage/](#report-samples) for real generated samples.

---

## create-report-pts.sh

Generates reports from `benchmark-results/` directories produced by any benchmark
script. When more than one run directory is supplied, same-type results are merged
for cross-run comparison. Reports are written in all supported PTS export formats.

| Format | Extension | Notes |
|---|---|---|
| Text | `.text` | Human-readable summary table |
| CSV | `.csv` | Flat CSV for spreadsheet import |
| JSON | `.json` | Structured data for custom processing |
| HTML | `.html` | Self-contained page with charts |
| PDF | `.pdf` | Requires `wkhtmltopdf` |

### Usage

```
./create-report-pts.sh [OPTIONS] <run-dir> [<run-dir> ...]

ARGUMENTS:
  <run-dir>                One or more benchmark-results/<result-id>/ directories.

OPTIONS:
  -o, --output-dir <path>  Directory to write reports (default: ./pts-reports/<timestamp>/)
  -l, --label <dir>=<label>  Assign a friendly label to a run directory.
                             May be repeated. Overrides auto-detection.
  --identifier <value>     Custom system identifier for all runs without --label.
                           Overrides OS auto-detection.
  -h, --help               Show help
```

When multiple run directories are supplied, each system gets a label used in
comparison charts. Labels are auto-detected from the OS field in
`composite.xml` (e.g. "openSUSE Leap 16.0"), or can be overridden with
`--label` for clarity. Results with empty values (failed tests) are
automatically skipped.

### Result directory model

Every script writes to the **same outer layout** — a single run directory named
after `--result-id`, containing the system snapshot plus one or more PTS result
subdirectories:

```
benchmark-results/<result-id>/
├── <result-id>-system-snapshot.txt
└── <one or more PTS result subdirectories>   # naming varies per script, see below
```

What differs between scripts is **how many PTS result subdirectories are created
and how they are named** — this follows how each PTS test family reports results:

| Script | Result subdirectory(ies) | One subdir per… | Differentiator |
|---|---|---|---|
| `benchmark-cpu-pts.sh` | `<result-id>` (single, shared by all CPU tests) | run | `--result-id` |
| `benchmark-memory-pts.sh` | `<result-id>_<test>` | test | `--result-id` |
| `benchmark-network-pts.sh` | `<result-id>_<test-variant>` | test variant | `--result-id` |
| `benchmark-storage-pts.sh` (direct) | `fio-direct-<disk-label>/` (summary.txt/csv + JSON) | disk | disk label in `--disk` |
| `benchmark-storage-pts.sh` (`--method pts`) | `<disk-label>_<test>_result` | disk × test | disk label in `--disk` |

Key points:

- **CPU** groups all five tests into one PTS result directory (named `<result-id>`);
  the others create a separate directory per test.
- **Storage** distinguishes results by the **disk label** from
  `--disk "<dev;label>"`, not by `--result-id`, because a single run can test
  several disks. Use distinct labels to compare disks within one run, or the same
  label across runs to compare a disk over time. The default direct method writes
  a self-contained `fio-direct-<label>/` directory (summary table + CSV + JSON);
  the PTS method writes one `<label>_<test>_result` per disk×test.
- `create-report-pts.sh` consumes PTS result directories (CPU, memory, network,
  and storage `--method pts`). The direct-fio storage output is already a
  finished report and is not fed to `create-report-pts.sh`.

### System identifier

The PTS comparison column label (what appears in chart legends and tables) is
controlled by `--identifier`:

| Value | Resolves to | Example |
|---|---|---|
| `upload-name` (default) | `--result-name` value | "Rocky Linux 9 - 8 vCPU benchmark" |
| `upload-id` | `--result-id` value | "cpu-rocky9-8vcpu" |
| Any other string | Literal value | "DC1 Node3" |

When `--identifier` is not specified, the system identifier defaults to the
`--result-name` value. This is the string PTS writes into the
`<System><Identifier>` element in `composite.xml`.

For `create-report-pts.sh`, `--identifier` sets a custom default label for all
run directories that lack an explicit `--label` override. It takes priority over
OS auto-detection from `composite.xml`.

### Examples

```bash
# Single run — export all formats for every PTS test found
./create-report-pts.sh ./benchmark-results/dc1-node3-ddr5/

# CPU / memory / network: compare two runs
./benchmark-memory-pts.sh --result-id "node3-baseline"
./benchmark-memory-pts.sh --result-id "node3-tuned"
./create-report-pts.sh \
  ./benchmark-results/node3-baseline/ \
  ./benchmark-results/node3-tuned/

# Cross-distro comparison with explicit labels and output directory
./create-report-pts.sh -o ./report-samples/memory \
  --label "results/mem-test-opensuse=openSUSE 16.0" \
  --label "results/mem-test-rocky=Rocky Linux 9" \
  --label "results/mem-test-ubuntu=Ubuntu 24.04" \
  results/mem-test-opensuse results/mem-test-rocky results/mem-test-ubuntu

# Storage — compare disk types within a single run (different disk labels)
./benchmark-storage-pts.sh \
  --disk "/dev/vdb;NVMe_Replica3" \
  --disk "/dev/vdc;HDD_Replica3" \
  --result-id "ceph-dc1-q1-2026"
./create-report-pts.sh ./benchmark-results/ceph-dc1-q1-2026/

# Storage — compare the same disk type across two runs (e.g. before/after upgrade)
./benchmark-storage-pts.sh --disk "/dev/vdb;NVMe" --result-id "ceph-dc1-before"
./benchmark-storage-pts.sh --disk "/dev/vdb;NVMe" --result-id "ceph-dc1-after"
./create-report-pts.sh \
  ./benchmark-results/ceph-dc1-before/ \
  ./benchmark-results/ceph-dc1-after/
```

### Sample: cross-distribution memory comparison

The example below runs `benchmark-memory-pts.sh` on three KVM virtual machines
(identical hardware: 8 vCPU / 16 GB, Intel Xeon E5-2680 v2) running different
distributions, then uses `create-report-pts.sh` to produce a combined comparison
report.

**Step 1 — Run benchmarks on each machine:**

```bash
# openSUSE Leap 16.0 (x.x.x.101)
ssh cloudadmin@x.x.x.101 'sudo ./benchmark-memory-pts.sh --upload \
  --result-id mem-test-opensuse \
  --result-name "openSUSE Leap 16.0 - 8vCPU 16GB KVM"'

# Rocky Linux 9.7 (x.x.x.102)
ssh cloudadmin@x.x.x.102 'sudo ./benchmark-memory-pts.sh --upload \
  --result-id mem-test-rocky \
  --result-name "Rocky Linux 9.7 - 8vCPU 16GB KVM"'

# Ubuntu 24.04 (x.x.x.103)
ssh cloudadmin@x.x.x.103 'sudo ./benchmark-memory-pts.sh --upload \
  --result-id mem-test-ubuntu \
  --result-name "Ubuntu 24.04 - 8vCPU 16GB KVM"'
```

**Step 2 — Collect results locally:**

```bash
mkdir -p results/
for pair in "opensuse:x.x.x.101" "rocky:x.x.x.102" "ubuntu:x.x.x.103"; do
  name="${pair%%:*}"; ip="${pair##*:}"
  scp -r "cloudadmin@${ip}:~/benchmark-results/mem-test-${name}" results/
done
```

**Step 3 — Generate combined report:**

```bash
./create-report-pts.sh -o ./report-samples/memory \
  --label "results/mem-test-opensuse=openSUSE 16.0" \
  --label "results/mem-test-rocky=Rocky Linux 9" \
  --label "results/mem-test-ubuntu=Ubuntu 24.04" \
  results/mem-test-opensuse/ \
  results/mem-test-rocky/ \
  results/mem-test-ubuntu/
```

The `--label` flag maps each run directory to a human-readable name used in
chart legends and system comparison tables (instead of the default hardware
identifier like "Intel Xeon E5-2680 v2").

**Resulting directory structure:**

```
results/
├── mem-test-opensuse/
│   ├── mem-test-opensuse-system-snapshot.txt
│   ├── mem-test-opensusestream/
│   │   ├── composite.xml
│   │   ├── system-logs/
│   │   └── test-logs/
│   ├── mem-test-opensuseramspeed/
│   ├── mem-test-opensusetinymembench/
│   └── mem-test-opensusecachebench/
├── mem-test-rocky/
│   ├── mem-test-rocky-system-snapshot.txt
│   ├── mem-test-rockystream/
│   ├── mem-test-rockyramspeed/
│   ├── mem-test-rockytinymembench/
│   └── mem-test-rockycachebench/
└── mem-test-ubuntu/
    ├── mem-test-ubuntu-system-snapshot.txt
    ├── mem-test-ubuntustream/
    ├── mem-test-ubunturamspeed/
    ├── mem-test-ubuntutinymembench/
    └── mem-test-ubuntucachebench/
```

`create-report-pts.sh` merges same-test results (e.g. all three `*stream/composite.xml`
files) into a single comparison, making it easy to see how memory bandwidth and latency
differ across distributions and kernel versions on identical hardware.

### Report samples

The `report-samples/` directory contains pre-generated graphical comparison
reports (HTML with inline SVG bar charts, PDF, CSV, JSON, text) for all
benchmark results in the `results/` directory. Each HTML file is
self-contained and can be opened in any browser.

```
report-samples/
├── cpu/                     # 5 tests: build-linux-kernel, compress-7zip, c-ray, openssl, stockfish
│   ├── cpu-e5-2680v2-opensuse160/
│   │   ├── cpu-e5-2680v2-opensuse160.html
│   │   ├── cpu-e5-2680v2-opensuse160.pdf
│   │   ├── cpu-e5-2680v2-opensuse160.csv
│   │   ├── cpu-e5-2680v2-opensuse160.json
│   │   └── cpu-e5-2680v2-opensuse160.text
│   ├── cpu-e5-2680v2-rocky-9/
│   │   └── ...
│   └── cpu-e5-2680v2-ubuntu-2404/
│       └── ...
├── memory/                  # 4 tests: cachebench, ramspeed, stream, tinymembench
│   └── cachebench/
│       ├── cachebench.html  # Bar charts comparing 3 distros
│       ├── cachebench.pdf
│       ├── cachebench.csv
│       ├── cachebench.json
│       └── cachebench.text
├── network-peer/            # 8 tests: loopback, netperf×4, sockperf×3
│   └── netperftcpstream/
│       └── ...
├── network-standalone/      # 4 tests: loopback, sockperf×3
│   └── ...
└── storage/                 # direct-fio method (default): per-disk summary + raw JSON
    ├── fio-direct-data01/
    │   ├── summary.txt      # IOPS / throughput / p50/p99 latency table
    │   ├── summary.csv      # same data incl. p99.9
    │   ├── randread_4k_qd1.json    # raw fio JSON, one per workload
    │   ├── randread_4k_qd32.json
    │   ├── randwrite_4k_qd1.json
    │   ├── randwrite_4k_qd32.json
    │   ├── randrw_4k_70_30_qd32.json
    │   ├── seqread_1m_qd16.json
    │   └── seqwrite_1m_qd16.json
    └── fio-direct-data02/
        └── ...
```

> The storage samples are produced by the default direct-fio method, so they are
> finished summary tables (not PTS charts). For PTS-style storage charts and
> OpenBenchmarking.org comparison, run with `--method pts` and feed the result to
> `create-report-pts.sh`.

To regenerate all report-samples from the raw results:

```bash
# CPU benchmarks (3 distros)
./create-report-pts.sh -o ./report-samples/cpu \
  --label "results/cpu-E5-2680v2-opensuse.16.0=openSUSE 16.0" \
  --label "results/cpu-E5-2680v2-ubuntu-24.04=Ubuntu 24.04" \
  --label "results/cpu-E5-2680v2-rocky-9=Rocky Linux 9" \
  results/cpu-E5-2680v2-opensuse.16.0 results/cpu-E5-2680v2-ubuntu-24.04 \
  results/cpu-E5-2680v2-rocky-9

# Memory benchmarks (3 distros)
./create-report-pts.sh -o ./report-samples/memory \
  --label "results/mem-test-opensuse=openSUSE 16.0" \
  --label "results/mem-test-rocky=Rocky Linux 9" \
  --label "results/mem-test-ubuntu=Ubuntu 24.04" \
  results/mem-test-opensuse results/mem-test-rocky results/mem-test-ubuntu

# Network peer benchmarks (3 distros)
./create-report-pts.sh -o ./report-samples/network-peer \
  --label "results/peer/net-peer-opensuse16=openSUSE 16.0" \
  --label "results/peer/net-peer-rocky9=Rocky Linux 9" \
  --label "results/peer/net-peer-ubuntu2404=Ubuntu 24.04" \
  results/peer/net-peer-opensuse16 results/peer/net-peer-rocky9 \
  results/peer/net-peer-ubuntu2404

# Network standalone benchmarks (3 distros)
./create-report-pts.sh -o ./report-samples/network-standalone \
  --label "results/standalone/net-standalone-opensuse16=openSUSE 16.0" \
  --label "results/standalone/net-standalone-rocky9=Rocky Linux 9" \
  --label "results/standalone/net-standalone-ubuntu2404=Ubuntu 24.04" \
  results/standalone/net-standalone-opensuse16 \
  results/standalone/net-standalone-rocky9 \
  results/standalone/net-standalone-ubuntu2404

# Storage: the default direct-fio method produces its own summary tables, so
# there is no create-report step. The samples under report-samples/storage/ are
# copied straight from a run's benchmark-results/<id>/fio-direct-<label>/ dirs:
#   sudo ./benchmark-storage-pts.sh --disk "/dev/sdb;data01" --disk "/dev/sdc;data02" \
#     --result-id storage-sample --fio-size 2G
#   cp -r benchmark-results/storage-sample/fio-direct-* report-samples/storage/
#
# Only the legacy --method pts path feeds create-report-pts.sh:
# ./create-report-pts.sh -o ./report-samples/storage-pts \
#   results/sto-pve-opensuse16/sto-pve-opensuse16 \
#   results/sto-pve-ubuntu2404/sto-pve-ubuntu2404 \
#   results/sto-pve-rocky9/sto-pve-rocky9
```

**OpenBenchmarking.org results:**

| Distro | stream | ramspeed | tinymembench | cachebench |
|---|---|---|---|---|
| openSUSE Leap 16.0 | [2603124-NE-MEMTESTOP85](https://openbenchmarking.org/result/2603124-NE-MEMTESTOP85) | [2603126-NE-MEMTESTOP06](https://openbenchmarking.org/result/2603126-NE-MEMTESTOP06) | [2603129-NE-MEMTESTOP26](https://openbenchmarking.org/result/2603129-NE-MEMTESTOP26) | [2603124-NE-MEMTESTOP46](https://openbenchmarking.org/result/2603124-NE-MEMTESTOP46) |
| Rocky Linux 9.7 | [2603120-NE-MEMTESTRO17](https://openbenchmarking.org/result/2603120-NE-MEMTESTRO17) | [2603129-NE-MEMTESTRO47](https://openbenchmarking.org/result/2603129-NE-MEMTESTRO47) | [2603121-NE-MEMTESTRO67](https://openbenchmarking.org/result/2603121-NE-MEMTESTRO67) | [2603127-NE-MEMTESTRO87](https://openbenchmarking.org/result/2603127-NE-MEMTESTRO87) |

---

## Prerequisites

- A user with `sudo` access
- Internet connectivity to reach package repositories and PTS download mirrors
- For `benchmark-storage-pts.sh`: raw block devices (not mounted, not in use)

All other dependencies (PTS, test binaries, compilers) are installed automatically
on first run. `install-pts.sh` must be co-located with the benchmark scripts
(same directory). If scripts are deployed to `/usr/local/bin/`, copy
`install-pts.sh` there as well.

---

## OS preparation

### Ubuntu / Debian

No additional steps. The script uses `apt-get` and falls back to a direct `.deb`
download from the PTS project if `phoronix-test-suite` is not in the distribution
repositories.

### Rocky Linux / RHEL

EPEL must be reachable. The script enables it automatically with:

```bash
sudo dnf install -y epel-release
```

### openSUSE

The script adds the `benchmark` OBS repository automatically for the detected
version (Leap 15.6, Tumbleweed, or Slowroll). On Leap 15.6, `gcc12` is installed
and registered as the default compiler via `update-alternatives`.

---

## Virtual machine setup

### vSphere

1. Install a supported guest OS and configure SSH access.
2. Create a VM with the desired CPU and memory configuration.
3. For storage testing, attach additional virtual disks with the characteristics
   to compare (e.g. one disk on an NVMe-backed datastore, one on an HDD-backed
   datastore). Attach them as independent persistent disks so they are excluded
   from snapshots.
4. Note the guest device names assigned to the extra disks (typically `/dev/sdb`,
   `/dev/sdc`, … or `/dev/vdb`, `/dev/vdc`, … depending on the controller type)
   and pass them to the script via `--disk` or `--disk-file`.
5. Clone this repository on the instance and run the desired script.

### OpenStack

1. Create an instance with the desired flavor and install a supported guest OS.
2. For storage testing, create Cinder volumes with the desired volume types and
   attach them to the instance:

   ```bash
   openstack volume create --size 100 --type ceph-nvme nvme-test-vol
   openstack volume create --size 100 --type ceph-hdd  hdd-test-vol
   openstack server add volume <instance-id> <volume-id>
   ```

3. Identify the device names inside the guest (e.g. via `lsblk`) and pass them
   to the script via `--disk` or `--disk-file`.
4. Clone this repository on the instance and run the desired script.

### Notes on virtual machines and shared storage

Benchmarking on virtual machines with shared storage backends (e.g. vSAN, Ceph,
NFS-backed datastores) introduces I/O jitter that is not present on bare-metal
systems with locally attached drives. The hypervisor scheduler, storage backend
contention, network latency between the guest and the storage cluster, and dynamic
resource allocation (ballooning, QoS policies) all contribute to run-to-run
variation that the benchmark framework cannot eliminate.

In practice this means:

- **PTS will exceed the minimum 3 runs** per test combination. Deviations of
  10–40% are common on virtual disks, causing PTS to repeat each test up to its
  maximum iteration limit before accepting a result. This significantly extends
  total benchmark time compared to bare-metal runs.
- **Results across hypervisor platforms or storage backends are not directly
  comparable** unless the VMs are identically sized, pinned to the same physical
  hosts, and tested under equivalent storage load conditions.
- **Absolute throughput and IOPS values will be lower** than the underlying
  storage hardware can deliver, due to virtualisation overhead and the
  shared-tenancy nature of the backend.

Results from virtual machine runs should be interpreted as indicative of general
performance characteristics rather than precise absolute values.
