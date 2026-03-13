#!/bin/bash

# Script Name: benchmark-storage-pts.sh
# Description: This script performs destructive I/O benchmarks on specified storage devices.
#                 It will COMPLETELY WIPE ALL DATA on the disks defined in the DISKS array.
#                 After testing, it will clean up by unmounting and wiping filesystem signatures.
#
# This version is validated to work on Rocky Linux, openSUSE, and Debian/Ubuntu.
#
# Author: Ciro Iriarte <ciro.iriarte@gmail.com>
# Version: 3.11.0
#
# Changelog:
#   - 2026-03-13: v3.11.0 - Add --identifier flag to control TEST_RESULTS_IDENTIFIER.
#                            Accepts "upload-id" (uses --result-id value),
#                            "upload-name" (uses --result-name, the default),
#                            or a custom literal string.
#   - 2026-03-12: v3.10.0 - Export TEST_RESULTS_IDENTIFIER=$UPLOAD_NAME so PTS
#                            comparison columns show --result-name instead of
#                            auto-generated hardware/date labels.
#   - 2026-03-12: v3.9 - Use batch-install instead of install for PTS test
#                        installation to prevent interactive dependency prompts
#                        that hang under nohup (stdin=/dev/null).
#   - 2026-03-12: v3.8 - Extract detect_privileges, collect_results, upload,
#                        result file listing, and invocation context into
#                        shared libraries (common-checks.sh, install-pts.sh
#                        configure_pts_batch).
#                        Fix upload-result: pipe 'n' to suppress interactive
#                        "attach system logs?" prompt; add PTS result name
#                        resolution with underscore-stripping and /var/lib/
#                        fallback.
#   - 2026-03-11: v3.7 - Extract PTS installation into shared install-pts.sh
#                        library.  Add build-essential to apt deps (was missing).
#                        Add result file listing at end of run.
#   - 2026-03-09: v3.6 - Add unzip to Ubuntu/Debian and openSUSE deps; PTS
#                        needs it to extract test archives (.zip). Rocky Linux
#                        ships unzip in the base install so no change needed
#                        there.
#   - 2026-03-09: v3.5 - Move DEBIAN_FRONTEND=noninteractive and
#                        NEEDRESTART_MODE=a exports to top-level scope so
#                        they also cover PTS's own internal apt-get calls
#                        during phoronix-test-suite install (which triggered
#                        the needrestart hang reported in issue #3).
#   - 2026-02-25: v3.4 - Fix persistent mkfs.xfs EBUSY: add explicit wait for
#                        kernel in_flight I/O counter to reach 0 before each
#                        mkfs attempt; the prior wipefs in cleanup leaves one
#                        in-flight write that udevadm settle does not drain.
#   - 2026-02-25: v3.3 - Fix install gate: check php presence in addition to
#                        phoronix-test-suite, so a broken prior install (iU
#                        dpkg state with PTS binary present but PHP missing)
#                        still triggers install_packages() on the next run.
#   - 2026-02-25: v3.2 - Fix Ubuntu/Debian PTS install: pre-install php-cli
#                        and php-xml before the PTS deb so dpkg never fails on
#                        missing PHP deps; add '|| true' to dpkg -i so set -e
#                        does not abort before apt-get install -f -y runs.
#   - 2026-02-25: v3.1 - Capture INVOKING_USER (SUDO_USER or whoami) and
#                        INVOKING_GROUP at startup; chown benchmark-results/
#                        output tree to that user after collection so results
#                        are not root-owned when the script is run via sudo.
#   - 2026-02-25: v3.0 - Extend run_lock cleanup in the EXIT trap to also cover
#                        /var/lib/phoronix-test-suite/installed-tests and
#                        ~/.phoronix-test-suite, where PTS writes a global lock
#                        regardless of PTS_TEST_INSTALL_ROOT_PATH.  Previously
#                        only the per-disk /mnt/<label>/pts path was cleaned.
#   - 2026-02-25: v2.9 - Harden mkfs.xfs against intermittent EBUSY: replace
#                        the single udevadm-settle+mkfs call with a retry loop
#                        (up to 3 attempts, 5 s back-off) so that any residual
#                        udevd probe triggered by a prior wipefs or lazy unmount
#                        clears before the next attempt.
#   - 2026-02-25: v2.8 - Fix cpu-threads expansion in patch_fio_disk_target():
#                        PTS treats 'cpu-threads' as a special identifier that
#                        auto-generates 1/2/N job-count permutations regardless
#                        of XML content, turning each combination into three
#                        sequential runs.  Rename identifier to 'job-count' (a
#                        regular, non-special name) and set a single value equal
#                        to the machine's CPU count so fio runs all workers in
#                        parallel (numjobs=<nproc>) rather than sweeping through
#                        job counts sequentially.  This reduces the total test
#                        count from 1152 to 384 (4 types × 4 engines × 2 direct
#                        × 12 block sizes × 1 job count × 1 disk target).
#   - 2026-02-25: v2.7 - Replace iozone and postmark (both fail to build with
#                        GCC 15) with pts/dbench and pts/fs-mark.
#                        Add Python 2 pre-check: skip compilebench with a clear
#                        warning instead of silently producing empty result logs.
#                        Add Windows AIO removal to patch_fio_disk_target() so
#                        those permutations are not attempted on Linux.
#                        Add run_lock cleanup to release_disk() EXIT trap so
#                        killed runs never block subsequent executions.
#                        Add phoronix-test-suite estimate-run-time call before
#                        each batch-run so operators know expected duration.
#                        Capture script invocation CWD and copy final results
#                        (PTS result XMLs + system snapshot) to
#                        ./benchmark-results/<run-id>/ as required by spec.
#   - 2026-02-25: v2.6 - Add udevadm settle before mkfs.xfs in prepare_disk()
#                        to prevent EBUSY race when udevd briefly opens the
#                        block device after wipefs or a prior lazy unmount.
#   - 2026-02-24: v2.5 - Fix fio disk-target auto-detection problem: with
#                        RunAllTestCombinations=Y, PTS calls batch_user_options()
#                        which ignores PRESET_OPTIONS entirely, causing fio to run
#                        tests on ALL writable disk mount points auto-detected from
#                        /proc/mounts (potentially 9+ filesystems) instead of just
#                        the target disk. Fix: patch the system-level
#                        test-definition.xml before each fio batch-run to replace
#                        the auto-disk-mount-points option with a fixed single-value
#                        menu entry pointing to the target mount point. The regex
#                        handles re-patching for subsequent disks. Remove the now-
#                        useless PRESET_OPTIONS export from the fio run loop.
#   - 2026-02-24: v2.4 - Fix fio-2.2.0 parameter mismatch: the profile passes
#                        $6=disk_target but the bundled fio-run script reads
#                        $6=NUM_JOBS and $7=DIRECTORY. This caused
#                        numjobs=<mount_path> and DIRECTORY="" (defaulting to
#                        "fiofile" on the root FS), making every fio sub-test
#                        fail immediately. Fix: after successful fio install,
#                        patch fio-run to shift parameter positions ($6→$5 for
#                        NUM_JOBS, $7→$6 for DIRECTORY). Also move
#                        PRESET_OPTIONS for fio to before phoronix-test-suite
#                        install so the disk target is baked into
#                        pts-install.json at install time, not just at run time.
#   - 2026-02-24: v2.3 - Fix three bugs that prevented tests from running on
#                        openSUSE Leap 16:
#                        1. zypper ar now skipped when benchmark repo alias
#                           already exists (was triggering set -e exit).
#                        2. update-alternatives for gcc-12 restricted to Leap
#                           15.6 only (was running on all Leap versions).
#                        3. batch-setup heredoc extended from 5 to 7 answers;
#                           missing answer for PromptSaveName left it TRUE,
#                           causing batch-run to hang waiting for user input.
#                        Add save_results_from_disk(): copies test artifacts
#                        from the mount point to ~/benchmark-artifacts-<label>/
#                        before the disk is unmounted and wiped.
#   - 2026-02-24: v2.2a - Quote device;label examples in usage to prevent
#                         shell misinterpretation of ';'.
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

