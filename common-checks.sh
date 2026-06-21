#!/bin/bash

# Script Name: common-checks.sh
# Version: 1.3.0
#
# Shared library of pre-run check functions, result collection, upload
# helpers, and invocation context setup.  Sourced (not executed) by the
# benchmark-*-pts.sh scripts to eliminate duplicated code.
#
# Author: Ciro Iriarte <ciro.iriarte@gmail.com>
#
# Changelog:
#   - 2026-06-21: v1.3.0 - Fix upload of results whose id contains a dot
#                          (issue #12).  Extract resolve_pts_result_dir() and use
#                          it in both collect_results() and upload_pts_results()
#                          so upload resolution applies the same PTS name
#                          sanitization (lowercase, strip underscores AND dots)
#                          as collection.  Previously upload stripped only
#                          underscores, so a dotted result-id collected fine but
#                          failed to upload.
#   - 2026-06-21: v1.2.0 - Add pts_test_installed(): detect when a PTS test was
#                          not actually installed (build failed or dependency
#                          unavailable) despite batch-install exiting 0, by
#                          checking the pts-install.json completion marker.
#                          Used by the CPU and network scripts to avoid silent
#                          zero-result runs (issue #24).
#   - 2026-03-14: v1.1.0 - Fix collect_results(): PTS lowercases, strips
#                          underscores AND dots from result directory names.
#                          Add all candidate variants to the search.
#   - 2026-03-12: v1.0 - Initial release.  Extracted from benchmark-cpu-pts.sh
#                        (v2.3) and benchmark-memory-pts.sh (v1.8) as the
#                        canonical implementations.  Consolidates:
#                        detect_privileges, confirm_change, check_cpu_governor,
#                        check_thermal, check_system_load, check_steal_time,
#                        setup_invocation_context, collect_results (with
#                        /var/lib/ fallback + underscore handling),
#                        upload_pts_results (with name resolution + echo n
#                        pipe), and list_result_files.
#
# Usage:
#   This file must be sourced, not executed directly:
#
#     SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#     . "${SCRIPT_DIR}/common-checks.sh"
#
#   Callers may override these configuration variables before invoking
#   the check functions:
#     RECOMMENDED_GOVERNOR        (default: "performance")
#     CPU_TEMP_WARN_THRESHOLD_MC  (default: 80000, millidegrees Celsius)
#     LOAD_WARN_MULTIPLIER        (default: 1)
#     STEAL_TIME_WARN_THRESHOLD   (default: 5, percent)
#
#   Callers must set the following before calling collect/upload/list:
#     SCRIPT_INVOCATION_DIR, RUN_ID, SNAPSHOT_FILE, RESULT_NAMES[],
#     INVOKING_USER, INVOKING_GROUP, UPLOAD_RESULTS
#
#   Alternatively, call setup_invocation_context after argument parsing
#   to set SCRIPT_INVOCATION_DIR, INVOKING_USER, INVOKING_GROUP, RUN_ID,
#   and SNAPSHOT_FILE automatically from UPLOAD_ID.

# Guard against direct execution.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    echo "ERROR: common-checks.sh is a library and must be sourced, not executed."
    echo "       Usage: . /path/to/common-checks.sh"
    exit 1
fi

# === Defaults for configuration variables ===
# Callers may override these before invoking check functions.
: "${RECOMMENDED_GOVERNOR:=performance}"
: "${CPU_TEMP_WARN_THRESHOLD_MC:=80000}"
: "${LOAD_WARN_MULTIPLIER:=1}"
: "${STEAL_TIME_WARN_THRESHOLD:=5}"

# === Privilege Detection ===

SUDO_CMD=""
HAS_PRIVILEGE=0

# Detect whether the script has privileges to make system configuration changes.
# Sets HAS_PRIVILEGE=1 and SUDO_CMD if running as root or passwordless sudo
# is available.
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

# === Pre-run Check Functions ===

# Check the CPU frequency governor on all CPUs and offer to set it to
# the recommended value.
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

# Warn if any thermal zone reports a temperature above the configured
# threshold.
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

# Warn if CPU steal time (sampled over 1 second) exceeds the configured
# threshold.  Steal time indicates the hypervisor is withholding CPU
# cycles from this VM.  On physical machines the value is expected to
# be 0.
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

# === Invocation Context ===

# Set up common variables derived from the invocation environment.
# Call after argument parsing so UPLOAD_ID is already set.
#   $1 - default prefix for RUN_ID when UPLOAD_ID is empty
#        (e.g. "storage-benchmark")
setup_invocation_context() {
    local default_prefix="${1:-benchmark}"
    SCRIPT_INVOCATION_DIR=$(pwd)
    INVOKING_USER="${SUDO_USER:-$(whoami)}"
    INVOKING_GROUP=$(id -gn "$INVOKING_USER" 2>/dev/null || echo "$INVOKING_USER")
    RUN_ID="${UPLOAD_ID:-${default_prefix}-$(date +%Y-%m-%d_%H%M%S)}"
    SNAPSHOT_FILE="${RUN_ID}-system-snapshot.txt"
}

# === PTS Install Verification ===

