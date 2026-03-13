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
# Author: Ciro Iriarte <ciro.iriarte@gmail.com>
# Version: 2.7.0
#
# Changelog:
#   - 2026-03-12: v2.7.0 - Export TEST_RESULTS_IDENTIFIER=$UPLOAD_NAME so PTS
#                           comparison columns show --result-name instead of
#                           auto-generated hardware/date labels.
#   - 2026-03-12: v2.6 - Switch RunAllTestCombinations from N to Y to work
#                        around PTS v10.8.4 PHP Fatal error (array_keys() on
#                        null $option_names) that crashes tests with multiple
#                        options (build-linux-kernel, c-ray, openssl).  Remove
#                        -t/--threads option and PRESET_OPTIONS since PTS
#                        ignores them when RunAllTestCombinations=Y; all thread
#                        counts are now exercised automatically.
#   - 2026-03-12: v2.5 - Use batch-install instead of install for PTS test
#                        installation to prevent interactive dependency prompts
#                        that hang under nohup (stdin=/dev/null).
#   - 2026-03-12: v2.4 - Extract pre-run checks (detect_privileges, confirm_change,
#                        check_cpu_governor, check_thermal, check_system_load,
#                        check_steal_time), collect_results, upload, result file
#                        listing, and invocation context into shared libraries
#                        (common-checks.sh, install-pts.sh configure_pts_batch).
#   - 2026-03-12: v2.3 - Fix batch-setup: expand from 5 to 7 answers; add
#                        missing PromptSaveName=N (caused batch-run to hang
#                        in non-interactive mode) and RunAllTestCombinations=N;
#                        fix OpenBrowser=Y→N for headless servers.
#                        Fix upload-result: pipe "n" to suppress interactive
#                        "attach system logs?" prompt that loops infinitely
#                        without a TTY; add PTS result name resolution with
#                        underscore-stripping (PTS strips underscores from
#                        directory names).
#                        Fix collect_results(): add /var/lib/ fallback for
#                        system-wide PTS installs; add underscore-stripped
#                        name resolution matching the memory/storage scripts.
#   - 2026-03-11: v2.2 - Extract PTS installation into shared install-pts.sh
#                        library.  Fixes: openSUSE repo idempotency, zypper
#                        exit code 106 handling, python_pkg detection for
#                        Leap 16+/Tumbleweed, VERSION_ID-based gcc12 guard.
#                        Add result file listing at end of run.
#   - 2026-03-09: v2.1 - Add unzip to Ubuntu/Debian and openSUSE deps; PTS
#                        needs it to extract test archives (.zip). Rocky Linux
#                        ships unzip in the base install so no change needed
#                        there.
#   - 2026-03-09: v2.0 - Move DEBIAN_FRONTEND=noninteractive and
#                        NEEDRESTART_MODE=a exports to top-level scope so
#                        they also cover PTS's own internal apt-get calls
#                        during phoronix-test-suite install (which triggered
#                        the needrestart hang reported in issue #3).
#   - 2026-03-09: v1.9 - Fix Ubuntu/Debian PTS install: pre-install php-cli
#                        and php-xml before the PTS deb so dpkg never fails on
#                        missing PHP deps; add '|| true' to dpkg -i so set -e
#                        does not abort before apt-get install -f -y runs.
#                        Add php to install gate check so a broken prior install
#                        (dpkg iU state) triggers re-installation.
#   - 2026-02-26: v1.8 - Add collect_results(): copy system snapshot and all PTS
#                        result directories to benchmark-results/${RUN_ID}/ relative
#                        to the invocation CWD; transfer ownership to the invoking
#                        user (SUDO_USER) so results are readable without sudo.
#                        Add RUN_ID, SNAPSHOT_FILE, INVOKING_USER/GROUP variables.
#   - 2026-02-19: v1.7 - Replace set -e abort-on-failure in the run loop with per-test
#                        error handling so that a single test failure does not orphan
#                        results from completed tests. Failed tests are reported in a
#                        summary and the script exits non-zero when any test fails.
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
#   # Run the full default test suite with all sub-option permutations.
#   ./benchmark-cpu-pts.sh
#
#   # Run only two specific tests.
#   ./benchmark-cpu-pts.sh --tests pts/compress-7zip,pts/openssl
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