# Resolve the directory containing this script so co-located libraries can be
# sourced regardless of the caller's working directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/install-pts.sh"
. "${SCRIPT_DIR}/common-checks.sh"

# WARNING: ALL DATA ON THE TARGET DISKS WILL BE PERMANENTLY ERASED.
# Target disks are supplied at runtime via --disk or --disk-file (see usage).
# Each entry uses the format:  <block_device>;<label>
# The label names the mount point (/mnt/<label>) and result files.
# Inline flag examples (quotes are required to prevent ';' from being interpreted
# by the shell as a command separator):
#   --disk "/dev/vdb;NVMe_Replica3"
#   --disk "/dev/vdc;NVMe_EC32"
# Disk-file lines (no quoting needed, one entry per line):
#   /dev/vdb;NVMe_Replica3
#   /dev/vdc;NVMe_EC32
#   /dev/vdd;HDD_Replica3
#   /dev/vde;HDD_EC32
DISKS=()
# iozone (pts/iozone-1.9.6) and postmark (pts/postmark-1.1.2) are excluded:
# both fail to compile with GCC 15 due to K&R-style function declarations.
# pts/dbench and pts/fs-mark cover comparable metadata-heavy and filesystem
# throughput workloads and build cleanly on modern toolchains.
REQUIRED_TESTS=("fio" "dbench" "fs-mark" "compilebench")
TESTUSER=$(whoami)

