#!/bin/bash

# Script Name: benchmark-storage-pts.sh
# Description: This script performs destructive I/O benchmarks on specified storage devices.
#                 It will COMPLETELY WIPE ALL DATA on the disks defined in the DISKS array.
#                 After testing, it will clean up by unmounting and wiping filesystem signatures.
#
# This version is validated to work on Rocky Linux, openSUSE, and Debian/Ubuntu.
#
# Author: Ciro Iriarte <ciro.iriarte@gmail.com>
# Version: 2.2
#
# Changelog:
#   - 2026-02-19: v2.2 - Replace fragile mtime-based result directory detection
#                        with a before/after directory diff. Snapshots the results
#                        directory before each batch-run and uses comm(1) to find
#                        directories created during that specific run. If multiple
#                        new directories appear (race condition or PTS artefact),
#                        all candidates are logged and the most recently modified
#                        one is selected with a warning.
#   - 2026-02-19: v2.1 - Remove hardcoded DISKS array. Target disks are now supplied
#                        via --disk <device;label> (repeatable) or --disk-file <path>.
#                        The disk file format is one device;label per line with #
#                        comments and blank lines ignored. The script exits with a
#                        usage error when no disks are provided.
#   - 2026-02-19: v2.0 - Add SSD steady-state preconditioning via two full sequential
#                        write passes (fio, 128 KiB, qdepth=32) before each disk is
#                        formatted and tested. Enabled by default; skip with
#                        --skip-preconditioning. HDD and unknown device types are
#                        always skipped. fio added as a system-level dependency so it
#                        is available before PTS installs its own copy.
#   - 2026-02-19: v1.9 - Add per-test failure handling so a single test failure does not
#                        orphan results from completed disks/tests; failed runs are reported
#                        in a summary and the script exits non-zero if any failed.
#                        Add capture_system_snapshot() to record kernel, OS, and per-disk
#                        driver/scheduler/queue attributes before each run.
#   - 2026-02-19: v1.8 - Replace device-name and rotational-flag detection with driver-based
#                        detection via sysfs. Adds get_device_driver() which resolves the
#                        host controller driver for SCSI-layer devices by walking the sysfs
#                        tree, correctly identifying virtio-scsi, PVSCSI, and physical HBAs.
#                        Adds 'virtual' device type for paravirtual drivers.
#   - 2026-02-19: v1.7 - Change recommended scheduler for SSD from mq-deadline to none;
#                        SSD has no seek penalty and scheduler overhead distorts measurements.
#   - 2026-02-19: v1.6 - Add device type detection (NVMe/SSD/HDD via sysfs) and
#                        automatic I/O scheduler configuration per device before testing.
#   - 2026-02-17: v1.5 - Fix tests running on OS disk instead of target disks.
#                      - Replace non-existent PTS_TEST_DIR_OVERRIDE with
#                        PTS_TEST_INSTALL_ROOT_PATH (real PTS variable).
#                      - Add PRESET_OPTIONS for fio's auto-disk-mount-points option.
#                      - Move test installation inside per-disk loop so installs
#                        and runs land on the target disk, not the OS disk.
#   - 2025-09-17: v1.4 - Fix python dependency for openSUSE
#                      - avoid assuming group name equals username
#   - 2025-09-17: v1.3 - Fix dependency for iozone on openSUSE
#   - 2025-09-17: v1.2 - Match GCC for quick-benchmark-cpu for openSUSE 15.6
#   - 2025-09-17: v1.1 - Use latest PTS for Debian/Ubuntu
#   - 2025-09-17: v1.0 - Improve documentation.
#                      - Fix test working directory.
#                      - Add release disk function.
#                      - Add option to upload results.
#   - 2025-09-16: v0.1 - First draft.

set -e
set -o pipefail

