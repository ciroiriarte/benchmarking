#!/bin/bash

# Script Name: benchmark-network-pts.sh
#
# A script to benchmark network performance using the Phoronix Test Suite (PTS).
#
# Description: Runs a comprehensive set of network benchmarks in two modes:
#
#              Standalone (always run — no second machine required):
#                pts/network-loopback - TCP stack throughput via loopback interface.
#                pts/sockperf         - Socket API latency and throughput; starts
#                                       its own server locally.
#
#              Peer (run when --server is provided):
#                pts/iperf   - TCP/UDP bulk throughput with single and multi-stream.
#                pts/netperf - TCP/UDP throughput and request-response latency.
#
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
#   ./benchmark-network-pts.sh [OPTIONS]
#
# OPTIONS:
#   -s, --server <address>       IP or hostname of the peer for iperf3/netperf tests.
#                                If omitted, only standalone tests are run.
#   -u, --upload                 Upload results to OpenBenchmarking.org.
#   -i, --result-id <id>         Test identifier (e.g. 'dc1-vm1-to-vm2').
#   -n, --result-name <name>     Display name (e.g. 'VM1 to VM2 - 10GbE vSwitch').
#   -h, --help                   Display this help message and exit.
#
# NOTES:
#   Before running peer tests, start the server daemons on the remote host:
#
#     iperf3 server:   iperf3 -s -D
#     netperf server:  netserver
#
#   pts/network-loopback uses nc (netcat). On RHEL/Rocky Linux the default nc
#   is ncat (from nmap), whose -d flag semantics differ from OpenBSD netcat.
#   If this test fails on those systems, install OpenBSD netcat manually or
#   disregard the loopback result; the remaining tests are unaffected.
#
# EXAMPLES:
#   # Run standalone loopback and socket tests only.
#   ./benchmark-network-pts.sh
#
#   # Run the full suite including peer-to-peer tests.
#   ./benchmark-network-pts.sh --server 192.168.100.10 \
#     --result-id "dc1-vm1-to-vm2" \
#     --result-name "VM1 to VM2 - Ceph cluster network"
#
#   # Run the full suite and upload results.
#   ./benchmark-network-pts.sh --server 192.168.100.10 --upload \
#     --result-id "dc1-vm1-to-vm2" \
#     --result-name "VM1 to VM2 - 10GbE vSwitch"
#
# DEPENDENCIES:
#   - gcc, make, autoconf, automake, libtool (to build sockperf, iperf3, netperf)
#   - nc / netcat (for pts/network-loopback)
#   - phoronix-test-suite (installed automatically if missing)
#

set -e
set -o pipefail

# === Configuration ===
# Standalone tests run on a single host with no remote peer required.
STANDALONE_TESTS=("pts/network-loopback" "pts/sockperf")
# Peer tests require a server running on the host specified via --server.
PEER_TESTS=("pts/iperf" "pts/netperf")
# === End Configuration ===

# === Helper Functions ===

# Function to display help message
usage() {
    # Skip the shebang line by matching only lines starting with '# ' or bare '#'
    grep '^#[^!]' "$0" | cut -c3-
    exit 0
}

# Function to install Phoronix Test Suite and build dependencies
install_packages() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "$ID" in
            rocky|rhel|centos)
                echo "Detected Rocky Linux or RHEL-based system"
                sudo dnf install -y epel-release
                sudo dnf install -y phoronix-test-suite gcc gcc-c++ make \
                    autoconf automake libtool nmap-ncat
                ;;
            ubuntu|debian)
                echo "Detected Ubuntu or Debian-based system"
                sudo apt-get update
                sudo apt-get install -y phoronix-test-suite build-essential \
                    autoconf automake libtool netcat-openbsd || {
                    echo "Phoronix Test Suite not found in repo, attempting fallback install..."
                    wget -O /tmp/phoronix.deb https://phoronix-test-suite.com/releases/repo/pts.debian/files/phoronix-test-suite_10.8.4_all.deb
                    sudo dpkg -i /tmp/phoronix.deb
                    sudo apt-get install -f -y
                    sudo apt-get install -y build-essential autoconf automake libtool netcat-openbsd
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
    case "$VERSION_ID" in
        *Tumbleweed*)
            echo "Adding benchmark repo for Tumbleweed..."
            repo_url="https://download.opensuse.org/repositories/benchmark/openSUSE_Tumbleweed"
            ;;
        *Slowroll*)
            echo "Adding benchmark repo for Slowroll..."
            repo_url="https://download.opensuse.org/repositories/benchmark/openSUSE_Slowroll"
            ;;
        "15.6")
            echo "Adding benchmark repo for Leap 15.6..."
            repo_url="https://download.opensuse.org/repositories/benchmark/15.6/"
            gcc_extra="gcc12 gcc12-c++"
            ;;
        *)
            echo "Unsupported openSUSE version: $VERSION_ID"
            exit 1
            ;;
    esac
    sudo zypper ar -f -p 90 "$repo_url" benchmark
    sudo zypper --gpg-auto-import-keys refresh
    sudo zypper install -y phoronix-test-suite gcc gcc-c++ ${gcc_extra} make \
        autoconf automake libtool netcat-openbsd
    if [ "$VERSION_ID" == "15.6" ]
    then
        sudo update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-12 100
        sudo update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-12 100
    fi
}