# Perform two sequential full-drive write passes on SSD/NVMe/virtual devices
# before formatting and testing. This moves the drive from a rested/fresh state
# to steady state so that results are reproducible across repeated runs.
# Set to 0 or pass --skip-preconditioning to disable.
PRECONDITIONING_ENABLED=1
IDENTIFIER_SOURCE="upload-name"

# === Function to Display Usage ===
usage() {
    echo "Usage: $0 --disk \"<dev;label>\" [--disk \"<dev;label>\" ...] [options]"
    echo "       $0 --disk-file <path> [options]"
    echo
    echo "Disk target options (at least one disk is required):"
    echo "  --disk \"<device;label>\"    Add a target disk. May be repeated for multiple disks."
    echo "                             <device> is the block device path (e.g. /dev/vdb)."
    echo "                             <label>  is a short name used for the mount point and"
    echo "                             result files (e.g. NVMe_Replica3)."
    echo "                             The argument must be quoted so the shell does not"
    echo "                             interpret ';' as a command separator."
    echo "                             Example: --disk \"/dev/vdb;NVMe_Replica3\""
    echo "  --disk-file <path>         Read disk entries from a file (one device;label per"
    echo "                             line). Lines starting with # and blank lines are"
    echo "                             ignored. May be combined with --disk."
    echo
    echo "Options:"
    echo "  --upload                   Upload results to OpenBenchmarking.org."
    echo "  --result-name <name>       Set the 'Saved Test Name' for the upload (e.g., 'My Server NVMe vs HDD')."
    echo "  --result-id <identifier>   Set the 'Test Identifier' for the upload (e.g., 'Q3-2025-Storage-Test')."
    echo "  --identifier <value>       Set the system identifier for PTS comparison columns."
    echo "                             \"upload-id\" = use --result-id value,"
    echo "                             \"upload-name\" = use --result-name value (default),"
    echo "                             or any custom string."
    echo "  --skip-preconditioning     Skip the SSD steady-state preconditioning passes."
    echo "                             Preconditioning is on by default: it writes across"
    echo "                             the full device twice to move SSDs/NVMe from a rested"
    echo "                             state to steady state before measurement begins."
    echo "                             Use this flag when re-running tests immediately after"
    echo "                             a previous run, or when the drive is already conditioned."
    echo "  --help                     Display this help message."
    echo
    echo "Examples:"
    echo "  $0 --disk \"/dev/vdb;NVMe_Replica3\" --disk \"/dev/vdc;NVMe_EC32\" \\"
    echo "     --disk \"/dev/vdd;HDD_Replica3\"  --disk \"/dev/vde;HDD_EC32\""
    echo
    echo "  $0 --disk-file disks.conf --upload \\"
    echo "     --result-name \"Ceph NVMe vs HDD\" --result-id \"ceph-dc1-q1-2026\""
    echo
    echo "  $0 --disk \"/dev/vdb;NVMe_Replica3\" --skip-preconditioning"
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
        --identifier) IDENTIFIER_SOURCE="$2"; shift ;;
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