# === Configuration ===
# WARNING: ALL DATA ON THE TARGET DISKS WILL BE PERMANENTLY ERASED.
# Target disks are supplied at runtime via --disk or --disk-file (see usage).
# Each entry uses the format:  <block_device>;<label>
# The label names the mount point (/mnt/<label>) and result files.
# Example (equivalent inline flags or disk-file lines):
#   /dev/vdb;NVMe_Replica3
#   /dev/vdc;NVMe_EC32
#   /dev/vdd;HDD_Replica3
#   /dev/vde;HDD_EC32
DISKS=()
REQUIRED_TESTS=("iozone" "fio" "postmark" "compilebench")
TESTUSER=$(whoami)

# Perform two sequential full-drive write passes on SSD/NVMe/virtual devices
# before formatting and testing. This moves the drive from a rested/fresh state
# to steady state so that results are reproducible across repeated runs.
# Set to 0 or pass --skip-preconditioning to disable.
PRECONDITIONING_ENABLED=1

# === Function to Display Usage ===
usage() {
    echo "Usage: $0 --disk <dev;label> [--disk <dev;label> ...] [options]"
    echo "       $0 --disk-file <path> [options]"
    echo
    echo "Disk target options (at least one disk is required):"
    echo "  --disk <device;label>      Add a target disk. May be repeated for multiple disks."
    echo "                             <device> is the block device path (e.g. /dev/vdb)."
    echo "                             <label>  is a short name used for the mount point and"
    echo "                             result files (e.g. NVMe_Replica3)."
    echo "                             Example: --disk /dev/vdb;NVMe_Replica3"
    echo "  --disk-file <path>         Read disk entries from a file (one device;label per"
    echo "                             line). Lines starting with # and blank lines are"
    echo "                             ignored. May be combined with --disk."
    echo
    echo "Options:"
    echo "  --upload                   Upload results to OpenBenchmarking.org."
    echo "  --result-name <name>       Set the 'Saved Test Name' for the upload (e.g., 'My Server NVMe vs HDD')."
    echo "  --result-id <identifier>   Set the 'Test Identifier' for the upload (e.g., 'Q3-2025-Storage-Test')."
    echo "  --skip-preconditioning     Skip the SSD steady-state preconditioning passes."
    echo "                             Preconditioning is on by default: it writes across"
    echo "                             the full device twice to move SSDs/NVMe from a rested"
    echo "                             state to steady state before measurement begins."
    echo "                             Use this flag when re-running tests immediately after"
    echo "                             a previous run, or when the drive is already conditioned."
    echo "  --help                     Display this help message."
    echo
    echo "Examples:"
    echo "  $0 --disk /dev/vdb;NVMe_Replica3 --disk /dev/vdc;NVMe_EC32 \\"
    echo "     --disk /dev/vdd;HDD_Replica3  --disk /dev/vde;HDD_EC32"
    echo
    echo "  $0 --disk-file disks.conf --upload \\"
    echo "     --result-name \"Ceph NVMe vs HDD\" --result-id \"ceph-dc1-q1-2026\""
    echo
    echo "  $0 --disk /dev/vdb;NVMe_Replica3 --skip-preconditioning"
}

# Read disk entries from a file into the DISKS array.
# Format: one <device>;<label> per line; lines starting with # and blank lines
# are ignored.
load_disk_file() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        echo "Error: disk file not found: $file"
        exit 1
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue   # skip comments
        [[ -z "${line//[[:space:]]/}" ]] && continue  # skip blank lines
        DISKS+=("$line")
    done < "$file"
}

# === Argument Parsing ===
UPLOAD_RESULTS=0
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --disk) DISKS+=("$2"); shift ;;
        --disk-file) load_disk_file "$2"; shift ;;
        --upload) UPLOAD_RESULTS=1 ;;
        --result-name) UPLOAD_NAME="$2"; shift ;;
        --result-id) UPLOAD_ID="$2"; shift ;;
        --skip-preconditioning) PRECONDITIONING_ENABLED=0 ;;
        --help) usage; exit 0 ;;
        *) echo "Unknown parameter passed: $1"; usage; exit 1 ;;
    esac
    shift
done

