#!/bin/bash

# Script Name: benchmark-cpu-pts.sh
#
# A script to quickly benchmark CPU performance using the Phoronix Test Suite (PTS).
#
# Description: This script is designed to be a simple, easy-to-use tool for running a
# 		standardized CPU benchmark. It automatically installs PTS on supported systems
# 		(Ubuntu, Rocky Linux, openSUSE) if it is not present.
#
# 		It autodetects the system's CPU topology (sockets, cores, threads) and scales
# 		the test accordingly. It also provides an option to manually specify the number
# 		of threads to use.
#
# Author: Ciro Iriarte <ciro.iriarte@millicom.com>
# Version: 1.6
#
# Changelog:
#   - 2026-02-19: v1.6 - Add one unmeasured warmup run per test before timed runs to
#                        bring CPU caches and branch predictor to steady state.
#   - 2026-02-19: v1.5 - Expand default test suite to cover integer, floating point,
#                        cryptographic, compression, and branchy integer workloads.
#                        Add -T/--tests option to override the test list at runtime.
#   - 2026-02-19: v1.4 - Add capture_system_snapshot() to save kernel, OS, CPU topology,
#                        frequency scaling state, memory, and hardware info to a file
#                        named after the result identifier before each run.
#   - 2026-02-19: v1.3 - Add pre-run system checks: CPU governor (with optional
#                        remediation), thermal state, system load, and VM steal time.
#   - 2026-02-19: v1.2 - Replace hardcoded FORCE_TIMES_TO_RUN=1 with DEFAULT_RUNS=3
#                        and expose -r/--runs option for statistical validity.
#   - 2026-02-17: v1.1 - Fix --threads/--upload argument parsing (bad shift counts).
#                      - Replace PTS_CONCURRENT_TEST_RUNS (wrong variable) with
#                        PRESET_OPTIONS to pass thread count to the test profile.
#                      - Remove invalid -s flag from phoronix-test-suite batch-run.
#                      - Remove duplicate UPLOAD_RESULTS=0 declaration.
#                      - Fix export UPLOAD_RESULTS="TRUE" clobbering bash variable;
#                        use explicit upload-result call instead.
#                      - Fix usage() printing shebang line.
#   - 2025-09-17: v0.1 - First draft.
#
#
# Usage:
#   ./quick-benchmark-cpu.sh [OPTIONS]
#
# OPTIONS:
#   -t, --threads <N>            Manually specify the number of threads to use (default: all available).
#   -r, --runs <N>               Number of timed runs per test (default: 3). More runs improve statistical confidence.
#   -T, --tests <t1,t2,...>      Comma-separated list of PTS test profiles to run.
#                                Overrides the built-in default test suite.
#                                (default: build-linux-kernel,compress-7zip,c-ray,openssl,stockfish)
#   -u, --upload                 Upload the benchmark results to OpenBenchmarking.org.
#   -i, --result-id <identifier> Set the 'Test Identifier' for the upload (e.g., 'XCloud-cpuN-20250917')."
#   -n, --result-name <name>     Set the 'Saved Test Name' for the upload (e.g., 'CPU type N on X Cloud provider')."
#   -h, --help                   Display this help message and exit.
#
# EXAMPLES:
#   # Run the full default test suite using all available CPU threads.
#   ./benchmark-cpu-pts.sh
#
#   # Run only two specific tests.
#   ./benchmark-cpu-pts.sh --tests pts/compress-7zip,pts/openssl
#
#   # Run a benchmark using only 4 threads.
#   ./benchmark-cpu-pts.sh -t 4
#
#   # Run a benchmark and upload the results with a custom name and description.
#   ./benchmark-cpu-pts.sh --upload --result-id "XCloud-cpuN-20250917" --result-name "CPU type N on X Cloud provider"
#
# DEPENDENCIES:
#   - lscpu (from util-linux)
#   - wget or curl (for PTS installation)
#

set -e
set -o pipefail