# Set up invocation context (SCRIPT_INVOCATION_DIR, INVOKING_USER/GROUP,
# RUN_ID, SNAPSHOT_FILE).  The default prefix is used when --result-id is
# not provided.
setup_invocation_context "storage-benchmark"

# === Device Detection and I/O Scheduler Configuration ===
# detect_privileges is provided by common-checks.sh (sourced above).

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

# === Result Preservation ===
# Copy any test artifacts (logs, configs, small output files) from a disk's
# mount point to a safe directory on the OS filesystem BEFORE the mount is
# torn down and the disk is wiped.  Large scratch/test-data files (> 10 MiB)
# are excluded — they are just filler written by fio/iozone and carry no
# result value.  PTS result XML files are always written to
# ~/.phoronix-test-suite/test-results/ (on the OS disk) so they are safe
# regardless; this function captures any supplementary per-disk artifacts.
save_results_from_disk() {
    local mount_point="$1"
    local label="$2"
    local pts_dir="${mount_point}/pts"   # PTS creates this with the trailing-slash path

    [[ -d "$pts_dir" ]] || return 0

    local backup_dir="${HOME}/benchmark-artifacts-${label}"
    echo "  Preserving test artifacts: ${pts_dir} -> ${backup_dir}"
    mkdir -p "$backup_dir"

    # rsync with --max-size skips large scratch files cleanly; fall back to
    # find+cp on systems where rsync is absent.
    if command -v rsync &>/dev/null; then
        rsync -a --max-size=10m "$pts_dir/" "$backup_dir/" 2>/dev/null || true
    else
        find "$pts_dir" -type f -size -10M | while IFS= read -r f; do
            local rel_dir
            rel_dir=$(dirname "${f#${mount_point}/}")
            mkdir -p "${backup_dir}/${rel_dir}"
            cp "$f" "${backup_dir}/${rel_dir}/" 2>/dev/null || true
        done
    fi
    echo "  Artifacts saved to: ${backup_dir}"
}

# collect_results is provided by common-checks.sh (sourced above).
# It handles both /var/lib/ (system-wide PTS) and $HOME/ result directories,
# plus PTS underscore-stripping of directory names.

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

    # Remove stale PTS run_lock files before unmounting.  When the script is
    # killed mid-run, PTS leaves a run_lock file in each test profile directory
    # on the benchmark disk.  These block subsequent batch-run calls with
    # "the <test> test is already running" until manually removed.
    if [[ -d "${mount_point}/pts" ]]; then
        find "${mount_point}/pts" -name "run_lock" -delete 2>/dev/null || true
    fi

    # Preserve any test artifacts before the mount is torn down.
    if mountpoint -q "$mount_point"; then
        save_results_from_disk "$mount_point" "$label"
        echo "Unmounting $mount_point..."
        sudo umount "$mount_point" 2>/dev/null || \
            sudo umount -l "$mount_point" 2>/dev/null || true
    fi

    # Remove the mount point directory
    if [ -d "$mount_point" ]; then
        echo "Removing mount point directory $mount_point..."
        sudo rmdir "$mount_point" 2>/dev/null || true
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
    # Clean up any stale PTS run_lock files in the system-level installed-tests
    # directory.  These are created by PTS as a global lock regardless of
    # PTS_TEST_INSTALL_ROOT_PATH and persist if the script is killed mid-run,
    # blocking subsequent executions with "the test is already running".
    find /var/lib/phoronix-test-suite/installed-tests -name "run_lock" \
        -delete 2>/dev/null || true
    find "$HOME/.phoronix-test-suite" -name "run_lock" \
        -delete 2>/dev/null || true
    echo "--- Benchmark script finished ---"
}
trap cleanup EXIT

