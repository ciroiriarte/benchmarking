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
# Version: 1.0
#
# Changelog:
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
for test_name in "${REQUIRED_TESTS[@]}"; do
    echo "Installing test: $test_name"
    phoronix-test-suite install "$test_name"
done

# === Run Tests ===
RESULT_NAMES=()

# Run each test once. Because RunAllTestCombinations=Y, a single batch-run
# exercises all sub-options (e.g. Copy/Scale/Add/Triad for pts/stream) and
# saves them together as one result set.
export FORCE_TIMES_TO_RUN=1
export TEST_RESULTS_DESCRIPTION="$UPLOAD_NAME"

for test_name in "${REQUIRED_TESTS[@]}"; do
    echo -e "\n=== Running memory benchmark: $test_name ==="

    # Name each result as <result-id>_<short-test-name> (strip leading 'pts/').
    local_name="${UPLOAD_ID}_${test_name##*/}"
    export TEST_RESULTS_NAME="$local_name"

    phoronix-test-suite batch-run "$test_name"

    RESULT_NAMES+=("$local_name")
    echo "Result saved as: $local_name"
done

unset TEST_RESULTS_NAME
unset TEST_RESULTS_DESCRIPTION
unset FORCE_TIMES_TO_RUN

# === Upload Results if Requested ===
if [[ "$UPLOAD_RESULTS" -eq 1 ]]; then
    echo "--- Uploading results to OpenBenchmarking.org ---"
    for result in "${RESULT_NAMES[@]}"; do
        echo "Uploading: $result"
        phoronix-test-suite upload-result "$result"
    done
    echo "All uploads complete."
fi

echo -e "\n=== Memory benchmark complete ==="
