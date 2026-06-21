#!/bin/bash

# Script Name: install-pts.sh
# Version: 1.8.0
#
# Shared library for installing the Phoronix Test Suite and system-level
# build dependencies.  Sourced (not executed) by the benchmark-*-pts.sh
# scripts.  Consolidates distro detection, PTS installation, openSUSE repo
# management, and the install gate into a single location to eliminate
# drift across scripts.
#
# Author: Ciro Iriarte <ciro.iriarte@gmail.com>
#
# Changelog:
#   - 2026-06-21: v1.8.0 - Add ensure_fio_installed(): install only fio + fs tools
#                          (no full PTS) for benchmark-storage-pts.sh --method
#                          direct, which calls fio directly (issue #25).
#   - 2026-06-21: v1.7.0 - Ensure wget and python3 are installed (issue #17):
#                          wget backs the upstream .deb/tarball fallbacks and
#                          python3 backs the fio/report XML patching, but neither
#                          was guaranteed on minimal images.  Added to the apt and
#                          dnf package sets and wget to zypper (python3 is provided
#                          by the detected python_pkg on openSUSE).
#   - 2026-06-20: v1.6.0 - Make needrestart non-interactive on Debian/Ubuntu via
#                          an /etc/needrestart/conf.d drop-in so PTS test-dependency
#                          installs no longer hang at "Restarting services..."
#                          under nohup/SSH (issues #3, #6, #10).  Add php-gd and a
#                          DejaVu TTF font to PTS dependencies so create-report
#                          PDF/HTML graphs render instead of showing a "PHP GD /
#                          TTF support required" message (issue #7).
#   - 2026-03-12: v1.5.0 - Fix batch-setup comment: answer #4
#                          (PromptForTestIdentifier) uses TEST_RESULTS_IDENTIFIER
#                          env var, not TEST_RESULTS_NAME.
#   - 2026-03-12: v1.4 - Refactor openSUSE PTS install: install build tools and
#                        PHP deps from standard repos first, then attempt PTS from
#                        the benchmark repo.  When the benchmark repo is unreachable
#                        (CDN timeouts on Leap 16.0) or PTS not available, fall
#                        back to upstream tarball install.  Detect php_pkg prefix
#                        (php8 on Leap 16.0+, php on older Leap).
#   - 2026-03-12: v1.3 - Add autoconf to Ubuntu/Debian base packages; PTS maps
#                        build-utilities to build-essential + autoconf and prompts
#                        interactively when autoconf is absent.  Under nohup
#                        (stdin=/dev/null) the prompt loops infinitely.
#   - 2026-03-12: v1.2 - Add configure_pts_batch() to centralise PTS batch-setup
#                        with the correct 7 answers.  Parameterised by
#                        RunAllTestCombinations (Y/N) since that is the only
#                        answer that varies across benchmark scripts.
#   - 2026-03-12: v1.1 - Add bzip2 to Rocky/RHEL dnf install; needed by PTS
#                        to extract .tar.bz2 test archives (e.g. stream).
#   - 2026-03-11: v1.0 - Initial release.  Extracted from benchmark-storage-pts.sh
#                        (v3.6) and benchmark-memory-pts.sh (v1.6) as the most
#                        complete copies.  Adds consolidated bugfixes:
#                        repo idempotency, zypper 106 handling, python_pkg
#                        detection, VERSION_ID-based gcc12 guard.
#
# Usage:
#   This file must be sourced, not executed directly:
#
#     SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#     . "${SCRIPT_DIR}/install-pts.sh"
#
#   Callers may set EXTRA_PKGS_APT, EXTRA_PKGS_DNF, EXTRA_PKGS_ZYPPER arrays
#   before calling ensure_pts_installed to pull in script-specific packages:
#
#     EXTRA_PKGS_APT=(xfsprogs fio)
#     EXTRA_PKGS_DNF=(xfsprogs fio)
#     EXTRA_PKGS_ZYPPER=(xfsprogs fio libaio-devel)
#     ensure_pts_installed

# Guard against direct execution.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    echo "ERROR: install-pts.sh is a library and must be sourced, not executed."
    echo "       Usage: . /path/to/install-pts.sh"
    exit 1
fi