# --- SCRIPT EXECUTION STARTS HERE ---

echo "Starting storage benchmark script..."

# === Install PTS and dependencies ===
EXTRA_PKGS_APT=(xfsprogs util-linux fio)
EXTRA_PKGS_DNF=(xfsprogs util-linux fio)
EXTRA_PKGS_ZYPPER=(xfsprogs util-linux fio autoconf bison flex libopenssl-devel Mesa-demo-x libelf-devel libaio-devel)
ensure_pts_installed

# === Configure Phoronix Test Suite for Batch Mode ===
# RunAllTestCombinations=Y: exercise every sub-option permutation.
configure_pts_batch "Y"

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

    # Ensure the device is not mounted before formatting.  A previous aborted
    # run may have left the device mounted with orphaned processes still holding
    # it open.  Use lazy unmount (-l) as the final fallback: it immediately
    # detaches the filesystem from the VFS directory tree even if processes
    # still have files open, allowing mkfs to proceed safely.
    if mountpoint -q "$mount_point" 2>/dev/null || \
       grep -q "^${device} " /proc/mounts 2>/dev/null; then
        echo "  Force-unmounting ${device}..."
        sudo umount "$mount_point" 2>/dev/null || \
            sudo umount "$device"   2>/dev/null || \
            sudo umount -l "$mount_point" 2>/dev/null || \
            sudo umount -l "$device" 2>/dev/null || true
    fi
    # Wait for udev to finish processing any device events (e.g. from wipefs or
    # a prior lazy unmount) before formatting; avoids EBUSY from mkfs.xfs.
    # Two sources of EBUSY exist:
    #  1. udevd briefly opens the block device for partition probing after an
    #     unmount or wipefs event → drained by udevadm settle.
    #  2. The kernel in_flight counter stays non-zero while the block layer
    #     flushes the write issued by the prior wipefs in cleanup(); this is
    #     invisible to udev but blocks O_EXCL opens used by mkfs.xfs.
    # Both sources are transient (clear within seconds); we wait for both and
    # retry up to MKFS_MAX_ATTEMPTS times with short back-off.
    local mkfs_attempt=0
    local mkfs_max_attempts=5
    local dev_name
    dev_name=$(basename "$device")
    while [[ $mkfs_attempt -lt $mkfs_max_attempts ]]; do
        sudo udevadm settle --timeout=15 2>/dev/null || true
        # Drain any in-flight kernel I/Os (e.g. from prior wipefs) that would
        # cause O_EXCL to return EBUSY even with no userspace opener.
        local inflight_wait=0
        while [[ $inflight_wait -lt 30 ]]; do
            local inflight
            inflight=$(awk '{print $9}' /sys/block/${dev_name}/stat 2>/dev/null || echo 0)
            [[ "$inflight" -eq 0 ]] && break
            sleep 1
            (( inflight_wait++ )) || true
        done
        if sudo mkfs.xfs -f -L "$label" "$device" 2>/dev/null; then
            break
        fi
        (( mkfs_attempt++ )) || true
        if [[ $mkfs_attempt -lt $mkfs_max_attempts ]]; then
            echo "  mkfs.xfs attempt ${mkfs_attempt} failed (device busy?); retrying in 5s..."
            sleep 5
        fi
    done
    # Final attempt outside the loop so any remaining error is not swallowed.
    if [[ $mkfs_attempt -ge $mkfs_max_attempts ]]; then
        sudo udevadm settle --timeout=15 2>/dev/null || true
        sudo mkfs.xfs -f -L "$label" "$device"
    fi
    sudo mkdir -p "$mount_point"
    # Mount by device path rather than LABEL= to avoid a race where udev has
    # not yet processed the new filesystem signature written by mkfs.xfs.
    sudo mount "$device" "$mount_point"
    sudo chown "$TESTUSER:" "$mount_point"
    echo "Disk $device mounted at $mount_point and ready for testing."
}

