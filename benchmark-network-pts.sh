#!/bin/bash

# Script Name: benchmark-network-pts.sh
#
# A script to benchmark network performance using the Phoronix Test Suite (PTS).
#
# Description: Runs a comprehensive set of network benchmarks in three modes:
#
#              Standalone (always run — no second machine required):
#                pts/network-loopback - TCP stack throughput via loopback interface.
#                pts/sockperf         - Socket API latency and throughput; starts
#                                       its own server locally.
#
#              Peer/client (run when --server is provided):
#                pts/iperf   - TCP/UDP bulk throughput with single and multi-stream.
#                pts/netperf - TCP/UDP throughput and request-response latency.
#
#              Server (run with --server-mode on the remote host):
#                Installs test binaries via PTS and starts iperf3 and netserver as
#                local daemons, bound to a specific interface/IP or all interfaces.
#
#              PTS is installed automatically on supported systems if not present.
#
# Author: Ciro Iriarte <ciro.iriarte@gmail.com>
# Version: 2.8.0
#
# Changelog:
#   - 2026-06-21: v2.8.0 - Validate value-taking CLI options via require_optarg()
#                          (issue #16).  Start netserver with -D in the background
#                          and stop it by PID instead of 'pkill -x netserver', so
#                          server mode no longer kills unrelated netserver
#                          processes on a shared host (issue #19).
#   - 2026-06-21: v2.7.0 - Make the peer reachability preflight fatal (issue #13).
#                          check_server_reachable's result was previously ignored,
#                          so the script ran the full peer suite (multiple 360 s
#                          benchmarks) against an unreachable server.  Now skip the
#                          peer tests and exit non-zero when either daemon port is
#                          closed, with guidance to start --server-mode remotely.
#   - 2026-06-21: v2.6.0 - Verify test installs with pts_test_installed() (issue
#                           #24).  PTS batch-install exits 0 even when a build
#                           fails or a dependency is unavailable, which could add
#                           a never-installed test to the run list; gate
#                           INSTALLED_TESTS on the pts-install.json marker so such
#                           tests are reported as failed installs and skipped.
#   - 2026-03-13: v2.5.0 - Add --identifier flag to control TEST_RESULTS_IDENTIFIER.
#                          Accepts "upload-id" (uses --result-id value),
#                          "upload-name" (uses --result-name, the default),
#                          or a custom literal string.
#   - 2026-03-12: v2.4.0 - Fix find_binary(): search /var/lib/phoronix-test-suite/
#                          in addition to ~/.phoronix-test-suite/ so server mode
#                          finds iperf3/netserver on system-wide PTS installs.
#                          Fix netperf 2.7.0 build: pass -fcommon (duplicate
#                          globals, GCC 10+), -Wno-error=implicit-function-
#                          declaration, and -std=gnu17 (GCC 15 defaults to C23
#                          where () means (void), breaking K&R prototypes) via
#                          CFLAGS to unblock the build on modern toolchains.
#                          Export TEST_RESULTS_IDENTIFIER=$UPLOAD_NAME so PTS
#                          comparison columns show --result-name instead of
#                          auto-generated hardware/date labels.
#                          Fix detect_nic_speed(): return 0 explicitly when
#                          speed is unavailable (virtio-net returns -1) so
#                          set -e does not abort the script during peer tests.
#                          Add psmisc (killall) to openSUSE dependencies; the
#                          pts/sockperf test wrapper uses killall to stop the
#                          server process between runs.
#   - 2026-03-12: v2.3 - Use batch-install instead of install for PTS test
#                        installation to prevent interactive dependency prompts
#                        that hang under nohup (stdin=/dev/null).
#   - 2026-03-12: v2.2 - Extract pre-run checks, collect_results, upload,
#                        result file listing, and invocation context into
#                        shared libraries (common-checks.sh, install-pts.sh
#                        configure_pts_batch).
#                        Fix batch-setup: expand from 5 to 7 answers; add
#                        missing PromptSaveName=N and RunAllTestCombinations=N
#                        (5-answer version caused batch-run to hang).
#                        Fix upload-result: pipe 'n' to suppress interactive
#                        "attach system logs?" prompt; add PTS result name
#                        resolution with underscore-stripping.
#                        Fix collect_results: add /var/lib/ fallback for
#                        system-wide PTS installs; add underscore-stripped
#                        name resolution.
#   - 2026-03-11: v2.1 - Extract PTS installation into shared install-pts.sh
#                        library.  Fixes: openSUSE repo idempotency, zypper
#                        exit code 106 handling, python_pkg detection for
#                        Leap 16+/Tumbleweed, VERSION_ID-based gcc12 guard.
#                        Add result file listing at end of run.
#   - 2026-03-09: v2.0 - Add unzip to Ubuntu/Debian and openSUSE deps; PTS
#                        needs it to extract test archives (.zip). Rocky Linux
#                        ships unzip in the base install so no change needed
#                        there.
#   - 2026-03-09: v1.9 - Move DEBIAN_FRONTEND=noninteractive and
#                        NEEDRESTART_MODE=a exports to top-level scope so
#                        they also cover PTS's own internal apt-get calls
#                        during phoronix-test-suite install (which triggered
#                        the needrestart hang reported in issue #3).
#   - 2026-03-09: v1.8 - Fix Ubuntu/Debian PTS install: pre-install php-cli
#                        and php-xml before the PTS deb so dpkg never fails on
#                        missing PHP deps; add '|| true' to dpkg -i so set -e
#                        does not abort before apt-get install -f -y runs.
#                        Add php to install gate check so a broken prior install
#                        (dpkg iU state) triggers re-installation.
#   - 2026-02-26: v1.7 - Add collect_results(): copy system snapshot and all PTS
#                        result directories to benchmark-results/${RUN_ID}/ relative
#                        to the invocation CWD; transfer ownership to the invoking
#                        user (SUDO_USER) so results are readable without sudo.
#                        Add RUN_ID, SNAPSHOT_FILE, INVOKING_USER/GROUP variables.
#   - 2026-02-19: v1.6 - Add --server-mode: installs pts/iperf and pts/netperf
#                        to obtain compiled binaries, then starts iperf3 (-s) and
#                        netserver as local server daemons. --interface accepts an
#                        interface name (resolved to its primary IPv4) or a literal
#                        IP address and passes it as the bind address to both daemons.
#                        Omitting --interface binds to all interfaces. Both daemons
#                        are stopped cleanly on SIGINT / SIGTERM.
#   - 2026-02-19: v1.5 - Remove FORCE_TIMES_TO_RUN=1. None of the network test
#                        profiles support DynamicRunCount; PTS falls back to the
#                        static TimesToRun declared in each profile (pts/iperf: 3,
#                        pts/netperf: 3, pts/sockperf: 5, pts/network-loopback: 3).
#                        Forcing a single run discarded that repeatability entirely.
#   - 2026-02-19: v1.4 - Add check_tcp_buffers(): computes the bandwidth-delay
#                        product (BDP) for the link under test using ping RTT and
#                        NIC speed, then warns if rmem_max/wmem_max are below
#                        BDP + 20% headroom; includes sysctl recommendations for
#                        both client and server sides. Extend iperf and netperf
#                        test duration from 60 s to 360 s — the maximum value
#                        supported by the pts/iperf and pts/netperf profiles —
#                        to allow TCP slow-start to complete and produce stable
#                        steady-state throughput measurements.
#   - 2026-02-19: v1.3 - Add TCP port reachability check before peer tests
#                        (iperf3 :5201, netserver :12865) so unreachable daemons
#                        are reported clearly instead of failing silently. Add
#                        install failure tracking: failed installs are recorded
#                        and their dependent run steps are skipped; a summary
#                        is printed at the end and the script exits non-zero if
#                        any install failed.
#   - 2026-02-19: v1.2 - Add interface auto-detection (ip route get) and
#                        --interface/--nic-speed/--streams options. Detect NIC
#                        speed from sysfs and scale the parallel stream count for
#                        both the multi-stream TCP test and the UDP-1G test.
#                        pts/iperf UDP-1G target is 1 Gbps per stream, so
#                        stream count = link speed in Gbps matches line rate exactly
#                        (e.g. 25G→25 streams, 100G→100 streams); 10-stream minimum
#                        for links up to 10 GbE. Overridable with --streams.
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
#                                Mutually exclusive with --server-mode.
#   --server-mode                Run as the server side: install test binaries and
#                                start iperf3 and netserver as local daemons. Stops
#                                both daemons cleanly on Ctrl+C / SIGTERM.
#                                Mutually exclusive with --server.
#   -I, --interface <iface|IP>   In client mode: egress interface for NIC speed
#                                detection; auto-detected from the routing table.
#                                In server mode: interface name (e.g. eth0, bond0)
#                                or literal IP address to bind both daemons to.
#                                If omitted in server mode, daemons bind to all
#                                interfaces (0.0.0.0).
#   --nic-speed <Mbps>           Override the detected NIC speed in Mbps (e.g. 100000
#                                for 100 GbE). Client mode only. Use when the
#                                interface does not report speed via sysfs, which is
#                                common with virtual NICs such as virtio-net, vmxnet3.
#   --streams <N>                Override the parallel stream count for the multi-stream
#                                TCP test. Client mode only. Auto-scaled from NIC speed
#                                when not specified.
#   -u, --upload                 Upload results to OpenBenchmarking.org. Client mode only.
#   -i, --result-id <id>         Test identifier (e.g. 'dc1-vm1-to-vm2'). Client mode only.
#   -n, --result-name <name>     Display name (e.g. 'VM1 to VM2 - 100GbE vSwitch').
#                                Client mode only.
#   --identifier <value>         Set the system identifier for PTS comparison columns.
#                                "upload-id" = use --result-id value,
#                                "upload-name" = use --result-name value (default),
#                                or any custom string. Client mode only.
#   -h, --help                   Display this help message and exit.
#
# NOTES:
#   The same script is used on both sides of a peer test. Run it with --server-mode
#   on the remote host first, then run the client on the local host with --server.
#
#   pts/network-loopback uses nc (netcat). On RHEL/Rocky Linux the default nc
#   is ncat (from nmap), whose -d flag semantics differ from OpenBSD netcat.
#   If this test fails on those systems, install OpenBSD netcat manually or
#   disregard the loopback result; the remaining tests are unaffected.
#
# EXAMPLES:
#   # On the remote host: start server daemons bound to a specific interface.
#   ./benchmark-network-pts.sh --server-mode --interface eth0
#
#   # On the remote host: bind to a specific IP instead of interface name.
#   ./benchmark-network-pts.sh --server-mode --interface 192.168.100.10
#
#   # On the remote host: bind to all interfaces (no --interface).
#   ./benchmark-network-pts.sh --server-mode
#
#   # On the local host: run standalone tests only (no second machine needed).
#   ./benchmark-network-pts.sh
#
#   # On the local host: run full peer suite; interface and speed auto-detected.
#   ./benchmark-network-pts.sh --server 192.168.100.10 \
#     --result-id "dc1-vm1-to-vm2" \
#     --result-name "VM1 to VM2 - Ceph cluster network"
#
#   # On the local host: 100 GbE link where the virtual NIC does not report speed.
#   ./benchmark-network-pts.sh --server 192.168.100.10 \
#     --interface eth0 --nic-speed 100000 \
#     --result-id "dc1-vm1-to-vm2" \
#     --result-name "VM1 to VM2 - 100GbE vSwitch"
#
#   # On the local host: manually specified stream count, upload results.
#   ./benchmark-network-pts.sh --server 192.168.100.10 --streams 64 --upload \
#     --result-id "dc1-vm1-to-vm2" \
#     --result-name "VM1 to VM2 - 400GbE"
#
# DEPENDENCIES:
#   - gcc, make, autoconf, automake, libtool (to build sockperf, iperf3, netperf)
#   - nc / netcat (for pts/network-loopback)
#   - phoronix-test-suite (installed automatically if missing)
#

