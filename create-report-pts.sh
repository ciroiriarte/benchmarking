#!/bin/bash

# Script Name: create-report-pts.sh
# Description: Generate PTS comparison reports from benchmark-results directories.
#              Accepts N run directories (N>=1) produced by any benchmark-*-pts.sh
#              script. Groups PTS results by test identifier, merges when N>1, and
#              exports reports in all supported formats: text, CSV, JSON, HTML, PDF.
#
#              When multiple runs are supplied, system identifiers are rewritten
#              to user-friendly labels (auto-detected from OS or via --label) so
#              that PTS comparison charts show distinguishable bars per system.
#
# Author: Ciro Iriarte <ciro.iriarte@gmail.com>
# Version: 1.3.0
#
# Changelog:
#   - 2026-03-21: v1.3.0 - Fix SIGPIPE (exit 141) caused by grep|head pipelines
#                           under set -eo pipefail; use grep -m1 and find -quit.
#                           Fix variant grouping for timestamp-named result dirs:
#                           derive variant from PTS test type + disk label instead
#                           of directory name prefix stripping
#   - 2026-03-13: v1.2.1 - Fix HTML/PDF export: capture stdout for formats that
#                           print content instead of writing files, and broaden
#                           file search to cover PTS version-dependent locations
#   - 2026-03-13: v1.2.0 - Add --identifier flag: sets a custom system identifier
#                           applied to all run directories that lack an explicit
#                           --label override. Takes priority over OS auto-detection.
#   - 2026-03-13: v1.1 - Add --label for friendly system identifiers,
#                         auto-detect OS label from XML, rewrite identifiers
#                         in imported copies, skip results with no data
#   - 2026-02-26: v1.0 - Initial implementation

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
readonly SCRIPT_VERSION="1.3.0"
readonly SCRIPT_NAME=$(basename "$0")
readonly TIMESTAMP=$(date +%Y%m%d-%H%M%S)

# Temp prefix used to register imported PTS result entries — must be unique
# per invocation so cleanup does not collide with user-named results.
readonly TEMP_PREFIX="pts_report_${TIMESTAMP}"

# Default output directory
readonly DEFAULT_OUTPUT_DIR="./pts-reports/${TIMESTAMP}"

# PTS export formats:
#   stdout-only — result-file-to-text, result-file-to-csv, result-file-to-json
#   file/mixed  — result-file-to-html, result-file-to-pdf  (may use stdout or file)
readonly FORMAT_STDOUT_FORMATS=("text" "csv" "json")
readonly FORMAT_FILE_FORMATS=("html" "pdf")

# ---------------------------------------------------------------------------
# State tracking (populated at runtime)
# ---------------------------------------------------------------------------
TEMP_RESULT_NAMES=()   # All temp entries imported to PTS test-results
MERGED_RESULT_NAMES=() # Merged result entries created by merge-results

# ---------------------------------------------------------------------------
# Argument defaults
# ---------------------------------------------------------------------------
OUTPUT_DIR=""
RUN_DIRS=()
declare -A LABEL_MAP  # run_dir (stripped of trailing /) → friendly label
CUSTOM_IDENTIFIER=""  # --identifier value; overrides OS auto-detection

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [OPTIONS] <run-dir> [<run-dir> ...]

  Generate PTS reports comparing N benchmark runs.
  Each <run-dir> must be a directory previously produced by a
  benchmark-*-pts.sh script (e.g. ./benchmark-results/my-run/).

  PTS results are detected automatically. Runs are grouped by PTS test
  identifier and merged when more than one run is supplied. Reports are
  exported in all supported formats: text, CSV, JSON, HTML, PDF.

  System identifiers in the XML are rewritten to friendly labels before
  merging, so comparison charts show distinguishable bars per system.
  Labels are auto-detected from the OS field in composite.xml, or can
  be overridden with --label.

OPTIONS:
  -o, --output-dir <path>   Directory where reports are written.
                            Default: ./pts-reports/<timestamp>/
  -l, --label <dir>=<label> Assign a friendly label to a run directory.
                            May be repeated. Overrides auto-detection.
  --identifier <value>      Set a custom system identifier for all run
                            directories. Overrides OS auto-detection but
                            yields to per-directory --label overrides.
  -h, --help                Show this help message

