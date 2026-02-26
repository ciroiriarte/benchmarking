#!/bin/bash

# Script Name: create-report-pts.sh
# Description: Generate PTS comparison reports from benchmark-results directories.
#              Accepts N run directories (N>=1) produced by any benchmark-*-pts.sh
#              script. Groups PTS results by test identifier, merges when N>1, and
#              exports reports in all supported formats: text, CSV, JSON, HTML, PDF.
#
# Author: Ciro Iriarte <ciro.iriarte@gmail.com>
# Version: 1.0
#
# Changelog:
#   - 2026-02-26: v1.0 - Initial implementation

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
readonly SCRIPT_VERSION="1.0"
readonly SCRIPT_NAME=$(basename "$0")
readonly TIMESTAMP=$(date +%Y%m%d-%H%M%S)

# Temp prefix used to register imported PTS result entries — must be unique
# per invocation so cleanup does not collide with user-named results.
readonly TEMP_PREFIX="pts_report_${TIMESTAMP}"

# Default output directory
readonly DEFAULT_OUTPUT_DIR="./pts-reports/${TIMESTAMP}"

# PTS export formats and how each delivers its output:
#   stdout  — result-file-to-text, result-file-to-csv, result-file-to-json
#   file    — result-file-to-html, result-file-to-pdf  (writes to CWD)
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

OPTIONS:
  -o, --output-dir <path>   Directory where reports are written.
                            Default: ./pts-reports/<timestamp>/
  -h, --help                Show this help message

EXAMPLES:
  # Single run — export all format reports for each PTS test found
  ${SCRIPT_NAME} ./benchmark-results/dc1-node3-ddr5/

  # Two runs — merge same-type tests and compare
  ${SCRIPT_NAME} ./benchmark-results/dc1-node3-ddr5/ ./benchmark-results/dc2-node1-ddr4/

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
# composite.xml Result element. Returns the identifier or an empty string.
# ---------------------------------------------------------------------------
get_pts_identifier() {
    local xml_file="$1"
    # The Identifier element looks like: <Identifier>pts/fio-2.2.0</Identifier>
    grep -o '<Identifier>[^<]*</Identifier>' "$xml_file" \
        | head -1 \
        | sed 's|<[^>]*>||g'
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
# a single comparison result. TEST_RESULTS_NAME pre-answers the save-as
# prompt so the command runs non-interactively.
# ---------------------------------------------------------------------------
merge_results() {
    local merged_name="$1"
    shift
    local names=("$@")

    log "  Merging ${#names[@]} results → ${merged_name}"

    TEST_RESULTS_NAME="$merged_name" \
        phoronix-test-suite merge-results "${names[@]}" \
        > /dev/null 2>&1 \
        || warn "merge-results returned non-zero for ${merged_name}"

    MERGED_RESULT_NAMES+=("$merged_name")
}

# ---------------------------------------------------------------------------
# export_formats <pts-result-name> <output-dir> <label>
#
# Exports a PTS result in all supported formats.
#   stdout formats (text, csv, json): capture to file
#   file   formats (html, pdf):       PTS writes the file to CWD; move it
# ---------------------------------------------------------------------------
export_formats() {
    local result_name="$1"
    local output_dir="$2"
    local label="$3"

    local format
    local tmp_cwd
    tmp_cwd=$(mktemp -d)

    # Stdout-based formats
    for format in "${FORMAT_STDOUT_FORMATS[@]}"; do
        local out_file="${output_dir}/${label}.${format}"
        log "  Exporting ${format} → ${out_file}"
        phoronix-test-suite "result-file-to-${format}" "$result_name" \
            > "$out_file" 2>/dev/null \
            || warn "result-file-to-${format} returned non-zero for ${result_name}"
    done

    # File-based formats (PTS writes to CWD)
    for format in "${FORMAT_FILE_FORMATS[@]}"; do
        local out_file="${output_dir}/${label}.${format}"
        log "  Exporting ${format} → ${out_file}"
        (
            cd "$tmp_cwd"
            phoronix-test-suite "result-file-to-${format}" "$result_name" \
                > /dev/null 2>&1 \
                || true
        )
        # PTS writes <result-name>.{html,pdf} in the CWD
        local pts_out="${tmp_cwd}/${result_name}.${format}"
        if [[ -f "$pts_out" ]]; then
            mv "$pts_out" "$out_file"
        else
            warn "result-file-to-${format}: expected output not found (${pts_out})"
        fi
    done

    rm -rf "$tmp_cwd"
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
    # Build a map: test_type → list of temp result names
    # ------------------------------------------------------------------
    # Bash 4 associative array: test_type → space-separated temp names
    declare -A TYPE_TO_NAMES

    local run_idx=0
    for run_dir in "${RUN_DIRS[@]}"; do
        run_dir="${run_dir%/}"  # strip trailing slash
        local run_label
        run_label=$(basename "$run_dir")
        log "Scanning run directory: ${run_dir}"

        local result_dir
        while IFS= read -r result_dir; do
            [[ -z "$result_dir" ]] && continue
            local xml="${result_dir}/composite.xml"
            [[ -f "$xml" ]] || continue

            local pts_id
            pts_id=$(get_pts_identifier "$xml")
            if [[ -z "$pts_id" ]]; then
                warn "Could not extract PTS identifier from ${xml}, skipping."
                continue
            fi

            local test_type
            test_type=$(get_pts_test_type "$pts_id")

            local result_basename
            result_basename=$(basename "$result_dir")

            local temp_name="${TEMP_PREFIX}_r${run_idx}_${result_basename}"

            log "Found: ${pts_id} (type: ${test_type}) in run ${run_label}"
            import_result "$result_dir" "$temp_name"

            # Append to the associative array entry
            if [[ -n "${TYPE_TO_NAMES[$test_type]+x}" ]]; then
                TYPE_TO_NAMES[$test_type]+=" $temp_name"
            else
                TYPE_TO_NAMES[$test_type]="$temp_name"
            fi
        done < <(find_pts_result_dirs "$run_dir")

        (( run_idx++ )) || true
    done

    if [[ ${#TYPE_TO_NAMES[@]} -eq 0 ]]; then
        die "No PTS results found in the supplied run directories."
    fi

    # ------------------------------------------------------------------
    # Phase 2: For each test type, merge (if N>1) then export all formats
    # ------------------------------------------------------------------
    log "---"
    log "Generating reports for ${#TYPE_TO_NAMES[@]} test type(s)..."

    local test_type
    for test_type in "${!TYPE_TO_NAMES[@]}"; do
        # Convert space-separated string back to array
        read -ra names <<< "${TYPE_TO_NAMES[$test_type]}"
        local count="${#names[@]}"

        # Sanitize test_type for use as filename component (replace / with -)
        local safe_type="${test_type//\//-}"
        local report_name

        if [[ $count -gt 1 ]]; then
            report_name="${TEMP_PREFIX}_merged_${safe_type}"
            log "Merging ${count} results for test type: ${test_type}"
            merge_results "$report_name" "${names[@]}"
        else
            report_name="${names[0]}"
            log "Single result for test type: ${test_type}"
        fi

        local report_output_dir="${OUTPUT_DIR}/${safe_type}"
        mkdir -p "$report_output_dir"

        export_formats "$report_name" "$report_output_dir" "$safe_type"
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