for disk in "${DISKS[@]}"; do
    prepare_disk "$disk"
done

# === Run Tests on Each Disk ===
RESULT_NAMES=()
FAILED_RUNS=()

# Patch the fio-2.2.0 test-definition.xml to:
#   1. Replace the auto-disk-mount-points option with a fixed single-value disk
#      target pointing at the target mount point (prevents PTS from running fio
#      on all detected mount points when RunAllTestCombinations=Y).
#   2. Remove the Windows AIO engine entry (not supported on Linux; attempting
#      it produces one failed permutation for every block-size × direct-IO ×
#      type combination, wasting test slots and polluting results).
#
# The disk-target regex matches both the original auto-disk-mount-points form
# and the already-patched disk-target form so re-patching for a second disk
# works correctly without doubling entries.
patch_fio_disk_target() {
    local mount_point="$1"
    local fio_xml="/var/lib/phoronix-test-suite/test-profiles/pts/fio-2.2.0/test-definition.xml"

    if [[ ! -f "$fio_xml" ]]; then
        echo "  INFO: fio test-definition.xml not found at ${fio_xml}; skipping patch."
        return 0
    fi

    # Detect the CPU count to use as the single parallel job count.
    # nproc returns the number of available processing units (cores/vCPUs).
    local cpu_count
    cpu_count=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo)

    echo "  Patching fio test-definition.xml: Disk Target → ${mount_point}, Job Count → ${cpu_count} (parallel workers), removing Windows AIO"
    python3 - "$fio_xml" "$mount_point" "$cpu_count" <<'PYEOF'
import sys, re
xml_path, mount, cpu_count = sys.argv[1], sys.argv[2], sys.argv[3]
with open(xml_path, 'r') as f:
    content = f.read()

# 1. Replace disk-target option (handles both auto-detection and already-patched forms).
new_disk_option = (
    '<Option>\n'
    '      <DisplayName>Disk Target</DisplayName>\n'
    '      <Identifier>disk-target</Identifier>\n'
    '      <Menu>\n'
    '        <Entry>\n'
    '          <Name>' + mount + '</Name>\n'
    '          <Value>' + mount + '</Value>\n'
    '        </Entry>\n'
    '      </Menu>\n'
    '    </Option>')
content = re.sub(
    r'<Option>\s*<DisplayName>Disk Target</DisplayName>\s*'
    r'<Identifier>(?:auto-disk-mount-points|disk-target)</Identifier>'
    r'(?:\s*<Menu>.*?</Menu>)?\s*</Option>',
    new_disk_option, content, flags=re.DOTALL)

# 2. Replace the cpu-threads Job Count option.
#    The 'cpu-threads' identifier is special in PTS: regardless of what values
#    are listed in the XML, PTS auto-generates a permutation set based on the
#    machine's CPU count (typically 1, 2, N for an N-core system).  This turns
#    one test combination into three sequential runs with different numjobs
#    values.  The project requirement is 1 parallel worker per CPU core — all
#    running simultaneously — not a scalability sweep.
#    Fix: rename the identifier to a non-special name ('job-count') and set a
#    single entry equal to the actual CPU count so fio runs with numjobs=<cpu_count>.
new_job_option = (
    '<Option>\n'
    '      <DisplayName>Job Count</DisplayName>\n'
    '      <Identifier>job-count</Identifier>\n'
    '      <Menu>\n'
    '        <Entry>\n'
    '          <Name>' + cpu_count + '</Name>\n'
    '          <Value>' + cpu_count + '</Value>\n'
    '        </Entry>\n'
    '      </Menu>\n'
    '    </Option>')
content = re.sub(
    r'<Option>\s*<DisplayName>Job Count</DisplayName>\s*'
    r'<Identifier>(?:cpu-threads|job-count)</Identifier>'
    r'(?:\s*<Menu>.*?</Menu>)?\s*</Option>',
    new_job_option, content, flags=re.DOTALL)