# === Environment Exports ===
# Prevent interactive prompts from dpkg config dialogs and the needrestart
# service-restart checker that ships on Ubuntu 22.04+.  Without these,
# apt-get/dpkg can hang indefinitely when run non-interactively (e.g. via
# nohup or SSH without a TTY).  Set at the top level so they apply to both
# install_pts_packages() and PTS's own internal apt-get calls when it installs
# external test dependencies (e.g. during phoronix-test-suite install).
# Harmless on non-Debian systems where these variables are simply ignored.
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

# === Internal: Upstream PTS Tarball Install ===
# Fallback when PTS is not available from distro/benchmark repos.
# Downloads and installs the upstream Phoronix Test Suite release.
_PTS_UPSTREAM_VERSION="10.8.4"
_PTS_UPSTREAM_URL="https://github.com/phoronix-test-suite/phoronix-test-suite/archive/refs/tags/v${_PTS_UPSTREAM_VERSION}.tar.gz"

_install_pts_from_tarball() {
    echo "Installing PTS ${_PTS_UPSTREAM_VERSION} from upstream tarball..."
    local tarball="/tmp/pts-${_PTS_UPSTREAM_VERSION}.tar.gz"
    wget -q -O "$tarball" "$_PTS_UPSTREAM_URL"
    tar xzf "$tarball" -C /tmp
    (cd "/tmp/phoronix-test-suite-${_PTS_UPSTREAM_VERSION}" && sudo ./install-sh)
    rm -rf "$tarball" "/tmp/phoronix-test-suite-${_PTS_UPSTREAM_VERSION}"
}

# === Internal: openSUSE Package Installation ===
# Handles benchmark repo addition, python/PHP detection, Leap 15.6 gcc12
# management, zypper exit code 106, repo idempotency, and upstream PTS
# fallback when the benchmark repo is unreachable.
_setup_opensuse_repo() {
    local repo_url
    local gcc_extra=""

    # python_pkg: Leap 15.x ships 'python' (Python 2) as a PTS build dependency.
    # Leap 16+ dropped Python 2; the interpreter is a versioned package (e.g.
    # python313). Detect the actual provider of the 'python3' capability so the
    # correct package name is used regardless of the Python version bundled with
    # the release. Tumbleweed/Slowroll also no longer ship plain 'python'.
    local python_pkg
    # --no-refresh: python3 is in the base repos; avoids triggering a refresh
    # of the benchmark repo (which may not yet have its GPG key imported).
    python_pkg=$(zypper --no-refresh -q search --provides --match-exact python3 2>/dev/null \
        | awk -F'|' '/\| python3[0-9]+/{gsub(/ /,"",$2); print $2; exit}')
    : "${python_pkg:=python}"   # fall back to 'python' if detection fails

    # php_pkg: PTS needs php-cli, php-xml (dom + xmlreader + xmlwriter), php-zip,
    # php-openssl, php-zlib, php-bz2, and php-pcntl at runtime.
    # Leap 16.0+ ships php8-* packages; older Leap and Tumbleweed use php*.
    local php_pkg_prefix="php"
    if zypper --no-refresh -q search --match-exact php8-cli &>/dev/null; then
        php_pkg_prefix="php8"
    fi
    local php_pkgs=(
        "${php_pkg_prefix}-cli"
        "${php_pkg_prefix}-dom"
        "${php_pkg_prefix}-xmlreader"
        "${php_pkg_prefix}-xmlwriter"
        "${php_pkg_prefix}-zip"
        "${php_pkg_prefix}-openssl"
        "${php_pkg_prefix}-zlib"
        "${php_pkg_prefix}-bz2"
        "${php_pkg_prefix}-pcntl"
        "${php_pkg_prefix}-gd"
    )

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
    echo "  Python package: ${python_pkg}"
    echo "  PHP packages:   ${php_pkgs[*]}"

    # --- Step 1: Install build tools and PHP from standard repos ---
    # These packages are always available from the base repos and must be
    # installed before PTS (which needs PHP to run).
    local rc=0
    # dejavu-fonts: TTF font required (with php-gd) for create-report graphs (#7).
    # wget: used by the upstream tarball fallback below (issue #17).  python3 is
    # provided by ${python_pkg} (the detected python3 provider).
    sudo zypper install -y gcc gcc-c++ ${gcc_extra} make unzip bzip2 wget dejavu-fonts \
        "${python_pkg}" "${php_pkgs[@]}" "${EXTRA_PKGS_ZYPPER[@]}" || rc=$?
    if [[ "$rc" -ne 0 && "$rc" -ne 106 ]]; then
        echo "ERROR: zypper install (build tools) failed with exit code $rc"
        return "$rc"
    fi

    # Leap 15.6 ships an old GCC as the system default; point alternatives at
    # the gcc12 package that was added to gcc_extra above.  Leap 16+ ships a
    # current GCC as the default so no alternatives change is needed.
    if [[ "$VERSION_ID" == "15.6" ]]; then
        sudo update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-12 100
        sudo update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-12 100
    fi

    # --- Step 2: Install PTS from benchmark repo, with upstream fallback ---
    # Add benchmark repo only if the alias does not already exist (idempotent).
    if sudo zypper lr benchmark &>/dev/null; then
        echo "  Benchmark repo already present; skipping add."
    else
        sudo zypper ar -f -p 90 "$repo_url" benchmark
    fi

    # Refresh may fail transiently (CDN timeouts); do not abort.
    sudo zypper --gpg-auto-import-keys refresh || true

    # Try to install PTS from the benchmark repo.  If the repo is unreachable
    # or PTS is not packaged for this version, fall back to upstream tarball.
    rc=0
    sudo zypper install -y phoronix-test-suite || rc=$?
    if [[ "$rc" -ne 0 && "$rc" -ne 106 ]]; then
        echo "WARNING: PTS not available from benchmark repo (rc=$rc); using upstream tarball."
        _install_pts_from_tarball
    fi
}

