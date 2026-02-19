#!/bin/bash

# Script Name: benchmark-memory-pts.sh
#
# A script to benchmark memory subsystem performance using the Phoronix Test Suite (PTS).
#
# Description: Runs a comprehensive set of memory benchmarks covering sustained DRAM
#              bandwidth, integer vs. floating-point memory paths, cache hierarchy
#              bandwidth, and combined bandwidth + latency profiling.
#
#              All sub-option permutations (operation type, benchmark mode, access
#              pattern) are exercised automatically via PTS batch mode.
#              PTS is installed automatically on supported systems if not present.
#
# Author: Ciro Iriarte <ciro.iriarte@millicom.com>
# Version: 1.2
#
# Changelog:
#   - 2026-02-19: v1.2 - Remove FORCE_TIMES_TO_RUN=1. PTS DynamicRunCount is
#                        enabled by default and reruns each test until the
#                        coefficient of variation falls below ~3.5%, providing
#                        statistical validity and rendering a fixed run count
#                        unnecessary.
#   - 2026-02-19: v1.1 - Add pre-run system checks (governor, thermals, load,
#                        steal time, Transparent Huge Pages) mirroring the CPU
#                        benchmark script. Add capture_system_snapshot() recording
#                        kernel, OS, CPU topology, frequency scaling, NUMA topology,
#                        THP state, DIMM info (dmidecode -t 17), memory, and load
#                        average. Add per-test install and run failure handling so
#                        a single failure does not abort the script or orphan results;
#                        failed tests are reported in a summary and the script exits
#                        non-zero if any failed.
#   - 2026-02-17: v1.0 - Initial release.
#
#
# Usage:
#   ./benchmark-memory-pts.sh [OPTIONS]
#
# OPTIONS:
#   -u, --upload                 Upload results to OpenBenchmarking.org.
#   -i, --result-id <id>         Test identifier for the result (e.g. 'dc1-node3-ddr5').
#   -n, --result-name <name>     Display name for the result (e.g. 'DC1 Node3 - DDR5 6400').
#   -h, --help                   Display this help message and exit.
#
# EXAMPLES:
#   # Run all memory benchmarks.
#   ./benchmark-memory-pts.sh
#
#   # Run and upload results with a custom identifier.
#   ./benchmark-memory-pts.sh --upload \
#     --result-id "dc1-node3-ddr5" \
#     --result-name "DC1 Node3 - DDR5 6400 MT/s"
#
# TESTS:
#   pts/stream       - Sustained DRAM bandwidth: Copy, Scale, Add, Triad operations.
#   pts/ramspeed     - Bandwidth for Integer and Floating Point modes:
#                      Copy, Scale, Add, Triad, Average.
#   pts/tinymembench - Bandwidth and access latency across the full cache hierarchy
#                      (L1, L2, L3, DRAM). Only standard PTS memory test that
#                      reports latency alongside bandwidth.
#   pts/cachebench   - Cache-level bandwidth: Read, Write, Read/Modify/Write.
#
# DEPENDENCIES:
#   - gcc, make (build tools for compiling test binaries)
#   - phoronix-test-suite (installed automatically if missing)
#

set -e
set -o pipefail

# === Configuration ===
# Tests to run. All sub-option permutations (operation type, benchmark mode,
# access pattern) are exercised automatically because batch-setup is configured
# with RunAllTestCombinations=Y.
REQUIRED_TESTS=("pts/stream" "pts/ramspeed" "pts/tinymembench" "pts/cachebench")
# Recommended CPU frequency governor for benchmarking; minimises frequency-scaling variance.
RECOMMENDED_GOVERNOR="performance"
# CPU temperature threshold above which results may be affected by thermal throttling (millidegrees Celsius).
CPU_TEMP_WARN_THRESHOLD_MC=80000
# Warn if the 1-minute load average exceeds (available CPU count × this multiplier).
LOAD_WARN_MULTIPLIER=1
# VM CPU steal time percentage above which hypervisor contention may distort results.
STEAL_TIME_WARN_THRESHOLD=5
# === End Configuration ===

# === Helper Functions ===

# Function to display help message
usage() {
    # Skip the shebang line by matching only lines starting with '# ' or bare '#'
    grep '^#[^!]' "$0" | cut -c3-
}