# 3. Remove the Windows AIO engine entry so it is not attempted on Linux.
content = re.sub(
    r'\s*<Entry>\s*<Name>Windows AIO</Name>\s*<Value>windowsaio</Value>\s*</Entry>',
    '', content, flags=re.DOTALL)

with open(xml_path, 'w') as f:
    f.write(content)
print('    Patched: ' + xml_path)
PYEOF
}

run_tests_on_disk() {
    local disk_entry=$1
    local label
    label=$(echo "$disk_entry" | cut -d';' -f2)
    local mount_point="/mnt/${label}"

    # Direct PTS to install and run tests on the target disk.
    # PTS_TEST_INSTALL_ROOT_PATH overrides the install root for all tests,
    # so both the test binaries and their scratch/data files land on the
    # target disk rather than the OS disk.
    # The trailing slash is required: PTS concatenates this path directly with
    # "pts/" and without it produces "/mnt/labelpts/" instead of "/mnt/label/pts/".
    export PTS_TEST_INSTALL_ROOT_PATH="${mount_point}/"

    echo "--- Installing tests on $label ($mount_point) ---"
    local installed_tests=()
    for test_name in "${REQUIRED_TESTS[@]}"; do
        # compilebench (pts/compilebench-1.0.3) requires Python 2 to run.
        # Modern distributions (Leap 16+, Ubuntu 24.04+, Rocky 9+) only ship
        # Python 3.  Without Python 2 the benchmark installs successfully but
        # produces empty result log files, giving no data and no error.
        # Detect early and skip rather than wasting time on a silent no-op.
        if [[ "$test_name" == "compilebench" ]]; then
            if ! command -v python2 &>/dev/null && \
               ! (command -v python &>/dev/null && \
                  python --version 2>&1 | grep -q "^Python 2"); then
                echo "WARNING: compilebench requires Python 2, which is not available; skipping."
                FAILED_RUNS+=("${label}/${test_name} (Python 2 not available)")
                unset PRESET_OPTIONS
                continue
            fi
        fi

        # fio: pre-answer the disk-target option before install so the target
        # disk path is baked into pts-install.json rather than being applied
        # only at run time.  Clear PRESET_OPTIONS after install to avoid
        # leaking it into subsequent test installations.
        if [[ "$test_name" == "fio" ]]; then
            export PRESET_OPTIONS="pts/fio.auto-disk-mount-points=${mount_point}"
        fi

        if phoronix-test-suite batch-install "$test_name"; then
            # PTS exits 0 even when a test fails to compile; detect a build
            # failure by looking for install-failed.log in the test's directory.
            # PTS installs directly under ${mount_point}/pts/<test>-<ver>/ (no
            # 'installed-tests/' level).  '|| true' prevents set -o pipefail
            # from triggering when the pts/ directory does not yet exist or
            # find returns no matches.
            local failed_log
            failed_log=$(find "${mount_point}/pts" -maxdepth 2 \
                -name "install-failed.log" -path "*${test_name}*" \
                2>/dev/null | head -1) || true
            if [[ -n "$failed_log" ]]; then
                echo "WARNING: $test_name build failed (see ${failed_log}); skipping."
                FAILED_RUNS+=("${label}/${test_name} (build failed)")
            else
                # fio-2.2.0 profile bug: test-definition.xml passes 6 args:
                #   $1=type $2=engine $3=direct $4=block_size $5=cpu-threads $6=disk_target
                # but the bundled fio-run script reads $6=NUM_JOBS, $7=DIRECTORY.
                # Result: disk_target lands in NUM_JOBS ("numjobs=/mnt/..."),
                # DIRECTORY is empty so fio writes to "fiofile" on the root FS,
                # and every sub-test fails immediately.
                # Fix: patch fio-run post-install to shift parameter positions
                # ($6→$5 for NUM_JOBS, $7→$6 for DIRECTORY).  Apply NUM_JOBS
                # fix first so the $6→$5 substitution does not cascade onto
                # the $7→$6 change in the same sed pass.
                if [[ "$test_name" == "fio" ]]; then
                    local fio_run_script
                    fio_run_script=$(find "${mount_point}/pts" -name "fio-run" \
                        -maxdepth 4 2>/dev/null | head -1) || true
                    if [[ -n "$fio_run_script" ]]; then
                        echo "  Patching fio-run for parameter position mismatch (fio-2.2.0 profile bug)..."
                        sed -i -e 's/\$6/$5/g' -e 's/\$7/$6/g' "$fio_run_script"
                        echo "  Patched: $fio_run_script"
                    else
                        echo "  WARNING: fio-run not found after install; fio tests may fail."
                    fi
                fi
                installed_tests+=("$test_name")
            fi
        else
            echo "WARNING: Failed to install $test_name on $label; skipping."
            FAILED_RUNS+=("${label}/${test_name} (install)")
        fi

        unset PRESET_OPTIONS
    done

    for test_name in "${installed_tests[@]}"; do
        echo "--- Running $test_name on $label ($mount_point) ---"

        # fio uses the auto-disk-mount-points option which PTS resolves at run
        # time by scanning /proc/mounts.  With RunAllTestCombinations=Y, PTS
        # ignores PRESET_OPTIONS and runs on ALL detected mount points.  Patch
        # the test-definition.xml to restrict the disk target to the current
        # test disk before calling batch-run.
        if [[ "$test_name" == "fio" ]]; then
            patch_fio_disk_target "$mount_point"
        fi

        # Print estimated run time before starting so the operator can judge
        # whether to proceed or adjust the test configuration.  PTS calculates
        # this from the TimesToRun value, average per-run duration (from prior
        # runs on this machine), and the number of option permutations.
        # '|| true' prevents set -e from stopping the script if the estimate
        # command fails (e.g. first run with no timing history yet).
        echo "  Estimating run time for $test_name on $label..."
        phoronix-test-suite estimate-run-time "$test_name" 2>/dev/null || true

        # Snapshot existing result directories before the run so we can
        # identify exactly which directory was created by this batch-run call.
        # '|| true' prevents set -e from firing when test-results is empty
        # (ls exits 1 when no glob matches).
        local results_before
        results_before=$(ls -d ~/.phoronix-test-suite/test-results/*/ 2>/dev/null \
            | sort || true)

        if ! phoronix-test-suite batch-run "$test_name"; then
            echo "WARNING: $test_name failed on $label."
            FAILED_RUNS+=("${label}/${test_name}")
            continue
        fi

        # Identify directories created during this run by diffing before/after.
        local results_after
        results_after=$(ls -d ~/.phoronix-test-suite/test-results/*/ 2>/dev/null \
            | sort || true)

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

# Set PTS result metadata so the identifier column in comparisons shows the
# --result-name value rather than auto-generated hardware/date labels.
[[ -n "$UPLOAD_NAME" ]] && export TEST_RESULTS_DESCRIPTION="$UPLOAD_NAME"
# Resolve TEST_RESULTS_IDENTIFIER based on --identifier flag.
case "$IDENTIFIER_SOURCE" in
    upload-id)   [[ -n "$UPLOAD_ID" ]]   && export TEST_RESULTS_IDENTIFIER="$UPLOAD_ID" ;;
    upload-name) [[ -n "$UPLOAD_NAME" ]] && export TEST_RESULTS_IDENTIFIER="$UPLOAD_NAME" ;;
    *)           export TEST_RESULTS_IDENTIFIER="$IDENTIFIER_SOURCE" ;;
esac

for disk in "${DISKS[@]}"; do
    run_tests_on_disk "$disk"
done

unset TEST_RESULTS_DESCRIPTION TEST_RESULTS_IDENTIFIER

# === Upload Results if Requested ===
upload_pts_results

# === Collect Results to ./benchmark-results/ ===
collect_results

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

# === Result Files ===
list_result_files

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