set -e
set -o pipefail

# === Configuration ===

# Resolve the directory containing this script so co-located libraries can be
# sourced regardless of the caller's working directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/install-pts.sh"
. "${SCRIPT_DIR}/common-checks.sh"

# Standalone tests run on a single host with no remote peer required.
STANDALONE_TESTS=("pts/network-loopback" "pts/sockperf")
# Peer tests require a server running on the host specified via --server.
PEER_TESTS=("pts/iperf" "pts/netperf")
# Pre-run check thresholds use defaults from common-checks.sh:
#   RECOMMENDED_GOVERNOR=performance, CPU_TEMP_WARN_THRESHOLD_MC=80000,
#   LOAD_WARN_MULTIPLIER=1, STEAL_TIME_WARN_THRESHOLD=5
# Test duration in seconds for pts/iperf and pts/netperf.
# 360 s is the maximum value exposed by both PTS profiles. A long run allows
# TCP slow-start to complete and gives the congestion-control algorithm time
# to reach steady state, producing stable, reproducible throughput figures.
# Valid values for pts/iperf:   10, 30, 60, 360
# Valid values for pts/netperf: 10, 60, 360
IPERF_DURATION=360
NETPERF_DURATION=360
# === End Configuration ===

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

# === High-speed NIC Support Functions ===