# Run a single network test configuration.
# Arguments:
#   $1 - PTS test profile (e.g. pts/iperf)
#   $2 - PRESET_OPTIONS value (semicolon-separated; empty string for no options)
#   $3 - Short result label appended to UPLOAD_ID (e.g. iperf_tcp_1stream)
run_network_test() {
    local test_profile="$1"
    local preset_opts="$2"
    local result_label="$3"
    local local_name="${UPLOAD_ID}_${result_label}"

    echo "--- Running ${test_profile} [${result_label}] ---"

    [[ -n "$preset_opts" ]] && export PRESET_OPTIONS="$preset_opts"
    export TEST_RESULTS_NAME="$local_name"

    # Use 'if' to catch failures without triggering set -e so the remaining
    # tests continue even if one configuration fails (e.g. netcat flavor mismatch).
    if phoronix-test-suite batch-run "$test_profile"; then
        RESULT_NAMES+=("$local_name")
        echo "Result saved as: $local_name"
    else
        echo "Warning: ${test_profile} [${result_label}] failed. Skipping result."
    fi

    unset PRESET_OPTIONS
    unset TEST_RESULTS_NAME
}

# === Main Script ===

# Default values
UPLOAD_RESULTS=0
SERVER_ADDRESS=""
UPLOAD_ID="benchmark-network-$(date +%Y-%m-%d-%H%M%S)"
UPLOAD_NAME="Automated network benchmark run with benchmark-network-pts.sh"

# === Argument Parsing ===
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -s|--server)
            SERVER_ADDRESS="$2"
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

# === Install packages ===
install_packages

# === Configure Phoronix Test Suite for Batch Mode ===
# RunAllTestCombinations=N: iperf has too many option permutations (protocol ×
# duration × parallel streams) to run exhaustively. Specific configurations
# that cover the key dimensions are invoked explicitly below instead.
echo "Setting up Phoronix Test Suite in batch mode..."
phoronix-test-suite batch-setup <<EOF
Y
Y
N
N
N
EOF

# === Install Tests ===
echo "--- Installing standalone tests ---"
for test_name in "${STANDALONE_TESTS[@]}"; do
    phoronix-test-suite install "$test_name"
done

if [[ -n "$SERVER_ADDRESS" ]]; then
    echo "--- Installing peer tests ---"
    for test_name in "${PEER_TESTS[@]}"; do
        phoronix-test-suite install "$test_name"
    done
fi

# === Run Tests ===
RESULT_NAMES=()

export FORCE_TIMES_TO_RUN=1
export TEST_RESULTS_DESCRIPTION="$UPLOAD_NAME"

# --- Standalone tests (no remote peer required) ---

# TCP stack throughput through the loopback interface (10 GB transfer via nc+dd).
# Characterises kernel network buffer performance independent of NIC or fabric.
run_network_test "pts/network-loopback" "" "loopback"

# Socket API latency — pure ping-pong round-trip time with no background load.
run_network_test "pts/sockperf" \
    "pts/sockperf.run-test=ping-pong" \
    "sockperf_pingpong"

# Socket API latency — round-trip time while the link is saturated.
run_network_test "pts/sockperf" \
    "pts/sockperf.run-test=under-load" \
    "sockperf_underload"

# Socket-level throughput through loopback.
run_network_test "pts/sockperf" \
    "pts/sockperf.run-test=throughput" \
    "sockperf_throughput"

# --- Peer tests (require --server) ---
if [[ -n "$SERVER_ADDRESS" ]]; then
    echo "--- Running peer-to-peer tests against ${SERVER_ADDRESS} ---"
    echo "    Ensure iperf3 -s -D and netserver are running on the remote host."

    # TCP bulk throughput — single stream baseline.
    run_network_test "pts/iperf" \
        "pts/iperf.server-address=${SERVER_ADDRESS};pts/iperf.test=TCP;pts/iperf.parallel=1;pts/iperf.duration=60" \
        "iperf_tcp_1stream"

    # TCP bulk throughput — 10 parallel streams to saturate multi-queue NICs.
    run_network_test "pts/iperf" \
        "pts/iperf.server-address=${SERVER_ADDRESS};pts/iperf.test=TCP;pts/iperf.parallel=10;pts/iperf.duration=60" \
        "iperf_tcp_10streams"

    # UDP at 1 Gbps target — measures packet loss and jitter under bounded load.
    run_network_test "pts/iperf" \
        "pts/iperf.server-address=${SERVER_ADDRESS};pts/iperf.test=UDP-1G;pts/iperf.parallel=1;pts/iperf.duration=60" \
        "iperf_udp_1g"

    # TCP throughput — client to server (same direction as iperf TCP above,
    # but measured by netperf for cross-tool validation).
    run_network_test "pts/netperf" \
        "pts/netperf.server-address=${SERVER_ADDRESS};pts/netperf.run-test=TCP_STREAM;pts/netperf.duration=60" \
        "netperf_tcp_stream"

    # TCP throughput — server to client (reverse direction).
    run_network_test "pts/netperf" \
        "pts/netperf.server-address=${SERVER_ADDRESS};pts/netperf.run-test=TCP_MAERTS;pts/netperf.duration=60" \
        "netperf_tcp_maerts"

    # TCP request-response — transactions/sec as a latency proxy.
    # Higher values indicate lower per-transaction overhead.
    run_network_test "pts/netperf" \
        "pts/netperf.server-address=${SERVER_ADDRESS};pts/netperf.run-test=TCP_RR;pts/netperf.duration=60" \
        "netperf_tcp_rr"

    # UDP request-response — same as TCP_RR but over UDP.
    run_network_test "pts/netperf" \
        "pts/netperf.server-address=${SERVER_ADDRESS};pts/netperf.run-test=UDP_RR;pts/netperf.duration=60" \
        "netperf_udp_rr"
else
    echo "--- No --server provided; skipping peer-to-peer tests ---"
fi

unset FORCE_TIMES_TO_RUN
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

echo -e "\n=== Network benchmark complete ==="