# Require at least one target disk
if [[ ${#DISKS[@]} -eq 0 ]]; then
    echo "Error: no target disks specified. Use --disk or --disk-file."
    echo
    usage
    exit 1
fi

# Check if upload is requested but details are missing
if [[ "$UPLOAD_RESULTS" -eq 1 ]] && ([[ -z "$UPLOAD_NAME" ]] || [[ -z "$UPLOAD_ID" ]]); then
    echo "Error: When using --upload, both --result-name and --result-id must be provided."
    usage
    exit 1
fi

# Snapshot file is named after the result identifier when provided, or a timestamp otherwise.
SNAPSHOT_FILE="${UPLOAD_ID:-storage-benchmark-$(date +%Y-%m-%d-%H%M%S)}-system-snapshot.txt"

# === OS Detection and Package Installation ===
install_packages() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "$ID" in
            rocky|rhel|centos)
                echo "Detected Rocky Linux or RHEL-based system"
                sudo dnf install -y epel-release
                sudo dnf install -y phoronix-test-suite xfsprogs util-linux fio
                ;;
            ubuntu|debian)
                echo "Detected Ubuntu or Debian-based system"
                sudo apt-get update
                # util-linux provides wipefs
                sudo apt-get install -y phoronix-test-suite xfsprogs util-linux fio || {
                    echo "Phoronix Test Suite not found in repo, attempting fallback install..."
                    wget -O /tmp/phoronix.deb https://phoronix-test-suite.com/releases/repo/pts.debian/files/phoronix-test-suite_10.8.4_all.deb
                    sudo dpkg -i /tmp/phoronix.deb
                    sudo apt-get install -f -y # Install dependencies
                }
                ;;
            opensuse*|suse)
                echo "Detected openSUSE system"
                setup_opensuse_repo
                ;;
            *)
                echo "Unsupported OS: $ID"
                exit 1
                ;;
        esac
    else
        echo "Cannot detect OS. /etc/os-release not found."
        exit 1
    fi
}

# === openSUSE Repository Setup ===
setup_opensuse_repo() {
    local repo_url
    # Match on $ID (e.g. opensuse-tumbleweed, opensuse-slowroll, opensuse-leap)
    # because $VERSION_ID is a snapshot date on Tumbleweed/Slowroll, not the OS name.
    case "$ID" in
        opensuse-tumbleweed)
            echo "Adding benchmark repo for Tumbleweed..."
            repo_url="https://download.opensuse.org/repositories/benchmark/openSUSE_Tumbleweed"
            ;;
        opensuse-slowroll)
            echo "Adding benchmark repo for Slowroll..."
            repo_url="https://download.opensuse.org/repositories/benchmark/openSUSE_Slowroll"
            ;;
        opensuse-leap)
            echo "Adding benchmark repo for Leap $VERSION_ID..."
            repo_url="https://download.opensuse.org/repositories/benchmark/${VERSION_ID}/"
            # Leap 15.6 ships an old GCC; install gcc12 and set it as the default.
            if [[ "$VERSION_ID" == "15.6" ]]; then
                gcc_extra="gcc12 gcc12-c++"
            fi
            ;;
        *)
            echo "Unsupported openSUSE variant: $ID"
            exit 1
            ;;
    esac
    sudo zypper ar -f -p 90 "$repo_url" benchmark
    sudo zypper --gpg-auto-import-keys refresh
    sudo zypper install -y phoronix-test-suite xfsprogs util-linux fio gcc gcc-c++ ${gcc_extra} make autoconf bison flex libopenssl-devel Mesa-demo-x libelf-devel libaio-devel python
    if [[ "$ID" == "opensuse-leap" ]]; then
        sudo update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-12 100
        sudo update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-12 100
    fi
}

# === Device Detection and I/O Scheduler Configuration ===

# Detect whether the script can make privileged system changes.
# Sets HAS_PRIVILEGE=1 and SUDO_CMD if running as root or passwordless sudo is available.
SUDO_CMD=""
HAS_PRIVILEGE=0
detect_privileges() {
    if [[ "$EUID" -eq 0 ]]; then
        HAS_PRIVILEGE=1
    elif sudo -n true 2>/dev/null; then
        HAS_PRIVILEGE=1
        SUDO_CMD="sudo"
    else
        HAS_PRIVILEGE=0
        echo "INFO: Not running as root and no passwordless sudo available."
        echo "      I/O schedulers will not be configured automatically."
    fi
}