# Return the speed of a network interface in Mbps, read from sysfs.
# Outputs the integer speed, or an empty string when unavailable (no carrier,
# virtual NIC that does not expose speed, or sysfs entry missing).
# Use --nic-speed to override when the interface returns an empty result.
detect_nic_speed() {
    local iface="$1"
    local speed_file="/sys/class/net/${iface}/speed"
    [[ ! -r "$speed_file" ]] && return 0
    local speed
    speed=$(< "$speed_file")
    # sysfs reports -1 when speed is unknown or there is no carrier.
    # Always return 0 so set -e does not abort when speed is unavailable.
    if [[ "$speed" =~ ^[0-9]+$ ]] && [[ "$speed" -gt 0 ]]; then
        echo "$speed"
    fi
    return 0
}

# Calculate the number of parallel streams for multi-stream tests (TCP and UDP).
# pts/iperf UDP-1G sends 1 Gbps per stream, so stream count = link speed in Gbps
# exactly matches the line rate for UDP. For TCP, more streams overcome the per-core
# throughput ceiling (~10–20 Gbps per flow on modern kernels).
# Formula: max(10, floor(speed_mbps / 1000)).
# The floor keeps stream count proportional to actual link speed; the 10-stream
# minimum ensures meaningful multi-queue coverage on links up to 10 GbE.
# Examples: 1G→10, 10G→10, 25G→25, 40G→40, 100G→100, 400G→400.
# Use --streams to override when the default is not appropriate.
calc_parallel_streams() {
    local speed_mbps="$1"
    if [[ ! "$speed_mbps" =~ ^[0-9]+$ ]] || [[ "$speed_mbps" -le 0 ]]; then
        echo "10"   # unknown speed: safe default
        return
    fi
    local speed_gbps=$(( speed_mbps / 1000 ))
    echo $(( speed_gbps > 10 ? speed_gbps : 10 ))
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

# Check whether TCP socket buffer sizes are large enough to fill the
# bandwidth-delay product (BDP) for the link under test.
#
# BDP (bytes) = line_rate_bps × RTT_s
#             = speed_mbps × 1 000 000 × rtt_ms × 0.001 / 8
#             = speed_mbps × rtt_ms × 125
#
# A 20% headroom is added to the raw BDP. rmem_max and wmem_max are compared
# against the result; if either falls short, the function prints the expected
# throughput ceiling and the sysctl commands needed to fix it on both the client
# (this host) and the server (which must be tuned separately by the operator).
#
# Arguments: $1=server_address  $2=speed_mbps (may be empty)
check_tcp_buffers() {
    local server="$1"
    local speed_mbps="$2"
    local rmem_max wmem_max
    rmem_max=$(cat /proc/sys/net/core/rmem_max 2>/dev/null || echo 0)
    wmem_max=$(cat /proc/sys/net/core/wmem_max 2>/dev/null || echo 0)

    echo "=== TCP Buffer Sizes ==="
    echo "  rmem_max: ${rmem_max} bytes  ($(( rmem_max / 1024 )) KiB)"
    echo "  wmem_max: ${wmem_max} bytes  ($(( wmem_max / 1024 )) KiB)"

    if [[ ! "$speed_mbps" =~ ^[0-9]+$ ]] || [[ "$speed_mbps" -le 0 ]]; then
        echo "  NIC speed unknown — skipping BDP calculation."
        echo "  Use --nic-speed <Mbps> to enable the buffer adequacy check."
        echo ""
        return
    fi

    # Measure round-trip time to the peer via ICMP ping.
    local rtt_ms
    rtt_ms=$(ping -c 4 -q "$server" 2>/dev/null | awk -F'/' '/rtt/ {print $5}')
    if [[ -z "$rtt_ms" ]]; then
        echo "  RTT measurement to ${server} failed (ping unavailable or ICMP blocked)."
        echo "  Skipping BDP adequacy check."
        echo ""
        return
    fi
    echo "  RTT to ${server}: ${rtt_ms} ms"

    # Compute required buffer size: BDP + 20% headroom.
    local required_bytes required_mib
    required_bytes=$(awk -v s="$speed_mbps" -v r="$rtt_ms" \
        'BEGIN { printf "%d", s * r * 125 * 1.2 }')
    required_mib=$(( required_bytes / 1024 / 1024 ))
    echo "  Required (BDP + 20%): ${required_bytes} bytes  (${required_mib} MiB)"

    if [[ "$rmem_max" -lt "$required_bytes" ]] || [[ "$wmem_max" -lt "$required_bytes" ]]; then
        local cap_rx cap_tx
        cap_rx=$(awk -v b="$rmem_max" -v r="$rtt_ms" \
            'BEGIN { printf "%.1f Gbps", b * 8 / r / 1e6 }')
        cap_tx=$(awk -v b="$wmem_max" -v r="$rtt_ms" \
            'BEGIN { printf "%.1f Gbps", b * 8 / r / 1e6 }')
        echo ""
        echo "WARNING: TCP buffers too small for this link's bandwidth-delay product."
        echo "  Effective throughput ceiling: RX ${cap_rx}  TX ${cap_tx}"
        echo ""
        echo "  Apply on this host (client):"
        echo "    sudo sysctl -w net.core.rmem_max=${required_bytes}"
        echo "    sudo sysctl -w net.core.wmem_max=${required_bytes}"
        echo "    sudo sysctl -w net.ipv4.tcp_rmem=\"4096 87380 ${required_bytes}\""
        echo "    sudo sysctl -w net.ipv4.tcp_wmem=\"4096 65536 ${required_bytes}\""
        echo ""
        echo "  IMPORTANT: Apply the same settings on the server (${server})."
        echo "  Asymmetric buffer limits will cap throughput in one direction."
    else
        echo "  Buffers are sufficient for this link's BDP."
    fi
    echo ""
}

# Locate a binary by name: prefer the system PATH, then fall back to any binary
# compiled by PTS under ~/.phoronix-test-suite/ or /var/lib/phoronix-test-suite/.
find_binary() {
    local name="$1"
    if command -v "$name" &>/dev/null; then
        command -v "$name"
        return 0
    fi
    local pts_bin dir
    for dir in "${HOME}/.phoronix-test-suite/installed-tests/pts/" \
               "/var/lib/phoronix-test-suite/installed-tests/pts/"; do
        pts_bin=$(find "$dir" -name "$name" -type f 2>/dev/null | head -1)
        [[ -n "$pts_bin" ]] && echo "$pts_bin" && return 0
    done
    return 1
}

# Start iperf3 and netserver as local server daemons for peer benchmark tests.
# --interface (interface name or IP) controls the bind address for both daemons.
# Both processes are stopped cleanly on SIGINT / SIGTERM.
run_server_mode() {
    echo "=== Network benchmark server mode ==="

    # Resolve bind address from --interface: interface name → primary IPv4,
    # or a literal IP address passed through unchanged.
    local bind_addr=""
    if [[ -n "$INTERFACE" ]]; then
        if [[ "$INTERFACE" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            bind_addr="$INTERFACE"
            echo "Bind address: ${bind_addr} (explicit IP)"
        else
            bind_addr=$(ip addr show "$INTERFACE" 2>/dev/null \
                | grep -oP '(?<=inet )\d+\.\d+\.\d+\.\d+' | head -1)
            if [[ -z "$bind_addr" ]]; then
                echo "ERROR: Could not determine IPv4 address for interface '${INTERFACE}'."
                echo "       Check available interfaces with: ip addr"
                exit 1
            fi
            echo "Bind address: ${bind_addr} (interface: ${INTERFACE})"
        fi
    else
        echo "Bind address: all interfaces (use --interface to restrict)"
    fi

    # Install PTS and build dependencies if not already present.
    ensure_pts_installed

    # Install pts/iperf and pts/netperf to obtain compiled server binaries.
    # netperf 2.7.0 has duplicate global definitions in nettest_omni.c and
    # nettest_bsd.c which cause linker errors on GCC 10+ where -fno-common
    # is the default. Export CFLAGS=-fcommon to restore the legacy behaviour.
    echo "--- Installing test binaries ---"
    phoronix-test-suite batch-install pts/iperf
    CFLAGS="${CFLAGS:+$CFLAGS }-fcommon -Wno-error=implicit-function-declaration -std=gnu17" \
        phoronix-test-suite batch-install pts/netperf

    # Locate binaries (system PATH or PTS-compiled).
    local iperf3_bin netserver_bin
    iperf3_bin=$(find_binary "iperf3") || {
        echo "ERROR: iperf3 binary not found after installing pts/iperf."
        exit 1
    }
    netserver_bin=$(find_binary "netserver") || {
        echo "ERROR: netserver binary not found after installing pts/netperf."
        exit 1
    }
    echo "iperf3:    ${iperf3_bin}"
    echo "netserver: ${netserver_bin}"

    # Build argument lists for each daemon.
    local iperf3_args=("-s")
    [[ -n "$bind_addr" ]] && iperf3_args+=("-B" "$bind_addr")

    local netserver_args=()
    [[ -n "$bind_addr" ]] && netserver_args+=("-L" "$bind_addr")

    # Start iperf3 in the background (no -D so we own the PID).
    echo "--- Starting iperf3 server (port 5201) ---"
    "$iperf3_bin" "${iperf3_args[@]}" &
    local iperf3_pid=$!

    # Start netserver with -D (do not daemonize) in the background so we own its
    # PID and can stop exactly this instance on exit.  Previously netserver was
    # left to self-daemonize and cleanup used 'pkill -x netserver', which would
    # kill every netserver on the host — unsafe on shared machines (issue #19).
    echo "--- Starting netserver (port 12865) ---"
    "$netserver_bin" -D "${netserver_args[@]}" &
    local netserver_pid=$!

    echo ""
    echo "=== Server daemons running ==="
    [[ -n "$bind_addr" ]] \
        && echo "  Bind address : ${bind_addr}" \
        || echo "  Bind address : all interfaces (0.0.0.0)"
    echo "  iperf3       : port 5201   (PID ${iperf3_pid})"
    echo "  netserver    : port 12865  (PID ${netserver_pid})"
    echo ""
    echo "Press Ctrl+C to stop."

    # Stop only the daemons this script started (by PID) on exit — never other
    # netserver/iperf3 processes that may belong to other users (issue #19).
    trap 'echo; echo "Stopping server daemons..."; \
          kill "${iperf3_pid}" 2>/dev/null; \
          kill "${netserver_pid}" 2>/dev/null; \
          echo "Done."; exit 0' SIGINT SIGTERM

    # Block until iperf3 exits (or the trap fires).
    wait "$iperf3_pid"
}

# Return 0 if the named PTS test was successfully installed, 1 otherwise.
# Used to skip run steps when their install failed.
is_installed() {
    local target="$1"
    local t
    for t in "${INSTALLED_TESTS[@]}"; do
        [[ "$t" == "$target" ]] && return 0
    done
    return 1
}

# Probe a TCP port on the remote server with a 5-second timeout.
# Prints the result and returns 0 on success, 1 on failure.
# Uses the bash /dev/tcp built-in — no external nc/nmap dependency.
# Arguments: $1=host $2=port $3=service-name
check_server_reachable() {
    local host="$1"
    local port="$2"
    local service="$3"
    if timeout 5 bash -c ">/dev/tcp/${host}/${port}" 2>/dev/null; then
        echo "  ${service} (${host}:${port}): OK"
        return 0
    else
        echo "WARNING: ${service} (${host}:${port}) is not reachable."
        echo "         Start the daemon on the remote host before running peer tests."
        return 1
    fi
}

# === Main Script ===

# Default values
UPLOAD_RESULTS=0
SERVER_MODE=0
SERVER_ADDRESS=""
INTERFACE=""          # client: auto-detected from routing table; server: bind address
NIC_SPEED_MBPS=""     # empty = auto-detect; override with --nic-speed for virtual NICs
OVERRIDE_STREAMS=""   # empty = auto-scale from NIC speed; override with --streams
UPLOAD_ID="benchmark-network-$(date +%Y-%m-%d-%H%M%S)"
UPLOAD_NAME="Automated network benchmark run with benchmark-network-pts.sh"
IDENTIFIER_SOURCE="upload-name"

# === Argument Parsing ===
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -s|--server)
            require_optarg "$1" "${2:-}"
            SERVER_ADDRESS="$2"
            shift
            ;;
        --server-mode)
            SERVER_MODE=1
            ;;
        -I|--interface)
            require_optarg "$1" "${2:-}"
            INTERFACE="$2"
            shift
            ;;
        --nic-speed)
            require_optarg "$1" "${2:-}"
            NIC_SPEED_MBPS="$2"
            shift
            ;;
        --streams)
            require_optarg "$1" "${2:-}"
            OVERRIDE_STREAMS="$2"
            shift
            ;;
        -u|--upload)
            UPLOAD_RESULTS=1
            ;;
        -n|--result-name)
            require_optarg "$1" "${2:-}"
            UPLOAD_NAME="$2"
            shift
            ;;
        -i|--result-id)
            require_optarg "$1" "${2:-}"
            UPLOAD_ID="$2"
            shift
            ;;
        --identifier)
            require_optarg "$1" "${2:-}"
            IDENTIFIER_SOURCE="$2"
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