# Function to install Phoronix Test Suite and build dependencies
install_packages() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "$ID" in
            rocky|rhel|centos)
                echo "Detected Rocky Linux or RHEL-based system"
                sudo dnf install -y epel-release
                sudo dnf install -y phoronix-test-suite gcc gcc-c++ make
                ;;
            ubuntu|debian)
                echo "Detected Ubuntu or Debian-based system"
                sudo apt-get update
                sudo apt-get install -y phoronix-test-suite build-essential || {
                    echo "Phoronix Test Suite not found in repo, attempting fallback install..."
                    wget -O /tmp/phoronix.deb https://phoronix-test-suite.com/releases/repo/pts.debian/files/phoronix-test-suite_10.8.4_all.deb
                    sudo dpkg -i /tmp/phoronix.deb
                    sudo apt-get install -f -y
                    sudo apt-get install -y build-essential
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

    if ! command -v phoronix-test-suite &> /dev/null; then
        echo "Installation failed. Please try installing Phoronix Test Suite manually."
        exit 1
    fi
    echo "Phoronix Test Suite installed successfully."
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
    sudo zypper install -y phoronix-test-suite gcc gcc-c++ ${gcc_extra} make
    if [[ "$ID" == "opensuse-leap" ]]; then
        sudo update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-12 100
        sudo update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-12 100
    fi
}

# === Pre-run Check Functions ===

# Detect whether the script has privileges to make system configuration changes.
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
        echo "      Pre-run checks will warn only; no system changes will be made."
    fi
}

# Prompt the user for confirmation before applying a system change.
# Automatically declines in non-interactive (piped/redirected) mode.
confirm_change() {
    local prompt="$1"
    if [[ ! -t 0 ]]; then
        echo "INFO: Non-interactive mode; skipping change."
        return 1
    fi
    local response
    read -r -p "$prompt [y/N]: " response
    [[ "$response" =~ ^[Yy]$ ]]
}

# Check the CPU frequency governor on all CPUs and offer to set it to the recommended value.
check_cpu_governor() {
    if [[ ! -d "/sys/devices/system/cpu/cpu0/cpufreq" ]]; then
        echo "INFO: cpufreq interface not available (VM or container); skipping governor check."
        return
    fi

    local suboptimal_count=0
    local gov_file gov
    for gov_file in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        gov=$(< "$gov_file")
        if [[ "$gov" != "$RECOMMENDED_GOVERNOR" ]]; then
            suboptimal_count=$(( suboptimal_count + 1 ))
        fi
    done

    if [[ "$suboptimal_count" -eq 0 ]]; then
        echo "OK: CPU governor is '$RECOMMENDED_GOVERNOR' on all CPUs."
        return
    fi

    local current_govs
    current_govs=$(sort -u /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null | tr '\n' ' ')
    echo "WARNING: $suboptimal_count CPU(s) are not using the '$RECOMMENDED_GOVERNOR' governor."
    echo "         Current governor(s): ${current_govs% }."
    echo "         Frequency scaling may introduce variance in benchmark results."

    if [[ "$HAS_PRIVILEGE" -eq 0 ]]; then
        echo "         Insufficient privileges to change governor; proceeding with current settings."
        return
    fi

    if confirm_change "Set CPU governor to '$RECOMMENDED_GOVERNOR' on all CPUs?"; then
        for gov_file in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
            echo "$RECOMMENDED_GOVERNOR" | ${SUDO_CMD} tee "$gov_file" > /dev/null
        done
        echo "OK: CPU governor set to '$RECOMMENDED_GOVERNOR'."
    else
        echo "INFO: Keeping current governor; proceeding."
    fi
}

# Warn if any thermal zone reports a temperature above the configured threshold.
check_thermal() {
    local temp_files=(/sys/class/thermal/thermal_zone*/temp)
    if [[ ! -f "${temp_files[0]}" ]]; then
        echo "INFO: Thermal sensors not available; skipping temperature check."
        return
    fi

    local hot_zones=()
    local temp_file temp
    for temp_file in "${temp_files[@]}"; do
        temp=$(< "$temp_file")
        if [[ "$temp" -ge "$CPU_TEMP_WARN_THRESHOLD_MC" ]]; then
            hot_zones+=("$(basename "$(dirname "$temp_file")"): $((temp / 1000))°C")
        fi
    done

    if [[ "${#hot_zones[@]}" -eq 0 ]]; then
        echo "OK: All thermal zones are below $((CPU_TEMP_WARN_THRESHOLD_MC / 1000))°C."
    else
        echo "WARNING: High temperatures detected; results may be affected by thermal throttling."
        local zone
        for zone in "${hot_zones[@]}"; do
            echo "         $zone"
        done
    fi
}

# Warn if the 1-minute load average exceeds the available CPU count.
check_system_load() {
    local load_1min cpu_count
    load_1min=$(cut -d' ' -f1 /proc/loadavg)
    cpu_count=$(nproc)
    if awk "BEGIN { exit !($load_1min > $cpu_count * $LOAD_WARN_MULTIPLIER) }"; then
        echo "WARNING: 1-minute load average ($load_1min) exceeds CPU count ($cpu_count)."
        echo "         Background activity may distort benchmark results."
    else
        echo "OK: System load ($load_1min) is within normal range for $cpu_count CPUs."
    fi
}