# Resolve the kernel driver handling a block device from sysfs.
# For simple devices (NVMe, virtio-blk) this is the direct device driver.
# For SCSI-layer devices the disk is always driven by the generic 'sd' driver;
# this function walks up the sysfs device tree to find the underlying host
# controller driver (e.g. virtio_scsi, vmw_pvscsi, ahci, mpt3sas).
# Outputs the driver name, or 'unknown' if it cannot be determined.
get_device_driver() {
    local dev_name="$1"
    local driver_link="/sys/block/${dev_name}/device/driver"

    if [[ ! -L "$driver_link" ]]; then
        echo "unknown"
        return
    fi

    local direct_driver
    direct_driver=$(basename "$(readlink "$driver_link")")

    # For non-SCSI drivers the direct driver is the answer.
    if [[ "$direct_driver" != "sd" ]]; then
        echo "$direct_driver"
        return
    fi

    # For SCSI block devices the direct driver is always the generic 'sd'.
    # Walk up the sysfs tree to find the host controller driver.
    local device_path
    device_path=$(readlink -f "/sys/block/${dev_name}/device")
    local path="$device_path"

    while [[ "$path" =~ ^/sys/ ]]; do
        path=$(dirname "$path")
        if [[ -L "${path}/driver" ]]; then
            local host_drv
            host_drv=$(basename "$(readlink "${path}/driver")")
            # Skip intermediate SCSI transport layer drivers and keep walking up.
            case "$host_drv" in
                sd|scsi_transport_sas|scsi_transport_fc|scsi_transport_spi)
                    continue
                    ;;
                *)
                    echo "$host_drv"
                    return
                    ;;
            esac
        fi
    done

    echo "sd"
}

# Detect the storage device type using the kernel driver rather than device name
# or rotational flag, which are unreliable for paravirtual devices in VMs.
# Outputs: nvme | virtual | ssd | hdd | unknown
detect_device_type() {
    local device="$1"
    local dev_name
    dev_name=$(basename "$device")

    local driver
    driver=$(get_device_driver "$dev_name")

    case "$driver" in
        nvme)
            # NVMe: real hardware or paravirtual NVMe controller.
            echo "nvme"
            ;;
        virtio_blk|virtio_scsi|vmw_pvscsi|xen-blkfront|xen_blkfront)
            # Known paravirtual drivers: the hypervisor handles scheduling.
            echo "virtual"
            ;;
        unknown|sd)
            # Driver interface unavailable or unresolved; fall back to rotational flag.
            local rotational_file="/sys/block/${dev_name}/queue/rotational"
            [[ -f "$rotational_file" ]] || { echo "unknown"; return; }
            [[ "$(< "$rotational_file")" -eq 0 ]] && echo "ssd" || echo "hdd"
            ;;
        *)
            # Physical HBA driver (ahci, mpt3sas, megaraid_sas, hpsa, etc.).
            # Use the rotational flag to distinguish SSD from HDD.
            local rotational_file="/sys/block/${dev_name}/queue/rotational"
            [[ -f "$rotational_file" ]] || { echo "unknown"; return; }
            [[ "$(< "$rotational_file")" -eq 0 ]] && echo "ssd" || echo "hdd"
            ;;
    esac
}

# Return the recommended I/O scheduler for a given device type.
# NVMe, SSD, and paravirtual devices benefit from 'none': the device or hypervisor
# handles scheduling and adding a guest-level scheduler only introduces overhead.
# HDDs still benefit from mq-deadline's seek reordering and deadline guarantees.
recommended_scheduler() {
    case "$1" in
        nvme|ssd|virtual) echo "none" ;;
        hdd)              echo "mq-deadline" ;;
        *)                echo "mq-deadline" ;;
    esac
}