# === Install PTS and Build Dependencies ===
# Detects the distro and installs PTS plus common build tools.
# Callers may set EXTRA_PKGS_APT, EXTRA_PKGS_DNF, EXTRA_PKGS_ZYPPER arrays
# before calling to pull in script-specific packages.
install_pts_packages() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "$ID" in
            rocky|rhel|centos)
                echo "Detected Rocky Linux or RHEL-based system"
                sudo dnf install -y epel-release
                # php-gd + dejavu fonts let create-report render PDF/HTML graphs (#7).
                # wget is used by the upstream tarball/.deb fallbacks; python3 by
                # the fio/report XML patching — install both explicitly (#17).
                sudo dnf install -y phoronix-test-suite gcc gcc-c++ make unzip \
                    bzip2 wget python3 php-gd dejavu-sans-fonts "${EXTRA_PKGS_DNF[@]}"
                ;;
            ubuntu|debian)
                echo "Detected Ubuntu or Debian-based system"
                sudo apt-get update
                # php-cli + php-xml are PTS runtime deps (needed when PTS is
                # installed from the upstream .deb rather than the distro repo,
                # which may not pull them automatically).
                # unzip is needed by PTS to extract test archives (.zip).
                # autoconf is part of PTS's build-utilities FileCheck on Ubuntu;
                # without it PTS install prompts interactively — fatal under nohup.
                # php-gd + a TTF font let create-report render PDF/HTML graphs
                # (issue #7); without them PTS embeds a "PHP GD/TTF required" note.
                # wget is used by the .deb/tarball fallbacks; python3 by the
                # fio/report XML patching — install both explicitly (issue #17).
                sudo apt-get install -y build-essential autoconf php-cli php-xml \
                    php-gd fonts-dejavu-core unzip wget python3 "${EXTRA_PKGS_APT[@]}"
                sudo apt-get install -y phoronix-test-suite || {
                    echo "Phoronix Test Suite not found in repo, attempting fallback install..."
                    wget -O /tmp/phoronix.deb https://phoronix-test-suite.com/releases/repo/pts.debian/files/phoronix-test-suite_10.8.4_all.deb
                    # dpkg -i may exit non-zero when optional deps are absent;
                    # apt-get install -f resolves them, so suppress the dpkg error.
                    sudo dpkg -i /tmp/phoronix.deb || true
                    sudo apt-get install -f -y
                }
                ;;
            opensuse*|suse)
                echo "Detected openSUSE system"
                _setup_opensuse_repo
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