# Warn if CPU steal time (sampled over 1 second) exceeds the configured threshold.
# Steal time indicates the hypervisor is withholding CPU cycles from this VM.
# On physical machines the value is expected to be 0.
check_steal_time() {
    local s1 s2
    s1=$(grep '^cpu ' /proc/stat)
    sleep 1
    s2=$(grep '^cpu ' /proc/stat)
    local steal_pct
    steal_pct=$(awk -v s1="$s1" -v s2="$s2" '
        BEGIN {
            split(s1, a); split(s2, b)
            delta_total = 0
            for (i = 2; i <= length(a); i++) delta_total += b[i] - a[i]
            delta_steal = b[9] - a[9]
            printf "%.1f", (delta_total > 0) ? (delta_steal / delta_total) * 100 : 0
        }')
    if awk "BEGIN { exit !($steal_pct >= $STEAL_TIME_WARN_THRESHOLD) }"; then
        echo "WARNING: CPU steal time is ${steal_pct}% (threshold: ${STEAL_TIME_WARN_THRESHOLD}%)."
        echo "         The hypervisor may be withholding CPU time; results may be unreliable."
    else
        echo "OK: CPU steal time is ${steal_pct}% (below ${STEAL_TIME_WARN_THRESHOLD}% threshold)."
    fi
}

# Warn if Transparent Huge Pages is set to 'always'.
# In that mode the khugepaged background scanner can promote pages mid-benchmark,
# adding noise to memory bandwidth and latency measurements.
check_thp() {
    local thp_file="/sys/kernel/mm/transparent_hugepage/enabled"
    if [[ ! -f "$thp_file" ]]; then
        echo "INFO: Transparent Huge Pages interface not available; skipping THP check."
        return
    fi
    local thp_setting
    thp_setting=$(sed 's/.*\[\([^]]*\)\].*/\1/' "$thp_file")
    if [[ "$thp_setting" == "always" ]]; then
        echo "WARNING: Transparent Huge Pages is set to 'always'."
        echo "         The khugepaged scanner may promote pages during measurement,"
        echo "         adding noise to memory bandwidth and latency results."
        echo "         Consider: echo 'never' | sudo tee $thp_file"
    else
        echo "OK: Transparent Huge Pages is set to '${thp_setting}'."
    fi
}

# Capture system and memory subsystem metadata to a file for reproducibility.
# Records kernel, OS, CPU topology, frequency scaling state, NUMA topology,
# Transparent Huge Pages state, DIMM information, memory, and load average.
capture_system_snapshot() {
    local snapshot_file="${UPLOAD_ID}-system-snapshot.txt"
    {
        echo "=== Benchmark Configuration ==="
        echo "Date:        $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
        echo "Result ID:   $UPLOAD_ID"
        echo "Result Name: $UPLOAD_NAME"
        echo "Tests:       ${REQUIRED_TESTS[*]}"
        echo ""

        echo "=== Kernel ==="
        uname -a
        echo ""

        echo "=== OS Release ==="
        cat /etc/os-release
        echo ""

        echo "=== CPU Topology ==="
        lscpu
        echo ""

        echo "=== CPU Frequency Scaling ==="
        if [[ -d "/sys/devices/system/cpu/cpu0/cpufreq" ]]; then
            echo "governor:  $(sort -u /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null | tr '\n' ' ')"
            echo "driver:    $(sort -u /sys/devices/system/cpu/cpu*/cpufreq/scaling_driver 2>/dev/null | tr '\n' ' ')"
            echo "min_freq:  $(< /sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq) kHz"
            echo "max_freq:  $(< /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq) kHz"
            echo "hw_max:    $(< /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq) kHz"
        else
            echo "cpufreq interface not available"
        fi
        echo ""

        echo "=== NUMA Topology ==="
        if command -v numactl &>/dev/null; then
            numactl --hardware
        else
            echo "numactl not available; falling back to /proc/cpuinfo"
            grep -E "^physical id|^core id|^cpu MHz" /proc/cpuinfo | head -40 || true
        fi
        echo ""

        echo "=== Transparent Huge Pages ==="
        local thp_file="/sys/kernel/mm/transparent_hugepage/enabled"
        if [[ -f "$thp_file" ]]; then
            echo "enabled: $(cat "$thp_file")"
            [[ -f "/sys/kernel/mm/transparent_hugepage/defrag" ]] && \
                echo "defrag:  $(cat /sys/kernel/mm/transparent_hugepage/defrag)"
        else
            echo "THP interface not available"
        fi
        echo ""

        echo "=== Memory ==="
        free -h
        echo ""

        echo "=== Load Average ==="
        cat /proc/loadavg
        echo ""

        if command -v dmidecode &>/dev/null && [[ "$HAS_PRIVILEGE" -eq 1 ]]; then
            echo "=== Memory Modules (dmidecode) ==="
            ${SUDO_CMD} dmidecode -t 17
        fi
    } > "$snapshot_file"
    echo "System snapshot saved to: $(realpath "$snapshot_file")"
}

# === Main Script ===

# Default values
UPLOAD_RESULTS=0
UPLOAD_ID="benchmark-memory-$(date +%Y-%m-%d-%H%M%S)"
UPLOAD_NAME="Automated memory benchmark run with benchmark-memory-pts.sh"

# === Argument Parsing ===
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -u|--upload)
            UPLOAD_RESULTS=1
            ;;
        -n|--result-name)
            UPLOAD_NAME="$2"
            shift
            ;;
        -i|--result-id)
            UPLOAD_ID="$2"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown parameter passed: $1"
            usage
            exit 1
            ;;
    esac
    shift