# === Configuration ===
# Default set of PTS CPU test profiles.  Each profile targets a distinct workload
# class so that results characterise the CPU across multiple stress patterns.
#   pts/build-linux-kernel  integer, multi-threaded compilation
#   pts/compress-7zip       integer, multi-threaded LZMA compression
#   pts/c-ray               floating point, ray tracing
#   pts/openssl             cryptographic operations (AES, RSA, SHA)
#   pts/stockfish           branchy integer, chess-engine search
REQUIRED_TESTS=(
    "pts/build-linux-kernel"
    "pts/compress-7zip"
    "pts/c-ray"
    "pts/openssl"
    "pts/stockfish"
)
# Minimum number of timed runs required for statistical confidence.
# A single run cannot reveal variance; 3 runs provide a baseline mean ± range.
DEFAULT_RUNS=3
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

# Function to install Phoronix Test Suite on supported distributions
install_packages() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "$ID" in
            rocky|rhel|centos)
                echo "Detected Rocky Linux or RHEL-based system"
                sudo dnf install -y epel-release
                sudo dnf install -y phoronix-test-suite
		sudo dnf install -y xfsprogs util-linux gcc gcc-c++ make autoconf bison flex openssl-devel mesa-demos
                ;;
            ubuntu|debian)
                echo "Detected Ubuntu or Debian-based system"
                sudo apt-get update
                # util-linux provides wipefs
                sudo apt-get install -y phoronix-test-suite xfsprogs util-linux build-essential autoconf bison flex libssl-dev mesa-utils || {
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
    sudo zypper install -y phoronix-test-suite
    sudo zypper install -y xfsprogs util-linux gcc gcc-c++ ${gcc_extra} make autoconf bison flex libopenssl-devel Mesa-demo-x libelf-devel
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
    # /proc/stat cpu line fields: user nice system idle iowait irq softirq steal ...
    # steal is field 9 (field 1 is the 'cpu' label).
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

# Capture system metadata to a file tied to the result identifier.
# Provides an auditable environment record independent of PTS's own metadata,
# covering kernel, OS, CPU topology, frequency scaling state, memory, and hardware info.
capture_system_snapshot() {
    local snapshot_file="${UPLOAD_ID}-system-snapshot.txt"
    {
        echo "=== Benchmark Configuration ==="
        echo "Date:          $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
        echo "Result ID:     $UPLOAD_ID"
        echo "Result Name:   $UPLOAD_NAME"
        echo "Tests:         ${REQUIRED_TESTS[*]}"
        echo "Threads:       $THREADS_TO_USE"
        echo "Runs per test: $TIMES_TO_RUN"
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
        echo "=== Memory ==="
        free -h
        echo ""
        echo "=== Load Average ==="
        cat /proc/loadavg
        echo ""
        if command -v dmidecode &>/dev/null && [[ "$HAS_PRIVILEGE" -eq 1 ]]; then
            echo "=== Processor (dmidecode) ==="
            ${SUDO_CMD} dmidecode -t processor
        fi
    } > "$snapshot_file"
    echo "System snapshot saved to: $(realpath "$snapshot_file")"
}

# === Main Script ===

# Default values
UPLOAD_RESULTS=0
MANUAL_THREADS=0
TIMES_TO_RUN="$DEFAULT_RUNS"
UPLOAD_ID="quick-benchmark-cpu-$(date +%Y-%m-%d-%H%M%S)"
UPLOAD_NAME="Automated CPU benchmark run with quick-benchmark-cpu.sh"

# === Argument Parsing ===
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -t|--threads)
          MANUAL_THREADS="$2"
          shift
          ;;
        -T|--tests)
          IFS=',' read -ra REQUIRED_TESTS <<< "$2"
          shift
          ;;
        -r|--runs)
          TIMES_TO_RUN="$2"
          shift
          ;;
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
	  usage;
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

# === Check for PTS and install if it's missing ===
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
echo "------------------------------"

# === Configure Phoronix Test Suite for Batch Mode ===
echo "Setting up Phoronix Test Suite in batch mode..."
phoronix-test-suite batch-setup <<EOF
Y
Y
N
N
N
EOF

# === Install Required Phoronix Tests ===
for test_name in "${REQUIRED_TESTS[@]}"; do
    echo "Installing test: $test_name"
    phoronix-test-suite install "$test_name"
done

