#!/bin/bash
set -euo pipefail

# Overlay the bcachefs graphdriver onto an unpacked containers/storage tree.
#
# Usage: apply-driver.sh [--module PATH] [--strip-tests] <storage-tree> <driver-dir>
#
# <storage-tree> is a directory containing drivers/ and pkg/archive/ — either a
# containers/storage source tree or podman's vendor/go.podman.io/storage.

usage() {
    echo "usage: apply-driver.sh [--module PATH] [--strip-tests] <storage-tree> <driver-dir>" >&2
    exit 2
}

module=""
strip_tests=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --module) [[ $# -ge 2 ]] || usage; module="$2"; shift 2 ;;
        --strip-tests) strip_tests=1; shift ;;
        --) shift; break ;;
        -*) echo "unknown option: $1" >&2; usage ;;
        *) break ;;
    esac
done

[[ $# -eq 2 ]] || usage

src="$1"
driver="$2"
linux="$src/drivers/driver_linux.go"

for f in "$linux" "$driver/bcachefs.go"; do
    [[ -f "$f" ]] || { echo "missing $f" >&2; exit 1; }
done

install -d "$src/drivers/bcachefs"
install -m 0644 "$driver/bcachefs.go" "$driver/dummy_unsupported.go" "$src/drivers/bcachefs/"
install -m 0644 "$driver/register_bcachefs.go" "$src/drivers/register/"
install -m 0644 "$driver/changes_full.go" "$src/pkg/archive/"

if [[ $strip_tests -eq 0 ]]; then
    install -m 0644 "$driver/bcachefs_test.go" "$src/drivers/bcachefs/"
fi

# storage >= 1.60 renamed the module to go.podman.io/storage
if [[ -n "$module" && "$module" != "github.com/containers/storage" ]]; then
    find "$src/drivers/bcachefs" \
         "$src/drivers/register/register_bcachefs.go" \
         "$src/pkg/archive/changes_full.go" \
         -name '*.go' -exec sed -i "s|github.com/containers/storage|$module|g" {} +
fi

# driver_linux.go needs three independent edits. Each is guarded and verified
# separately: a single shared guard would skip edits that are still missing, and
# a single shared check would let a reformatted upstream silently no-op two of
# them while the build still succeeds — yielding a driver that never appears in
# Priority/FsNames. awk does the anchored matching because `grep` may be ugrep.
has_const()    { grep -qF 'FsMagicBcachefs = FsMagic(0xca451a4e)' "$linux"; }
has_fsname()   { grep -qF 'FsMagicBcachefs:' "$linux"; }
has_priority() { awk '/^\t\t"bcachefs",$/ { found = 1 } END { exit !found }' "$linux"; }

has_const || sed -i \
    '/FsMagicZfs = FsMagic(0x2fc12fc1)/a\\t// FsMagicBcachefs filesystem id for bcachefs\n\tFsMagicBcachefs = FsMagic(0xca451a4e)' "$linux"
has_priority || sed -i '/^\t\t"btrfs",$/a\\t\t"bcachefs",' "$linux"
has_fsname || sed -i '/FsMagicBtrfs:.*"btrfs",/a\\t\tFsMagicBcachefs:    "bcachefs",' "$linux"

failed=()
has_const    || failed+=("FsMagicBcachefs constant")
has_priority || failed+=("Priority entry")
has_fsname   || failed+=("FsNames entry")

if [[ ${#failed[@]} -gt 0 ]]; then
    printf 'driver_linux.go: anchor did not match, edit not applied: %s\n' "${failed[@]}" >&2
    echo "upstream $linux likely changed formatting; fix the sed anchors" >&2
    exit 1
fi