# Detect the device type, log it, and automatically set the recommended I/O
# scheduler. Warns without changing if the scheduler interface is unavailable
# or the script lacks the required privileges.
configure_io_scheduler() {
    local device="$1"
    local dev_name
    dev_name=$(basename "$device")
    local scheduler_file="/sys/block/${dev_name}/queue/scheduler"

    if [[ ! -f "$scheduler_file" ]]; then
        echo "  INFO: I/O scheduler interface not available for $device; skipping."
        return
    fi

    local driver
    driver=$(get_device_driver "$(basename "$device")")
    local device_type
    device_type=$(detect_device_type "$device")
    local recommended
    recommended=$(recommended_scheduler "$device_type")
    # The active scheduler is shown in brackets, e.g. "[mq-deadline] none kyber bfq"
    local current
    current=$(sed 's/.*\[\([^]]*\)\].*/\1/' "$scheduler_file")

    echo "  Device:    $device"
    echo "  Driver:    $driver"
    echo "  Type:      $device_type"
    echo "  Scheduler: current=${current}  recommended=${recommended}"

    if [[ "$current" == "$recommended" ]]; then
        echo "  Status:    OK (no change needed)"
        return
    fi

    if [[ "$HAS_PRIVILEGE" -eq 0 ]]; then
        echo "  Status:    WARNING — insufficient privileges; proceeding with '${current}'."
        return
    fi

    if ! grep -qw "$recommended" "$scheduler_file"; then
        echo "  Status:    WARNING — '${recommended}' unavailable for $device."
        echo "             Available: $(< "$scheduler_file")"
        return
    fi

    echo "$recommended" | ${SUDO_CMD} tee "$scheduler_file" > /dev/null
    echo "  Status:    OK — scheduler set to '${recommended}'."
}

# === System Snapshot ===

# Capture system and per-disk storage metadata to a file for reproducibility.
# Records kernel, OS, block device attributes (driver, type, scheduler, queue
# depth, read-ahead, rotational flag) and memory state before testing begins.
capture_system_snapshot() {
    {
        echo "=== Benchmark Configuration ==="
        echo "Date:        $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
        echo "Result ID:   ${UPLOAD_ID:-(not set)}"
        echo "Result Name: ${UPLOAD_NAME:-(not set)}"
        echo "Tests:       ${REQUIRED_TESTS[*]}"
        echo "Disks:"
        for disk in "${DISKS[@]}"; do
            echo "  $disk"
        done
        echo ""

        echo "=== Kernel ==="
        uname -a
        echo ""

        echo "=== OS Release ==="
        cat /etc/os-release
        echo ""

        echo "=== Block Devices ==="
        lsblk -o NAME,SIZE,TYPE,ROTA,SCHED,RQ-SIZE,RA 2>/dev/null || lsblk
        echo ""

        echo "=== Per-disk Detail ==="
        local device label dev_name qdir
        for disk in "${DISKS[@]}"; do
            device=$(echo "$disk" | cut -d';' -f1)
            label=$(echo "$disk" | cut -d';' -f2)
            dev_name=$(basename "$device")
            qdir="/sys/block/${dev_name}/queue"
            echo "--- $label ($device) ---"
            echo "  driver:      $(get_device_driver "$dev_name")"
            echo "  type:        $(detect_device_type "$device")"
            if [[ -d "$qdir" ]]; then
                echo "  scheduler:   $(sed 's/.*\[\([^]]*\)\].*/\1/' "${qdir}/scheduler" 2>/dev/null || echo n/a)"
                echo "  nr_requests: $( [[ -r "${qdir}/nr_requests"  ]] && cat "${qdir}/nr_requests"  || echo n/a )"
                echo "  read_ahead:  $( [[ -r "${qdir}/read_ahead_kb" ]] && cat "${qdir}/read_ahead_kb" || echo n/a ) kB"
                echo "  rotational:  $( [[ -r "${qdir}/rotational"   ]] && cat "${qdir}/rotational"   || echo n/a )"
            fi
            echo ""
        done

        echo "=== Memory ==="
        free -h
        echo ""

        echo "=== Load Average ==="
        cat /proc/loadavg
        echo ""

        if command -v dmidecode &>/dev/null && [[ "$HAS_PRIVILEGE" -eq 1 ]]; then
            echo "=== Storage Controllers (dmidecode) ==="
            ${SUDO_CMD} dmidecode -t 8
        fi
    } > "$SNAPSHOT_FILE"
    echo "System snapshot saved to: $(realpath "$SNAPSHOT_FILE")"
}