# Capture invocation context after arg parsing so --result-id is reflected in
# RUN_ID before SNAPSHOT_FILE and the output directory are derived from it.
# Not needed in --server-mode (which exits before any benchmarking).
setup_invocation_context

# --server-mode and --server are mutually exclusive.
if [[ "$SERVER_MODE" -eq 1 ]] && [[ -n "$SERVER_ADDRESS" ]]; then
    echo "ERROR: --server-mode and --server are mutually exclusive."
    usage
    exit 1
fi

# === Install PTS and dependencies ===
# Set extra packages once; both server mode and client mode use the same deps.
EXTRA_PKGS_APT=(autoconf automake libtool netcat-openbsd ethtool)
EXTRA_PKGS_DNF=(autoconf automake libtool nmap-ncat ethtool)
EXTRA_PKGS_ZYPPER=(autoconf automake libtool netcat-openbsd ethtool psmisc)

# === Server Mode ===
if [[ "$SERVER_MODE" -eq 1 ]]; then
    run_server_mode
    exit 0
fi

ensure_pts_installed

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
# RunAllTestCombinations=N: iperf has too many option permutations (protocol x
# duration x parallel streams) to run exhaustively. Specific configurations
# that cover the key dimensions are invoked explicitly below instead.
configure_pts_batch "N"