EXAMPLES:
  # Single run — export all format reports for each PTS test found
  ${SCRIPT_NAME} ./benchmark-results/dc1-node3-ddr5/

  # Two runs — merge same-type tests and compare
  ${SCRIPT_NAME} ./benchmark-results/dc1-node3-ddr5/ ./benchmark-results/dc2-node1-ddr4/

  # Three distros with explicit labels
  ${SCRIPT_NAME} -o ./report-samples/memory \\
      --label "./results/opensuse=openSUSE 16.0" \\
      --label "./results/rocky=Rocky Linux 9" \\
      --label "./results/ubuntu=Ubuntu 24.04" \\
      ./results/opensuse ./results/rocky ./results/ubuntu

  # Custom output directory
  ${SCRIPT_NAME} --output-dir /tmp/my-reports ./benchmark-results/run-a/ ./benchmark-results/run-b/
EOF
}

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
log()  { echo "[${SCRIPT_NAME}] $*"; }
warn() { echo "[${SCRIPT_NAME}] WARNING: $*" >&2; }
die()  { echo "[${SCRIPT_NAME}] ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
parse_args() {
    if [[ $# -eq 0 ]]; then
        usage
        exit 1
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -o|--output-dir)
                [[ $# -lt 2 ]] && die "--output-dir requires an argument"
                OUTPUT_DIR="$2"
                shift 2
                ;;
            -l|--label)
                [[ $# -lt 2 ]] && die "--label requires an argument in dir=label format"
                local label_key label_val
                label_key="${2%%=*}"
                label_val="${2#*=}"
                [[ "$label_key" == "$2" ]] && die "--label format must be dir=label (got: $2)"
                # Normalize: strip trailing slash from the key
                LABEL_MAP["${label_key%/}"]="$label_val"
                shift 2
                ;;
            --identifier)
                [[ $# -lt 2 ]] && die "--identifier requires an argument"
                CUSTOM_IDENTIFIER="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            -*)
                die "Unknown option: $1"
                ;;
            *)
                RUN_DIRS+=("$1")
                shift
                ;;
        esac
    done

    [[ ${#RUN_DIRS[@]} -eq 0 ]] && { usage; exit 1; }

    OUTPUT_DIR="${OUTPUT_DIR:-${DEFAULT_OUTPUT_DIR}}"
}

# ---------------------------------------------------------------------------
# Prerequisite checks
# ---------------------------------------------------------------------------
check_prerequisites() {
    command -v phoronix-test-suite &>/dev/null \
        || die "phoronix-test-suite not found. Run any benchmark-*-pts.sh first to install it."

    for dir in "${RUN_DIRS[@]}"; do
        [[ -d "$dir" ]] || die "Run directory not found: $dir"
    done
}

# ---------------------------------------------------------------------------
# extract_os_label <composite.xml>
#
# Extracts the OS name from the <Software> element for use as a fallback
# system label. e.g. "OS: openSUSE Leap 16.0, Kernel: ..." → "openSUSE Leap 16.0"
# ---------------------------------------------------------------------------
extract_os_label() {
    local xml_file="$1"
    grep -m1 -oP 'OS: \K[^,]+' "$xml_file" 2>/dev/null
}

# ---------------------------------------------------------------------------
# get_label_for_dir <run-dir>
#
# Returns the friendly label for a run directory. Checks LABEL_MAP first,
# then auto-detects from the first composite.xml's OS field, then falls
# back to the directory basename.
# ---------------------------------------------------------------------------
get_label_for_dir() {
    local run_dir="${1%/}"

    # 1. Explicit --label mapping (per-directory override)
    if [[ -n "${LABEL_MAP[$run_dir]+x}" ]]; then
        echo "${LABEL_MAP[$run_dir]}"
        return
    fi

    # 2. --identifier global override (takes priority over OS auto-detection)
    if [[ -n "$CUSTOM_IDENTIFIER" ]]; then
        echo "$CUSTOM_IDENTIFIER"
        return
    fi

    # 3. Auto-detect from the first composite.xml's Software/OS field
    local first_xml
    first_xml=$(find "$run_dir" -name composite.xml -type f -print -quit 2>/dev/null)
    if [[ -n "$first_xml" ]]; then
        local os_label
        os_label=$(extract_os_label "$first_xml")
        if [[ -n "$os_label" ]]; then
            echo "$os_label"
            return
        fi
    fi

    # 4. Fallback to directory name
    basename "$run_dir"
}

# ---------------------------------------------------------------------------
# rewrite_identifiers <pts-result-dir> <new-label>
#
# Rewrites the system identifier in a PTS result's composite.xml so that
# comparison charts show a friendly label instead of the hardware name.
# Operates on the COPY in PTS test-results, never on the original.
# ---------------------------------------------------------------------------
rewrite_identifiers() {
    local result_dir="$1"
    local new_label="$2"
    local xml="${result_dir}/composite.xml"

    [[ -f "$xml" ]] || return

    python3 - "$xml" "$new_label" <<'PYEOF'
import sys

xml_file = sys.argv[1]
new_label = sys.argv[2]

with open(xml_file, "r") as f:
    content = f.read()

# Extract current system identifier from <System><Identifier>...</Identifier>
import re
match = re.search(r"<System>\s*<Identifier>([^<]+)</Identifier>", content)
if not match:
    sys.exit(0)

old_id = match.group(1)

# Replace all occurrences of the old system identifier in <Identifier> tags.
# Test identifiers (e.g. "pts/cachebench-1.2.0") won't match the system ID.
content = content.replace(
    f"<Identifier>{old_id}</Identifier>",
    f"<Identifier>{new_label}</Identifier>",
)

with open(xml_file, "w") as f:
    f.write(content)
PYEOF
}

# ---------------------------------------------------------------------------
# has_valid_results <composite.xml>
#
# Returns 0 (true) if the composite.xml contains at least one Result with
# a non-empty <Value>. Used to skip tests that ran but produced no data.
# ---------------------------------------------------------------------------
has_valid_results() {
    local xml_file="$1"
    grep -q '<Value>[^<]\+</Value>' "$xml_file"
}

# ---------------------------------------------------------------------------
# find_pts_result_dirs <run-dir>
#
# Prints (one per line) every subdirectory inside <run-dir> that contains a
# composite.xml file — these are the individual PTS test result directories.
# ---------------------------------------------------------------------------
find_pts_result_dirs() {
    local run_dir="$1"
    # Use find to locate composite.xml; print the containing directory.
    find "$run_dir" -name "composite.xml" -type f \
        | xargs -r -I{} dirname {} \
        | sort
}

# ---------------------------------------------------------------------------
# get_pts_identifier <composite.xml path>
#
# Extracts the first PTS test identifier (e.g. "pts/fio-2.2.0") from the
# composite.xml <Result><Identifier> element. Returns the identifier or an
# empty string. Searches inside <Result> blocks to avoid matching the
# <System><Identifier> (which is the hardware/system name).
# ---------------------------------------------------------------------------
get_pts_identifier() {
    local xml_file="$1"
    # Match <Identifier>pts/...</Identifier> — PTS test IDs always start with "pts/"
    grep -m1 -oP '<Identifier>\Kpts/[^<]+' "$xml_file"
}

# ---------------------------------------------------------------------------
# get_pts_test_type <pts-identifier>
#
# Strips the version suffix to get a stable grouping key.
# e.g. "pts/fio-2.2.0" → "pts/fio"
# ---------------------------------------------------------------------------
get_pts_test_type() {
    local identifier="$1"
    # Remove trailing -<version> component
    echo "$identifier" | sed 's/-[0-9][0-9.]*$//'
}

# ---------------------------------------------------------------------------
# get_result_variant <result-dir-basename> <run-dir-basename>
#
# Derives a test-variant key by stripping the run-dir prefix from the result
# directory name. This gives a finer grouping than test type alone — e.g.
# "netperftcpmaerts" instead of "pts/netperf" — so that each composite.xml
# maps to exactly one group, avoiding duplicate system entries after merge.
#
# Example:
#   result_basename: "net-peer-opensuse16netperftcpmaerts"
#   run_basename:    "net-peer-opensuse16"
#   → "netperftcpmaerts"
# ---------------------------------------------------------------------------
get_result_variant() {
    local result_basename="$1"
    local run_basename="$2"
    echo "${result_basename#"${run_basename}"}"
}

# ---------------------------------------------------------------------------
# extract_disk_label <composite.xml>
#
# Extracts the disk mount-point label from a PTS result. Looks for
# "Disk Target: /mnt/LABEL" in <Description> elements (used by fio).
# Returns the label (e.g. "vSSD") or an empty string.
# ---------------------------------------------------------------------------
extract_disk_label() {
    local xml_file="$1"
    grep -m1 -oP 'Disk Target: /mnt/\K[^<"]+' "$xml_file" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# import_result <src-pts-result-dir> <temp-name>
#
# Copies a PTS result directory into the PTS test-results store under a
# temporary name so phoronix-test-suite can reference it by name.
# Registers the name in TEMP_RESULT_NAMES for cleanup.
# ---------------------------------------------------------------------------
import_result() {
    local src_dir="$1"
    local temp_name="$2"

    local pts_results_dir
    pts_results_dir="${HOME}/.phoronix-test-suite/test-results"

    mkdir -p "${pts_results_dir}/${temp_name}"
    cp -r "${src_dir}/." "${pts_results_dir}/${temp_name}/"

    TEMP_RESULT_NAMES+=("$temp_name")
    log "  Imported: $(basename "$src_dir") → ${temp_name}"
}

# ---------------------------------------------------------------------------
# cleanup_temp_results
#
# Removes all temporary entries from the PTS test-results store.
# Called via EXIT trap.
# ---------------------------------------------------------------------------
cleanup_temp_results() {
    local pts_results_dir="${HOME}/.phoronix-test-suite/test-results"
    local name

    for name in "${TEMP_RESULT_NAMES[@]}" "${MERGED_RESULT_NAMES[@]}"; do
        local target="${pts_results_dir}/${name}"
        if [[ -d "$target" ]]; then
            rm -rf "$target"
            log "  Cleaned up temp result: ${name}"
        fi
    done
}

# ---------------------------------------------------------------------------
# merge_results <merged-name> <temp-name-1> [<temp-name-2> ...]
#
# Calls phoronix-test-suite merge-results to combine N imported results into
# a single comparison result. PTS always saves to merge-XXXX, so we capture
# the actual path from stdout and rename to our desired name.
# ---------------------------------------------------------------------------
merge_results() {
    local merged_name="$1"
    shift
    local names=("$@")

    log "  Merging ${#names[@]} results → ${merged_name}"

    local pts_results_dir="${HOME}/.phoronix-test-suite/test-results"
    local merge_output
    merge_output=$(echo "n" | phoronix-test-suite merge-results "${names[@]}" 2>&1) \
        || warn "merge-results returned non-zero for ${merged_name}"

    # PTS prints: "Merged Results Saved To: /path/merge-XXXX/composite.xml"
    local merge_path
    merge_path=$(echo "$merge_output" | grep -oP 'Merged Results Saved To: \K[^\s]+')

    if [[ -n "$merge_path" ]]; then
        local merge_dir
        merge_dir=$(dirname "$merge_path")
        local merge_basename
        merge_basename=$(basename "$merge_dir")

        # Rename merge-XXXX → our desired name
        mv "${merge_dir}" "${pts_results_dir}/${merged_name}"
        log "  Renamed ${merge_basename} → ${merged_name}"
        MERGED_RESULT_NAMES+=("$merged_name")
    else
        warn "Could not determine merge output path for ${merged_name}"
        # Try to find the most recent merge-* directory as fallback
        local latest_merge
        latest_merge=$(ls -td "${pts_results_dir}"/merge-* 2>/dev/null | head -1 || true)
        if [[ -n "$latest_merge" ]]; then
            mv "$latest_merge" "${pts_results_dir}/${merged_name}"
            MERGED_RESULT_NAMES+=("$merged_name")
        fi
    fi
}

# ---------------------------------------------------------------------------
# export_formats <pts-result-name> <output-dir> <label>
#
# Exports a PTS result in all supported formats.
#   stdout formats (text, csv, json): capture to file
#   file   formats (html, pdf):       PTS respects OUTPUT_DIR / OUTPUT_FILE
# ---------------------------------------------------------------------------
export_formats() {
    local result_name="$1"
    local output_dir="$2"
    local label="$3"

    local format

    # Stdout-based formats
    for format in "${FORMAT_STDOUT_FORMATS[@]}"; do
        local out_file="${output_dir}/${label}.${format}"
        log "  Exporting ${format} → ${out_file}"
        phoronix-test-suite "result-file-to-${format}" "$result_name" \
            > "$out_file" 2>/dev/null \
            || warn "result-file-to-${format} returned non-zero for ${result_name}"
    done

    # File-based formats — PTS may write to a file at various locations OR
    # print content to stdout, depending on the PTS version and format.
    # Strategy: capture stdout to the target file; if it produces real
    # content we're done, otherwise search common PTS output locations.
    local abs_output_dir
    abs_output_dir=$(cd "$output_dir" && pwd)

    for format in "${FORMAT_FILE_FORMATS[@]}"; do
        local out_file="${output_dir}/${label}.${format}"
        local abs_out_file="${abs_output_dir}/${label}.${format}"
        log "  Exporting ${format} → ${out_file}"

        # Capture stdout → output file (covers formats that print to stdout)
        phoronix-test-suite "result-file-to-${format}" "$result_name" \
            > "$abs_out_file" 2>/dev/null \
            || true

        # If stdout produced a non-trivial file (> 100 bytes), accept it
        if [[ -f "$abs_out_file" ]] && [[ $(wc -c < "$abs_out_file") -gt 100 ]]; then
            log "    Saved: ${out_file}"
            continue
        fi

        # stdout was empty/trivial — remove placeholder and search elsewhere
        rm -f "$abs_out_file"

        local found=""
        local candidate
        local pts_results_base="${HOME}/.phoronix-test-suite/test-results"
        for candidate in \
            "${HOME}/${result_name}.${format}" \
            "$(pwd)/${result_name}.${format}" \
            "${pts_results_base}/${result_name}/${result_name}.${format}" \
            ; do
            if [[ -f "$candidate" ]]; then
                found="$candidate"
                break
            fi
        done

        # Last resort: any matching file inside the PTS result directory
        if [[ -z "$found" ]]; then
            found=$(find "${pts_results_base}/${result_name}" -maxdepth 1 \
                -name "*.${format}" -type f -print -quit 2>/dev/null)
        fi

        if [[ -n "$found" ]]; then
            mv "$found" "$out_file"
            log "    Moved: ${found} → ${out_file}"
        else
            warn "result-file-to-${format}: output not found for ${result_name}"
        fi
    done
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"
    check_prerequisites

    trap cleanup_temp_results EXIT

    log "create-report-pts.sh v${SCRIPT_VERSION}"
    log "Output directory: ${OUTPUT_DIR}"
    log "Run directories (${#RUN_DIRS[@]}):"
    for dir in "${RUN_DIRS[@]}"; do
        log "  ${dir}"
    done

    mkdir -p "$OUTPUT_DIR"

    # ------------------------------------------------------------------
    # Phase 1: Discover and import all PTS results from every run-dir.
    # Build a map: variant → list of temp result names
    #
    # The variant key groups same-test results across run directories.
    # Primary method: strip the run-dir prefix from the result directory
    # name (e.g. "net-peer-opensuse16netperftcpmaerts" minus
    # "net-peer-opensuse16" → "netperftcpmaerts").
    #
    # Fallback (timestamp dirs): when the result directory name does not
    # start with the run-dir prefix (e.g. "2026-03-17-2326"), derive
    # the variant from the PTS test type + disk label extracted from the
    # composite.xml, or a positional counter for tests without disk info.
    # ------------------------------------------------------------------
    # Bash 4 associative array: variant → space-separated temp names
    declare -A VARIANT_TO_NAMES

    # Per-run, per-test-type counter for position-based disk labeling
    declare -A _TEST_TYPE_COUNTER

    local run_idx=0
    for run_dir in "${RUN_DIRS[@]}"; do
        run_dir="${run_dir%/}"  # strip trailing slash
        local friendly_label
        friendly_label=$(get_label_for_dir "$run_dir")
        local run_basename
        run_basename=$(basename "$run_dir")
        log "Scanning run directory: ${run_dir} (label: ${friendly_label})"

        local result_dir
        while IFS= read -r result_dir; do
            [[ -z "$result_dir" ]] && continue
            local xml="${result_dir}/composite.xml"
            [[ -f "$xml" ]] || continue

            # Skip results with no actual data (e.g. tests that errored out)
            if ! has_valid_results "$xml"; then
                warn "No valid results in ${xml}, skipping."
                continue
            fi

            local pts_id
            pts_id=$(get_pts_identifier "$xml")
            if [[ -z "$pts_id" ]]; then
                warn "Could not extract PTS identifier from ${xml}, skipping."
                continue
            fi

            local result_basename
            result_basename=$(basename "$result_dir")

            # Derive the test variant key
            local variant
            variant=$(get_result_variant "$result_basename" "$run_basename")

            # If prefix stripping had no effect (result dir is not prefixed
            # by run-dir name, e.g. timestamp-based directories), fall back
            # to a semantic variant based on the PTS test type + disk label.
            if [[ "$variant" == "$result_basename" ]]; then
                local test_short
                test_short=$(get_pts_test_type "$pts_id")
                test_short="${test_short##*/}"  # "pts/fio" → "fio"

                # Try to extract disk label from composite.xml (fio has it)
                local disk_label
                disk_label=$(extract_disk_label "$xml")

                if [[ -z "$disk_label" ]]; then
                    # Position-based fallback: 1st occurrence = disk1, etc.
                    local counter_key="r${run_idx}_${test_short}"
                    local count=${_TEST_TYPE_COUNTER[$counter_key]:-0}
                    (( count++ )) || true  # avoid set -e on (( 0 ))
                    _TEST_TYPE_COUNTER[$counter_key]=$count
                    disk_label="disk${count}"
                fi

                variant="${test_short}-${disk_label}"
            fi

            local temp_name="${TEMP_PREFIX}_r${run_idx}_${result_basename}"

            log "Found: ${pts_id} (variant: ${variant}) in run ${friendly_label}"
            import_result "$result_dir" "$temp_name"

            # Rewrite system identifiers to the friendly label (on the COPY)
            local pts_results_dir="${HOME}/.phoronix-test-suite/test-results"
            rewrite_identifiers "${pts_results_dir}/${temp_name}" "$friendly_label"

            # Append to the associative array entry
            if [[ -n "${VARIANT_TO_NAMES[$variant]+x}" ]]; then
                VARIANT_TO_NAMES[$variant]+=" $temp_name"
            else
                VARIANT_TO_NAMES[$variant]="$temp_name"
            fi
        done < <(find_pts_result_dirs "$run_dir")

        (( run_idx++ )) || true
    done

    if [[ ${#VARIANT_TO_NAMES[@]} -eq 0 ]]; then
        die "No PTS results found in the supplied run directories."
    fi

    # ------------------------------------------------------------------
    # Phase 2: For each variant, merge (if N>1) then export all formats
    # ------------------------------------------------------------------
    log "---"
    log "Generating reports for ${#VARIANT_TO_NAMES[@]} test variant(s)..."

    local variant
    for variant in $(printf '%s\n' "${!VARIANT_TO_NAMES[@]}" | sort); do
        # Convert space-separated string back to array
        read -ra names <<< "${VARIANT_TO_NAMES[$variant]}"
        local count="${#names[@]}"

        local report_name

        if [[ $count -gt 1 ]]; then
            report_name="${TEMP_PREFIX}_merged_${variant}"
            log "Merging ${count} results for variant: ${variant}"
            merge_results "$report_name" "${names[@]}"
        else
            report_name="${names[0]}"
            log "Single result for variant: ${variant}"
        fi

        local report_output_dir="${OUTPUT_DIR}/${variant}"
        mkdir -p "$report_output_dir"

        export_formats "$report_name" "$report_output_dir" "$variant"
    done

    # ------------------------------------------------------------------
    # Phase 3: Summary
    # ------------------------------------------------------------------
    log "---"
    log "Reports written to: ${OUTPUT_DIR}"
    log ""
    log "Generated files:"
    find "$OUTPUT_DIR" -type f | sort | while read -r f; do
        log "  ${f}"
    done
}

main "$@"