# Return 0 if a PTS test profile is genuinely installed, 1 otherwise.
# PTS batch-install exits 0 even when a build fails or an external dependency is
# unavailable (e.g. pts/compress-7zip on RHEL/Rocky 9, where p7zip is absent
# from EPEL 9): it downloads the source but never writes the pts-install.json
# completion marker.  That marker is the reliable "installed" signal; an
# install-failed.log, when present, is a definitive failure.  Checks both the
# system-wide and per-user PTS install roots.
#   $1 - test id (e.g. pts/compress-7zip)
pts_test_installed() {
    local short="${1##pts/}"
    local base dir
    for base in "/var/lib/phoronix-test-suite/installed-tests/pts" \
                "${HOME}/.phoronix-test-suite/installed-tests/pts"; do
        [[ -d "$base" ]] || continue
        for dir in "${base}/${short}-"*; do
            [[ -d "$dir" ]] || continue
            [[ -f "${dir}/install-failed.log" ]] && return 1
            [[ -f "${dir}/pts-install.json" ]] && return 0
        done
    done
    return 1
}

# === PTS Result Directory Resolution ===

# Resolve a result name to the actual PTS result directory on disk.
# PTS sanitizes result directory names: it lowercases, strips underscores, and
# removes dots (e.g. "cpu-E5-2680v2-opensuse.16.0" becomes
# "cpu-e5-2680v2-opensuse160").  Searches both the system-wide (/var/lib/, root
# installs) and per-user ($HOME/) result stores, trying the original name and
# each sanitized candidate.  Echoes the matching directory path, or nothing if
# none is found.  Used by both collect_results() and upload_pts_results() so the
# two agree on name resolution (issue #12).
#   $1 - result name as recorded in RESULT_NAMES[]
resolve_pts_result_dir() {
    local result_name="$1"
    local lower_name="${result_name,,}"
    local no_underscore="${lower_name//_/}"
    local no_dots="${no_underscore//./}"
    local base candidate
    for base in "/var/lib/phoronix-test-suite/test-results" \
                "$HOME/.phoronix-test-suite/test-results"; do
        [[ -d "$base" ]] || continue
        for candidate in "$result_name" "$lower_name" "$no_underscore" "$no_dots"; do
            if [[ -d "${base}/${candidate}" ]]; then
                echo "${base}/${candidate}"
                return 0
            fi
        done
    done
    return 1
}

# === Result Collection ===

# Copy PTS result directories and the system snapshot into
# ./benchmark-results/<run-id>/ relative to the invocation CWD.
# Searches both /var/lib/ (system-wide PTS) and $HOME/ (user PTS) result
# directories, and handles PTS underscore-stripping of directory names.
# Requires: SCRIPT_INVOCATION_DIR, RUN_ID, SNAPSHOT_FILE, RESULT_NAMES[],
#           INVOKING_USER, INVOKING_GROUP.
collect_results() {
    local output_dir="${SCRIPT_INVOCATION_DIR}/benchmark-results/${RUN_ID}"
    echo "--- Collecting results to ${output_dir} ---"
    mkdir -p "$output_dir"

    if [[ -f "$SNAPSHOT_FILE" ]]; then
        cp "$SNAPSHOT_FILE" "$output_dir/"
        echo "  Copied snapshot: $SNAPSHOT_FILE"
    fi

    local copied=0
    for result_name in "${RESULT_NAMES[@]}"; do
        # Resolve to the actual PTS directory (handles lowercase/underscore/dot
        # sanitization and both result stores) via the shared resolver.
        local pts_result_dir
        pts_result_dir=$(resolve_pts_result_dir "$result_name") || true

        if [[ -n "$pts_result_dir" ]]; then
            cp -r "$pts_result_dir" "$output_dir/"
            echo "  Copied result: $(basename "$pts_result_dir")"
            (( copied++ )) || true
        else
            echo "  WARNING: PTS result directory not found for $result_name"
        fi
    done

    if [[ "$INVOKING_USER" != "root" ]]; then
        chown -R "${INVOKING_USER}:${INVOKING_GROUP}" "$output_dir" 2>/dev/null || true
    fi

    echo "Results collected: ${copied} PTS result(s) + snapshot -> ${output_dir}"
    echo "  Owner: ${INVOKING_USER}:${INVOKING_GROUP}"
}

# === Upload Results ===

# Upload all results in RESULT_NAMES[] to OpenBenchmarking.org.
# Resolves the PTS-sanitized directory name (via the shared resolver so it
# matches collection, including dot-stripping) and pipes 'n' to suppress the
# interactive "attach system logs?" prompt.
# Requires: UPLOAD_RESULTS, RESULT_NAMES[].
upload_pts_results() {
    if [[ "${UPLOAD_RESULTS:-0}" -ne 1 ]]; then
        return
    fi
    echo "--- Uploading results to OpenBenchmarking.org ---"
    for result in "${RESULT_NAMES[@]}"; do
        # upload-result takes the result directory name; resolve it the same way
        # collection does so dotted/underscored/mixed-case ids upload correctly.
        local resolved_dir upload_name
        resolved_dir=$(resolve_pts_result_dir "$result") || true
        if [[ -n "$resolved_dir" ]]; then
            upload_name=$(basename "$resolved_dir")
        else
            echo "  WARNING: PTS result directory not found for $result; trying name as-is."
            upload_name="$result"
        fi
        echo "Uploading: $upload_name"
        # Pipe 'n' to decline the interactive "attach system logs?" prompt
        # that PTS asks during upload (not covered by batch-setup).
        echo n | phoronix-test-suite upload-result "$upload_name"
    done
    echo "All uploads complete."
}

# === Result File Listing ===

# Print a sorted list of all files in the result output directory.
# Requires: SCRIPT_INVOCATION_DIR, RUN_ID.
list_result_files() {
    echo ""
    echo "=== Result Files ==="
    find "${SCRIPT_INVOCATION_DIR}/benchmark-results/${RUN_ID}" -type f 2>/dev/null | sort | while read -r f; do
        echo "  $f"
    done
}