# === SSD Steady-State Pre-conditioning ===

# Write across the full device twice to move it from a rested or fresh-out-of-box
# state to steady state before measurement begins. This follows the preconditioning
# methodology described in the SNIA Solid State Storage Performance Test
# Specification (SSS PTS) and Brendan Gregg's Active Benchmarking guidelines.
#
# Two full sequential write passes (128 KiB blocks, queue depth 32) are used:
#   - Pass 1 clears any idle caches and triggers the drive's garbage-collection cycle.
#   - Pass 2 confirms the drive has stabilised under sustained write pressure.
#
# HDDs are skipped: rotational media does not enter a rested state in the same
# way and a full sequential fill on a large HDD can add many hours to the run.
# Devices with unknown type are also skipped to avoid unintended long writes.
#
# Preconditioning writes directly to the raw block device before mkfs so the
# entire LBA space is covered regardless of filesystem overhead. Requires root
# or passwordless sudo and the system fio binary (installed as a package).
precondition_device() {
    local disk_entry="$1"
    local device label device_type
    device=$(echo "$disk_entry" | cut -d';' -f1)
    label=$(echo "$disk_entry" | cut -d';' -f2)
    device_type=$(detect_device_type "$device")

    echo "--- Pre-conditioning $label ($device, type=$device_type) ---"

    case "$device_type" in
        hdd)
            echo "  Skipped: HDD — sequential fills do not meaningfully move HDDs to steady state"
            return
            ;;
        unknown)
            echo "  Skipped: device type unknown — cannot determine if preconditioning is safe"
            return
            ;;
    esac

    if [[ "$HAS_PRIVILEGE" -eq 0 ]]; then
        echo "  Skipped: insufficient privileges to write to raw block device"
        return
    fi

    echo "  Pass 1/2: sequential write (128 KiB blocks, qdepth=32)..."
    ${SUDO_CMD} fio --name=precond-seq1 --filename="$device" \
        --rw=write --bs=128k --ioengine=libaio --iodepth=32 \
        --direct=1 --output=/dev/null

    echo "  Pass 2/2: sequential write (128 KiB blocks, qdepth=32)..."
    ${SUDO_CMD} fio --name=precond-seq2 --filename="$device" \
        --rw=write --bs=128k --ioengine=libaio --iodepth=32 \
        --direct=1 --output=/dev/null

    echo "  Pre-conditioning complete for $label."
}

# === Release and Clean Up Disks ===
# Defined here, before main execution, so the EXIT trap can always call it
# regardless of where the script exits (including early failures via set -e).
release_disk() {
    local disk_entry=$1
    local device
    local label
    device=$(echo "$disk_entry" | cut -d';' -f1)
    label=$(echo "$disk_entry" | cut -d';' -f2)
    local mount_point="/mnt/${label}"

    echo "--- Releasing disk $device ($label) ---"

    # Unmount the filesystem if it's mounted
    if mountpoint -q "$mount_point"; then
        echo "Unmounting $mount_point..."
        sudo umount "$mount_point"
    fi

    # Remove the mount point directory
    if [ -d "$mount_point" ]; then
        echo "Removing mount point directory $mount_point..."
        sudo rmdir "$mount_point"
    fi

    # Wipe filesystem signatures from the device to clean it
    echo "Wiping filesystem signatures from $device..."
    sudo wipefs --all --force "$device"

    echo "Disk $device has been cleaned and released."
}

