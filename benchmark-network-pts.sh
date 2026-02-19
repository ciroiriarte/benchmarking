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
# Version: 1.1
#
# Changelog:
#   - 2026-02-19: v1.1 - Add pre-run system checks (CPU governor, thermals, system
#                        load, VM steal time) mirroring the other benchmark scripts.
#                        Add capture_system_snapshot() recording kernel, OS, CPU
#                        topology, frequency scaling state, TCP/IP socket settings,
#                        and per-interface NIC attributes (speed, driver, firmware,
#                        MTU, offload flags, ring buffer sizes). When --server is
#                        provided the routing interface is identified automatically
#                        via 'ip route get' and highlighted in the snapshot.
#                        Add ethtool to system package installations.
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
                sudo dnf install -y phoronix-test-suite gcc gcc-c++ make \
                    autoconf automake libtool nmap-ncat ethtool
                ;;
            ubuntu|debian)
                echo "Detected Ubuntu or Debian-based system"
                sudo apt-get update
                sudo apt-get install -y phoronix-test-suite build-essential \
                    autoconf automake libtool netcat-openbsd ethtool || {
                    echo "Phoronix Test Suite not found in repo, attempting fallback install..."
                    wget -O /tmp/phoronix.deb https://phoronix-test-suite.com/releases/repo/pts.debian/files/phoronix-test-suite_10.8.4_all.deb
                    sudo dpkg -i /tmp/phoronix.deb
                    sudo apt-get install -f -y
                    sudo apt-get install -y build-essential autoconf automake libtool netcat-openbsd ethtool
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
    sudo zypper install -y phoronix-test-suite gcc gcc-c++ ${gcc_extra} make \
        autoconf automake libtool netcat-openbsd ethtool
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

# Capture system and network metadata to a file for reproducibility.
# Records kernel, OS, CPU topology, frequency scaling state, TCP/IP socket
# settings, and per-interface NIC attributes (speed, driver, firmware, MTU,
# offload flags, ring buffer sizes). When a server address is known the routing
# interface is identified automatically and highlighted in the snapshot.
capture_system_snapshot() {
    local snapshot_file="${UPLOAD_ID}-system-snapshot.txt"

    # Identify all non-loopback interfaces.
    local ifaces=()
    while IFS= read -r iface; do
        ifaces+=("$iface")
    done < <(ip link show | awk -F': ' '/^[0-9]+: /{print $2}' | grep -v '^lo$' | cut -d'@' -f1)

    # Identify the interface used to reach the peer (when --server is provided).
    local routing_iface=""
    if [[ -n "$SERVER_ADDRESS" ]]; then
        routing_iface=$(ip route get "$SERVER_ADDRESS" 2>/dev/null \
            | grep -oP 'dev \K\S+' | head -1)
    fi

    {
        echo "=== Benchmark Configuration ==="
        echo "Date:        $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
        echo "Result ID:   $UPLOAD_ID"
        echo "Result Name: $UPLOAD_NAME"
        echo "Server:      ${SERVER_ADDRESS:-(standalone only)}"
        [[ -n "$routing_iface" ]] && echo "Routing interface to server: $routing_iface"
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
            echo "driver:    $(sort -u /sys/devices/system/cpu/cpu*/cpufreq/scaling_driver   2>/dev/null | tr '\n' ' ')"
            echo "min_freq:  $(< /sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq) kHz"
            echo "max_freq:  $(< /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq) kHz"
            echo "hw_max:    $(< /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq) kHz"
        else
            echo "cpufreq interface not available"
        fi
        echo ""

        echo "=== Network Interfaces ==="
        ip -s link show
        echo ""
        ip addr show
        echo ""

        echo "=== Per-interface NIC Detail ==="
        for iface in "${ifaces[@]}"; do
            local marker=""
            [[ "$iface" == "$routing_iface" ]] && marker=" <-- routing interface to server"
            echo "--- ${iface}${marker} ---"
            echo "  MTU:   $( [[ -r /sys/class/net/${iface}/mtu   ]] && cat /sys/class/net/${iface}/mtu   || echo n/a )"
            echo "  Speed: $( [[ -r /sys/class/net/${iface}/speed ]] && cat /sys/class/net/${iface}/speed || echo n/a ) Mbps"
            if command -v ethtool &>/dev/null; then
                echo "  Driver / firmware:"
                ethtool -i "$iface" 2>/dev/null | sed 's/^/    /' || echo "    n/a"
                echo "  Offload flags (selected):"
                ethtool -k "$iface" 2>/dev/null \
                    | grep -E "(tcp-segmentation|generic-segmentation|generic-receive|large-receive|rx-checksumming|tx-checksumming|scatter-gather)" \
                    | sed 's/^/    /' || echo "    n/a"
                echo "  Ring buffers:"
                ethtool -g "$iface" 2>/dev/null | sed 's/^/    /' || echo "    n/a"
            else
                echo "  ethtool not available"
            fi
            echo ""
        done

        echo "=== TCP/IP Settings ==="
        echo "congestion_control:  $(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || echo n/a)"
        echo "moderate_rcvbuf:     $(cat /proc/sys/net/ipv4/tcp_moderate_rcvbuf    2>/dev/null || echo n/a)"
        echo "tcp_rmem:            $(cat /proc/sys/net/ipv4/tcp_rmem               2>/dev/null || echo n/a)"
        echo "tcp_wmem:            $(cat /proc/sys/net/ipv4/tcp_wmem               2>/dev/null || echo n/a)"
        echo "rmem_max:            $(cat /proc/sys/net/core/rmem_max               2>/dev/null || echo n/a)"
        echo "wmem_max:            $(cat /proc/sys/net/core/wmem_max               2>/dev/null || echo n/a)"
        echo "netdev_max_backlog:  $(cat /proc/sys/net/core/netdev_max_backlog     2>/dev/null || echo n/a)"
        echo ""

        echo "=== Memory ==="
        free -h
        echo ""

        echo "=== Load Average ==="
        cat /proc/loadavg
        echo ""

        if command -v dmidecode &>/dev/null && [[ "$HAS_PRIVILEGE" -eq 1 ]]; then
            echo "=== Network Adapters (dmidecode) ==="
            ${SUDO_CMD} dmidecode -t 9
        fi
    } > "$snapshot_file"
    echo "System snapshot saved to: $(realpath "$snapshot_file")"
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
echo "------------------------------"

# === System Snapshot ===
capture_system_snapshot

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