# Autodetect CPU resources
echo "--- Detecting CPU Resources ---"
CPU_INFO=$(lscpu)
SOCKETS=$(echo "$CPU_INFO" | grep -i "^socket(s):" | awk '{print $2}')
CORES_PER_SOCKET=$(echo "$CPU_INFO" | grep -i "^core(s) per socket:" | awk '{print $4}')
THREADS_PER_CORE=$(echo "$CPU_INFO" | grep -i "^thread(s) per core:" | awk '{print $4}')
TOTAL_THREADS=$((SOCKETS * CORES_PER_SOCKET * THREADS_PER_CORE))

if [[ "$TOTAL_THREADS" -le 0 ]]; then
    echo "Error: Could not detect CPU topology from lscpu."
    echo "       Detected: SOCKETS='$SOCKETS', CORES_PER_SOCKET='$CORES_PER_SOCKET', THREADS_PER_CORE='$THREADS_PER_CORE'"
    echo "       Use -t <N> to specify the thread count manually."
    exit 1
fi

echo "Sockets:          $SOCKETS"
echo "Cores per socket: $CORES_PER_SOCKET"
echo "Threads per core: $THREADS_PER_CORE"
echo "Total threads:    $TOTAL_THREADS"
echo "--------------------------------"

# Determine the number of threads to use
if [[ "$MANUAL_THREADS" -gt 0 ]]; then
  if [[ "$MANUAL_THREADS" -le "$TOTAL_THREADS" ]]; then
    THREADS_TO_USE="$MANUAL_THREADS"
    echo "Using manually specified thread count: $THREADS_TO_USE"
  else
    echo "Error: The specified number of threads ($MANUAL_THREADS) is greater than the available threads ($TOTAL_THREADS)."
    exit 1
  fi
else
  THREADS_TO_USE="$TOTAL_THREADS"
  echo "Using all available threads: $THREADS_TO_USE"
fi

# Set up PTS environment variables for automated runs.
export FORCE_TIMES_TO_RUN="$TIMES_TO_RUN"
echo "Runs per test: $FORCE_TIMES_TO_RUN"
# PRESET_OPTIONS pre-answers the test profile's thread-count option, which
# controls the -j N passed to make inside build-linux-kernel.
# PTS_CONCURRENT_TEST_RUNS would only run N parallel test *instances*, which
# is not the same thing and is not what we want here.
export PRESET_OPTIONS="pts/build-linux-kernel.threads-to-use=${THREADS_TO_USE}"

# Always name the result so it can be referenced for upload later.
export TEST_RESULTS_NAME="$UPLOAD_ID"
export TEST_RESULTS_DESCRIPTION="$UPLOAD_NAME"

if [[ "$UPLOAD_RESULTS" -eq 1 ]]; then
  echo "Results will be uploaded with the following details:"
  echo "  Name: $TEST_RESULTS_NAME"
  echo "  Description: $TEST_RESULTS_DESCRIPTION"
fi

# === System Snapshot ===
capture_system_snapshot

# Warmup result identifier: prefixed so it is clearly distinguishable from real
# results and can be safely removed after each per-test warmup run.
WARMUP_RESULT_ID="warmup-${UPLOAD_ID}"

# === Run Tests ===
for TEST_NAME in "${REQUIRED_TESTS[@]}"; do
    echo -e "\n=== Starting CPU Benchmark ==="
    echo "Test profile: $TEST_NAME"

    # Warmup run: execute the test once without recording results to bring CPU
    # caches and branch predictor to steady state before the timed runs begin.
    echo "--- Warmup run (result discarded) ---"
    FORCE_TIMES_TO_RUN=1 TEST_RESULTS_NAME="$WARMUP_RESULT_ID" \
        phoronix-test-suite batch-run "$TEST_NAME"
    rm -rf "${HOME}/.phoronix-test-suite/test-results/${WARMUP_RESULT_ID}"

    echo "--- Timed runs ($TIMES_TO_RUN) ---"
    phoronix-test-suite batch-run "$TEST_NAME"
done

# === Upload Results if Requested ===
if [[ "$UPLOAD_RESULTS" -eq 1 ]]; then
  echo "--- Uploading results to OpenBenchmarking.org ---"
  phoronix-test-suite upload-result "$UPLOAD_ID"
fi

echo -e "\n=== Benchmark Complete ==="