# === Install Tests ===
INSTALLED_TESTS=()
FAILED_INSTALLS=()

echo "--- Installing standalone tests ---"
for test_name in "${STANDALONE_TESTS[@]}"; do
    # batch-install exits 0 even on build/dependency failure, so confirm the test
    # actually installed (pts-install.json marker) before adding it (issue #24).
    if phoronix-test-suite batch-install "$test_name" && pts_test_installed "$test_name"; then
        INSTALLED_TESTS+=("$test_name")
    else
        echo "WARNING: Failed to install ${test_name}; dependent tests will be skipped."
        FAILED_INSTALLS+=("$test_name")
    fi
done

if [[ -n "$SERVER_ADDRESS" ]]; then
    echo "--- Installing peer tests ---"
    for test_name in "${PEER_TESTS[@]}"; do
        # netperf 2.7.0 has duplicate global definitions that cause linker
        # errors on GCC 10+ where -fno-common is the default. The PTS install
        # script appends to $CFLAGS, so exporting -fcommon restores the legacy
        # behaviour without affecting other test builds.
        if CFLAGS="${CFLAGS:+$CFLAGS }-fcommon -Wno-error=implicit-function-declaration -std=gnu17" \
            phoronix-test-suite batch-install "$test_name" && pts_test_installed "$test_name"; then
            INSTALLED_TESTS+=("$test_name")
        else
            echo "WARNING: Failed to install ${test_name}; dependent tests will be skipped."
            FAILED_INSTALLS+=("$test_name")
        fi
    done