# Runs on any exit (normal or error via set -e) so disks are always unmounted
# and wiped even if a benchmark fails mid-run.
cleanup() {
    set +e  # Do not let cleanup failures mask the original error
    echo "--- Cleaning up test disks ---"
    for disk in "${DISKS[@]}"; do
        release_disk "$disk"
    done
    echo "--- Benchmark script finished ---"
}
trap cleanup EXIT

# --- SCRIPT EXECUTION STARTS HERE ---

echo "Starting storage benchmark script..."

# === Install packages if not already present ===
if ! command -v phoronix-test-suite &> /dev/null; then
    install_packages
fi

# === Configure Phoronix Test Suite for Batch Mode ===
echo "Setting up Phoronix Test Suite in batch mode..."
phoronix-test-suite batch-setup <<EOF
Y
Y
N
N
N
EOF

# === Pre-run Device Configuration ===
echo "--- Detecting device types and configuring I/O schedulers ---"
detect_privileges
for disk in "${DISKS[@]}"; do
    device=$(echo "$disk" | cut -d';' -f1)
    label=$(echo "$disk" | cut -d';' -f2)
    echo "--- $label ($device) ---"
    configure_io_scheduler "$device"
done
echo "---------------------------------------------"

# === System Snapshot ===
capture_system_snapshot

# === SSD Steady-State Pre-conditioning ===
if [[ "$PRECONDITIONING_ENABLED" -eq 1 ]]; then
    if ! command -v fio &>/dev/null; then
        echo "WARNING: fio not found — skipping pre-conditioning."
        echo "         Install fio as a system package, or re-run after package installation."
    else
        echo "--- Pre-conditioning disks for steady state ---"
        for disk in "${DISKS[@]}"; do
            precondition_device "$disk"
        done
        echo "---------------------------------------------"
    fi
else
    echo "--- Pre-conditioning skipped (--skip-preconditioning) ---"
fi

# === Prepare Disks ===
prepare_disk() {
    local disk_entry=$1
    local device
    local label
    device=$(echo "$disk_entry" | cut -d';' -f1)
    label=$(echo "$disk_entry" | cut -d';' -f2)
    local mount_point="/mnt/${label}"

    echo "--- Preparing $device as $label ---"
    echo "WARNING: All data on $device will be erased."

    sudo umount "$device" 2>/dev/null || true # Ignore error if not mounted
    sudo mkfs.xfs -f -L "$label" "$device"
    sudo mkdir -p "$mount_point"
    sudo mount LABEL="$label" "$mount_point"
    sudo chown "$TESTUSER:" "$mount_point"
    echo "Disk $device mounted at $mount_point and ready for testing."
}

for disk in "${DISKS[@]}"; do
    prepare_disk "$disk"
done

# === Run Tests on Each Disk ===
RESULT_NAMES=()
FAILED_RUNS=()

