# benchmarking

Benchmark scripts for infrastructure using synthetic tests via the
[Phoronix Test Suite (PTS)](https://www.phoronix-test-suite.com/).
Each script targets a single workload dimension — CPU-bound or I/O-bound —
and produces results that can optionally be uploaded to
[OpenBenchmarking.org](https://openbenchmarking.org/) for comparison across
runs and systems.

Supported distributions: **Ubuntu**, **Debian**, **Rocky Linux**, **openSUSE**
(Leap 15.6, Tumbleweed, Slowroll).
Scripts work on both physical machines and virtual machines (vSphere, OpenStack).

---

## Scripts

| Script | Workload | PTS tests used |
|---|---|---|
| `benchmark-cpu-pts.sh` | CPU-bound | `pts/build-linux-kernel` |
| `benchmark-storage-pts.sh` | I/O-bound | `iozone`, `fio`, `postmark`, `compilebench` |

---

## benchmark-cpu-pts.sh

Benchmarks CPU performance using a kernel compilation workload. Automatically
detects CPU topology (sockets, cores, threads) and scales the test accordingly.
PTS is installed automatically if not present.

### Usage

```
./benchmark-cpu-pts.sh [OPTIONS]

OPTIONS:
  -t, --threads <N>            Number of threads to use (default: all available)
  -u, --upload                 Upload results to OpenBenchmarking.org
  -i, --result-id <id>         Test identifier for the result (e.g. 'prod-server-01')
  -n, --result-name <name>     Display name for the result (e.g. 'Prod Server - Intel Xeon')
  -h, --help                   Show help
```

### Examples

```bash
# Run with all available CPU threads
./benchmark-cpu-pts.sh

# Run with a specific thread count
./benchmark-cpu-pts.sh --threads 4

# Run and upload results
./benchmark-cpu-pts.sh --upload \
  --result-id "dc1-node3-baseline" \
  --result-name "DC1 Node3 - AMD EPYC 9354"
```

---

## benchmark-storage-pts.sh

> **WARNING: This script is destructive. It formats and completely wipes all
> data on every disk listed in the `DISKS` array.**

Benchmarks storage I/O across multiple disks sequentially. For each disk it
runs the full suite of PTS storage tests covering latency, IOPS, throughput,
and workload characterisation (read/write ratio, block size, access pattern).
Results across disks are compared locally at the end of the run and can
optionally be uploaded.

### Disk configuration

Before running, edit the `DISKS` array at the top of the script to match the
target system. Each entry is a `device;label` pair:

```bash
DISKS=(
    "/dev/vdb;NVMe_Replica3"
    "/dev/vdc;NVMe_EC32"
    "/dev/vdd;HDD_Replica3"
    "/dev/vde;HDD_EC32"
)
```

Labels are used to name mount points (`/mnt/<label>`) and result files.
Disks are tested sequentially — one disk at a time — to avoid I/O contention.

### Usage

```
./benchmark-storage-pts.sh [OPTIONS]

OPTIONS:
  --upload                     Upload results to OpenBenchmarking.org
  --result-name <name>         Display name for the upload (required with --upload)
  --result-id <id>             Test identifier for the upload (required with --upload)
  --help                       Show help
```

### Examples

```bash
# Run storage tests (no upload)
./benchmark-storage-pts.sh

# Run and upload results
./benchmark-storage-pts.sh --upload \
  --result-name "Ceph NVMe vs HDD - Q1 2026" \
  --result-id "ceph-dc1-q1-2026"
```

---

## OS preparation

Scripts install all dependencies automatically on first run. No manual
preparation is required beyond meeting the prerequisites below.

### Prerequisites (all distributions)

- A user with `sudo` access
- Internet connectivity to reach package repositories and PTS download mirrors
- For `benchmark-storage-pts.sh`: raw block devices (not mounted, not in use)

### Ubuntu / Debian

No additional steps. The script uses `apt-get` and falls back to a direct
`.deb` download from the PTS project if `phoronix-test-suite` is not in the
distribution's repositories.

### Rocky Linux / RHEL

EPEL must be reachable. The script enables it automatically with:

```bash
sudo dnf install -y epel-release
```

### openSUSE

The script adds the `benchmark` OBS repository automatically for the detected
version (Leap 15.6, Tumbleweed, or Slowroll). On Leap 15.6, `gcc12` is
installed and registered as the default compiler via `update-alternatives`.

---

## Virtual machine setup

### vSphere

1. Create a VM with the desired CPU and memory configuration.
2. For storage testing, attach additional virtual disks with the characteristics
   to compare (e.g. one disk on an NVMe-backed datastore, one on an HDD-backed
   datastore). Attach them as independent persistent disks so they are not
   included in snapshots.
3. Note the guest device names assigned to the extra disks (typically
   `/dev/sdb`, `/dev/sdc`, … or `/dev/vdb`, `/dev/vdc`, … depending on the
   controller type). Update the `DISKS` array in `benchmark-storage-pts.sh`.
4. Install a supported guest OS, configure SSH access, and clone this
   repository.

### OpenStack

1. Create an instance with the desired flavor.
2. For storage testing, create Cinder volumes with the desired volume types
   (e.g. `ceph-nvme`, `ceph-hdd`) and attach them to the instance:

   ```bash
   openstack volume create --size 100 --type ceph-nvme nvme-test-vol
   openstack volume create --size 100 --type ceph-hdd  hdd-test-vol
   openstack server add volume <instance-id> <volume-id>
   ```

3. Identify the device names inside the guest (e.g. via `lsblk`) and update
   the `DISKS` array in `benchmark-storage-pts.sh`.
4. Clone this repository on the instance and run the desired script.

---

## Result comparison

`benchmark-storage-pts.sh` automatically runs `phoronix-test-suite
compare-results` at the end of each run, grouping results by test type across
all tested disks. Results are also available under
`~/.phoronix-test-suite/test-results/` for manual inspection or later upload.