fi

# === Run Tests ===
RESULT_NAMES=()

# FORCE_TIMES_TO_RUN is intentionally not set here. PTS will use the run count
# declared in each test profile (pts/iperf: 3, pts/netperf: 3, pts/sockperf: 5,
# pts/network-loopback: 3). None of these profiles support DynamicRunCount, so
# the profile TimesToRun values are the correct mechanism for statistical validity.
export TEST_RESULTS_DESCRIPTION="$UPLOAD_NAME"
# Resolve TEST_RESULTS_IDENTIFIER based on --identifier flag.
case "$IDENTIFIER_SOURCE" in
    upload-id)   export TEST_RESULTS_IDENTIFIER="$UPLOAD_ID" ;;
    upload-name) export TEST_RESULTS_IDENTIFIER="$UPLOAD_NAME" ;;
    *)           export TEST_RESULTS_IDENTIFIER="$IDENTIFIER_SOURCE" ;;
esac

# --- Standalone tests (no remote peer required) ---

# TCP stack throughput through the loopback interface (10 GB transfer via nc+dd).
# Characterises kernel network buffer performance independent of NIC or fabric.
if is_installed "pts/network-loopback"; then
    run_network_test "pts/network-loopback" "" "loopback"
fi

if is_installed "pts/sockperf"; then
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
fi