run_tests_on_disk() {
    local disk_entry=$1
    local label
    label=$(echo "$disk_entry" | cut -d';' -f2)
    local mount_point="/mnt/${label}"

    # Direct PTS to install and run tests on the target disk.
    # PTS_TEST_INSTALL_ROOT_PATH overrides the install root for all tests,
    # so both the test binaries and their scratch/data files land on the
    # target disk rather than the OS disk.
    export PTS_TEST_INSTALL_ROOT_PATH="$mount_point"

    echo "--- Installing tests on $label ($mount_point) ---"
    local installed_tests=()
    for test_name in "${REQUIRED_TESTS[@]}"; do
        if phoronix-test-suite install "$test_name"; then
            installed_tests+=("$test_name")
        else
            echo "WARNING: Failed to install $test_name on $label; skipping."
            FAILED_RUNS+=("${label}/${test_name} (install)")
        fi
    done

    for test_name in "${installed_tests[@]}"; do
        echo "--- Running $test_name on $label ($mount_point) ---"

        # fio exposes an explicit disk-target option in its test profile.
        # Pre-answering it via PRESET_OPTIONS ensures the generated fio config
        # uses directory=<mount_point>, complementing PTS_TEST_INSTALL_ROOT_PATH.
        if [[ "$test_name" == "fio" ]]; then
            export PRESET_OPTIONS="pts/fio.auto-disk-mount-points=${mount_point}"
        fi

        # Snapshot existing result directories before the run so we can
        # identify exactly which directory was created by this batch-run call.
        local results_before
        results_before=$(ls -d ~/.phoronix-test-suite/test-results/*/ 2>/dev/null | sort)

        if ! phoronix-test-suite batch-run "$test_name"; then
            echo "WARNING: $test_name failed on $label."
            FAILED_RUNS+=("${label}/${test_name}")
            unset PRESET_OPTIONS
            continue
        fi

        unset PRESET_OPTIONS

        # Identify directories created during this run by diffing before/after.
        local results_after
        results_after=$(ls -d ~/.phoronix-test-suite/test-results/*/ 2>/dev/null | sort)

        local new_dirs=()
        mapfile -t new_dirs < <(comm -13 <(echo "$results_before") <(echo "$results_after"))

        local result_dir=""
        if [[ ${#new_dirs[@]} -eq 0 ]]; then
            echo "Warning: no new result directory detected for $test_name on $label"
        elif [[ ${#new_dirs[@]} -gt 1 ]]; then
            echo "Warning: ${#new_dirs[@]} new directories detected after $test_name; expected 1."
            echo "         Candidates:"
            printf '           %s\n' "${new_dirs[@]}"
            echo "         Picking the most recently modified one."
            result_dir=$(ls -td "${new_dirs[@]}" | head -n 1)
        else
            result_dir="${new_dirs[0]}"
        fi

        if [[ -d "$result_dir" ]]; then
            local result_name="${label}_${test_name}_result"
            mv "$result_dir" "$HOME/.phoronix-test-suite/test-results/$result_name"
            RESULT_NAMES+=("$result_name")
            echo "Result for $test_name on $label saved as: $result_name"
        fi
    done

    unset PTS_TEST_INSTALL_ROOT_PATH
}

for disk in "${DISKS[@]}"; do
    run_tests_on_disk "$disk"
done

# === Upload Results if Requested ===
if [[ "$UPLOAD_RESULTS" -eq 1 ]]; then
    echo "--- Starting result upload to OpenBenchmarking.org ---"
    export PTS_UPLOAD_NAME="$UPLOAD_NAME"
    export PTS_UPLOAD_IDENTIFIER="$UPLOAD_ID"
    
    for result in "${RESULT_NAMES[@]}"; do
        echo "Uploading result: $result"
        phoronix-test-suite upload-result "$result"
    done
    
    unset PTS_UPLOAD_NAME
    unset PTS_UPLOAD_IDENTIFIER
    echo "All uploads complete."
fi

# === Compare Results Locally ===
echo "--- Generating local result comparisons ---"
for test_name in "${REQUIRED_TESTS[@]}"; do
    echo "========================================"
    echo "    Comparison for $test_name"
    echo "========================================"
    
    # Build a list of results for the current test
    results_to_compare=()
    for r_name in "${RESULT_NAMES[@]}"; do
        if [[ "$r_name" == *_${test_name}_result ]]; then
            results_to_compare+=("$r_name")
        fi
    done

    if [ ${#results_to_compare[@]} -gt 0 ]; then
        phoronix-test-suite compare-results "${results_to_compare[@]}"
    else
        echo "No results found to compare for $test_name."
    fi
done

# === Results Summary ===
echo ""
echo "========================================"
echo "    Benchmark Summary"
echo "========================================"
echo "Completed results: ${#RESULT_NAMES[@]}"
for r in "${RESULT_NAMES[@]}"; do
    echo "  [OK] $r"
done

if [[ ${#FAILED_RUNS[@]} -gt 0 ]]; then
    echo ""
    echo "Failed runs: ${#FAILED_RUNS[@]}"
    for f in "${FAILED_RUNS[@]}"; do
        echo "  [FAIL] $f"
    done
    echo ""
    echo "ERROR: ${#FAILED_RUNS[@]} test run(s) failed. See output above for details."
    exit 1
fi

echo ""
echo "All tests completed successfully."