done

# === Install packages if not already present ===
if ! command -v phoronix-test-suite &> /dev/null; then
    install_packages
fi

# === Pre-run System Checks ===
echo "--- Pre-run System Checks ---"
detect_privileges
check_cpu_governor
check_thermal
check_system_load
check_steal_time
check_thp
echo "------------------------------"

# === Configure Phoronix Test Suite for Batch Mode ===
# RunAllTestCombinations=Y (5th prompt) ensures every sub-option permutation
# is exercised in a single batch-run call per test, without requiring
# per-test PRESET_OPTIONS overrides.
echo "Setting up Phoronix Test Suite in batch mode..."
phoronix-test-suite batch-setup <<EOF
Y
Y
N
N
Y
EOF

# === Install Required Phoronix Tests ===
FAILED_TESTS=()
INSTALLED_TESTS=()
for test_name in "${REQUIRED_TESTS[@]}"; do
    echo "Installing test: $test_name"
    if phoronix-test-suite install "$test_name"; then
        INSTALLED_TESTS+=("$test_name")
    else
        echo "WARNING: Failed to install $test_name; skipping."
        FAILED_TESTS+=("$test_name (install)")
    fi
done

# === System Snapshot ===
capture_system_snapshot

# === Run Tests ===
RESULT_NAMES=()

# PTS DynamicRunCount is enabled by default and runs each test repeatedly
# until the coefficient of variation falls below the threshold (~3.5%),
# providing both statistical validity and implicit warmup: if the first run
# is an outlier it raises variance and triggers additional runs.
export TEST_RESULTS_DESCRIPTION="$UPLOAD_NAME"

for test_name in "${INSTALLED_TESTS[@]}"; do
    echo -e "\n=== Running memory benchmark: $test_name ==="

    # Name each result as <result-id>_<short-test-name> (strip leading 'pts/').
    local_name="${UPLOAD_ID}_${test_name##*/}"
    export TEST_RESULTS_NAME="$local_name"

    if ! phoronix-test-suite batch-run "$test_name"; then
        echo "WARNING: $test_name failed."
        FAILED_TESTS+=("$test_name")
        unset TEST_RESULTS_NAME
        continue
    fi

    RESULT_NAMES+=("$local_name")
    echo "Result saved as: $local_name"
done

unset TEST_RESULTS_NAME
unset TEST_RESULTS_DESCRIPTION

# === Upload Results if Requested ===
if [[ "$UPLOAD_RESULTS" -eq 1 ]]; then
    echo "--- Uploading results to OpenBenchmarking.org ---"
    for result in "${RESULT_NAMES[@]}"; do
        echo "Uploading: $result"
        phoronix-test-suite upload-result "$result"
    done
    echo "All uploads complete."
fi

# === Results Summary ===
echo -e "\n=== Memory Benchmark Summary ==="
echo "Completed results: ${#RESULT_NAMES[@]}"
for r in "${RESULT_NAMES[@]}"; do
    echo "  [OK] $r"
done

if [[ ${#FAILED_TESTS[@]} -gt 0 ]]; then
    echo ""
    echo "Failed: ${#FAILED_TESTS[@]}"
    for f in "${FAILED_TESTS[@]}"; do
        echo "  [FAIL] $f"
    done
    echo ""
    echo "ERROR: ${#FAILED_TESTS[@]} test(s) failed. See output above for details."
    exit 1
fi

echo ""
echo "All tests completed successfully."