# Resolve the directory containing this script so co-located libraries can be
# sourced regardless of the caller's working directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/install-pts.sh"
. "${SCRIPT_DIR}/common-checks.sh"

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
# === End Configuration ===
# Pre-run check thresholds use defaults from common-checks.sh:
#   RECOMMENDED_GOVERNOR=performance, CPU_TEMP_WARN_THRESHOLD_MC=80000,
#   LOAD_WARN_MULTIPLIER=1, STEAL_TIME_WARN_THRESHOLD=5

# === Helper Functions ===

# Function to display help message
usage() {
  # Skip the shebang line by matching only lines starting with '# ' or bare '#'
  grep '^#[^!]' "$0" | cut -c3-
}

# === Pre-run checks: detect_privileges, confirm_change, check_cpu_governor,
# check_thermal, check_system_load, check_steal_time are provided by
# common-checks.sh (sourced above).

# collect_results is provided by common-checks.sh (sourced above).

capture_system_snapshot() {
    local snapshot_file="$SNAPSHOT_FILE"
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
TIMES_TO_RUN="$DEFAULT_RUNS"
UPLOAD_ID="quick-benchmark-cpu-$(date +%Y-%m-%d-%H%M%S)"
UPLOAD_NAME="Automated CPU benchmark run with quick-benchmark-cpu.sh"

# === Argument Parsing ===
while [[ "$#" -gt 0 ]]; do
    case $1 in
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

# Capture invocation context after arg parsing so --result-id is reflected in
# RUN_ID before SNAPSHOT_FILE and the output directory are derived from it.
setup_invocation_context

# === Install PTS and dependencies ===
EXTRA_PKGS_APT=(xfsprogs util-linux autoconf bison flex libssl-dev mesa-utils)
# perl-core provides the full set of Perl core modules (FindBin, lib, IPC::Cmd,
# File::Compare, File::Copy, etc.) needed to build openssl from source (PTS
# test pts/openssl).  RHEL 9 minimal installs split these out of perl-core.
EXTRA_PKGS_DNF=(xfsprogs util-linux autoconf bison flex openssl-devel mesa-demos perl-core)
# Full perl interpreter is needed on openSUSE Leap 16+ to build openssl from
# source; the minimal perl shipped in the base image omits FindBin.pm et al.
EXTRA_PKGS_ZYPPER=(xfsprogs util-linux autoconf bison flex libopenssl-devel Mesa-demo-x libelf-devel perl)
ensure_pts_installed

# === Pre-run System Checks ===
echo "--- Pre-run System Checks ---"
detect_privileges
check_cpu_governor
check_thermal
check_system_load
check_steal_time
echo "------------------------------"

# === Configure Phoronix Test Suite for Batch Mode ===
# RunAllTestCombinations=Y: exercise every sub-option permutation.  PTS v10.8.4
# crashes (PHP Fatal: array_keys() on null $option_names) when set to N for any
# test profile with multiple options (build-linux-kernel, c-ray, openssl).
# With Y, PTS ignores PRESET_OPTIONS and tests all thread counts, algorithms,
# and resolutions — providing a more comprehensive CPU characterisation.
configure_pts_batch "Y"

# === Install Required Phoronix Tests ===
for test_name in "${REQUIRED_TESTS[@]}"; do
    echo "Installing test: $test_name"
    phoronix-test-suite batch-install "$test_name"
done

# Autodetect CPU resources (for snapshot and informational output).
echo "--- Detecting CPU Resources ---"
CPU_INFO=$(lscpu)
SOCKETS=$(echo "$CPU_INFO" | grep -i "^socket(s):" | awk '{print $2}')
CORES_PER_SOCKET=$(echo "$CPU_INFO" | grep -i "^core(s) per socket:" | awk '{print $4}')
THREADS_PER_CORE=$(echo "$CPU_INFO" | grep -i "^thread(s) per core:" | awk '{print $4}')
TOTAL_THREADS=$((SOCKETS * CORES_PER_SOCKET * THREADS_PER_CORE))
THREADS_TO_USE="$TOTAL_THREADS"

echo "Sockets:          $SOCKETS"
echo "Cores per socket: $CORES_PER_SOCKET"
echo "Threads per core: $THREADS_PER_CORE"
echo "Total threads:    $TOTAL_THREADS"
echo "--------------------------------"

# Set up PTS environment variables for automated runs.
export FORCE_TIMES_TO_RUN="$TIMES_TO_RUN"
echo "Runs per test: $FORCE_TIMES_TO_RUN"

# Always name the result so it can be referenced for upload later.
export TEST_RESULTS_NAME="$UPLOAD_ID"
export TEST_RESULTS_DESCRIPTION="$UPLOAD_NAME"
export TEST_RESULTS_IDENTIFIER="$UPLOAD_NAME"

if [[ "$UPLOAD_RESULTS" -eq 1 ]]; then
  echo "Results will be uploaded with the following details:"
  echo "  Name: $TEST_RESULTS_NAME"
  echo "  Identifier: $TEST_RESULTS_IDENTIFIER"
  echo "  Description: $TEST_RESULTS_DESCRIPTION"
fi

# === System Snapshot ===
capture_system_snapshot

# Warmup result identifier: prefixed so it is clearly distinguishable from real
# results and can be safely removed after each per-test warmup run.
WARMUP_RESULT_ID="warmup-${UPLOAD_ID}"

# Accumulates names of tests that failed so the run loop can continue and
# completed results are not orphaned.
FAILED_TESTS=()
# All CPU tests share a single PTS result directory named after UPLOAD_ID.
RESULT_NAMES=()

# === Run Tests ===
for TEST_NAME in "${REQUIRED_TESTS[@]}"; do
    echo -e "\n=== Starting CPU Benchmark ==="
    echo "Test profile: $TEST_NAME"

    # Warmup run: execute the test once without recording results to bring CPU
    # caches and branch predictor to steady state before the timed runs begin.
    # On failure, skip the timed run for this test and move on to the next one.
    echo "--- Warmup run (result discarded) ---"
    if ! FORCE_TIMES_TO_RUN=1 TEST_RESULTS_NAME="$WARMUP_RESULT_ID" \
            phoronix-test-suite batch-run "$TEST_NAME"; then
        echo "WARNING: Warmup run failed for $TEST_NAME; skipping timed run."
        FAILED_TESTS+=("$TEST_NAME")
        rm -rf "${HOME}/.phoronix-test-suite/test-results/${WARMUP_RESULT_ID}"
        continue
    fi
    rm -rf "${HOME}/.phoronix-test-suite/test-results/${WARMUP_RESULT_ID}"

    echo "--- Timed runs ($TIMES_TO_RUN) ---"
    if ! phoronix-test-suite batch-run "$TEST_NAME"; then
        echo "WARNING: Timed run failed for $TEST_NAME."
        FAILED_TESTS+=("$TEST_NAME")
    else
        # All tests share the same result directory; record it once.
        if [[ ${#RESULT_NAMES[@]} -eq 0 ]]; then
            RESULT_NAMES+=("$UPLOAD_ID")
        fi
    fi
done

# === Collect Results to ./benchmark-results/ ===
collect_results

# === Upload Results if Requested ===
# Runs regardless of individual test failures to preserve results from
# tests that completed successfully.
upload_pts_results

# === Results Summary ===
list_result_files

echo -e "\n=== Benchmark Complete ==="
if [[ "${#FAILED_TESTS[@]}" -gt 0 ]]; then
    echo "WARNING: ${#FAILED_TESTS[@]} test(s) failed:"
    for t in "${FAILED_TESTS[@]}"; do
        echo "  - $t"
    done
    exit 1
fi