# === Non-interactive needrestart ===
# needrestart (default on Ubuntu 22.04+/Debian 12+) prompts to restart services
# after package installs.  PTS installs each test's external dependencies by
# invoking apt itself, which triggers needrestart and blocks at "Restarting
# services..." when there is no controlling terminal (nohup/SSH).  The
# DEBIAN_FRONTEND/NEEDRESTART_MODE env vars do not survive when PTS re-invokes
# apt through sudo (env_reset), so configure needrestart system-wide instead.
# Idempotent and applied every run (also covers hosts where PTS was installed by
# an earlier run, before this fix existed).  See issues #3, #6, #10.
_configure_needrestart_noninteractive() {
    [[ -d /etc/needrestart ]] || return 0
    sudo mkdir -p /etc/needrestart/conf.d 2>/dev/null || return 0
    printf '%s\n' \
        '# Installed by benchmark install-pts.sh: never prompt during package' \
        '# installs so PTS test-dependency installs do not hang under nohup/SSH.' \
        '$nrconf{restart} = "a";' \
        '$nrconf{kernelhints} = -1;' \
        | sudo tee /etc/needrestart/conf.d/00-phoronix-noninteractive.conf \
            >/dev/null 2>&1 || true
}

# === Install Gate ===
# Call this from each benchmark script after setting EXTRA_PKGS_* arrays.
# Skips installation if PTS and PHP are both already present.
ensure_pts_installed() {
    # Make needrestart non-interactive before any apt activity (including PTS's
    # own test-dependency installs) so non-interactive runs do not hang.
    _configure_needrestart_noninteractive
    # Check both PTS and PHP: a prior failed install may leave the PTS binary
    # in place (dpkg iU state) while PHP is still absent, causing PTS to fail
    # immediately with "PHP must be installed".
    if ! command -v phoronix-test-suite &>/dev/null || ! command -v php &>/dev/null; then
        install_pts_packages
    fi
}

# === Lightweight fio Install (direct-fio storage method) ===
# Install only fio + filesystem tools, without the full Phoronix Test Suite.
# Used by benchmark-storage-pts.sh --method direct, which calls fio directly and
# does not need PTS.  Makes needrestart non-interactive first so the apt run does
# not hang under nohup/SSH (issue #6/#10).
ensure_fio_installed() {
    _configure_needrestart_noninteractive
    if command -v fio &>/dev/null && command -v mkfs.xfs &>/dev/null; then
        return 0
    fi
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "$ID" in
            rocky|rhel|centos)
                sudo dnf install -y epel-release || true
                sudo dnf install -y fio xfsprogs util-linux
                ;;
            ubuntu|debian)
                sudo apt-get update
                sudo apt-get install -y fio xfsprogs util-linux
                ;;
            opensuse*|suse)
                sudo zypper install -y fio xfsprogs util-linux || true
                ;;
            *)
                echo "Unsupported OS for fio install: $ID"; exit 1
                ;;
        esac
    else
        echo "Cannot detect OS. /etc/os-release not found."; exit 1
    fi
    if ! command -v fio &>/dev/null; then
        echo "ERROR: fio installation failed; cannot run --method direct."
        exit 1
    fi
}

# === PTS Batch Mode Configuration ===
# Configures PTS for non-interactive batch operation.
#   $1 - RunAllTestCombinations: Y to exercise every sub-option permutation,
#        N to use PRESET_OPTIONS for selective test invocation.
#
# PTS batch-setup prompts (7 total):
#   1. SaveResults                 = Y  (persist results to disk)
#   2. OpenBrowser                 = N  (no GUI in headless mode)
#   3. UploadResults               = N  (manual upload via --upload flag)
#   4. PromptForTestIdentifier     = N  (use TEST_RESULTS_IDENTIFIER env var)
#   5. PromptForTestDescription    = N  (use TEST_RESULTS_DESCRIPTION env var)
#   6. PromptSaveName              = N  (auto-save; prompting hangs non-interactive runs)
#   7. RunAllTestCombinations      = $1
configure_pts_batch() {
    local run_all="${1:-N}"
    echo "Setting up Phoronix Test Suite in batch mode (RunAllTestCombinations=${run_all})..."
    phoronix-test-suite batch-setup <<EOF
Y
N
N
N
N
N
${run_all}
EOF
}