# --- Peer tests (require --server) ---
if [[ -n "$SERVER_ADDRESS" ]]; then
    echo "--- Running peer-to-peer tests against ${SERVER_ADDRESS} ---"
    echo "    Ensure iperf3 -s -D and netserver are running on the remote host."

    # Verify server daemons are reachable before committing to peer tests.
    # check_server_reachable returns non-zero when a port is closed; honour it so
    # we do not waste many minutes running 360 s benchmarks against a dead server
    # (issue #13).  Both ports are probed so the operator sees which is missing.
    echo "--- Checking server reachability ---"
    peer_reachable=1
    check_server_reachable "$SERVER_ADDRESS" 5201  "iperf3 server"              || peer_reachable=0
    check_server_reachable "$SERVER_ADDRESS" 12865 "netperf server (netserver)" || peer_reachable=0
    echo "------------------------------"

    if [[ "$peer_reachable" -ne 1 ]]; then
        echo "ERROR: peer server ${SERVER_ADDRESS} is not reachable on the required ports"
        echo "       (iperf3 5201, netserver 12865); skipping peer tests."
        echo "       Start the daemons on the remote host first:"
        echo "         ./benchmark-network-pts.sh --server-mode"
        FAILED_INSTALLS+=("peer server unreachable: ${SERVER_ADDRESS}")
    else

    # Auto-detect egress interface and NIC speed for the path to the server.
    if [[ -z "$INTERFACE" ]]; then
        INTERFACE=$(ip route get "$SERVER_ADDRESS" 2>/dev/null \
            | grep -oP 'dev \K\S+' | head -1)
        if [[ -n "$INTERFACE" ]]; then
            echo "Auto-detected egress interface: ${INTERFACE}"
        else
            echo "WARNING: Could not determine egress interface; NIC speed detection skipped."
        fi
    fi

    if [[ -z "$NIC_SPEED_MBPS" ]] && [[ -n "$INTERFACE" ]]; then
        NIC_SPEED_MBPS=$(detect_nic_speed "$INTERFACE")
        if [[ -n "$NIC_SPEED_MBPS" ]]; then
            echo "Detected NIC speed: ${NIC_SPEED_MBPS} Mbps (interface: ${INTERFACE})"
        else
            echo "WARNING: NIC speed not available for ${INTERFACE} (virtual NIC or no carrier)."
            echo "         Use --nic-speed <Mbps> to set it manually. Falling back to 1 Gbps defaults."
        fi
    fi

    # TCP buffer adequacy check against the link's bandwidth-delay product.
    check_tcp_buffers "$SERVER_ADDRESS" "$NIC_SPEED_MBPS"

    MULTI_STREAMS="${OVERRIDE_STREAMS:-$(calc_parallel_streams "$NIC_SPEED_MBPS")}"
    echo "Parallel streams: ${MULTI_STREAMS}  (UDP-1G target is per stream; total ≈ ${MULTI_STREAMS} Gbps)"

    if is_installed "pts/iperf"; then
        # TCP bulk throughput — single stream baseline.
        run_network_test "pts/iperf" \
            "pts/iperf.server-address=${SERVER_ADDRESS};pts/iperf.test=TCP;pts/iperf.parallel=1;pts/iperf.duration=${IPERF_DURATION}" \
            "iperf_tcp_1stream"

        # TCP bulk throughput — multiple parallel streams scaled to NIC line rate.
        # A single TCP stream cannot saturate >10 GbE links due to per-core throughput
        # limits; the stream count is computed by calc_parallel_streams().
        run_network_test "pts/iperf" \
            "pts/iperf.server-address=${SERVER_ADDRESS};pts/iperf.test=TCP;pts/iperf.parallel=${MULTI_STREAMS};pts/iperf.duration=${IPERF_DURATION}" \
            "iperf_tcp_${MULTI_STREAMS}streams"

        # UDP throughput — pts/iperf UDP-1G target is 1 Gbps per stream; scaling
        # the parallel stream count raises the aggregate target to cover the link rate.
        run_network_test "pts/iperf" \
            "pts/iperf.server-address=${SERVER_ADDRESS};pts/iperf.test=UDP-1G;pts/iperf.parallel=${MULTI_STREAMS};pts/iperf.duration=${IPERF_DURATION}" \
            "iperf_udp_${MULTI_STREAMS}streams"
    fi

    if is_installed "pts/netperf"; then
        # TCP throughput — client to server (same direction as iperf TCP above,
        # but measured by netperf for cross-tool validation).
        run_network_test "pts/netperf" \
            "pts/netperf.server-address=${SERVER_ADDRESS};pts/netperf.run-test=TCP_STREAM;pts/netperf.duration=${NETPERF_DURATION}" \
            "netperf_tcp_stream"

        # TCP throughput — server to client (reverse direction).
        run_network_test "pts/netperf" \
            "pts/netperf.server-address=${SERVER_ADDRESS};pts/netperf.run-test=TCP_MAERTS;pts/netperf.duration=${NETPERF_DURATION}" \
            "netperf_tcp_maerts"

        # TCP request-response — transactions/sec as a latency proxy.
        # Higher values indicate lower per-transaction overhead.
        run_network_test "pts/netperf" \
            "pts/netperf.server-address=${SERVER_ADDRESS};pts/netperf.run-test=TCP_RR;pts/netperf.duration=${NETPERF_DURATION}" \
            "netperf_tcp_rr"

        # UDP request-response — same as TCP_RR but over UDP.
        run_network_test "pts/netperf" \
            "pts/netperf.server-address=${SERVER_ADDRESS};pts/netperf.run-test=UDP_RR;pts/netperf.duration=${NETPERF_DURATION}" \
            "netperf_udp_rr"
    fi
    fi   # end peer_reachable guard (issue #13)
else
    echo "--- No --server provided; skipping peer-to-peer tests ---"
fi

unset TEST_RESULTS_DESCRIPTION
unset TEST_RESULTS_IDENTIFIER

# === Collect Results to ./benchmark-results/ ===
collect_results

# === Result Files ===
list_result_files

# === Results Summary ===
if [[ "${#FAILED_INSTALLS[@]}" -gt 0 ]]; then
    echo -e "\nWARNING: The following tests failed to install and were skipped:"
    for t in "${FAILED_INSTALLS[@]}"; do
        echo "  - $t"
    done
fi

# === Upload Results if Requested ===
upload_pts_results

echo -e "\n=== Network benchmark complete ==="

if [[ "${#FAILED_INSTALLS[@]}" -gt 0 ]]; then
    exit 1
fi
